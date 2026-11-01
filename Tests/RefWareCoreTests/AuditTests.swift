import Foundation
import Testing
@testable import RefWareCore

@Suite struct EntryParserTests {
    @Test func journalArticle() {
        let e = ManuscriptParser.parseEntry(
            "Jumper, J., Evans, R., & Hassabis, D. (2021). Highly accurate protein structure prediction with AlphaFold. Nature, 596(7873), 583–589. https://doi.org/10.1038/s41586-021-03819-2",
            line: 40)
        #expect(e.authors == [Author(family: "Jumper", given: "J."), Author(family: "Evans", given: "R."), Author(family: "Hassabis", given: "D.")])
        #expect(e.year == 2021)
        #expect(e.title == "Highly accurate protein structure prediction with AlphaFold")
        #expect(e.publication == "Nature")
        #expect(e.indexing == PublicationIndexing(volume: "596", issue: "7873", pages: "583-589"))
        #expect(e.doi == "10.1038/s41586-021-03819-2")
        #expect(!e.truncatedAuthors)
    }

    @Test func truncatedAuthorsSuffixAndQuestionTitle() {
        let e = ManuscriptParser.parseEntry("Li, J., Papay, S., et al. (2025b). Are humans as brittle as large language models? arXiv. https://arxiv.org/abs/2509.07869", line: 1)
        #expect(e.truncatedAuthors)
        #expect(e.authors.map(\.family) == ["Li", "Papay"])
        #expect(e.yearSuffix == "b")
        #expect(e.title == "Are humans as brittle as large language models?")
        #expect(e.publication == "arXiv")
        #expect(e.url == "https://arxiv.org/abs/2509.07869")
    }

    @Test func articleNumberOrganizationAndInitialsInTitle() {
        let e = ManuscriptParser.parseEntry("World Health Organization. (2023). Guidance on A.I. ethics in health. The Lancet Digital Health, 5(2), Article e101. doi:10.1016/x.2023.1", line: 1)
        #expect(e.authors == [Author(family: "World Health Organization", isOrganization: true)])
        #expect(e.title == "Guidance on A.I. ethics in health")
        #expect(e.indexing.articleNumber == "e101")
        #expect(e.doi == "10.1016/x.2023.1")
    }

    @Test func referenceSectionAndWrappedEntries() {
        let doc = """
        Intro cites (Smith, 2020).

        ## References

        Smith, J. A. (2020). A long title that wraps
        onto a second line. Journal of Things, 3(1), 1-9.
        Zed, Q. (2019). Another. Venue.

        ## Appendix A
        Not a reference (Fake, 2001).
        """
        let p = ManuscriptParser.parse(doc)
        #expect(p.referenceHeadingLine == 3)
        #expect(p.entries.count == 2)
        #expect(p.entries[0].title == "A long title that wraps onto a second line")
        #expect(p.entries[0].line == 5)
        #expect(p.citations.map(\.raw) == ["Smith, 2020", "Fake, 2001"]) // appendix is body text again
    }
}

@Suite struct InTextParserTests {
    @Test func parentheticalGroups() {
        let c = ManuscriptParser.citations(in: "Shown before (e.g., Smith & Jones, 2020; Lee et al., 2021a, p. 4; Kim, 2019, 2022).", line: 7)
        #expect(c.map(\.names) == [["Smith", "Jones"], ["Lee"], ["Kim"], ["Kim"]])
        #expect(c.map(\.etAl) == [false, true, false, false])
        #expect(c.map(\.year) == [2020, 2021, 2019, 2022])
        #expect(c[1].yearSuffix == "a")
        #expect(c[1].locator == "p. 4")
        #expect(c.allSatisfy { $0.line == 7 && !$0.narrative })
    }

    @Test func narrative() {
        let c = ManuscriptParser.citations(in: "As Haller et al. (2025) and Li and Papay (2025, p. 3) argue, and Rodionov's (2026) data show", line: 1)
        #expect(c.map(\.names) == [["Haller"], ["Li", "Papay"], ["Rodionov"]])
        #expect(c.map(\.narrative) == [true, true, true])
        #expect(c[1].locator == "p. 3")
    }

    @Test func statisticsAndBareYearsAreNotCitations() {
        #expect(ManuscriptParser.citations(in: "a large sample (N = 2019) and (p < .05) in (2020) during (In 2020)", line: 1).isEmpty)
    }
}

@Suite struct ComparisonTests {
    let source: ResolvedMetadata = {
        var m = ResolvedMetadata(
            authors: [Author(family: "Paulsen", given: "Norman")], year: 2026,
            title: "Context Is What You Need: The Maximum Effective Context Window for Real World Limits of LLMs",
            publication: "Advances in Artificial Intelligence and Machine Learning",
            indexing: PublicationIndexing(volume: "06", issue: "01", pages: "01-26"),
            doi: "10.54364/aaiml.2026.61268", source: .crossref, lookupKey: "x")
        m.yearsSeen = [2025, 2026]
        m.publicationAliases = ["Adv. Artif. Intell. Mach. Learn."]
        return m
    }()

    @Test func cleanEntryHasNoDiscrepancies() {
        let e = ManuscriptParser.parseEntry("Paulsen, N. (2026). Context is what you need: The maximum effective context window for real world limits of LLMs. Adv. Artif. Intell. Mach. Learn., 6(1), 1–26. https://doi.org/10.54364/aaiml.2026.61268", line: 1)
        #expect(ManuscriptAuditor.compare(e, source).isEmpty) // case, abbreviation, leading zeros all fine
    }

    @Test func llmStyleMistakesAreCaught() {
        let e = ManuscriptParser.parseEntry("Paulsen, N. (2024). Context is all you need: Finding the maximum effective context window. Journal of LLMs, 6(2), 1–26. https://doi.org/10.54364/aaiml.2026.61268", line: 1)
        let d = Dictionary(uniqueKeysWithValues: ManuscriptAuditor.compare(e, source).map { ($0.field, $0) })
        #expect(d["year"]?.severity == .error)
        #expect(d["year"]?.source == "2025 / 2026")
        #expect(d["title"]?.severity == .error)
        #expect(d["journal"]?.severity == .error)
        #expect(d["issue"]?.yours == "2")
        #expect(d["volume"] == nil && d["pages"] == nil)
    }

    @Test func alternateYearIsMinor() {
        let e = ManuscriptParser.parseEntry("Paulsen, N. (2025). Context is what you need: The maximum effective context window for real world limits of LLMs. Advances in Artificial Intelligence and Machine Learning, 6(1), 1-26.", line: 1)
        let d = ManuscriptAuditor.compare(e, source)
        #expect(d.first { $0.field == "year" }?.severity == .minor)
        #expect(d.first { $0.field == "DOI" }?.severity == .minor) // DOI missing from the entry
    }

    @Test func authorProblems() {
        let src = ResolvedMetadata(authors: [Author(family: "Jumper", given: "John M."), Author(family: "Evans", given: "Richard"), Author(family: "Pritzel", given: "A.")],
                                   year: 2021, title: "T", source: .crossref, lookupKey: "x")
        let e = ManuscriptParser.parseEntry("Jumper, J., & Pritzel, A. (2021). T.", line: 1)
        let d = ManuscriptAuditor.compare(e, src)
        #expect(d.first { $0.field == "authors" }?.note == "missing: Evans, R.")
        #expect(d.first { $0.field == "author 2" }?.note == "Pritzel is author 3 in the source — order differs")
        #expect(d.first { $0.field == "author 1 initials" }?.severity == .minor) // J. vs J. M.
    }
}

@Suite struct CrossCheckTests {
    func audits(_ entries: [String]) -> [EntryAudit] {
        entries.enumerated().map { i, raw in
            EntryAudit(entry: ManuscriptParser.parseEntry(raw, line: 100 + i), match: .notFound, record: nil, discrepancies: [], citedBy: [], importedAs: nil)
        }
    }

    @Test func formsAndMissingEntries() {
        var a = audits([
            "Jumper, J., Evans, R., & Pritzel, A. (2021). T. Nature.",
            "Li, J., & Papay, S. (2025). U. arXiv.",
            "Solo, A. (2019). V. W.",
            "Uncited, Z. (2000). X. Y.",
        ])
        let cites = ManuscriptParser.citations(in: "(Jumper & Evans, 2021; Li et al., 2025; Solo, 2018; Nobody, 2020) and Evans et al. (2021) and Solo (2019)", line: 3)
        let issues = ManuscriptAuditor.crossCheck(cites, against: &a)
        let problems = issues.map(\.problem)
        #expect(problems.contains("3 authors — cite as Jumper et al."))
        #expect(problems.contains("2 authors — cite both: Li & Papay"))
        #expect(problems.contains("no Solo 2018 in the reference list — did you mean Solo (2019)?"))
        #expect(problems.contains("no matching entry in the reference list"))
        #expect(problems.contains("no Evans 2021 entry — a Evans is a co-author of Jumper (2021); if that's the work, cite Jumper; otherwise the reference is missing"))
        #expect(a[2].citedBy.count == 1)
        #expect(a[3].citedBy.isEmpty)
    }

    @Test func ambiguousWithoutSuffix() {
        var a = audits(["Smith, J. (2020a). One. X.", "Smith, J. (2020b). Two. X."])
        let issues = ManuscriptAuditor.crossCheck(ManuscriptParser.citations(in: "(Smith, 2020) (Smith, 2020b)", line: 1), against: &a)
        #expect(issues.map(\.problem) == ["ambiguous — 2 entries by Smith in 2020; add a/b suffixes"])
        #expect(a[1].citedBy.count == 1)
    }
}

@Suite struct DataCiteTests {
    @Test func zenodoRecord() async throws {
        let http = MockHTTP()
        http.route("https://api.datacite.org/dois/10.5281", body: """
        {"data":{"attributes":{"doi":"10.5281/zenodo.1","url":"https://zenodo.org/records/1",
          "creators":[{"name":"Doe, Jane Q.","givenName":"Jane Q.","familyName":"Doe","nameType":"Personal"},{"name":"Example Lab","nameType":"Organizational"}],
          "titles":[{"title":"A Sample Framework"}],"publisher":{"name":"Zenodo"},"publicationYear":2026,
          "types":{"resourceTypeGeneral":"Preprint"}}}}
        """)
        let cascade = SearchCascade(crossref: CrossrefClient(http: http), http: http)
        let m = try #require(try await cascade.lookup(doi: "10.5281/zenodo.1"))
        #expect(m.source == .datacite)
        #expect(m.authors == [Author(family: "Doe", given: "Jane Q."), Author(family: "Example Lab", isOrganization: true)])
        #expect(m.year == 2026)
        #expect(m.publication == "Zenodo")
        #expect(m.publicationType == .preprint)
    }
}

@Suite struct AuditRegressionTests {
    @Test func titleMatchInAnotherYearIsNotAccepted() async {
        let http = MockHTTP()
        http.route("https://api.crossref.org/works?", body: """
        {"message":{"items":[{"DOI":"10.65215/junk","title":["Attention Is All You Need"],"author":[{"family":"Vaswani","given":"A."}],"issued":{"date-parts":[[2025]]}}]}}
        """)
        let auditor = ManuscriptAuditor(cascade: SearchCascade(crossref: CrossrefClient(http: http), http: http))
        let a = await auditor.auditEntry(ManuscriptParser.parseEntry("Vaswani, A. (2017). Attention is all you need. NeurIPS, 30.", line: 1))
        #expect(a.match == .notFound)
        #expect(a.record == nil)
        #expect(a.discrepancies.first?.source == "2025 doi:10.65215/junk")
    }

    @Test func zeroPaddedIndexingPrintsUnpadded() {
        let ref = Reference(id: 1, authors: [Author(family: "Paulsen", given: "N.")], year: 2026, title: "T", publication: "J",
                            indexing: .init(volume: "06", issue: "01", pages: "01-26"), doi: "10.54364/aaiml.2026.61268")
        #expect(CitationFormatter(references: [ref]).referenceEntry(ref) == "Paulsen, N. (2026). T. J, 6(1), 1–26. https://doi.org/10.54364/aaiml.2026.61268")
    }
}

/// Regression cases found auditing a real hand-built reference list.
@Suite struct RealWorldAuditRegressionTests {
    func arxivRecord(year: Int, authors: [String] = ["Wang"]) -> ResolvedMetadata {
        var m = ResolvedMetadata(authors: authors.map { Author(family: $0, given: "X.") }, year: year, title: "Self-Consistency Improves Chain of Thought Reasoning in Language Models",
                                 publication: "arXiv", doi: "10.48550/arXiv.2203.11171", arxiv: "2203.11171", publicationType: .preprint, source: .webMetadata, lookupKey: "x")
        m.yearsSeen = [year]
        return m
    }

    @Test func publishedVenueWithPreprintLinkIsAVersionNoteNotErrors() {
        let e = ManuscriptParser.parseEntry("Wang, X. (2023). Self-Consistency Improves Chain of Thought Reasoning in Language Models. ICLR. https://arxiv.org/abs/2203.11171", line: 1)
        let d = ManuscriptAuditor.compare(e, arxivRecord(year: 2022))
        #expect(d.first { $0.field == "version" }?.severity == .minor)
        #expect(d.allSatisfy { $0.severity == .minor })
        #expect(!d.contains { $0.field == "journal" })
    }

    @Test(arguments: [
        ("Findings of ACL", "Findings of the Association for Computational Linguistics ACL 2024", true),
        ("Proceedings of CHI 2026", "Proceedings of the 2026 CHI Conference on Human Factors in Computing Systems", true),
        ("Proceedings of ACL 2025", "Proceedings of the 63rd Annual Meeting of the Association for Computational Linguistics (Volume 1: Long Papers)", true),
        ("Findings of ACL", "Proceedings of the 62nd Annual Meeting of the Association for Computational Linguistics (Volume 1: Long Papers)", false),
    ])
    func venueAbbreviations(short: String, full: String, covered: Bool) {
        #expect(ManuscriptAuditor.venueTokensCovered(short, by: [full]) == covered)
    }

    @Test func titleContainmentIsMinor() {
        var r = arxivRecord(year: 2026)
        r.title = "Relational Dissonance in Human-AI Interactions: The Case of Knowledge Work"
        r.publication = "CHI"
        let e = ManuscriptParser.parseEntry("Wang, X. (2026). Relational dissonance in human-AI interactions. CHI.", line: 1)
        let t = ManuscriptAuditor.compare(e, r).first { $0.field == "title" }
        #expect(t?.severity == .minor)
        #expect(t?.note == "source title continues (subtitle or label missing)")
    }

    @Test func affiliationsAreNotAuthors() {
        #expect(CrossrefClient.Work.looksLikeAffiliation("School of Cyberspace Science and Technology, Beijing Institute of Technology, Beijing, China"))
        #expect(!CrossrefClient.Work.looksLikeAffiliation("World Health Organization"))
    }

    @Test func teamNamesAreOrganizations() {
        #expect(WebMetadataReader.parseName("Gemini Team") == Author(family: "Gemini Team", isOrganization: true))
        #expect(WebMetadataReader.parseName("Machel Reid") == Author(family: "Reid", given: "Machel"))
    }

    @Test func titleBeforeYearAndLint() {
        let e = ManuscriptParser.parseEntry("Zhao, J., Xie, H., Song, X. Shi, Z., Zhang., T. Connecting the Dots: A Framework. (2025). arXiv. https://arxiv.org/abs/2505.10936.", line: 1)
        #expect(e.authors.map(\.family) == ["Zhao", "Xie", "Song", "Shi", "Zhang"])
        #expect(e.title == "Connecting the Dots: A Framework")
        #expect(e.year == 2025)
        #expect(e.publication == "arXiv")
        #expect(e.lint.contains("missing comma before \"Shi\""))
        #expect(e.lint.contains("stray period after \"Zhang\" (\"Zhang.,\")"))
        #expect(e.lint.contains("missing \"&\" before the final author"))
        #expect(e.lint.contains("year placed after the title — APA order is Author, A. (Year). Title."))
        #expect(e.lint.contains("period after the DOI/URL — APA ends the entry at the link"))
    }

    @Test func volumeIssueWordsAndColonLocators() {
        let a = ManuscriptParser.parseEntry("Guan, S. (2026). Evaluating agents: A survey. ACM Transactions on Intelligent Systems and Technology, Vol. 17, Issue 4, Article 85.", line: 1)
        #expect(a.publication == "ACM Transactions on Intelligent Systems and Technology")
        #expect(a.indexing == PublicationIndexing(volume: "17", issue: "4", articleNumber: "85"))
        let b = ManuscriptParser.parseEntry("Gomez, C. (2024). Human-AI collaboration is not very collaborative yet. Front. Comput. Sci. 6:1521066.", line: 1)
        #expect(b.publication == "Front. Comput. Sci.")
        #expect(b.indexing == PublicationIndexing(volume: "6", articleNumber: "1521066"))
    }

    @Test func aclAnthologyAndAcronyms() {
        #expect(ManuscriptAuditor.aclAnthologyDOI("https://aclanthology.org/2024.acl-long.73.pdf") == "10.18653/v1/2024.acl-long.73")
        #expect(ManuscriptAuditor.isAcronym("WHO", of: "World Health Organization"))
        #expect(!ManuscriptAuditor.isAcronym("Who", of: "World Health Organization"))
    }
}

@Suite struct ManuscriptClaimTests {
    @Test func sentenceSplitKeepsEtAlAndInitials() {
        let s = ManuscriptAudit.sentences("Developers took 19 percent longer (Becker et al., 2025). The perception moved, e.g. per J. Smith. Done!")
        #expect(s == ["Developers took 19 percent longer (Becker et al., 2025).", "The perception moved, e.g. per J. Smith.", "Done!"])
    }

    @Test func citedSentencesBecomeLinkedClaims() {
        let text = """
        Errors fell (Wei et al., 2022). No citation here. Spending hit $644B (Gartner, 2025; Nobody, 2020).

        References
        Wei, J., Wang, X., & Zhou, D. (2022). Chain-of-thought prompting. NeurIPS.
        Gartner. (2025). Forecast. https://gartner.com/x
        """
        let parsed = ManuscriptParser.parse(text)
        var audits = parsed.entries.map { EntryAudit(entry: $0, match: .notFound, record: nil, discrepancies: [], citedBy: [], importedAs: nil) }
        _ = ManuscriptAuditor.crossCheck(parsed.citations, against: &audits)
        audits[0].importedAs = 7
        let audit = ManuscriptAudit(entries: audits, citationIssues: [], referenceHeadingLine: parsed.referenceHeadingLine, citationCount: parsed.citations.count)
        let claims = audit.claims(from: text, file: "ms.docx")
        #expect(claims.map(\.text) == ["Errors fell (Wei et al., 2022).", "Spending hit $644B (Gartner, 2025; Nobody, 2020)."])
        #expect(claims[0].references == [7])
        #expect(claims[1].sources.map(\.title) == ["Forecast", "Nobody, 2020 — no matching reference entry"])
        #expect(claims[1].sources[0].url == "https://gartner.com/x")
    }
}

@Suite struct RebuildTests {
    @Test func differentInitialsGetNoSuffix() {
        let a = Reference(id: 1, authors: [Author(family: "Zhao", given: "J."), Author(family: "X", given: "A."), Author(family: "Y", given: "B.")], year: 2025, title: "Cochain")
        let b = Reference(id: 2, authors: [Author(family: "Zhao", given: "K."), Author(family: "X", given: "A."), Author(family: "Y", given: "B.")], year: 2025, title: "Reason")
        #expect(CitationFormatter.disambiguationSuffixes(for: [a, b]).isEmpty)
    }

    @Test func webTitlesAndDiacritics() {
        let e = ManuscriptParser.parseEntry("Gülay, E., & Ciftci, S. (2025). Hybrid Intelligence in Action: A Taxonomy. ECIS 2025 Proceedings. https://aisel.aisnet.org/x", line: 1)
        let r = ResolvedMetadata(authors: [Author(family: "Gulay", given: "E."), Author(family: "Ciftci", given: "S.")], year: 2025,
                                 title: "AIS Electronic Library (AISeL) - ECIS 2025 Proceedings: Hybrid Intelligence in Action: A Taxonomy", source: .webPage, lookupKey: "x")
        let m = ManuscriptAudit.rebuilt(e, from: r, match: .webPage)
        #expect(m.title == "Hybrid Intelligence in Action: A Taxonomy")
        #expect(m.authors.first?.family == "Gülay")
        #expect(m.publication == "ECIS 2025 Proceedings")
        var r2 = r; r2.title = "How Perplexity AI Answers Work: Retrieval, Ranking | ziptie.ai Blog"
        let e2 = ManuscriptParser.parseEntry("ZipTie.dev. (2026). Something else entirely. https://ziptie.dev/x", line: 1)
        #expect(ManuscriptAudit.rebuilt(e2, from: r2, match: .webPage).title == "How Perplexity AI Answers Work: Retrieval, Ranking")
    }
}
