import Foundation

/// A single author as `Last, F. M.` per the RefWare spec.
///
/// The full given name is stored (when known) so initials are always derived,
/// never hand-typed. Organizational authors (e.g. "OpenAI") set `isOrganization`
/// and are rendered verbatim with no initials.
public struct Author: Codable, Hashable, Sendable {
    public var family: String
    public var given: String?
    public var isOrganization: Bool

    public init(family: String, given: String? = nil, isOrganization: Bool = false) {
        self.family = family.trimmingCharacters(in: .whitespacesAndNewlines)
        let g = given?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.given = (g?.isEmpty ?? true) ? nil : g
        self.isOrganization = isOrganization
    }

    /// Initials derived from the given name: "Jane Marie" → "J. M.",
    /// "Jean-Paul" → "J.-P.", "J.R.R." → "J. R. R.".
    public var initials: String {
        guard let given, !isOrganization else { return "" }
        let words = given
            .replacingOccurrences(of: #"\.\s*-\s*"#, with: "-", options: .regularExpression) // "M.-J." keeps its hyphen
            .replacingOccurrences(of: ".", with: " ")
            .split(whereSeparator: { $0 == " " })
        return words.map { word -> String in
            word.split(separator: "-")
                .compactMap { $0.first.map { "\($0.uppercased())." } }
                .joined(separator: "-")
        }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    /// `Last, F. M.` — or just `Last` when no given name is known.
    public var referenceForm: String {
        let i = initials
        return i.isEmpty ? family : "\(family), \(i)"
    }
}
