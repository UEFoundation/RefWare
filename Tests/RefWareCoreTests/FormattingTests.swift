import Testing
@testable import RefWareCore

@Suite struct AuthorTests {
    @Test(arguments: [
        ("Jane Marie", "J. M."),
        ("Jane M.", "J. M."),
        ("Jean-Paul", "J.-P."),
        ("J.R.R.", "J. R. R."),
        ("min-ji", "M.-J."),
        ("M.-J.", "M.-J."),
        ("J. -P.", "J.-P."),
    ])
    func initials(given: String, expected: String) {
        #expect(Author(family: "X", given: given).initials == expected)
    }

    @Test func referenceForm() {
        #expect(Author(family: "Doe", given: "Jane Q.").referenceForm == "Doe, J. Q.")
        #expect(Author(family: "Doe").referenceForm == "Doe")
        #expect(Author(family: "OpenAI", given: "ignored", isOrganization: true).referenceForm == "OpenAI")
    }
}

@Suite struct FormatterTests {
    let all = Fixtures.library.references.values.map { $0 }

    @Test func inlineAuthorCounts() {
        let f = CitationFormatter(references: [Fixtures.smith2020, Fixtures.jonesLee2019, Fixtures.adams2021])
        #expect(f.inline([Fixtures.smith2020]) == "(Smith, 2020)")
        #expect(f.inline([Fixtures.jonesLee2019]) == "(Jones & Lee, 2019)")
        #expect(f.inline([Fixtures.adams2021]) == "(Adams et al., 2021)")
    }

    @Test func multipleWorksSortedAlphabetically() {
        let f = CitationFormatter(references: [Fixtures.smith2020, Fixtures.adams2021])
        #expect(f.inline([Fixtures.smith2020, Fixtures.adams2021]) == "(Adams et al., 2021; Smith, 2020)")
    }

    @Test func sameAuthorSameYearDisambiguated() {
        let f = CitationFormatter(references: all)
        #expect(f.inline([Fixtures.smith2020]) == "(Smith, 2020a)")
        #expect(f.inline([Fixtures.smith2020b]) == "(Smith, 2020b)")
    }

    @Test func noSuffixWhenOnlyOneIsCited() {
        let f = CitationFormatter(references: [Fixtures.smith2020])
        #expect(f.inline([Fixtures.smith2020]) == "(Smith, 2020)")
    }

    @Test func referenceEntryWithDOI() {
        let f = CitationFormatter(references: [Fixtures.smith2020])
        #expect(f.referenceEntry(Fixtures.smith2020)
            == "Smith, J. A. (2020). Emergent coherence in language models. Journal of AI Research, 12(3), 45–67. https://doi.org/10.1000/JAIR.2020.1")
    }

    @Test func referenceEntryFallsBackToURL() {
        let f = CitationFormatter(references: [Fixtures.jonesLee2019])
        #expect(f.referenceEntry(Fixtures.jonesLee2019)
            == "Jones, K., & Lee, M.-J. (2019). Calibration under distribution shift. NeurIPS Proceedings. https://example.org/paper")
    }

    @Test func titleEndingInQuestionMarkGetsNoExtraPeriod() {
        let f = CitationFormatter(references: [Fixtures.adams2021], markup: .markdown)
        #expect(f.referenceEntry(Fixtures.adams2021)
            == "Adams, R., Baker, S., & Chen, T. (2021). Citation hallucination rates? *Nature*, *590*.")
    }

    @Test func noYearAndNoAuthor() {
        let ref = Reference(id: 9, authors: [], year: nil, title: "Developer guide to the API", publication: "Apple Developer")
        let f = CitationFormatter(references: [ref])
        #expect(f.inline([ref]) == "(\u{201C}Developer guide to the\u{2026}\u{201D}, n.d.)")
        #expect(f.referenceEntry(ref) == "Developer guide to the API. (n.d.). Apple Developer.")
    }

    @Test func referenceListAlphabetical() {
        let f = CitationFormatter(references: all)
        let firstWords = f.referenceList(all).split(separator: "\n").map { $0.split(separator: ",")[0] }
        #expect(firstWords == ["Adams", "Jones", "Smith", "Smith"])
        #expect(f.referenceList(all).split(separator: "\n")[2].contains("(2020a). Emergent"))
    }

    @Test func singleAuthorSortsBeforeMultiAuthorWithSameFirstAuthor() {
        let solo = Reference(id: 1, authors: [Author(family: "Lee", given: "M.")], year: 2023, title: "Z")
        let pair = Reference(id: 2, authors: [Author(family: "Lee", given: "M."), Author(family: "Abe", given: "K.")], year: 2001, title: "A")
        #expect(CitationFormatter.sorted([pair, solo]).map(\.id) == [1, 2])
    }

    @Test func houseStyleListsTenThenEtAl() {
        let authors = (1...25).map { Author(family: "A\($0)", given: "B") }
        #expect(CitationFormatter.referenceAuthors(authors) == (1...10).map { "A\($0), B." }.joined(separator: ", ") + ", et al.")
        let ten = Array(authors.prefix(10))
        #expect(CitationFormatter.referenceAuthors(ten).hasSuffix("A9, B., & A10, B.")) // exactly 10: all named
        #expect(CitationFormatter.referenceAuthors(authors, list: .all).hasSuffix("A24, B., & A25, B."))
    }

    @Test func twoGroupAuthorsHaveNoComma() {
        let a = [Author(family: "World Economic Forum", isOrganization: true), Author(family: "BCG", isOrganization: true)]
        #expect(CitationFormatter.referenceAuthors(a) == "World Economic Forum & BCG")
    }

    @Test func apa7TruncationIsOptIn() {
        let authors = (1...25).map { Author(family: "A\($0)", given: "B") }
        let s = CitationFormatter.referenceAuthors(authors, list: .apa7)
        #expect(s.hasSuffix("A19, B., . . . A25, B."))
        #expect(!s.contains("A20,"))
    }
}

@Suite struct APAItalicsTests {
    @Test func standaloneWorksItalicizeTheTitle() {
        let preprint = Reference(id: 1, authors: [Author(family: "Li", given: "J.")], year: 2025, title: "Are humans as brittle as LLMs?", publication: "arXiv", doi: "10.48550/arXiv.2509.07869")
        let web = Reference(id: 2, authors: [Author(family: "OpenAI", isOrganization: true)], year: 2024, title: "Learning to reason with LLMs", url: "https://openai.com/x")
        let journal = Fixtures.smith2020
        let f = CitationFormatter(references: [preprint, web, journal], markup: .markdown)
        #expect(f.referenceEntry(preprint) == "Li, J. (2025). *Are humans as brittle as LLMs?* arXiv. https://doi.org/10.48550/arXiv.2509.07869")
        #expect(f.referenceEntry(web) == "OpenAI. (2024). *Learning to reason with LLMs*. https://openai.com/x")
        #expect(f.referenceEntry(journal).contains("models. *Journal of AI Research*, *12*(3), 45–67."))
        // Plain markup is unchanged apart from punctuation.
        #expect(CitationFormatter(references: [web]).referenceEntry(web) == "OpenAI. (2024). Learning to reason with LLMs. https://openai.com/x")
    }
}
