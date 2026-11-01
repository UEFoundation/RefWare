import Foundation
import Testing
@testable import RefWareCore

/// A synthetic research chat (Fixtures/sample-transcript.txt) exercising every
/// import feature: per-turn footnotes, duplicate links, unlinked titles, an
/// attributed quotation, a mistitled source, uncited evidence, self-citation.
@Suite struct SampleTranscriptTests {
    let claims: [Claim]

    init() throws {
        let url = try #require(Bundle.module.url(forResource: "sample-transcript", withExtension: "txt", subdirectory: "Fixtures"))
        claims = TranscriptImporter(file: "sample-transcript.txt").claims(from: try String(contentsOf: url, encoding: .utf8))
    }

    func claim(atLine line: Int) throws -> Claim {
        try #require(claims.first { $0.origin?.line == line }, "no claim at line \(line)")
    }

    @Test func onlyAssistantTurnsAreScanned() {
        #expect(claims.allSatisfy { $0.origin?.speaker == "Assistant" })
        #expect(claims.map(\.id) == (1...claims.count).map { "C\($0)" })
    }

    @Test func footnotesResolvePerTurnAndDuplicatesCollapse() throws {
        // Turn 1: [1] and [2] are the same URL → one source.
        let c = try claim(atLine: 5)
        #expect(c.sources.map(\.url) == ["https://papers.example.org/html/heat-2024v1"])
        #expect(c.text.hasPrefix("Urban heat islands are metropolitan areas"))
        #expect(!c.text.contains("==") && !c.text.contains("[1"))

        // A later turn restarts numbering: its [2] is a different paper.
        let later = try claim(atLine: 57)
        #expect(later.sources.compactMap(\.url) == ["https://papers.example.org/html/grids-2025v1", "https://lab.example.com/research/grids"])
    }

    @Test func unlinkedReferencesAreFlagged() throws {
        let quoted = try claim(atLine: 34)
        #expect(quoted.flags.contains(.unlinkedTitle))
        #expect(quoted.flags.contains(.containsQuotation)) // "It notes:" + the verbatim quote two lines down
        #expect(quoted.text.contains("fundamental mismatch is climatic"))
        #expect(quoted.sources.map(\.title) == ["Limits of Reflective Surfaces in Humid Climates"])

        #expect(try claim(atLine: 40).sources.compactMap(\.title) == [
            "The Hidden Costs of Cool Roof Mandates", "SLOW: Staged Retrofits for Older Housing Stock",
        ])
        // Strikethrough markup is stripped from the title.
        #expect(try claim(atLine: 41).sources.compactMap(\.title) == ["Durability of Reflective Coatings Under Urban Pollution"])
        #expect(try claim(atLine: 42).flags == [.unlinkedTitle])
    }

    @Test func mistitledSourceKeepsTheTitleAsWritten() throws {
        let c = try claim(atLine: 59)
        #expect(c.sources.compactMap(\.title) == ["Heat Maps Are All You Need: Finding the Effective Grid Size"])
        #expect(c.sources.compactMap(\.url).contains("https://papers.example.org/pdf/effective-grid-2025"))
    }

    @Test func uncitedEvidenceLanguageIsFlagged() throws {
        let c = try claim(atLine: 75)
        #expect(c.flags == [.uncitedEvidence])
        #expect(c.sources.isEmpty)
    }

    @Test func selfSourcesAreCaptured() throws {
        let c = try claim(atLine: 73)
        #expect(c.sources.compactMap(\.url).allSatisfy { $0.contains("my-lab.example") })
        let index = ProjectCitationIndex(project: "UEF-T", selfDomains: ["my-lab.example"])
        #expect(index.isSelfSource("https://my-lab.example/contact"))
        #expect(!index.isSelfSource("https://papers.example.org/abs/canopy-2023"))
    }

    @Test func userTurnsAndPlainProseAreIgnored() {
        #expect(!claims.contains { $0.text.contains("My own group studies this") })
        #expect(!claims.contains { $0.text.hasPrefix("Token-Level Noise") }) // uncited explanation, no evidence language
    }
}

@Suite struct TranscriptStructureTests {
    @Test func turnsAndFootnotes() {
        let t = """
        **Me**: hi
        **Bot**: claim one [1]. Another [2, 3]
        more [9]
        [1] [https://a.org](https://a.org/x)
        [2] https://b.org/y
        **Me**: thanks
        """
        let claims = TranscriptImporter(file: "t").claims(from: t)
        #expect(claims.count == 2)
        #expect(claims[0].sources.map(\.url) == ["https://a.org/x", "https://b.org/y", nil])
        #expect(claims[0].sources.map(\.marker) == [1, 2, 3])
        #expect(claims[1].sources.first?.marker == 9)
        #expect(claims[1].sources.first?.url == nil) // footnote missing → kept, unresolved
    }

    @Test func speakerOverride() {
        let t = "**A**: x [1]\n[1] https://a.org\n**B**: y [1]\n[1] https://b.org"
        #expect(TranscriptImporter(file: "t", speakers: ["A"]).claims(from: t).first?.sources.first?.url == "https://a.org")
    }

    @Test(arguments: [
        ("The Dual-State Architecture for Reliable LLM Agents", true),
        ("Static Prompting Architecture", false), // 3 words
        ("\"The fundamental impedance mismatch is representational\"", false),
        ("Core Focus:", false),
        ("a sentence that is not a title at all", false),
    ])
    func titleHeuristic(phrase: String, expected: Bool) {
        #expect(TranscriptImporter.looksLikeTitle(phrase) == expected)
    }
}

@Suite struct IdentifierTests {
    @Test(arguments: [
        ("https://arxiv.org/html/2504.06969v1", "2504.06969"),
        ("https://arxiv.org/pdf/2509.21361", "2509.21361"),
        ("https://www.alphaxiv.org/abs/2604.01161", "2604.01161"),
        ("https://ui.adsabs.harvard.edu/abs/arXiv:2509.07869", "2509.07869"),
        ("https://arxiv.org/abs/hep-th/9901001v2", "hep-th/9901001"),
        ("10.48550/arXiv.2510.11905", "2510.11905"),
    ])
    func arxivIDs(url: String, id: String) {
        #expect(ArXiv.id(in: url) == id)
    }

    @Test func nonArXivNumbersIgnored() {
        #expect(ArXiv.id(in: "https://example.com/2504.06969") == nil)
        #expect(ArXiv.id(in: "https://openreview.net/forum?id=WcJN5D82ZV") == nil)
    }

    @Test func canonicalKeys() {
        #expect(CanonicalURL.key("https://arxiv.org/html/2504.06969v1") == CanonicalURL.key("https://arxiv.org/abs/2504.06969"))
        #expect(CanonicalURL.key("https://www.atlan.com/know/x/#frag") == CanonicalURL.key("http://atlan.com/know/x"))
    }
}

@Suite struct ResolverTests {
    static let arxivPage = """
    <meta name="citation_title" content="LLM Knowledge is Brittle: Truthfulness Representations Rely on Superficial Resemblance">
    <meta name="citation_author" content="Haller, Patrick"><meta name="citation_date" content="2025/10/13">
    """

    @Test func linksURLsThenTitlesAndNeverGuesses() async throws {
        let http = MockHTTP()
        http.route("https://arxiv.org/abs/2510.11905", body: Self.arxivPage)
        http.route("https://api.crossref.org/works?", body: crossrefSearchJSON)
        var library = Library()
        library.projects["UEF-T"] = ProjectCitationIndex(project: "UEF-T", claims: [
            Claim(id: "C1", text: "a", sources: [ClaimSource(marker: 3, url: "https://arxiv.org/html/2510.11905v1")]),
            Claim(id: "C2", text: "b", sources: [ClaimSource(title: "LLM knowledge is brittle: truthfulness representations rely on superficial resemblance")]),
            Claim(id: "C3", text: "c", sources: [ClaimSource(url: "https://arxiv.org/abs/2510.11905")]),
            Claim(id: "C4", text: "d", sources: [ClaimSource(title: "The Dual-State Architecture for Reliable LLM Agents")]),
        ])
        let resolver = ClaimResolver(cascade: SearchCascade(crossref: CrossrefClient(http: http), http: http))
        let report = await resolver.resolve(project: "UEF-T", in: &library)

        #expect(report.added == [1])
        let ref = try #require(library[1])
        #expect(ref.arxiv == "2510.11905")
        #expect(ref.publicationType == .preprint)
        #expect(ref.url == "https://arxiv.org/abs/2510.11905")
        let claims = try #require(library.projects["UEF-T"]).claims
        #expect(claims.map { $0.sources[0].reference } == [1, 1, 1, nil]) // C4: candidates shown, nothing linked
        #expect(report.titleCandidates.first?.title == "The Dual-State Architecture for Reliable LLM Agents")
        #expect(http.requested.filter { $0.host == "arxiv.org" }.count == 1) // cached across claims
    }
}

@Suite struct QuoteTests {
    let pages: PageLines = [
        ["Abstract", "Large language models are sensi-", "tive to prompt formatting, with “spurious”", "features changing accuracy."],
        ["We ﬁnd that performance drops by up", "to 76 accuracy points."],
    ]

    @Test func findsAcrossLineBreaksAndHyphenation() {
        let r = QuoteVerifier.locate("Large language models are sensitive to prompt formatting, with \"spurious\" features changing accuracy.", in: pages)
        #expect(r == .found(QuoteMatch(page: 1, line: 2, endPage: 1, endLine: 4, occurrences: 1)))
    }

    @Test func ligaturesAndPageBoundaries() {
        let r = QuoteVerifier.locate("changing accuracy. We find that performance drops", in: pages)
        #expect(r == .found(QuoteMatch(page: 1, line: 4, endPage: 2, endLine: 1, occurrences: 1)))
    }

    @Test func alteredNumberIsRejectedWithDivergencePoint() {
        // LLM-style paraphrase drift: 85 instead of 76.
        let r = QuoteVerifier.locate("We find that performance drops by up to 85 accuracy points", in: pages)
        #expect(r == .notFound(matchedWords: 8, totalWords: 11, nearest: (page: 2, line: 1)))
    }

    @Test func tooShort() {
        #expect(QuoteVerifier.locate("accuracy", in: pages) == .tooShort)
    }

    func library() -> Library {
        var lib = Library()
        try! lib.add(Reference(id: 1, authors: [Author(family: "Ngweta", given: "L.")], year: 2025, title: "T"))
        try! lib.add(Reference(id: 2, authors: [Author(family: "Other")], year: 2024, title: "U"))
        lib.projects["UEF-T"] = ProjectCitationIndex(project: "UEF-T", claims: [
            Claim(id: "C1", text: "Format changes hurt accuracy", sources: [ClaimSource(url: "x", reference: 1)]),
        ])
        return lib
    }

    @Test func recordsNumberedQuotesAndLinksClaim() throws {
        var lib = library()
        let q1 = try lib.addQuote(project: "UEF-T", reference: 1, text: "performance drops by up to 76 accuracy points", claim: "C1", pdfPages: pages)
        let q2 = try lib.addQuote(project: "UEF-T", reference: 1, text: "sensitive to prompt formatting", claim: "c1", pdfPages: pages)
        let again = try lib.addQuote(project: "UEF-T", reference: 1, text: "Performance drops by up to 76 accuracy points.", claim: "C1", pdfPages: pages)
        #expect(q1.tag == "IDI 1-Q1")
        #expect((q1.page, q1.line) == (2, 1))
        #expect(q2.tag == "IDI 1-Q2")
        #expect(again == q1) // same passage isn't recorded twice
        #expect(lib.projects["UEF-T"]?.claims[0].quotes == ["IDI 1-Q1", "IDI 1-Q2"])
    }

    @Test func quoteMustComeFromAClaimSource() {
        var lib = library()
        #expect(throws: EvidenceError.referenceNotLinkedToClaim(2, claim: "C1")) {
            try lib.addQuote(project: "UEF-T", reference: 2, text: "performance drops by up to 76 accuracy points", claim: "C1", pdfPages: pages)
        }
    }

    @Test func supportedRequiresVerifiedQuote() throws {
        var lib = library()
        #expect(throws: EvidenceError.statusNeedsQuote("C1")) {
            try lib.setClaimStatus(project: "UEF-T", claim: "C1", status: .supported, note: nil)
        }
        try lib.setClaimStatus(project: "UEF-T", claim: "C1", status: .overstated, note: "says 76, not 85")
        try lib.addQuote(project: "UEF-T", reference: 1, text: "performance drops by up to 76 accuracy points", claim: "C1", pdfPages: pages)
        try lib.setClaimStatus(project: "UEF-T", claim: "C1", status: .supported, note: nil)
        #expect(lib.projects["UEF-T"]?.claims[0].status == .supported)
        #expect(lib.projects["UEF-T"]?.claims[0].note == "says 76, not 85")
    }

    @Test func reportShowsEvidenceAndWarnings() throws {
        var lib = library()
        lib.projects["UEF-T"]!.selfDomains = ["my-lab.example"]
        lib.projects["UEF-T"]!.claims.append(Claim(id: "C2", text: "Enterprises pay a tax",
            sources: [ClaimSource(url: "https://my-lab.example/abstract"), ClaimSource(title: "Some Invented Paper Title Here")],
            flags: [.unlinkedTitle]))
        try lib.addQuote(project: "UEF-T", reference: 1, text: "performance drops by up to 76 accuracy points", claim: "C1", pdfPages: pages)
        try lib.setClaimStatus(project: "UEF-T", claim: "C1", status: .supported, note: nil)

        let md = ClaimsReport(library: lib, project: "UEF-T").markdown(generated: Date(timeIntervalSince1970: 0))
        #expect(md.contains("## Supported\n\n### C1"))
        #expect(md.contains("**IDI 1-Q1** (Ngweta, 2025, p. 2, line 1): \u{201C}performance drops by up to 76 accuracy points\u{201D} → cite as `[IDI 1, p. 2]`"))
        #expect(md.contains("⚠️ unresolved: https://my-lab.example/abstract — the author's own site"))
        #expect(md.contains("⚠️ named but not located: *Some Invented Paper Title Here*"))
        #expect(md.contains("- Ngweta, L. (2025). T. `[IDI 1]`"))
        #expect(md.contains("| IDI 1-Q1 | Ngweta, 2025 | 2 | 1 |"))
        #expect(!md.contains("Other")) // IDI 2 isn't linked to any claim
    }
}
