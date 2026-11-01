import Foundation
import Testing
@testable import RefWareCore

@Suite struct MergeTests {
    func library(dir: URL) throws -> Library {
        var lib = Library()
        try lib.add(Reference(id: 37, authors: [Author(family: "Amershi", given: "S.")], year: 2019, title: "Guidelines for Human-AI Interaction", doi: "10.1145/3290605.3300233"))
        try lib.add(Reference(id: 57, fileName: "IDI-0057_Anon_nd.pdf", authors: [], year: nil, title: "Guidelines-for-Human-AI-Interaction-camera-ready", url: "https://microsoft.com/g.pdf"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("%PDF stub".utf8).write(to: dir.appendingPathComponent("IDI-0057_Anon_nd.pdf"))
        lib.projects["UEF-T"] = ProjectCitationIndex(project: "UEF-T", references: [57, 37],
            quotes: [QuoteRecord(label: "Q1", reference: 37, text: "a"), QuoteRecord(label: "Q1", reference: 57, text: "b")],
            claims: [Claim(id: "C1", text: "x", sources: [ClaimSource(reference: 57)], quotes: ["IDI 57-Q1"])])
        return lib
    }

    @Test func mergeMovesPDFQuotesClaimsAndRetiresTheNumber() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("refware-merge-\(UUID())")
        var lib = try library(dir: dir)
        let r = try lib.merge(57, into: 37, pdfDirectory: dir)
        #expect(lib.references[57] == nil)
        #expect(lib[57]?.id == 37) // old tags still resolve
        #expect(lib[37]?.fileName == "IDI-0037_Amershi_2019.pdf")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("IDI-0037_Amershi_2019.pdf").path))
        #expect(lib[37]?.url == "https://microsoft.com/g.pdf") // gap filled
        #expect(r.retaggedQuotes == ["IDI 57-Q1": "IDI 37-Q2"])
        let p = lib.projects["UEF-T"]!
        #expect(p.references == [37])
        #expect(p.claims[0].references == [37])
        #expect(p.claims[0].quotes == ["IDI 37-Q2"])
        #expect(lib.nextIDI == 58) // 57 is never reissued

        // Survives a save/load round trip.
        let url = dir.appendingPathComponent("lib.json")
        try lib.save(to: url)
        let back = try Library.load(from: url)
        #expect(back[57]?.id == 37)
        #expect(back.nextIDI == 58)
    }

    @Test func taggedDraftsKeepWorkingAfterAMerge() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("refware-merge-\(UUID())")
        var lib = try library(dir: dir)
        try lib.merge(57, into: 37, pdfDirectory: dir)
        #expect(try DocumentProcessor(library: lib).process("As shown [IDI 57].").text == "As shown (Amershi, 2019).")
    }

    @Test func duplicatesAndReviewList() throws {
        var lib = Library()
        try lib.add(Reference(id: 22, authors: [Author(family: "Anthropic", isOrganization: true)], year: 2023, title: "Claude's constitution"))
        try lib.add(Reference(id: 56, authors: [Author(family: "Anthropic", isOrganization: true)], year: 2026, title: "Claude’s Constitution"))
        #expect(lib.likelyDuplicates() == [[22, 56]])
        #expect(lib.needsReview().map(\.id) == [22, 56]) // both unverified
    }
}

@Suite struct PDFIdentifierTests {
    let page1 = [
        "Guidelines for Human-AI Interaction",
        "Saleema Amershi, Dan Weld, Mihaela Vorvoreanu",
        "Microsoft, Redmond, WA, USA",
        "ABSTRACT Advances in artificial intelligence (AI) frame opportunities…",
    ]

    func cascade(_ http: MockHTTP) -> SearchCascade { SearchCascade(crossref: CrossrefClient(http: http), http: http) }

    @Test func titleOnPageOneMatchesExistingRecordConfidently() async throws {
        var lib = Library()
        try lib.add(Reference(id: 37, authors: [Author(family: "Amershi", given: "S.")], year: 2019, title: "Guidelines for Human-AI Interaction"))
        let c = await PDFIdentifier(cascade: cascade(MockHTTP())).identify([page1], library: lib)
        guard case .existing(37)? = PDFIdentifier.confident(c)?.kind else { Issue.record("\(c)"); return }
    }

    @Test func conflictingYearDowngradesToSuggestion() async throws {
        var lib = Library()
        try lib.add(Reference(id: 22, authors: [Author(family: "Anthropic", isOrganization: true)], year: 2023, title: "Claude's constitution: our approach"))
        try lib.add(Reference(id: 56, authors: [Author(family: "Anthropic", isOrganization: true)], year: 2026, title: "Claude's Constitution 2026"))
        let c = await PDFIdentifier(cascade: cascade(MockHTTP())).identify([["Claude's constitution: our approach", "Anthropic"]], library: lib, excluding: 56)
        #expect(c.count == 1)
        #expect(!c[0].strong)
        #expect(c[0].evidence.contains("years differ (2026 vs 2023)"))
    }

    @Test func journalNameAloneIsNotATitleMatch() async throws {
        let http = MockHTTP()
        http.route("https://api.crossref.org/works?", body: #"{"message":{"items":[{"DOI":"10.1257/x","title":["American Economic Review"],"issued":{"date-parts":[[2019]]}}]}}"#)
        let c = await PDFIdentifier(cascade: cascade(http)).identify([["Clio and the Economics of QWERTY", "Paul A. David", "The American Economic Review, Vol. 75, No. 2"]], library: Library())
        #expect(c.isEmpty)
    }

    @Test func jstorCoverSheets() {
        let old = ["Clio and the Economics of QWERTY", "STOR•", "Paul A. David",
                   "The American Economic Review, Vol. 75, No. 2, Papers and Proceedings of the",
                   "Ninety-Seventh Annual Meeting of the American Economic Association. (May, 1985),", "pp. 332-337.",
                   "Stable URL:", "http://links.jstor.org/sici?sici=0002-8282", "jstor"]
        let m = JSTORCover.parse(old)
        #expect(m?.title == "Clio and the Economics of QWERTY")
        #expect(m?.authors == [Author(family: "David", given: "Paul A.")])
        #expect(m?.year == 1985)
        #expect(m?.publication == "The American Economic Review")
        #expect(m?.indexing == PublicationIndexing(volume: "75", issue: "2", pages: "332-337"))
        #expect(m?.source == .pdfCover)

        let new = ["Competing Technologies, Increasing Returns, and Lock-In by Historical Events",
                   "Author(s): W. Brian Arthur Source: The Economic Journal, Vol. 99, No. 394 (Mar., 1989), pp. 116-131",
                   "Published by: Wiley", "Stable URL: https://www.jstor.org/stable/2234208"]
        let n = JSTORCover.parse(new)
        #expect(n?.authors == [Author(family: "Arthur", given: "W. Brian")])
        #expect(n?.year == 1989)
        #expect(n?.indexing.pages == "116-131")
        #expect(n?.url == "https://www.jstor.org/stable/2234208")
    }
}

@Suite struct GUIEngineTests {
    func lib() throws -> Library {
        var lib = Library()
        try lib.add(Reference(id: 1, authors: [Author(family: "Smith", given: "J.")], year: 2020, title: "One",
                              provenance: Provenance(source: .crossref, key: "x", retrieved: Date(), verified: true)))
        try lib.add(Reference(id: 2, authors: [Author(family: "Lee", given: "K.")], year: 2021, title: "Two"))
        lib.projects["UEF-T"] = ProjectCitationIndex(project: "UEF-T", references: [1, 2],
            quotes: [QuoteRecord(label: "Q1", reference: 1, text: "a quote long enough", page: 4, line: 2, verified: true)],
            claims: [Claim(id: "C1", text: "x", sources: [ClaimSource(reference: 1)], quotes: ["IDI 1-Q1"])])
        return lib
    }

    @Test func quoteTagRendersAndIsReported() throws {
        let out = try DocumentProcessor(library: try lib()).process("Shown [IDI 1-Q1].")
        #expect(out.text == "Shown (Smith, 2020, p. 4).")
        #expect(out.quoteTags == ["IDI 1-Q1"])
        #expect(TagParser.parse("[IDI 12-Q3]") == .quote(12, label: "Q3"))
    }

    @Test func unknownQuoteTagIsRefused() throws {
        #expect(throws: ProcessingError.self) { try DocumentProcessor(library: try lib()).process("Unknown [IDI 2-Q9].") }
    }

    @Test func freezeBlocksEditsButAllowsUnfreeze() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("refware-freeze-\(UUID()).json")
        var l = try lib(); try l.save(to: url)
        try Library.freeze(at: url, by: "SMH", note: "as submitted")
        var frozen = try Library.load(from: url)
        try frozen.confirm(2, by: "SMH")
        #expect(throws: LibraryError.self) { try frozen.save(to: url) }
        try Library.unfreeze(at: url)
        var open = try Library.load(from: url)
        try open.confirm(2, by: "SMH")
        try open.save(to: url)
        #expect(try Library.load(from: url)[2]?.provenance?.confirmedBy == "SMH")
    }

    @Test func insightsAndHits() throws {
        let library = try lib()
        var h = History()
        h.events.append(HistoryEvent(kind: .build, date: Date(timeIntervalSince1970: 100), project: "UEF-T", title: "draft v1", idis: [1, 2]))
        h.events.append(HistoryEvent(kind: .build, date: Date(timeIntervalSince1970: 200), project: "UEF-T", title: "draft v2", idis: [1], quoteTags: ["IDI 1-Q1"]))
        let i = LibraryInsights(library: library, history: h, project: "UEF-T")
        #expect(i.notHit(.ever).isEmpty)
        #expect(i.notHit(.last).map(\.id) == [2])
        #expect(i.quotesNotHit(.last).isEmpty)
        #expect(i.quotesNotExported.map(\.tag) == ["IDI 1-Q1"])
        #expect(i.hasVerifiedClaims(1))
        #expect(!i.hasVerifiedClaims(2))
        #expect(i.lastBuild(of: 2) == Date(timeIntervalSince1970: 100))
    }

    @Test func mergedQuoteTagsStillResolve() throws {
        var library = try lib()
        try library.add(Reference(id: 3, authors: [], year: nil, title: "stub"))
        library.projects["UEF-T"]!.quotes.append(QuoteRecord(label: "Q1", reference: 3, text: "stub quote text here", page: 9, verified: true))
        try library.merge(3, into: 1, pdfDirectory: nil)
        #expect(library.canonicalQuoteTag("IDI 3-Q1") == "IDI 1-Q2")
        #expect(try DocumentProcessor(library: library).process("[IDI 3-Q1]").text == "(Smith, 2020, p. 9)")
    }

    @Test func importDateAndSubprojects() throws {
        var library = Library()
        try library.add(Reference(id: 1, authors: [], year: nil, title: "t", projects: [ProjectTag(project: "UEF-T", subprojects: ["Section 1.3"])]))
        #expect(library[1]?.added != nil)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("refware-sub-\(UUID()).json")
        try library.save(to: url)
        #expect(try Library.load(from: url)[1]?.projects.first?.subprojects == ["Section 1.3"])
    }
}

@Suite struct PDFDetailsTests {
    @Test(arguments: [
        ("Microsoft Word - draft3.docx", true), ("untitled", true), ("report_final_v2", true), ("",  true),
        ("The State of Document Intelligence: How AI Is Reshaping Productivity", false),
    ])
    func junkTitles(title: String, junk: Bool) { #expect(PDFDetails.isJunkTitle(title) == junk) }

    @Test(arguments: [("Adobe", true), ("Microsoft Office User", true), ("admin", true), ("Microsoft", false), ("Foxit", false), ("Jane Q. Doe", false)])
    func junkAuthors(author: String, junk: Bool) { #expect(PDFDetails.isJunkAuthor(author) == junk) }
}

@Suite struct WebSnapshotDetailsTests {
    @Test(arguments: [("Skip to main content", true), ("Sign in to continue", true), ("Claude's Constitution: Our Approach", false)])
    func navigationLinesAreNotTitles(line: String, nav: Bool) { #expect(PDFDetails.isNavigation(line) == nav) }
}

@Suite struct HandCheckTests {
    @Test func checkAndUndoRestoreTheRightState() throws {
        var lib = Library()
        try lib.add(Reference(id: 1, authors: [Author(family: "Doe", given: "J.")], year: 2024, title: "Registry paper",
                              provenance: Provenance(source: .crossref, key: "10.1/x", retrieved: Date(), verified: true)))
        try lib.add(Reference(id: 2, authors: [Author(family: "Org", isOrganization: true)], year: 2025, title: "Web page",
                              provenance: Provenance(source: .webPage, key: "u", retrieved: Date(), verified: false)))
        try lib.confirm(1, by: "SMH"); try lib.confirm(2, by: "SMH")
        #expect(lib[1]?.provenance?.confirmedBy == "SMH" && lib[2]?.provenance?.verified == true)
        try lib.unconfirm(1); try lib.unconfirm(2)
        #expect(lib[1]?.provenance?.confirmedBy == nil)
        #expect(lib[1]?.provenance?.verified == true)   // still registry-verified
        #expect(lib[2]?.provenance?.verified == false)  // back to unverified
    }
}

@Suite struct DeleteTests {
    @Test func deleteRetiresNumberHandlesClaimsAndParksPDF() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("refware-del-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("%PDF".utf8).write(to: dir.appendingPathComponent("IDI-0021_Ciftci_2025.pdf"))
        var lib = Library()
        try lib.add(Reference(id: 21, fileName: "IDI-0021_Ciftci_2025.pdf", authors: [Author(family: "Ciftci", given: "S."), Author(family: "B", given: "C."), Author(family: "D", given: "E.")], year: 2025, title: "Hybrid Intelligence"))
        try lib.add(Reference(id: 22, authors: [Author(family: "Lee", given: "K.")], year: 2024, title: "Other"))
        lib.projects["UEF-T"] = ProjectCitationIndex(project: "UEF-T", references: [21, 22],
            quotes: [QuoteRecord(label: "Q1", reference: 21, text: "a quote long enough", verified: true)],
            claims: [Claim(id: "C1", text: "only 21", sources: [ClaimSource(reference: 21)], quotes: ["IDI 21-Q1"]),
                     Claim(id: "C2", text: "21 and 22", sources: [ClaimSource(reference: 21), ClaimSource(reference: 22)])])
        let r = try lib.delete(21, reason: "paywalled", by: "SMH", dropClaims: true, pdfDirectory: dir)
        #expect(r.droppedClaims == ["C1"])
        #expect(r.affectedClaims.sorted() == ["C1", "C2"])
        #expect(r.removedQuotes == ["IDI 21-Q1"])
        #expect(r.parkedPDF == "PDFs/deleted/IDI-0021_Ciftci_2025.pdf")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("deleted/IDI-0021_Ciftci_2025.pdf").path))
        let p = lib.projects["UEF-T"]!
        #expect(p.claims[0].status == .dropped && p.claims[0].note == "Source deleted (Ciftci et al., 2025): paywalled.")
        #expect(p.claims[0].quotes.isEmpty)
        #expect(p.claims[1].status == .unreviewed && p.claims[1].references == [22])
        #expect(p.references == [22] && p.quotes.isEmpty)
        #expect(lib[21] == nil && lib.nextIDI == 23)
        do {
            _ = try DocumentProcessor(library: lib).process("As shown [IDI 21].")
            Issue.record("expected an error")
        } catch {
            #expect(error.issues.first?.description.contains("IDI 21 was deleted (Ciftci et al., 2025") == true)
        }
    }
}

@Suite struct TakeDetailsMergeTests {
    @Test func keepNumberUseOtherDetails() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("refware-take-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("%PDF".utf8).write(to: dir.appendingPathComponent("IDI-0058_WHO_2024.pdf"))
        var lib = Library()
        try lib.add(Reference(id: 30, authors: [Author(family: "WHO", isOrganization: true)], year: 2024, title: "Old broken title", url: "https://who.int/dead"))
        try lib.add(Reference(id: 58, fileName: "IDI-0058_WHO_2024.pdf", authors: [Author(family: "WHO", isOrganization: true)], year: 2024,
                              title: "Ethics and governance of AI for health", url: "https://who.int/live",
                              provenance: Provenance(source: .manual, key: "x", retrieved: Date(), verified: true, confirmedBy: "SMH")))
        lib.projects["UEF-T"] = ProjectCitationIndex(project: "UEF-T", references: [30, 58],
            claims: [Claim(id: "C10", text: "governance", sources: [ClaimSource(reference: 30)])])
        try lib.merge(58, into: 30, pdfDirectory: dir, preferIncomingPDF: true, takeIncomingDetails: true)
        let r = try #require(lib[30])
        #expect(r.title == "Ethics and governance of AI for health")
        #expect(r.url == "https://who.int/live")
        #expect(r.provenance?.confirmedBy == "SMH")
        #expect(r.fileName == "IDI-0030_WHO_2024.pdf")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("IDI-0030_WHO_2024.pdf").path))
        #expect(lib[58]?.id == 30)                                // retired number resolves to the survivor
        #expect(lib.projects["UEF-T"]?.claims[0].references == [30])
    }
}
