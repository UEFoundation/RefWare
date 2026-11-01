import Foundation

/// Text-level view of a WordprocessingML part (document.xml, footnotes.xml…).
///
/// Word splits a paragraph's text across runs arbitrarily (`[IDI ` · `12` · `]`),
/// so edits are expressed against a paragraph's *plain text* and mapped back onto
/// the `<w:t>` nodes they touch. Everything outside those nodes — run formatting,
/// bookmarks, fields, drawings — is left exactly as it was.
struct WordXML {
    struct TextNode {
        /// Range of the whole `<w:t …>…</w:t>` element in the XML.
        var element: Range<String.Index>
        var text: String
    }

    struct Paragraph {
        /// Range of the whole `<w:p …>…</w:p>` element.
        var element: Range<String.Index>
        var nodes: [TextNode]
        var text: String { nodes.map(\.text).joined() }
    }

    let xml: String
    private(set) var paragraphs: [Paragraph] = []

    private static let tokenRE = try! NSRegularExpression(
        pattern: #"<w:p(?=[\s>])[^>]*?(/?)>|</w:p>|<w:t(?:\s[^>]*)?>([^<]*)</w:t>|<w:t(?:\s[^>]*)?/>"#)

    init(_ xml: String) {
        self.xml = xml
        var stack: [(start: String.Index, nodes: [TextNode])] = []
        for m in Self.tokenRE.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            guard let r = Range(m.range, in: xml) else { continue }
            let token = xml[r]
            if token.hasPrefix("<w:p") && !token.hasPrefix("<w:pP") {
                if Range(m.range(at: 1), in: xml).map({ !xml[$0].isEmpty }) == true {
                    paragraphs.append(Paragraph(element: r, nodes: [])) // <w:p/>
                } else {
                    stack.append((r.lowerBound, []))
                }
            } else if token == "</w:p>" {
                guard let open = stack.popLast() else { continue }
                paragraphs.append(Paragraph(element: open.start..<r.upperBound, nodes: open.nodes))
            } else if token.hasPrefix("<w:t") {
                let text = Range(m.range(at: 2), in: xml).map { Self.unescape(String(xml[$0])) } ?? ""
                if !stack.isEmpty { stack[stack.count - 1].nodes.append(TextNode(element: r, text: text)) }
            }
        }
        // Nested paragraphs (text boxes) close first; restore document order.
        paragraphs.sort { $0.element.lowerBound < $1.element.lowerBound }
    }

    // MARK: Editing

    /// A pending change: replace `[lower, upper)` of a paragraph's plain text.
    struct TextEdit {
        var paragraph: Int
        var range: Range<Int>
        var replacement: String
    }

    /// Applies text edits and whole-paragraph replacements; returns the new XML.
    /// Paragraph replacements take precedence over text edits in the same paragraph.
    func applying(_ edits: [TextEdit], replacingParagraphs: [Int: String] = [:]) -> String {
        var xmlEdits: [(Range<String.Index>, String)] = []
        for (p, newXML) in replacingParagraphs {
            xmlEdits.append((paragraphs[p].element, newXML))
        }
        let byParagraph = Dictionary(grouping: edits.filter { replacingParagraphs[$0.paragraph] == nil }, by: \.paragraph)
        for (p, list) in byParagraph {
            let nodes = paragraphs[p].nodes
            guard !nodes.isEmpty else { continue }
            // One pass over the paragraph's characters, each remembering its node.
            var chars: [Character] = [], owner: [Int] = []
            for (i, n) in nodes.enumerated() { for c in n.text { chars.append(c); owner.append(i) } }
            func node(at pos: Int) -> Int { pos < owner.count ? owner[pos] : nodes.count - 1 }

            var texts = Array(repeating: "", count: nodes.count)
            let sorted = list.sorted { $0.range.lowerBound < $1.range.lowerBound }
            var k = 0, pos = 0
            while pos < chars.count || k < sorted.count {
                if k < sorted.count, sorted[k].range.lowerBound <= pos {
                    // Replacement text inherits the formatting of the run where the edit starts.
                    texts[node(at: sorted[k].range.lowerBound)] += sorted[k].replacement
                    pos = max(pos, sorted[k].range.upperBound)
                    k += 1
                    continue
                }
                guard pos < chars.count else { break }
                texts[owner[pos]].append(chars[pos])
                pos += 1
            }
            for (i, n) in nodes.enumerated() where texts[i] != n.text {
                xmlEdits.append((n.element, "<w:t xml:space=\"preserve\">\(Self.escape(texts[i]))</w:t>"))
            }
        }
        var out = xml
        for (range, replacement) in xmlEdits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            out.replaceSubrange(range, with: replacement)
        }
        return out
    }

    // MARK: Building paragraphs

    /// `<w:pPr>…</w:pPr>` of a paragraph, if any.
    func paragraphProperties(_ p: Int) -> String? {
        let el = xml[paragraphs[p].element]
        guard let r = el.range(of: #"<w:pPr>.*?</w:pPr>|<w:pPr/>"#, options: .regularExpression) else { return nil }
        return String(el[r])
    }

    /// `<w:rPr>…</w:rPr>` of the run holding the paragraph's first text.
    func firstRunProperties(_ p: Int) -> String? {
        guard let node = paragraphs[p].nodes.first else { return nil }
        let before = xml[paragraphs[p].element.lowerBound..<node.element.lowerBound]
        guard let runStart = before.range(of: #"<w:r(?=[\s>])"#, options: [.regularExpression, .backwards]) else { return nil }
        let run = before[runStart.lowerBound...]
        guard let r = run.range(of: #"<w:rPr>.*?</w:rPr>"#, options: .regularExpression) else { return nil }
        return String(run[r])
    }

    /// Builds a paragraph from `*italic*`-marked text, reusing paragraph and run
    /// properties. Section breaks (`w:sectPr`) are never copied.
    static func paragraph(markdown: String, pPr: String?, rPr: String?, hangingIndent: Bool) -> String {
        var props = (pPr ?? "<w:pPr></w:pPr>").replacingOccurrences(of: #"<w:sectPr[\s>].*?</w:sectPr>"#, with: "", options: .regularExpression)
        if props == "<w:pPr/>" { props = "<w:pPr></w:pPr>" }
        if hangingIndent && !props.contains("<w:ind ") {
            props = insertIndent(into: props)
        }
        var runs = ""
        for (i, piece) in markdown.components(separatedBy: "*").enumerated() where !piece.isEmpty {
            let italic = i % 2 == 1
            runs += "<w:r>\(italic ? withItalic(rPr) : (rPr ?? ""))<w:t xml:space=\"preserve\">\(escape(piece))</w:t></w:r>"
        }
        return "<w:p>\(props)\(runs)</w:p>"
    }

    /// `w:ind` must sit after `w:spacing` and before `w:jc` etc. (schema order).
    static func insertIndent(into pPr: String) -> String {
        let indent = "<w:ind w:left=\"720\" w:hanging=\"720\"/>"
        var s = pPr
        if let r = s.range(of: #"<w:spacing[^>]*/>|<w:spacing[^>]*>.*?</w:spacing>"#, options: .regularExpression) {
            s.insert(contentsOf: indent, at: r.upperBound)
            return s
        }
        let later = ["<w:contextualSpacing", "<w:mirrorIndents", "<w:suppressOverlap", "<w:jc", "<w:textDirection", "<w:textAlignment",
                     "<w:textboxTightWrap", "<w:outlineLvl", "<w:divId", "<w:cnfStyle", "<w:rPr", "<w:sectPr", "<w:pPrChange", "</w:pPr>"]
        let at = later.compactMap { s.range(of: $0)?.lowerBound }.min() ?? s.endIndex
        s.insert(contentsOf: indent, at: at)
        return s
    }

    /// `w:i` goes after `w:rStyle`, `w:rFonts`, `w:b`, `w:bCs` (schema order).
    static func withItalic(_ rPr: String?) -> String {
        guard var s = rPr, s.hasPrefix("<w:rPr>") else { return "<w:rPr><w:i/><w:iCs/></w:rPr>" }
        if s.contains("<w:i/>") || s.contains("<w:i ") { return s }
        var at = s.index(s.startIndex, offsetBy: "<w:rPr>".count)
        for tag in [#"<w:rStyle[^>]*/>"#, #"<w:rFonts[^>]*/>"#, #"<w:b/>|<w:b [^>]*/>"#, #"<w:bCs/>|<w:bCs [^>]*/>"#] {
            if let r = s.range(of: tag, options: .regularExpression), r.upperBound > at { at = r.upperBound }
        }
        s.insert(contentsOf: "<w:i/><w:iCs/>", at: at)
        return s
    }

    // MARK: Escaping

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return TextCleanup.decodeEntities(s)
    }
}
