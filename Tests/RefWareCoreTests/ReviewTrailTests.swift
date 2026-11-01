import Foundation
import Testing
@testable import RefWareCore

@Suite struct ReviewTrailTests {
    let human = Reviewer(name: "SMH", type: .human)
    let agent = Reviewer(name: "Claude Opus 5.5", type: .ai, model: "claude-opus-5-5")

    func lib() throws -> Library {
        var lib = Library()
        try lib.add(Reference(id: 1, authors: [Author(family: "Smith", given: "J.")], year: 2020, title: "One",
                              provenance: Provenance(source: .crossref, key: "x", retrieved: Date(), verified: true)))
        lib.projects["UEF-T"] = ProjectCitationIndex(project: "UEF-T", references: [1],
            quotes: [QuoteRecord(label: "Q1", reference: 1, text: "a quote long enough", page: 4, line: 2, verified: true)],
            claims: [Claim(id: "C1", text: "x", sources: [ClaimSource(reference: 1)], quotes: ["IDI 1-Q1"]),
                     Claim(id: "C2", text: "y", sources: [ClaimSource(reference: 1)])])
        return lib
    }

    func claim(_ l: Library, _ id: String) -> Claim { l.projects["UEF-T"]!.claims.first { $0.id == id }! }

    @Test func aiJudgmentIsAProposalByDefault() throws {
        var l = try lib()
        #expect(try l.judge(project: "UEF-T", claim: "C1", status: .supported, by: agent, reasons: ["direct-quote"]) == .proposed)
        #expect(claim(l, "C1").status == .unreviewed)
        #expect(claim(l, "C1").pendingProposals.first?.model == "claude-opus-5-5")
        #expect(try l.acceptProposal(project: "UEF-T", claim: "C1", by: human) == .supported)
        let c = claim(l, "C1")
        #expect(c.status == .supported && c.reviewedBy == "SMH" && c.pendingProposals.isEmpty)
        #expect(c.reviews.last?.reviewerType == .human && c.reviews.last?.responds != nil)
    }

    @Test func aiMayNotAcceptItsOwnProposal() throws {
        var l = try lib()
        try l.judge(project: "UEF-T", claim: "C1", status: .supported, by: agent)
        #expect(throws: ReviewError.needsPerson) { try l.acceptProposal(project: "UEF-T", claim: "C1", by: agent) }
    }

    @Test func policyLetsAIFinalize() throws {
        var l = try lib()
        l.projects["UEF-T"]!.aiMayFinalize = true
        #expect(try l.judge(project: "UEF-T", claim: "C1", status: .supported, by: agent) == .applied)
        #expect(claim(l, "C1").status == .supported && claim(l, "C1").reviewedBy == "Claude Opus 5.5")
    }

    @Test func supportedStillNeedsAQuoteEvenAsAProposal() throws {
        var l = try lib()
        #expect(throws: EvidenceError.self) { try l.judge(project: "UEF-T", claim: "C2", status: .supported, by: agent) }
    }

    @Test func questionedIsIndependentOfStatus() throws {
        var l = try lib()
        try l.judge(project: "UEF-T", claim: "C1", status: .supported, by: human)
        try l.flag(project: "UEF-T", claim: "C1", by: agent, reasons: ["overclaim"], rationale: "quote says organizations, claim says pilots")
        #expect(claim(l, "C1").isQuestioned && claim(l, "C1").status == .supported)
        #expect(try l.resolveFlags(project: "UEF-T", claim: "C1", by: human, note: "checked; fine") == 1)
        #expect(!claim(l, "C1").isQuestioned)
        #expect(claim(l, "C1").reviews.map(\.kind) == [.judgment, .flag, .resolution])
    }

    @Test func reviewsSurviveSaveAndLoad() throws {
        var l = try lib()
        try l.comment(project: "UEF-T", claim: "C1", by: agent, text: "see p. 4")
        let data = try JSONEncoder().encode(l)
        let back = try JSONDecoder().decode(Library.self, from: data)
        #expect(claim(back, "C1").reviews.first?.rationale == "see p. 4")
    }

    @Test func candidateKeysAreStable() {
        let m = ResolvedMetadata(authors: [Author(family: "Smith")], year: 2020, title: "One", doi: "10.1/ABC", source: .crossref, lookupKey: "x")
        #expect(IdentCandidate(kind: .registry(m), evidence: "", strong: true).key == "doi:10.1/abc")
        #expect(IdentCandidate(kind: .existing(7), evidence: "", strong: true).key == "idi:7")
        var pdf = m; pdf.source = .pdfCover
        let k = IdentCandidate(kind: .registry(pdf), evidence: "", strong: false).key
        #expect(k.hasPrefix("details:") && k == IdentCandidate(kind: .registry(pdf), evidence: "x", strong: true).key)
    }
}
