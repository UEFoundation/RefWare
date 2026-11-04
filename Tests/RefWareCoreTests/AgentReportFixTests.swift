import Foundation
import Testing
@testable import RefWareCore

@Suite struct AgentReportFixTests {
    @Test func splitterKeepsCitationsAndAbbreviationsTogether() {
        let s = ManuscriptAudit.sentences("Pilots stalled (cf. Smith, 2020; Dr. Lee, 2021). See Fig. 2. for details. Next one (WHO, 2024; WEF, 2025).")
        #expect(s == ["Pilots stalled (cf. Smith, 2020; Dr. Lee, 2021).", "See Fig. 2. for details.", "Next one (WHO, 2024; WEF, 2025)."])
    }

    @Test func possessiveNarrative() throws {
        var lib = Library()
        try lib.add(Reference(id: 1, authors: [Author(family: "Smith", given: "J.")], year: 2020, title: "One"))
        #expect(TagParser.parse("[IDI 1, possessive]") == .possessive(1, locator: nil))
        #expect(try DocumentProcessor(library: lib).process("[IDI 1, possessive] model.").text == "Smith’s (2020) model.")
    }

    @Test func tagsInsideHTMLCommentsAreIgnored() throws {
        var lib = Library()
        try lib.add(Reference(id: 1, authors: [Author(family: "Smith", given: "J.")], year: 2020, title: "One"))
        let out = try DocumentProcessor(library: lib).process("Text [IDI 1]. <!-- todo: [IDI 99, broken -->")
        #expect(out.text.hasPrefix("Text (Smith, 2020)."))
        #expect(out.cited == [1])
    }

    @Test func importedClaimsAreDeduplicatedByText() {
        var index = ProjectCitationIndex(project: "UEF-T", claims: [Claim(id: "C1", text: "Pilots stall — often.")])
        let r = index.addClaims([Claim(id: "C9", text: "pilots stall, often"), Claim(id: "C10", text: "A new claim.")])
        #expect(r.existing.map(\.id) == ["C1"])
        #expect(r.added.map(\.id) == ["C2"])
    }

    @Test func statedYearBeatsFileDates() {
        #expect(PDFDetails.statedYear(in: [["Report"], ["", "© World Health Organization 2024", "Suggested citation. Ethics of AI. Geneva: WHO; 2024."]]) == 2024)
        #expect(PDFDetails.statedYear(in: [["arXiv:2203.11171v4 [cs.CL] 7 Mar 2023", "Self-Consistency"]]) == 2023)
        #expect(PDFDetails.isArXivStamp("arXiv:2203.11171v4 [cs.CL] 7 Mar 2023"))
        #expect(!PDFDetails.isArXivStamp("Self-Consistency Improves Chain of Thought"))
    }

    @Test func changedDetailsExpireChecksAndDistinctMarks() throws {
        var lib = Library()
        var p = Provenance(source: .manual, key: "x", retrieved: Date(), verified: false)
        p.confirmedBy = "SMH"
        try lib.add(Reference(id: 1, authors: [Author(family: "Anthropic", isOrganization: true)], year: 2023, title: "Claude's Constitution", provenance: p))
        try lib.add(Reference(id: 2, authors: [Author(family: "Anthropic", isOrganization: true)], year: 2026, title: "Claude's Constitution"))
        lib.markDistinct([1, 2])
        #expect(lib.likelyDuplicates().isEmpty)
        var r = lib[1]!
        r.year = 2026
        try lib.update(r)
        #expect(lib[1]?.provenance?.confirmedBy == nil)
        #expect(lib.likelyDuplicates() == [[1, 2]])
    }
}

@Suite struct CitationMatrixTests {
    let matrix = """
    **Gemini**: Here is a slide-by-slide citation matrix.
    ### **Slide 5–6: The ROI Gap**

    * **Claim:** Despite massive capital investment, enterprise ROI remains elusive.
    * **Citations:**
      * **Solow, R. (1987).** *We'd better watch out.* New York Times Book Review.
        * *Why:* The original formulation of the productivity paradox.
      * **Deloitte Global (2025).** *AI ROI: The Paradox of Rising Investment and Elusive Returns.* Deloitte Research.
        * *Why:* Empirical backing: 85%+ of organizations increased AI spending.
      * **Stanford HAI (2025).** *Artificial Intelligence Index Report 2025.* Stanford University.
        * *Why:* Gains vanish end to end.

    **Gemini**:
    # Selected References & Bibliography
    ### Primary Academic & Industry Citations
    * **Deloitte Global.** (2025). *AI ROI: The Paradox of Rising Investment and Elusive Returns*. Deloitte Research.
    * **Solow, R.** (1987). We'd better watch out. *New York Times Book Review*, 36.
    ### Collaborative Attribution Entry
    * **Collaborator:** Gemini
    """

    @Test func recognizedAndSplitIntoClaims() throws {
        #expect(CitationMatrixImporter.looksLikeCitationMatrix(matrix))
        #expect(!ClaimsListImporter.looksLikeClaimsList(matrix))
        var lib = Library()
        try lib.add(Reference(id: 1, authors: [Author(family: "Solow", given: "R.")], year: 1987, title: "We'd better watch out"))
        try lib.add(Reference(id: 2, authors: [Author(family: "Deloitte Global", isOrganization: true)], year: 2025, title: "Some other Deloitte report"))
        try lib.add(Reference(id: 3, authors: [Author(family: "Stanford Institute for Human-Centered Artificial Intelligence (HAI)", isOrganization: true)], year: 2025,
                              title: "Artificial Intelligence Index Report 2025"))
        let r = CitationMatrixImporter(file: "m.txt").claims(from: matrix, library: lib, firstID: 1)
        #expect(r.claims.count == 2)                       // the slide claim + the 85% figure
        let slide = r.claims[0]
        #expect(slide.origin?.label == "Slide 5–6: The ROI Gap")
        #expect(slide.references == [1, 3])                // Deloitte: same org and year, different title → not linked
        #expect(slide.note?.contains("Solow (1987): The original formulation") == true)
        #expect(r.claims[1].text.hasPrefix("Deloitte Global (2025): Empirical backing: 85%+"))
        #expect(r.unresolved.count == 1)
    }

    @Test func bibliographyHeadingAndMarkdownEntries() {
        let parsed = ManuscriptParser.parse(matrix)
        #expect(parsed.entries.count == 2)
        #expect(parsed.entries.first?.authors.first?.family == "Deloitte Global")
        #expect(parsed.entries.last?.title == "We'd better watch out")
    }
}

@Suite struct AdoptKeepsWhatItDoesNotStateTests {
    @Test func webPageWithoutBylineKeepsTheAuthor() throws {
        var lib = Library()
        var r = Reference(id: 1, authors: [Author(family: "Deloitte Global", isOrganization: true)], year: 2025, title: "AI ROI")
        r.pdfSHA256 = "abc"
        r.publicationType = .report
        try lib.add(r)
        let page = ResolvedMetadata(authors: [], year: nil, title: "AI ROI: The paradox of rising investment and elusive returns",
                                    publication: "Deloitte", source: .webPage, lookupKey: "https://www.deloitte.com/x")
        try lib.adopt(page, for: 1, verified: false, pdfDirectory: nil)
        let after = lib[1]!
        #expect(after.authors.first?.family == "Deloitte Global")
        #expect(after.year == 2025)
        #expect(after.title == "AI ROI: The paradox of rising investment and elusive returns")
        #expect(after.pdfSHA256 == "abc")
        #expect(after.publicationType == .report)
    }
}

@Suite struct PrintedBylineTests {
    @Test func bylinesAreRead() {
        let run = PDFDetails.printedAuthors(in: ["Research 22 Oct 2025", "Authors: Jan Michalski Stacey Winters Douglas Gunn Jennifer Holland"])
        #expect(run.map(\.family) == ["Michalski", "Winters", "Gunn", "Holland"])
        #expect(PDFDetails.printedAuthors(in: ["By Ada Lovelace and Charles Babbage"]).map(\.family) == ["Lovelace", "Babbage"])
        #expect(PDFDetails.printedAuthors(in: ["By the numbers: AI in 2025"]).isEmpty)
        #expect(PDFDetails.printedAuthors(in: ["Authors: Jan Michalski Stacey"]).isEmpty)   // odd count: don't guess
    }
}
