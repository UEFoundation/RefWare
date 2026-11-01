import Foundation
import Testing
@testable import RefWareCore

enum DocxFixture {
    static let w = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main""#

    static func make(body: String, footnotes: String? = nil, extra: [String: Data] = [:]) throws -> Data {
        var zip = try ZipArchive(data: emptyZip())
        try zip.set("[Content_Types].xml", Data(#"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>"#.utf8))
        try zip.set("word/document.xml", Data("<?xml version=\"1.0\"?><w:document \(w)><w:body>\(body)</w:body></w:document>".utf8))
        if let footnotes { try zip.set("word/footnotes.xml", Data("<w:footnotes \(w)>\(footnotes)</w:footnotes>".utf8)) }
        for (k, v) in extra { try zip.set(k, v) }
        return zip.serialized()
    }

    static func emptyZip() -> Data {
        Data([0x50, 0x4b, 0x05, 0x06] + Array(repeating: 0, count: 18))
    }

    static func xml(_ docx: Data, _ part: String = "word/document.xml") throws -> String {
        String(decoding: try #require(try ZipArchive(data: docx).data(part)), as: UTF8.self)
    }

    static func text(_ docx: Data) throws -> [String] {
        WordXML(try xml(docx)).paragraphs.map(\.text)
    }
}

@Suite struct ZipTests {
    @Test func roundTripAndIdenticalUntouchedEntries() throws {
        let image = Data((0..<5000).map { UInt8($0 % 251) })
        let docx = try DocxFixture.make(body: "<w:p><w:r><w:t>Hello</w:t></w:r></w:p>", extra: ["word/media/image1.png": image])
        let zip = try ZipArchive(data: docx)
        #expect(try zip.data("word/media/image1.png") == image)
        let again = try ZipArchive(data: zip.serialized())
        #expect(again.names == zip.names)
        #expect(again.serialized() == zip.serialized())
    }

    @Test func crc() {
        #expect(ZipArchive.crc32(Data("The quick brown fox jumps over the lazy dog".utf8)) == 0x414F_A339)
    }
}

@Suite struct DocxCiterTests {
    @Test func tagSplitAcrossRunsKeepsFormatting() throws {
        let body = """
        <w:p><w:pPr><w:pStyle w:val="Body"/></w:pPr>\
        <w:r><w:t xml:space="preserve">Shown before </w:t></w:r>\
        <w:r><w:rPr><w:b/></w:rPr><w:t>[IDI </w:t></w:r><w:proofErr w:type="spellStart"/>\
        <w:r><w:t>2</w:t></w:r><w:bookmarkStart w:id="0" w:name="x"/><w:r><w:t>]</w:t></w:r>\
        <w:r><w:t>, and by [IDI 1, narrative].</w:t></w:r></w:p>
        """
        let out = try DocxCiter(library: Fixtures.library).process(try DocxFixture.make(body: body))
        #expect(try DocxFixture.text(out.data) == ["Shown before (Jones & Lee, 2019), and by Smith (2020)."])
        let xml = try DocxFixture.xml(out.data)
        #expect(xml.contains(#"<w:rPr><w:b/></w:rPr><w:t xml:space="preserve">(Jones &amp; Lee, 2019)</w:t>"#)) // escaped, in the bold run
        #expect(xml.contains(#"<w:bookmarkStart w:id="0" w:name="x"/>"#))
        #expect(out.citationsReplaced == 2)
        #expect(out.cited == [2, 1])
    }

    @Test func allRefBecomesStyledHangingIndentParagraphs() throws {
        let body = """
        <w:p><w:r><w:t>Cites [IDI 3] and [IDI 1].</w:t></w:r></w:p>\
        <w:p><w:pPr><w:pStyle w:val="Bibliography"/><w:spacing w:after="120"/><w:jc w:val="left"/></w:pPr>\
        <w:r><w:rPr><w:rFonts w:ascii="Georgia"/><w:sz w:val="22"/></w:rPr><w:t>[IDI # - ALLREF]</w:t></w:r></w:p>\
        <w:p><w:r><w:t>After.</w:t></w:r></w:p><w:sectPr/>
        """
        let out = try DocxCiter(library: Fixtures.library).process(try DocxFixture.make(body: body))
        let paras = try DocxFixture.text(out.data)
        #expect(paras == [
            "Cites (Adams et al., 2021) and (Smith, 2020).",
            "Adams, R., Baker, S., & Chen, T. (2021). Citation hallucination rates? Nature, 590.",
            "Smith, J. A. (2020). Emergent coherence in language models. Journal of AI Research, 12(3), 45–67. https://doi.org/10.1000/JAIR.2020.1",
            "After.",
        ])
        let xml = try DocxFixture.xml(out.data)
        // Style kept; indent inserted after spacing, before jc (schema order).
        #expect(xml.contains(#"<w:pStyle w:val="Bibliography"/><w:spacing w:after="120"/><w:ind w:left="720" w:hanging="720"/><w:jc w:val="left"/>"#))
        // Journal and volume italic, in the original font.
        #expect(xml.contains(#"<w:rPr><w:rFonts w:ascii="Georgia"/><w:i/><w:iCs/><w:sz w:val="22"/></w:rPr><w:t xml:space="preserve">Journal of AI Research</w:t>"#))
        #expect(out.referenceListEntries == 2)
        #expect(out.unverified == [3, 1]) // fixtures have no provenance
    }

    @Test func unknownIDIRefusesWholeDocument() throws {
        let docx = try DocxFixture.make(body: "<w:p><w:r><w:t>ok [IDI 1]</w:t></w:r></w:p><w:p><w:r><w:t>bad [IDI 99]</w:t></w:r></w:p>")
        #expect(throws: ProcessingError.self) { try DocxCiter(library: Fixtures.library).process(docx) }
    }

    @Test func footnotesAreProcessedAndOtherPartsUntouched() throws {
        let image = Data(repeating: 7, count: 3000)
        let docx = try DocxFixture.make(body: "<w:p><w:r><w:t>Body.</w:t></w:r></w:p>",
                                        footnotes: "<w:footnote w:id=\"1\"><w:p><w:r><w:t>See [IDI 1, p. 4].</w:t></w:r></w:p></w:footnote>",
                                        extra: ["word/media/fig.png": image])
        let out = try DocxCiter(library: Fixtures.library).process(docx)
        #expect(try DocxFixture.xml(out.data, "word/footnotes.xml").contains("See (Smith, 2020, p. 4)."))
        let before = try ZipArchive(data: docx), after = try ZipArchive(data: out.data)
        #expect(after.names == before.names)
        #expect(try after.data("word/document.xml") == before.data("word/document.xml")) // no tags → untouched
        #expect(try after.data("word/media/fig.png") == image)
    }

    @Test func textBoxParagraphsAreSeparate() throws {
        let body = """
        <w:p><w:r><w:t>Outer [IDI 1]</w:t></w:r><w:r><w:pict><w:txbxContent>\
        <w:p><w:r><w:t>Inner [IDI 2]</w:t></w:r></w:p></w:txbxContent></w:pict></w:r></w:p>
        """
        let out = try DocxCiter(library: Fixtures.library).process(try DocxFixture.make(body: body))
        let xml = try DocxFixture.xml(out.data)
        #expect(xml.contains("Outer (Smith, 2020)"))
        #expect(xml.contains("Inner (Jones &amp; Lee, 2019)"))
    }
}

@Suite struct DocxTaggerTests {
    static let entries = [
        "Jones, K., & Lee, M.-J. (2019). Calibration under distribution shift. NeurIPS Proceedings.",
        "Smith, J. A. (2020). Emergent coherence in language models. Journal of AI Research, 12(3), 45-67.",
        "World Health Organization. (2024). Guidance on large multi-modal models. https://who.int/x",
        "Zhao, J., Xie, H., & Zhang, H. (2025). Cochain. arXiv.",
    ]

    func manuscript() throws -> Data {
        func p(_ t: String, style: String? = nil) -> String {
            "<w:p>\(style.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? "")<w:r><w:t xml:space=\"preserve\">\(WordXML.escape(t))</w:t></w:r></w:p>"
        }
        let body = [
            p("Calibration drifts (Jones & Lee, 2019; Smith, 2020), as Smith (2020, p. 4) notes."),
            p("Guidance exists (WHO, 2024). Alignment trades off diversity (Zhang et al., 2025)."),
            p("A page in a group (Smith, 2020, p. 3; Jones & Lee, 2019)."),
            p("References", style: "Heading1"),
            p("Core Reasoning", style: "Heading2"),
        ] + Self.entries.map { p($0, style: "Bibliography") } + [p("Credits and Attributions", style: "Heading1")]
        return try DocxFixture.make(body: body.joined() + "<w:sectPr/>")
    }

    let ids = Dictionary(uniqueKeysWithValues: entries.enumerated().map { (DocxTagger.key(forEntry: $1), $0 + 1) })

    @Test func convertsOnlyExactMatchesAndReplacesTheList() throws {
        let (data, report) = try DocxTagger(entryIDs: ids).tag(try manuscript())
        let paras = try DocxFixture.text(data)
        #expect(paras[0] == "Calibration drifts [IDI 1, 2], as [IDI 2, narrative, p. 4] notes.")
        // WHO matches by acronym; Zhang is only a co-author of Zhao → left alone.
        #expect(paras[1] == "Guidance exists [IDI 3]. Alignment trades off diversity (Zhang et al., 2025).")
        #expect(paras[2] == "A page in a group (Smith, 2020, p. 3; Jones & Lee, 2019).")
        #expect(Array(paras[3...]) == ["References", "[IDI # - ALLREF]", "Credits and Attributions"])
        #expect(report.converted == 3)
        #expect(report.skipped.map(\.reason) == ["Zhang et al., 2025: no entry by Zhang in 2025", "page locator inside a multi-work citation — tag by hand"])
        #expect(report.referenceListReplaced)
        #expect(try DocxFixture.xml(data).contains(#"<w:pStyle w:val="Bibliography"/></w:pPr><w:r><w:t xml:space="preserve">[IDI # - ALLREF]"#))
    }

    @Test func listKeptWhenAnEntryIsMissingFromTheLibrary() throws {
        var partial = ids
        partial.removeValue(forKey: DocxTagger.key(forEntry: Self.entries[3]))
        let (data, report) = try DocxTagger(entryIDs: partial).tag(try manuscript())
        #expect(!report.referenceListReplaced)
        #expect(report.unmappedEntries == [Self.entries[3]])
        #expect(try DocxFixture.text(data).contains(Self.entries[0]))
    }

    @Test func tagThenCiteRoundTrip() throws {
        var lib = Library()
        try lib.add(Reference(id: 1, authors: [Author(family: "Jones", given: "K."), Author(family: "Lee", given: "M.-J.")], year: 2019, title: "Calibration under distribution shift", publication: "NeurIPS Proceedings"))
        try lib.add(Reference(id: 2, authors: [Author(family: "Smith", given: "J. A.")], year: 2020, title: "Emergent coherence in language models", publication: "Journal of AI Research", indexing: .init(volume: "12", issue: "3", pages: "45-67")))
        try lib.add(Reference(id: 3, authors: [Author(family: "World Health Organization", isOrganization: true)], year: 2024, title: "Guidance on large multi-modal models", url: "https://who.int/x"))
        try lib.add(Reference(id: 4, authors: [Author(family: "Zhao", given: "J."), Author(family: "Xie", given: "H."), Author(family: "Zhang", given: "H.")], year: 2025, title: "Cochain", publication: "arXiv"))
        let tagged = try DocxTagger(entryIDs: ids).tag(try manuscript()).data
        let out = try DocxCiter(library: lib).process(tagged)
        let paras = try DocxFixture.text(out.data)
        #expect(paras[0] == "Calibration drifts (Jones & Lee, 2019; Smith, 2020), as Smith (2020, p. 4) notes.")
        #expect(paras[1] == "Guidance exists (World Health Organization, 2024). Alignment trades off diversity (Zhang et al., 2025).")
        // Only the works actually cited appear (Zhao isn't cited by a tag).
        #expect(Array(paras[4...6]) == [
            "Jones, K., & Lee, M.-J. (2019). Calibration under distribution shift. NeurIPS Proceedings.",
            "Smith, J. A. (2020). Emergent coherence in language models. Journal of AI Research, 12(3), 45–67.",
            "World Health Organization. (2024). Guidance on large multi-modal models. https://who.int/x",
        ])
        #expect(paras[7] == "Credits and Attributions")
    }
}
