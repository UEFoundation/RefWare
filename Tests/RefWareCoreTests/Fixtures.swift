import Foundation
@testable import RefWareCore

enum Fixtures {
    static let smith2020 = Reference(
        id: 1, authors: [Author(family: "Smith", given: "Jane Ann")], year: 2020,
        title: "Emergent coherence in language models",
        publication: "Journal of AI Research", indexing: .init(volume: "12", issue: "3", pages: "45-67"),
        doi: "https://doi.org/10.1000/JAIR.2020.1"
    )
    static let jonesLee2019 = Reference(
        id: 2, authors: [Author(family: "Jones", given: "Kai"), Author(family: "Lee", given: "Min-Ji")], year: 2019,
        title: "Calibration under distribution shift", publication: "NeurIPS Proceedings",
        url: "https://example.org/paper"
    )
    static let adams2021 = Reference(
        id: 3,
        authors: [Author(family: "Adams", given: "R."), Author(family: "Baker", given: "S."), Author(family: "Chen", given: "T.")],
        year: 2021, title: "Citation hallucination rates?", publication: "Nature", indexing: .init(volume: "590")
    )
    static let smith2020b = Reference(
        id: 4, authors: [Author(family: "Smith", given: "Jane Ann")], year: 2020,
        title: "A second paper by Smith"
    )

    static var library: Library {
        var l = Library()
        for r in [smith2020, jonesLee2019, adams2021, smith2020b] { try! l.add(r) }
        return l
    }
}

/// Serves canned responses by URL prefix and records requests.
final class MockHTTP: HTTPClient, @unchecked Sendable {
    var routes: [(prefix: String, response: HTTPResponse)] = []
    private(set) var requested: [URL] = []
    private let lock = NSLock()

    func route(_ prefix: String, status: Int = 200, body: String) {
        routes.append((prefix, HTTPResponse(status: status, data: Data(body.utf8))))
    }

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        lock.withLock { requested.append(url) }
        let s = url.absoluteString
        return routes.first { s.hasPrefix($0.prefix) }?.response ?? HTTPResponse(status: 404, data: Data())
    }
}

let crossrefWorkJSON = """
{"status":"ok","message":{
  "DOI":"10.1038/S41586-021-03819-2","URL":"https://doi.org/10.1038/s41586-021-03819-2",
  "title":["Highly accurate protein structure prediction with <i>AlphaFold</i>"],
  "container-title":["Nature"],
  "author":[{"given":"John","family":"Jumper"},{"given":"Richard","family":"Evans"},{"name":"DeepMind Team"}],
  "issued":{"date-parts":[[2021,7,15]]},
  "volume":"596","issue":"7873","page":"583-589","type":"journal-article"
}}
"""

let crossrefSearchJSON = """
{"status":"ok","message":{"items":[
  {"DOI":"10.1/other","title":["Something related"],"author":[{"family":"Doe","given":"A."}],"issued":{"date-parts":[[2018]]}},
  {"DOI":"10.1/exact","title":["Calibration Under Distribution Shift"],"author":[{"family":"Jones","given":"Kai"}],"issued":{"date-parts":[[2019]]}},
  {"DOI":"10.1/untitled","author":[{"family":"X"}]}
]}}
"""
