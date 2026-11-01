import CoreText
import Foundation
import Testing
@testable import RefWareCore

/// Acceptance tests from the 2026-10-28 agent report (#1) and GPT-6's FIX-01.
@Suite struct NumericQuoteTests {
    let pages: PageLines = [[
        "Knowledge workers spend 4.3 hours per week correcting outputs, a mean",
        "effect of 7.6 points (p < 0.05). Spending fell by −0.5% while time",
        "rose 19%. The sensi-", "tive measure covered 1,000 firms and COVID-19 cases."
    ]]

    func found(_ q: String) -> Bool { if case .found = QuoteVerifier.locate(q, in: pages) { return true }; return false }

    @Test(arguments: [
        "spend 43 hours per week correcting outputs",          // 4.3 → 43
        "a mean effect of 76 points (p < 0.05)",               // 7.6 → 76
        "a mean effect of 7.6 points (p > 0.05)",              // < → >
        "Spending fell by 0.5% while time rose",               // −0.5 → 0.5
        "Spending fell by −0.5% while time rose 1.9%",         // 19% → 1.9%
        "measure covered 1000 firms and COVID-19 cases",       // 1,000 → 1000
    ])
    func changedNumbersOrSymbolsDoNotMatch(_ q: String) { #expect(!found(q), "should not match: \(q)") }

    @Test(arguments: [
        "Knowledge workers   spend 4.3 hours per week correcting outputs",   // whitespace
        "a mean effect of 7.6 points (p < 0.05). Spending fell by −0.5%",   // across a line break
        "Spending fell by -0.5% while time rose 19%",                       // ASCII hyphen for minus
        "The sensitive measure covered 1,000 firms and COVID-19 cases",    // line-end hyphenation
    ])
    func artifactsStillMatch(_ q: String) { #expect(found(q), "should match: \(q)") }

    @Test func storesThePDFsOwnText() {
        guard case .found(let m) = QuoteVerifier.locate("the SENSITIVE measure covered 1,000 firms", in: pages) else { Issue.record("no match"); return }
        #expect(m.matchedText == "The sensitive measure covered 1,000 firms")
        #expect((m.page, m.line, m.endLine) == (1, 3, 4))
    }
}

/// GPT-6 FIX-02 + agent report #2: quotes are bound to the PDF they were verified against.
@Suite struct PDFBindingTests {
    /// A tiny real PDF with the given text (so PDFText can read it back).
    static func pdf(_ text: String) -> Data {
        let d = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(consumer: CGDataConsumer(data: d)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        let attr = NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 11, nil)])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attr), CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 50, y: 50, width: 500, height: 700), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return d as Data
    }

    func setup() throws -> (Library, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("refware-bind-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.pdf")
        try Self.pdf("Developers took nineteen percent longer to finish complex tasks with AI tools.").write(to: a)
        var lib = Library()
        try lib.add(Reference(id: 1, authors: [Author(family: "Becker", given: "J.")], year: 2025, title: "Study"))
        try lib.add(Reference(id: 2, authors: [Author(family: "Other", given: "K.")], year: 2024, title: "Other"))
        lib.projects["UEF-T"] = ProjectCitationIndex(project: "UEF-T", claims: [Claim(id: "C1", text: "slower", sources: [ClaimSource(reference: 1)])])
        try lib.attachPDF(from: a, to: 1, pdfDirectory: dir)
        let pages = try PDFText.pages(of: dir.appendingPathComponent(lib[1]!.fileName!))
        try lib.addQuote(project: "UEF-T", reference: 1, text: "took nineteen percent longer to finish complex tasks", claim: "C1",
                         pdfPages: pages, pdfSHA256: lib[1]!.pdfSHA256)
        try lib.setClaimStatus(project: "UEF-T", claim: "C1", status: .supported, note: nil)
        return (lib, dir)
    }

    @Test func unchangedPDFKeepsVerification() throws {
        var (lib, dir) = try setup()
        let r = lib.revalidateQuotes(of: 1, pdfDirectory: dir)
        #expect(r.unchanged == ["IDI 1-Q1"] && r.stale.isEmpty)
    }

    @Test func replacedPDFMakesMissingQuotesStaleButKeepsThem() throws {
        var (lib, dir) = try setup()
        let b = dir.appendingPathComponent("b.pdf")
        try Self.pdf("An entirely different report about document intelligence and trust.").write(to: b)
        try lib.attachPDF(from: b, to: 1, pdfDirectory: dir)
        let q = try #require(lib.projects["UEF-T"]?.quotes.first)
        #expect(q.staleSince != nil && !q.isCurrent && q.verified)      // history kept, no longer current
        #expect(lib.claimsNeedingRevalidation().map(\.claim.id) == ["C1"])
        #expect(throws: EvidenceError.self) { try lib.setClaimStatus(project: "UEF-T", claim: "C1", status: .supported, note: nil) }
    }

    @Test func reattachingIdenticalBytesCreatesNoWork() throws {
        var (lib, dir) = try setup()
        let copy = dir.appendingPathComponent("copy.pdf")
        try FileManager.default.copyItem(at: dir.appendingPathComponent(lib[1]!.fileName!), to: copy)
        let r = lib.revalidateQuotes(of: 1, pdfDirectory: dir)
        #expect(r.stale.isEmpty)
        // …but the same bytes can't be attached to a *different* record.
        #expect(throws: LibraryError.pdfInUse(1, file: lib[1]!.fileName!)) { try lib.attachPDF(from: copy, to: 2, pdfDirectory: dir) }
        #expect(lib.sharedPDFs(pdfDirectory: dir).isEmpty)
    }
}

/// Agent report #3, #5, #18, #19, #25.
@Suite struct CitationCorrectnessTests {
    func lib() throws -> Library {
        var l = Library()
        let three = { (f: String, g: String) in [Author(family: f, given: g), Author(family: "B", given: "C."), Author(family: "D", given: "E.")] }
        try l.add(Reference(id: 9, authors: three("Zhao", "J."), year: 2025, title: "Cochain"))
        try l.add(Reference(id: 13, authors: three("Zhao", "K."), year: 2025, title: "Reason-to-Recommend"))
        try l.add(Reference(id: 30, authors: [Author(family: "World Health Organization", isOrganization: true)], year: 2024, title: "Guidance"))
        try l.add(Reference(id: 58, authors: [Author(family: "World Health Organization", isOrganization: true)], year: 2024, title: "Guidance (copy)"))
        try l.add(Reference(id: 5, authors: [Author(family: "Meincke", given: "L.")], year: 2025, title: "Report"))
        try l.add(Reference(id: 29, authors: [Author(family: "MIT NANDA", isOrganization: true)], year: 2025, title: "GenAI Divide"))
        try l.merge(58, into: 30, pdfDirectory: nil)
        return l
    }

    @Test func sameSurnameDifferentInitialsGetInitials() throws {
        let out = try DocumentProcessor(library: try lib()).process("[IDI 9] and [IDI 13], narratively [IDI 13, narrative].").text
        #expect(out == "(J. Zhao et al., 2025) and (K. Zhao et al., 2025), narratively K. Zhao et al. (2025).")
    }

    @Test func retiredNumberAndSurvivorAreOneReference() throws {
        let out = try DocumentProcessor(library: try lib()).process("[IDI 58] then [IDI 30].\n[IDI # - ALLREF]").text
        #expect(out.components(separatedBy: "World Health Organization. (2024)").count == 2) // exactly one entry
        #expect(!out.contains("2024b") && !out.contains("2024a"))
    }

    @Test func repeatedIDsCiteOnce() throws {
        #expect(try DocumentProcessor(library: try lib()).process("[IDI 9, 9]").text == "(Zhao et al., 2025)") // initials only when both Zhaos are cited
    }

    @Test func markdownListHasBlankLinesAndMixedCaseSortsAlphabetically() throws {
        let out = try DocumentProcessor(library: try lib(), markup: .markdown).process("[IDI 5, 29]\n[IDI # - ALLREF]").text
        #expect(out.hasPrefix("(Meincke, 2025; MIT NANDA, 2025)"))
        #expect(out.contains("*Report*.\n\nMIT NANDA. (2025)"))
    }
}
