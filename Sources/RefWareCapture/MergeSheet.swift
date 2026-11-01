import AppKit
import RefWareCore
import SwiftUI

/// "Merge with…": combine this record with any other — e.g. a broken-link record with the
/// verified record you captured to replace it. You choose which number survives and whose
/// details to keep; the defaults keep the number your claims cite and the verified details.
struct MergeSheet: View {
    @ObservedObject var store: LibraryStore
    let id: IDI
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var other: IDI?
    @State private var keepThisNumber = true
    @State private var useThisDetails = false

    var me: Reference? { store.library[id] }

    /// Recent captures and similar titles first, then everything else.
    var candidates: [Reference] {
        guard let me else { return [] }
        let all = store.library.references.values.filter { $0.id != id }
        let q = search.lowercased().split(separator: " ").map(String.init)
        let filtered = q.isEmpty ? Array(all) : all.filter { r in let hay = searchText(r); return q.allSatisfy { hay.contains($0) } }
        let mine = Set(TextCleanup.comparable(me.title).split(separator: " ").filter { $0.count > 3 })
        let recent = Set(store.recentCaptures(excluding: id).map(\.0))
        func score(_ r: Reference) -> Double {
            let words = Set(TextCleanup.comparable(r.title).split(separator: " ").filter { $0.count > 3 })
            let overlap = mine.isEmpty ? 0 : Double(mine.intersection(words).count) / Double(mine.count)
            let sameAuthor = (me.authors.first?.family).map { f in r.authors.first.map { ManuscriptAuditor.sameName($0.family, f) } ?? false } ?? false
            return overlap * 3 + (sameAuthor ? 2 : 0) + (recent.contains(r.id) ? 2 : 0) + (r.added.map { Date().timeIntervalSince($0) < 86_400 * 7 ? 1 : 0 } ?? 0)
        }
        return filtered.sorted { score($0) == score($1) ? $0.id > $1.id : score($0) > score($1) }
    }

    func uses(_ i: IDI) -> Int {
        store.library.claimsCiting(i).count + store.library.projects.values.flatMap(\.quotes).filter { $0.reference == i }.count
    }
    func strength(_ r: Reference) -> Int {
        (r.provenance?.verified == true ? 2 : 0) + (r.fileName != nil ? 1 : 0) + (r.provenance?.confirmedBy != nil ? 1 : 0) + (r.doi != nil ? 1 : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge IDI \(id) with another record").font(.title3.bold())
            if let me { Text(CitationFormatter(references: [me]).referenceEntry(me)).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            TextField("Search title, author, IDI…", text: $search).textFieldStyle(.roundedBorder)
            List(candidates.prefix(60), id: \.id, selection: $other) { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("IDI \(r.id) · \(CitationFormatter(references: [r]).inline([r]))").font(.callout.bold())
                        if r.fileName != nil { Image(systemName: "doc.fill").font(.caption) }
                        if r.provenance?.verified == true { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.caption) }
                    }
                    Text(r.title).font(.callout).lineLimit(1)
                }
                .tag(r.id)
            }
            .frame(minHeight: 200)
            .onChange(of: other) { _, o in
                guard let o, let me, let them = store.library[o] else { return }
                // Defaults: keep the number already cited; use the stronger (verified, has PDF) details.
                keepThisNumber = uses(id) > uses(o) || (uses(id) == uses(o) && id < o)
                useThisDetails = strength(me) >= strength(them)
            }

            if let o = other, let me, let them = store.library[o] {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Keep number", selection: $keepThisNumber) {
                            Text("IDI \(id) — cited by \(uses(id)) claim(s)/quote(s)").tag(true)
                            Text("IDI \(o) — cited by \(uses(o)) claim(s)/quote(s)").tag(false)
                        }
                        Picker("Use details from", selection: $useThisDetails) {
                            Text("IDI \(id)\(me.provenance?.verified == true ? " (verified)" : "")\(me.fileName != nil ? " · has PDF" : "")").tag(true)
                            Text("IDI \(o)\(them.provenance?.verified == true ? " (verified)" : "")\(them.fileName != nil ? " · has PDF" : "")").tag(false)
                        }
                        let detailsRef = useThisDetails ? me : them
                        Text("Result: IDI \(keepThisNumber ? id : o) — " + CitationFormatter(references: [detailsRef]).referenceEntry(detailsRef))
                            .font(.callout).textSelection(.enabled)
                        Text("IDI \(keepThisNumber ? o : id) will be retired; tags and claims using it move to IDI \(keepThisNumber ? id : o). The PDF comes from the record whose details you keep (if it has one); any other PDF is kept in PDFs/merged/.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Merge") { merge() }.keyboardShortcut(.defaultAction).disabled(other == nil)
            }
        }
        .padding(20)
        .frame(width: 620, height: 600)
    }

    func merge() {
        guard let o = other, let me, let them = store.library[o] else { return }
        let survivor = keepThisNumber ? id : o, retired = keepThisNumber ? o : id
        let detailsFromRetired = (useThisDetails ? id : o) == retired
        let retiredRef = retired == id ? me : them, survivorRef = survivor == id ? me : them
        let pdfFromRetired = retiredRef.fileName != nil && (detailsFromRetired || survivorRef.fileName == nil)
        var note = ""
        if store.mutate({ lib in
            let m = try lib.merge(retired, into: survivor, pdfDirectory: store.pdfDir, preferIncomingPDF: pdfFromRetired, takeIncomingDetails: detailsFromRetired)
            note = "IDI \(m.retired) → IDI \(m.survivor)"
            return "Merged IDI \(m.retired) into IDI \(m.survivor)\(detailsFromRetired ? ", using IDI \(m.retired)'s details" : ""). \(m.pdfNote ?? "")"
        }) {
            store.record(HistoryEvent(kind: .merge, project: store.project, title: note, idis: [survivor, retired]))
            UIEvents.shared.select = survivor
        }
        dismiss()
    }
}
