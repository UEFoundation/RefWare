import Foundation
import Testing
@testable import RefWareCore

@Suite struct TagParserTests {
    @Test(arguments: [
        ("[IDI 12]", RefTag.cite([12], locator: nil)),
        ("[IDI #12]", .cite([12], locator: nil)),
        ("[IDI-12]", .cite([12], locator: nil)),
        ("[idi 12]", .cite([12], locator: nil)),
        ("[IDI 12, 7]", .cite([12, 7], locator: nil)),
        ("[IDI 12; IDI 7]", .cite([12, 7], locator: nil)),
        ("[IDI 12, p. 4]", .cite([12], locator: "p. 4")),
        ("[IDI 12, pp. 4-6]", .cite([12], locator: "pp. 4–6")),
        ("[IDI # - ALLREF]", .allReferences),
        ("[IDI-ALLREF]", .allReferences),
        ("[IDI ALLREF]", .allReferences),
    ])
    func parses(source: String, expected: RefTag) {
        #expect(TagParser.parse(source) == expected)
    }

    @Test(arguments: ["[IDI]", "[IDI abc]", "[IDI 12, 7, p. 4]", "[IDI p. 4]", "[IDI 3, p. 4, 5]"])
    func rejects(source: String) {
        #expect(TagParser.parse(source) == nil)
    }

    @Test func scanReportsLines() {
        let (tags, bad) = TagParser.scan("one [IDI 1]\ntwo\nthree [IDI oops] [IDI 2]")
        #expect(tags.map(\.line) == [1, 3])
        #expect(bad == [MalformedTag(source: "[IDI oops]", line: 3)])
    }

    @Test func ignoresOrdinaryBrackets() {
        #expect(TagParser.scan("see [1] and [IDIOM]").tags.isEmpty)
        #expect(TagParser.scan("see [1] and [IDIOM]").malformed.isEmpty)
    }
}

@Suite struct DocumentProcessorTests {
    @Test func replacesTagsAndBuildsReferenceList() throws {
        let doc = """
        Models drift [IDI 2]. Coherence emerges [IDI 1, 3], as quoted [IDI 1, p. 50].

        References
        [IDI # - ALLREF]
        """
        // IDI 4 (the other Smith 2020) is in the library but not cited — no a/b suffix, not listed.
        let result = try DocumentProcessor(library: Fixtures.library).process(doc)
        #expect(result.cited == [2, 1, 3])
        #expect(result.text == """
        Models drift (Jones & Lee, 2019). Coherence emerges (Adams et al., 2021; Smith, 2020), as quoted (Smith, 2020, p. 50).

        References
        Adams, R., Baker, S., & Chen, T. (2021). Citation hallucination rates? Nature, 590.
        Jones, K., & Lee, M.-J. (2019). Calibration under distribution shift. NeurIPS Proceedings. https://example.org/paper
        Smith, J. A. (2020). Emergent coherence in language models. Journal of AI Research, 12(3), 45–67. https://doi.org/10.1000/JAIR.2020.1
        """)
    }

    @Test func unknownIDIBlocksAllOutput() {
        let doc = "ok [IDI 1]\nbad [IDI 99]\nworse [IDI ?]"
        do {
            _ = try DocumentProcessor(library: Fixtures.library).process(doc)
            Issue.record("expected failure")
        } catch {
            #expect(error.issues.map(\.kind) == [.unknownIDI(99), .malformedTag])
            #expect(error.issues.map(\.line) == [2, 3])
        }
    }

    @Test func requireVerifiedRejectsUnverified() {
        #expect(throws: ProcessingError.self) {
            try DocumentProcessor(library: Fixtures.library, requireVerified: true).process("[IDI 1]")
        }
    }

    @Test func textWithoutTagsIsUnchanged() throws {
        let s = "Nothing to cite here. [1] (Smith, 2020)"
        #expect(try DocumentProcessor(library: Fixtures.library).process(s).text == s)
    }
}

@Suite struct LibraryTests {
    @Test func roundTrip() throws {
        var lib = Fixtures.library
        lib.projects["UEF-0001"] = ProjectCitationIndex(project: "UEF-0001", references: [1], quotes: [
            QuoteRecord(label: "Q1", reference: 1, text: "coherence emerges", page: 3, line: 12, verified: true),
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("refware-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try lib.save(to: url)

        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(json.contains(#""references" : ["#)) // array, not a flat key/value list

        let loaded = try Library.load(from: url)
        #expect(loaded.references == lib.references)
        #expect(loaded.projects == lib.projects)
        #expect(loaded.nextIDI == 5)
    }

    @Test func rejectsDuplicateDOI() {
        var lib = Fixtures.library
        let dup = Reference(id: 50, authors: [], year: 2020, title: "dup", doi: "doi:10.1000/jair.2020.1")
        #expect(throws: LibraryError.duplicateDOI("10.1000/jair.2020.1", existing: 1)) { try lib.add(dup) } // case-insensitive
    }

    @Test func rejectsDuplicateIDI() {
        var lib = Fixtures.library
        #expect(throws: LibraryError.duplicateIDI(1)) { try lib.add(Fixtures.smith2020) }
    }

    @Test func missingFileIsEmptyLibrary() throws {
        let lib = try Library.load(from: URL(fileURLWithPath: "/nonexistent/refware.json"))
        #expect(lib.references.isEmpty)
        #expect(lib.nextIDI == 1)
    }
}

@Suite struct DOITests {
    @Test func normalize() {
        #expect(DOI.normalize("https://doi.org/10.1038/ABC") == "10.1038/ABC")
        #expect(DOI.same("10.1038/ABC", "https://doi.org/10.1038/abc"))
        #expect(DOI.normalize("doi: 10.1038/abc") == "10.1038/abc")
        #expect(DOI.normalize("not a doi") == nil)
    }

    @Test func findInURL() {
        #expect(DOI.find(in: "https://www.nature.com/articles/10.1038/s41586-021-03819-2.") == "10.1038/s41586-021-03819-2")
        #expect(DOI.find(in: "https://arxiv.org/abs/2106.01234") == nil)
    }
}

@Suite struct NarrativeTagTests {
    @Test func parses() {
        #expect(TagParser.parse("[IDI 12, narrative]") == .narrative(12, locator: nil))
        #expect(TagParser.parse("[IDI 12, Narrative, p. 4]") == .narrative(12, locator: "p. 4"))
        #expect(TagParser.parse("[IDI 12, 7, narrative]") == nil)
        #expect(TagParser.parse("[IDI narrative, 12]") == nil)
    }

    @Test func renders() throws {
        let doc = "As [IDI 2, narrative] and [IDI 3, narrative, p. 9] show, and [IDI 1, narrative] agrees."
        let out = try DocumentProcessor(library: Fixtures.library).process(doc).text
        #expect(out == "As Jones and Lee (2019) and Adams et al. (2021, p. 9) show, and Smith (2020) agrees.")
    }
}
