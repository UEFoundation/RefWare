import Foundation

/// Recovers what a reviewer typed into an exported claims report, so it can be
/// stored on the claims themselves instead of living only in a file that the
/// next export would replace.
public enum ReviewerNotes {
    /// Claim ID → the lines the reviewer added under that claim's heading
    /// (anything not in the freshly generated report), in their original order.
    public static func added(edited: String, generated: String) -> [String: String] {
        let mine = sections(edited), fresh = sections(generated)
        var notes: [String: String] = [:]
        for (id, lines) in mine {
            let known = Set((fresh[id] ?? []).map(normalize).filter { !$0.isEmpty })
            let isBlank = lines.map { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            let isNew = lines.indices.map { !isBlank[$0] && !known.contains(normalize(lines[$0])) }
            // Blank lines survive only between two added lines (paragraph breaks inside a note).
            var extra: [String] = []
            for i in lines.indices {
                if isNew[i] {
                    extra.append(lines[i])
                } else if isBlank[i] {
                    let prev = lines.indices.prefix(i).last { !isBlank[$0] }
                    let next = lines.indices.suffix(from: i + 1).first { !isBlank[$0] }
                    if let p = prev, let n = next, isNew[p], isNew[n] { extra.append("") }
                }
            }
            // Trim blank edges; keep inner blank lines (paragraph breaks).
            while extra.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { extra.removeFirst() }
            while extra.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { extra.removeLast() }
            if extra.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                notes[id] = extra.joined(separator: "\n")
            }
        }
        return notes
    }

    static func sections(_ md: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        var current: String?
        for line in md.components(separatedBy: "\n") {
            if let r = line.range(of: #"^### (C\d+)\s*$"#, options: .regularExpression) {
                current = String(line[r].dropFirst(4)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("## ") { current = nil; continue }
            if let c = current { out[c, default: []].append(line) }
        }
        return out
    }

    /// Lines compare without capture links, so a newer export doesn't make old lines look new.
    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: #" \[📥 capture\]\([^)]*\)"#, with: "", options: .regularExpression)
            .folding(options: .diacriticInsensitive, locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }
}
