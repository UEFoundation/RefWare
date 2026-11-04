import Foundation
import RefWareCore

struct UsageError: Error, CustomStringConvertible { var description: String }

/// Minimal argument parser: `--key value` options, `--flag` switches, and positionals.
struct Arguments {
    var positionals: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    static let switches: Set<String> = ["markdown", "require-verified", "help", "all", "import", "claims", "no-indent", "replace", "prefer-incoming-pdf", "missing", "last", "quotes", "json", "move", "drop-claims", "take-details", "import-all", "no-bibliography"]

    init(_ args: [String]) throws {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") || a == "-o" {
                let key = a == "-o" ? "output" : String(a.dropFirst(2))
                if Self.switches.contains(key) {
                    flags.insert(key)
                } else {
                    guard i + 1 < args.count else { throw UsageError(description: "\(a) needs a value") }
                    options[key] = args[i + 1]
                    i += 1
                }
            } else {
                positionals.append(a)
            }
            i += 1
        }
    }
}

func libraryURL(_ args: Arguments) -> URL {
    let path = args.options["library"] ?? ProcessInfo.processInfo.environment["REFWARE_LIBRARY"] ?? RefWareConfig.load().library ?? "library.json"
    return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
}

func publicationType(_ raw: String?) throws -> PublicationType? {
    guard let raw else { return nil }
    guard let t = PublicationType(rawValue: raw) else { throw UsageError(description: "unknown publication type \"\(raw)\"") }
    return t
}

func projectTag(_ args: Arguments) throws -> ProjectTag? {
    guard let project = args.options["project"] ?? (args.options["handle"] == nil ? RefWareConfig.load().project : nil) else {
        if args.options["handle"] != nil { throw UsageError(description: "--handle requires --project") }
        return nil
    }
    guard project.range(of: #"^UEF-\w+$"#, options: .regularExpression) != nil else {
        throw UsageError(description: "project must look like UEF-XXXX, got \"\(project)\"")
    }
    return ProjectTag(project: project, handle: args.options["handle"])
}

/// One record as text. With the library, its citation carries the same 2026a/2026b suffix as everywhere else.
func describe(_ ref: Reference, in library: Library? = nil) -> String {
    let f = CitationFormatter(references: library.map { Array($0.references.values) } ?? [ref])
    var lines = [
        "[IDI \(ref.id)] \(f.inline([ref]))",
        "  \(f.referenceEntry(ref))",
        "  type: \(ref.publicationType.rawValue)",
    ]
    if let file = ref.fileName { lines.append("  file: \(file)") }
    for p in ref.projects { lines.append("  project: \(p.project)\(p.handle.map { " (\($0))" } ?? "")") }
    if let p = ref.provenance {
        lines.append("  source: \(p.source.rawValue) [\(p.key)] \(p.verified ? "verified" : "UNVERIFIED")")
    }
    return lines.joined(separator: "\n")
}

func requireProject(_ args: Arguments) throws -> String {
    guard let tag = try projectTag(args) else { throw UsageError(description: "--project UEF-XXXX is required") }
    return tag.project
}

func stderr(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}
