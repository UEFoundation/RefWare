import Foundation
import Testing
@testable import RefWareCore

@Suite struct CrossrefTests {
    @Test func parsesWork() async throws {
        let http = MockHTTP()
        http.route("https://api.crossref.org/works/10.1038", body: crossrefWorkJSON)
        let m = try #require(try await CrossrefClient(http: http).work(doi: "https://doi.org/10.1038/s41586-021-03819-2"))

        #expect(m.title == "Highly accurate protein structure prediction with AlphaFold")
        #expect(m.authors == [
            Author(family: "Jumper", given: "John"),
            Author(family: "Evans", given: "Richard"),
            Author(family: "DeepMind Team", isOrganization: true),
        ])
        #expect(m.year == 2021)
        #expect(m.publication == "Nature")
        #expect(m.indexing == PublicationIndexing(volume: "596", issue: "7873", pages: "583-589"))
        #expect(m.doi == "10.1038/S41586-021-03819-2") // as registered
        #expect(m.publicationType == .unclassified) // journal-article does not imply peer review
    }

    @Test func notFoundIsNil() async throws {
        #expect(try await CrossrefClient(http: MockHTTP()).work(doi: "10.1/missing") == nil)
    }

    @Test func mailtoIsSent() async throws {
        let http = MockHTTP()
        _ = try await CrossrefClient(http: http, mailto: "lab@uef.org").work(doi: "10.1/x")
        #expect(http.requested.first?.query?.contains("mailto=lab@uef.org") == true)
    }
}

@Suite struct CascadeTests {
    @Test func doiWinsFirst() async {
        let http = MockHTTP()
        http.route("https://api.crossref.org/works/10.1038", body: crossrefWorkJSON)
        let cascade = SearchCascade(crossref: CrossrefClient(http: http), http: http)
        let result = await cascade.run(SearchQuery(doi: "10.1038/s41586-021-03819-2", title: "ignored"))
        guard case .exact(let m, .doi) = result.outcome else { Issue.record("\(result.outcome)"); return }
        #expect(m.year == 2021)
        #expect(http.requested.count == 1)
    }

    @Test func fallsThroughMissingDOIToURLMetadata() async {
        let http = MockHTTP()
        http.route("https://blog.example.com/post", body: """
        <html><head>
          <meta name="citation_title" content="Scaling &amp; alignment">
          <meta content="Doe, Jane Q." name="citation_author">
          <meta name="citation_author" content="Kai Jones">
          <meta name="citation_publication_date" content="2024/03/01">
          <meta property="og:site_name" content="UEF Notes">
        </head></html>
        """)
        let cascade = SearchCascade(crossref: CrossrefClient(http: http), http: http)
        let result = await cascade.run(SearchQuery(doi: "10.1/missing", url: "https://blog.example.com/post"))
        guard case .exact(let m, .url) = result.outcome else { Issue.record("\(result.outcome)"); return }
        #expect(m.title == "Scaling & alignment")
        #expect(m.authors == [Author(family: "Doe", given: "Jane Q."), Author(family: "Jones", given: "Kai")])
        #expect(m.year == 2024)
        #expect(m.publication == "UEF Notes")
        #expect(result.log.map(\.step) == [.doi, .url])
    }

    @Test func urlDeclaringDOIResolvesThroughCrossref() async {
        let http = MockHTTP()
        http.route("https://journal.example.com/a", body: #"<meta name="citation_doi" content="10.1038/s41586-021-03819-2">"#)
        http.route("https://api.crossref.org/works/10.1038", body: crossrefWorkJSON)
        let cascade = SearchCascade(crossref: CrossrefClient(http: http), http: http)
        guard case .exact(let m, .url) = await cascade.run(SearchQuery(url: "https://journal.example.com/a")).outcome else {
            Issue.record("expected exact"); return
        }
        #expect(m.source == .crossref)
    }

    @Test func titleSearchReturnsCandidatesExactTitleFirst() async {
        let http = MockHTTP()
        http.route("https://api.crossref.org/works?", body: crossrefSearchJSON)
        let cascade = SearchCascade(crossref: CrossrefClient(http: http), http: http)
        let result = await cascade.run(SearchQuery(title: "Calibration under distribution shift"))
        guard case .candidates(let found, .title) = result.outcome else { Issue.record("\(result.outcome)"); return }
        #expect(found.map(\.doi) == ["10.1/exact", "10.1/other"]) // untitled item dropped
    }

    @Test func outletAloneIsSkipped() async {
        let http = MockHTTP()
        http.route("https://api.crossref.org/works?", body: crossrefSearchJSON)
        let cascade = SearchCascade(crossref: CrossrefClient(http: http), http: http)
        let result = await cascade.run(SearchQuery(outlet: "Nature"))
        guard case .notFound = result.outcome else { Issue.record("\(result.outcome)"); return }
        #expect(http.requested.isEmpty)
    }

    @Test func errorsAreLoggedAndCascadeContinues() async {
        let http = MockHTTP()
        http.route("https://api.crossref.org/works/", status: 500, body: "")
        http.route("https://api.crossref.org/works?", body: crossrefSearchJSON)
        let cascade = SearchCascade(crossref: CrossrefClient(http: http), http: http)
        let result = await cascade.run(SearchQuery(doi: "10.1/x", author: "Jones"))
        guard case .candidates(_, .author) = result.outcome else { Issue.record("\(result.outcome)"); return }
        #expect(result.log.first?.note.contains("HTTP 500") == true)
    }
}

@Suite struct WebPageTests {
    @Test func botCheckPagesAreRejected() {
        let page = WebMetadataReader.read(html: "<title>Verifying your browser | OpenReview</title>", url: "https://openreview.net/forum?id=X")
        #expect(page.metadata == nil)
    }

    @Test func generalPagesAreMarkedNonScholarlyAndEntitiesDecoded() throws {
        let page = WebMetadataReader.read(html: """
        <meta property="og:title" content="Contact &mdash; Example Research Group &#8212; &#x2014; &bogus;">
        <meta property="og:site_name" content="ERG"><meta name="article:published_time" content="2026-01-02">
        """, url: "https://my-lab.example/contact")
        let m = try #require(page.metadata)
        #expect(!page.scholarly)
        #expect(m.source == .webPage)
        #expect(m.title == "Contact \u{2014} Example Research Group \u{2014} \u{2014} &bogus;")
        #expect(m.year == 2026)
    }
}
