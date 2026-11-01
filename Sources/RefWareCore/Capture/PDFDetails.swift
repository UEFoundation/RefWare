import Foundation
import PDFKit

/// Bibliographic details a PDF states about itself: its document properties
/// (Title, Author, creation date) and, where those are empty or junk, its first
/// page. Reports and white papers (no DOI, no registry record) often only have this.
public enum PDFDetails {
    public static func read(_ url: URL) -> ResolvedMetadata? {
        guard let doc = PDFDocument(url: url) else { return nil }
        let attrs = doc.documentAttributes ?? [:]
        let pages = (try? PDFText.pages(of: url)) ?? []
        let firstLines = (pages.first ?? []).prefix(12).map { $0.trimmingCharacters(in: .whitespaces) }

        var title = (attrs[PDFDocumentAttribute.titleAttribute] as? String).map(TextCleanup.clean) ?? ""
        if isJunkTitle(title) || isArXivStamp(title) {
            // First substantial line on page 1.
            title = firstLines.first { l in
                let w = l.split(separator: " ").count
                return w >= 3 && w <= 24 && l.rangeOfCharacter(from: .letters) != nil && !l.lowercased().hasPrefix("http") && !isNavigation(l) && !isArXivStamp(l)
            } ?? ""
        }
        guard !title.isEmpty else { return nil }

        var authors: [Author] = []
        if let raw = attrs[PDFDocumentAttribute.authorAttribute] as? String, !isJunkAuthor(raw) {
            authors = raw.replacingOccurrences(of: #"\s+and\s+|;"#, with: ",", options: .regularExpression)
                .components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 1 }
                .map { name in name.contains(" ") ? WebMetadataReader.parseName(name) : Author(family: name, isOrganization: true) }
        }

        let head = firstLines.joined(separator: " ")
        // What the document says about itself beats the file's creation date — which, for a
        // web snapshot, is merely the day it was captured.
        var year = statedYear(in: Array(pages.prefix(5))) ?? title.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression).flatMap { Int(title[$0]) }
        if year == nil, !url.lastPathComponent.contains("_web-") {
            let created = (attrs[PDFDocumentAttribute.creationDateAttribute] as? Date) ?? (attrs[PDFDocumentAttribute.modificationDateAttribute] as? Date)
            year = created.map { Calendar(identifier: .gregorian).component(.year, from: $0) }
        }

        var m = ResolvedMetadata(authors: authors, year: year, title: title, doi: DOI.find(in: head),
                                 source: .manual, lookupKey: url.lastPathComponent)
        m.yearsSeen = year.map { [$0] } ?? []
        return m
    }

    /// The year the document states on its first pages, most explicit first:
    /// a "Suggested citation", a © line, a "Published …" line, then an arXiv side stamp's date.
    static func statedYear(in pages: PageLines) -> Int? {
        let lines = pages.flatMap { $0 }.map { $0.trimmingCharacters(in: .whitespaces) }
        func years(_ s: String) -> [Int] {
            s.matches(of: /\b(?:19|20)\d{2}\b/).compactMap { Int(s[$0.range]) }.filter { $0 <= Calendar.current.component(.year, from: Date()) + 1 }
        }
        if let i = lines.firstIndex(where: { $0.lowercased().contains("suggested citation") }) {
            if let y = years(lines[i..<min(i + 4, lines.count)].joined(separator: " ")).first { return y }
        }
        for l in lines where l.contains("©") || l.lowercased().hasPrefix("copyright") || l.lowercased().contains("(c) ") {
            if let y = years(l).max() { return y }
        }
        for l in lines where l.lowercased().hasPrefix("published") || l.lowercased().contains("first published") {
            if let y = years(l).first { return y }
        }
        for l in lines where isArXivStamp(l) {
            if let y = years(l.replacingOccurrences(of: #"arXiv:\S+"#, with: "", options: .regularExpression)).first { return y }
        }
        return nil
    }

    /// The arXiv side stamp: "arXiv:2203.11171v4 [cs.CL] 7 Mar 2023".
    static func isArXivStamp(_ line: String) -> Bool {
        line.range(of: #"^\s*arXiv:\s*\d{4}\.\d{4,5}(v\d+)?\s*\[[\w.-]+\]"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "Microsoft Word - draft3.docx", "untitled", file names…
    static func isJunkTitle(_ t: String) -> Bool {
        let l = t.lowercased().trimmingCharacters(in: .whitespaces)
        return l.isEmpty || l.count < 6 || l.hasPrefix("microsoft word") || l.hasPrefix("untitled") || l.hasPrefix("powerpoint")
            || l.range(of: #"\.(docx?|pptx?|indd|pdf|tex)$"#, options: .regularExpression) != nil
            || l.range(of: #"^[\w-]+$"#, options: .regularExpression) != nil && !l.contains(" ")
    }

    /// Web-page chrome that a snapshot's first lines are full of.
    static func isNavigation(_ line: String) -> Bool {
        let l = line.lowercased()
        return ["skip to main content", "skip to content", "skip navigation", "sign in", "log in", "menu", "search", "subscribe",
                "cookie", "accept all", "toggle navigation", "home ", "back to"].contains { l.contains($0) }
    }

    /// Software names and placeholders that end up in the Author field.
    static func isJunkAuthor(_ a: String) -> Bool {
        let l = a.lowercased()
        // "Microsoft" can be a real author (reports); "Microsoft Office User" is Word's placeholder.
        return l.isEmpty || ["microsoft office user", "adobe", "user", "admin", "owner", "author", "unknown", "acrobat", "indesign", "word"]
            .contains { l == $0 || (l.hasPrefix($0 + " ") && l.count < 18) }
    }
}
