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
