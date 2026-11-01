import Foundation
import Testing
@testable import RefWareCore

struct FakeSnapshotter: PageSnapshotter {
    var text: String
    func snapshot(_ url: URL) async throws -> (pdf: Data, text: String) { (Data("%PDF-1.4 snapshot".utf8), text) }
}

@Suite struct CaptureTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("refware-capture-\(UUID())")
    let day = Date(timeIntervalSince1970: 1_791_000_000) // 2026-10-03

    func capture(_ http: MockHTTP, page: String = String(repeating: "Gartner forecasts $644 billion. ", count: 20), unpaywall: Bool = false) -> Capture {
        Capture(cascade: SearchCascade(crossref: CrossrefClient(http: http), http: http), http: http,
                snapshotter: FakeSnapshotter(text: page), unpaywall: unpaywall ? UnpaywallClient(http: http, email: "a@b.org") : nil)
    }

    func library() -> Library {
        var lib = Library()
        try! lib.add(Reference(id: 27, authors: [Author(family: "Gartner", isOrganization: true)], year: 2025, title: "Gartner forecasts…",
                               url: "https://www.gartner.com/en/newsroom/x",
                               provenance: Provenance(source: .webPage, key: "x", retrieved: Date(), verified: false)))
        lib.projects["UEF-T"] = ProjectCitationIndex(project: "UEF-T", claims: [
            Claim(id: "C1", text: "Spending hits $644B", sources: [ClaimSource(title: "Gartner, 2025 — no matching reference entry")]),
        ])
        return lib
    }

    @Test func existingWebEntryGetsDatedSnapshotAndClaimLink() async throws {
        let http = MockHTTP()
        http.route("https://www.gartner.com/", body: "<html><title>Gartner</title></html>")
        var lib = library()
        let r = try await capture(http).run("https://www.gartner.com/en/newsroom/x", project: "UEF-T", claim: "C1", library: &lib, pdfDirectory: dir, now: day)
        #expect(!r.isNew)
        #expect(r.reference.id == 27)
        #expect(r.document == .webSnapshot)
        #expect(r.reference.fileName?.hasPrefix("IDI-0027_Gartner_2025_web-2026-10-") == true)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(r.reference.fileName!).path))
        #expect(lib.projects["UEF-T"]?.claims[0].references == [27])
        #expect(r.linkedClaim == "C1")
    }

    @Test func pdfLinkIsSavedAsIs() async throws {
        let http = MockHTTP()
        http.route("https://data.x.ai/card.pdf", body: "%PDF-1.7 model card")
        var lib = library()
        let r = try await capture(http).run("https://data.x.ai/card.pdf", project: "UEF-T", claim: nil, library: &lib, pdfDirectory: dir, now: day)
        #expect(r.isNew)
        #expect(r.document == .pdfLink)
        #expect(r.reference.provenance?.verified == false) // no metadata anywhere: kept, clearly unverified
        #expect(r.reference.title == "card")
    }

    @Test func arxivPageGetsVerifiedMetadataAndPaperPDF() async throws {
        let http = MockHTTP()
        http.route("https://arxiv.org/abs/2509.07869", body: #"<meta name="citation_title" content="Are Humans as Brittle as Large Language Models?"><meta name="citation_author" content="Li, Jiaxin"><meta name="citation_date" content="2025/09/09">"#)
        http.route("https://arxiv.org/pdf/2509.07869", body: "%PDF-1.5 paper")
        var lib = library()
        let r = try await capture(http).run("https://arxiv.org/html/2509.07869v2", project: "UEF-T", claim: nil, library: &lib, pdfDirectory: dir, now: day)
        #expect(r.reference.provenance?.verified == true)
        #expect(r.reference.arxiv == "2509.07869")
        #expect(r.document == .arXiv)
        #expect(r.reference.fileName == "IDI-0028_Li_2025.pdf")
    }

    @Test func botCheckSnapshotIsRefused() async throws {
        let http = MockHTTP()
        http.route("https://www.gartner.com/", body: "<html></html>")
        var lib = library()
        await #expect(throws: CaptureError.self) {
            try await capture(http, page: "Just a moment... Verifying your browser").run("https://www.gartner.com/en/newsroom/x", project: "UEF-T", claim: nil, library: &lib, pdfDirectory: dir)
        }
        #expect(lib[27]?.fileName == nil)
    }

    @Test func doiPaperUsesUnpaywallOpenAccessCopy() async throws {
        let http = MockHTTP()
        http.route("https://api.crossref.org/works/10.1038", body: crossrefWorkJSON)
        http.route("https://api.unpaywall.org/v2/10.1038", body: #"{"best_oa_location":{"url_for_pdf":"https://europepmc.org/oa.pdf"}}"#)
        http.route("https://europepmc.org/oa.pdf", body: "%PDF-1.6 open access")
        var lib = library()
        let r = try await capture(http, unpaywall: true).run("https://doi.org/10.1038/s41586-021-03819-2", project: "UEF-T", claim: nil, library: &lib, pdfDirectory: dir)
        #expect(r.document == .openAccess)
        #expect(r.reference.provenance?.source == .crossref)
    }

    @Test func reportOffersCaptureLinksWhereThereIsNoPDF() {
        var lib = library()
        lib.projects["UEF-T"]!.claims[0].sources = [ClaimSource(url: "https://www.gartner.com/en/newsroom/x", reference: 27), ClaimSource(url: "https://who.int/x")]
        let md = ClaimsReport(library: lib, project: "UEF-T").markdown()
        #expect(md.contains("[📥 capture](refware://capture?url=https%3A%2F%2Fwww%2Egartner%2Ecom%2Fen%2Fnewsroom%2Fx&project=UEF-T&claim=C1)"))
        #expect(md.contains("⚠️ unresolved: https://who.int/x [📥 capture](refware://capture?url=https%3A%2F%2Fwho%2Eint%2Fx&project=UEF-T&claim=C1)"))
    }
}

@Suite struct ReviewerNotesTests {
    @Test func recoversOnlyWhatTheReviewerAdded() {
        let generated = """
        ## Unreviewed

        ### C1

        > Spending hits $644B.

        - **Sources:**
          - `[IDI 27]` Gartner, 2025 — *Forecast* (web page · no PDF) [📥 capture](refware://capture?url=x)

        ### C2

        > Other claim.
        """
        let edited = """
        ## Unreviewed

        ### C1

        > Spending hits $644B.

        Source quote, verbatim: "…$644 billion in 2025…"

        Checked & verified by SMH on 10.04.2026.

        - **Sources:**
          - `[IDI 27]` Gartner, 2025 — *Forecast* (web page · no PDF)

        ### C2

        > Other claim.
        """
        let notes = ReviewerNotes.added(edited: edited, generated: generated)
        #expect(notes == ["C1": "Source quote, verbatim: \"…$644 billion in 2025…\"\n\nChecked & verified by SMH on 10.04.2026."])
    }
}

@Suite struct DeadLinkCaptureTests {
    @Test func notFoundPagesAreNeverSaved() async throws {
        let http = MockHTTP()
        http.route("https://www.who.int/", body: "<html></html>")
        var lib = Library()
        try lib.add(Reference(id: 30, authors: [Author(family: "World Health Organization", isOrganization: true)], year: 2024, title: "AI ethics", url: "https://www.who.int/news/item/18-01-2024"))
        let snap = FakeSnapshotter(text: "WHO\nThis page cannot be found\nThe page or file you are trying to access cannot be found." + String(repeating: " Regions", count: 40))
        let cap = Capture(cascade: SearchCascade(crossref: CrossrefClient(http: http), http: http), http: http, snapshotter: snap, unpaywall: nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("refware-dead-\(UUID())")
        await #expect(throws: CaptureError.self) {
            try await cap.run("https://www.who.int/news/item/18-01-2024", project: "UEF-T", claim: nil, library: &lib, pdfDirectory: dir)
        }
        #expect(lib[30]?.fileName == nil)
    }
}
