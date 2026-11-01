import Foundation
import Testing
@testable import RefWareCore

@Suite struct ClaimsListImportTests {
    let list = """
    # Claims Export

    ## C1
    > M. (2026).

    - In-text citation(s): (2026)

    ## C2
    > Developers took 19 percent longer with AI tools (Doe et al., 2025).

    - In-text citation(s): (Doe et al., 2025)

    ## C3
    > Spending reached \\$644 billion (Gartner, 2025; Zhang, 2025).

    - In-text citation(s): (Gartner, 2025); (Zhang, 2025)

    ## C4
    > Roe et al., 2023). Operational agility improves with portable records (Lee et al., 2024).

    - In-text citation(s): (Lee et al., 2024)
    """

    func library() throws -> Library {
        var lib = Library()
        try lib.add(Reference(id: 20, authors: [Author(family: "Doe", given: "J."), Author(family: "Roe", given: "K."), Author(family: "Poe", given: "L.")], year: 2025, title: "AI and developers"))
        try lib.add(Reference(id: 27, authors: [Author(family: "Gartner, Inc.", isOrganization: true)], year: 2025, title: "Forecast"))
        try lib.add(Reference(id: 9, authors: [Author(family: "Zhao", given: "J."), Author(family: "Zhang", given: "H.")], year: 2025, title: "Cochain"))
        try lib.add(Reference(id: 18, authors: [Author(family: "Lee", given: "Y."), Author(family: "Kim", given: "S."), Author(family: "Park", given: "J.")], year: 2024, title: "Records"))
        return lib
    }

    @Test func detectsTheFormat() {
        #expect(ClaimsListImporter.looksLikeClaimsList(list))
        #expect(!ClaimsListImporter.looksLikeClaimsList("**Me**: hi\n**Assistant**: claim [1]"))
    }

    @Test func linksCitationsAndFlagsFragments() throws {
        let r = ClaimsListImporter(file: "v4_claims.md").claims(from: list, library: try library(), firstID: 27)
        #expect(r.claims.map(\.id) == ["C27", "C28", "C29", "C30"])
        #expect(r.claims.map { $0.origin?.label } == ["C1", "C2", "C3", "C4"])
        #expect(r.claims[1].references == [20])
        #expect(r.claims[1].text == "Developers took 19 percent longer with AI tools (Doe et al., 2025).")
        #expect(r.claims[2].references == [27])                    // "Gartner" matches "Gartner, Inc."
        #expect(r.claims[2].text.contains("$644 billion"))         // markdown \\$ unescaped
        #expect(r.unresolved == ["C3: Zhang, 2025 — no record led by Zhang; a Zhang is a co-author of IDI 9 (Zhao, 2025)"])
        #expect(r.fragments == ["C1", "C4"])
        #expect(r.claims[0].flags == [.fragment])                  // too short, but not "uncited evidence"
        #expect(r.claims[3].references == [18])
    }
}

@Suite struct EvidenceFinderTests {
    let pages: PageLines = [
        ["Measuring the Impact of AI on Developer Productivity", "Abstract",
         "Before starting tasks, developers forecast that allowing AI will reduce completion",
         "time by 24%. After completing the study, developers estimate that allowing AI",
         "reduced completion time by 20%. Surprisingly, we find that allowing AI actually",
         "increases completion time by 19%—AI tooling slowed developers down."],
        ["Figures 19, 20, and 21 present breakdowns of developer time across activities in the study.",
         "Smith, J. (2020). Developers and tools. Journal of Things, 3(1), 1–9. https://doi.org/10.1/x"],
    ]
    let claim = "Experienced developers using AI tools took 19 percent longer to complete tasks, while reporting a 20 percent improvement in their own productivity (Becker et al., 2025)."

    @Test func ranksTheFindingFirstAndIgnoresFigureNumbersAndReferences() {
        let found = EvidenceFinder.passages(for: claim, in: pages)
        #expect(found.first?.page == 1)
        #expect(found.first?.numbers.sorted() == ["19", "20"])
        #expect(found.first?.text.contains("increases completion time by 19%") == true)
        #expect(!found.contains { $0.text.hasPrefix("Figures 19") && !$0.numbers.isEmpty })
        #expect(!found.contains { $0.text.contains("doi.org") })
    }

    @Test func candidatesVerifyAsQuotes() {
        for p in EvidenceFinder.passages(for: claim, in: pages) {
            guard case .found = QuoteVerifier.locate(p.text, in: pages) else { Issue.record("passage didn't verify: \(p.text)"); continue }
        }
    }

    @Test func yearsAreNotFindings() {
        #expect(EvidenceFinder.numbers(in: "In 2025, spending hit $644 billion (Gartner, 2025), up 76.4%.") == ["644", "76.4"])
    }
}
