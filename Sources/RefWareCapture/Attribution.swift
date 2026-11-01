import AppKit
import SwiftUI

/// Credits and the development record (the RPA Attribution Log from the
/// RefWare Project Charter, copied into the app bundle at install).
enum Attribution {
    static let design = "Designed by S. M. Hykin"
    static let build = "Built by Claude Code · Claude Opus 5.5 (Anthropic)"
    static let method = "with Coherence-Based Collaboration"
    static let org = "Universal Emergence Foundation"

    struct Entry: Identifiable {
        let id = UUID()
        let heading: String   // "2026-10-04 — Claude Code / Opus 5.5 (Anthropic)"
        let body: String
    }

    /// Entries from the charter's "### Attribution Log" section, oldest first.
    static func log() -> [Entry] {
        guard let url = Bundle.main.url(forResource: "ProjectCharter", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let start = text.range(of: "### Attribution Log") else { return [] }
        return text[start.upperBound...].components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("* **") }
            .compactMap { line -> Entry? in
                // * **2026-10-04 — Name:** text
                guard let close = line.range(of: ":**") else { return nil }
                let heading = String(line[line.index(line.startIndex, offsetBy: 4)..<close.lowerBound])
                let body = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)
                return Entry(heading: heading, body: body)
            }
    }

    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { "v\($0)" } ?? ""
    }
}

/// Bottom of the title card.
struct CreditLine: View {
    @State private var showing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider().padding(.bottom, 4)
            Text(Attribution.design).font(.caption2)
            Text(Attribution.build).font(.caption2)
            HStack(spacing: 4) {
                Text("\(Attribution.method) · UEF").font(.caption2).foregroundStyle(.secondary)
                Button { showing = true } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).font(.caption2).help("Credits & development record")
            }
        }
        .foregroundStyle(.secondary)
        .popover(isPresented: $showing, arrowEdge: .trailing) { CreditsView().frame(width: 460, height: 520) }
    }
}

struct CreditsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("RefWare \(Attribution.version)").font(.system(size: 26, weight: .semibold, design: .serif))
                Text("UEF Citation & Reference Engine").font(.headline)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Attribution.design)
                    Text(Attribution.build)
                    Text(Attribution.method)
                    Text(Attribution.org).foregroundStyle(.secondary)
                }
                .font(.callout)
                Text("Citation architecture and project charter curation: Gemini (Google).").font(.callout).foregroundStyle(.secondary)
                Divider()
                DevelopmentRecord(expanded: true)
            }
            .padding(20)
        }
    }
}

/// The charter's RPA Attribution Log — developer record, shown in Records and Credits.
struct DevelopmentRecord: View {
    @State var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            let entries = Attribution.log()
            VStack(alignment: .leading, spacing: 10) {
                if entries.isEmpty {
                    Text("The project charter wasn't bundled with this build — reinstall with scripts/install-capture-app.sh.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(entries.reversed()) { e in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(e.heading).font(.caption.bold())
                        Text((try? AttributedString(markdown: e.body)) ?? AttributedString(e.body))
                            .font(.caption).textSelection(.enabled)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 4) {
                Text("Development record (RPA log)")
                Text("· for developers").foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }
}
