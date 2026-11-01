import Foundation
import Testing
@testable import RefWareCore

@Suite struct DataSafetyTests {
    func tempLibrary() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rw-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("library.json")
        var lib = Library()
        try lib.save(to: url)
        return url
    }

    @Test func staleCopyCannotOverwriteNewerEdits() throws {
        let url = try tempLibrary()
        var a = try Library.load(from: url)
        var b = try Library.load(from: url)
        a.deleted[99] = Deletion(by: "A", reason: nil, citation: "X, 2020")
        try a.save(to: url)                      // first writer wins
        #expect(throws: LibraryError.self) { try b.save(to: url) }  // second, stale copy is refused
        try a.save(to: url)                      // the writer's own successive saves still work
    }

    @Test func staleCopyCannotUnfreeze() throws {
        let url = try tempLibrary()
        var stale = try Library.load(from: url)
        try Library.freeze(at: url, by: "SMH", note: nil)
        #expect(throws: LibraryError.self) { try stale.save(to: url) }
        #expect(try Library.load(from: url).frozen != nil)
    }

    @Test func unreadableHistoryIsSetAsideNotWiped() throws {
        let url = try tempLibrary()
        let dir = url.deletingLastPathComponent()
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: History.url(forLibraryAt: url))
        let h = History.load(forLibraryAt: url)
        #expect(h.events.count == 1)
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("refware-history.unreadable-") }
        #expect(aside.count == 1)
        #expect(try Data(contentsOf: dir.appendingPathComponent(aside[0])) == garbage)
    }

    @Test func unknownHistoryKindsSurviveARoundTrip() throws {
        let json = #"{"events":[{"id":"\#(UUID().uuidString)","date":"2026-10-30T10:00:00Z","kind":"future-thing","title":"x","idis":[],"quoteTags":[]}]}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let h = try d.decode(History.self, from: Data(json.utf8))
        #expect(h.events[0].kind == .other)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        #expect(String(decoding: try e.encode(h), as: UTF8.self).contains("future-thing"))
    }
}
