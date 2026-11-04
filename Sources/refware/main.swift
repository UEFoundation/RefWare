import Foundation
import RefWareCore

let usage = """
usage: refware <command> [options]

commands:
  add     Look up a paper via the search cascade and add it to the library
            --doi D --url U --title T --claim C --outlet O --author A
            --project UEF-XXXX [--handle NAME] [--file NAME.pdf] [--type TYPE]
  set     Edit a reference's internal metadata
            <IDI> [--project UEF-XXXX [--handle NAME]] [--file NAME.pdf] [--type TYPE]
                  [--title T] [--url U] [--year Y] [--publication P] [--org-author "Gartner, Inc."]
                  [--authors "Family, Given; Family, Given"] [--volume V] [--issue I] [--pages P] [--doi D]
  list    List every reference in the library
  show    Show one reference:  show <IDI>
  cite    Replace [IDI #] tags with citations and build the reference list
            <input.txt|.md> [-o OUTPUT] [--project UEF-XXXX] [--markdown] [--require-verified]
            <input.docx> -o OUTPUT.docx [--project UEF-XXXX] [--require-verified] [--no-indent]
            tags: [IDI 12]  [IDI 12, 7]  [IDI 12, p. 4]  [IDI 12, narrative]  [IDI # - ALLREF]
  tag     Convert a hand-cited .docx to [IDI] tags (audits and imports every reference first)
            <manuscript.docx> --project UEF-XXXX -o TAGGED.docx

  audit   Check a manuscript's reference list and in-text citations against the DOI registries
            <manuscript.docx|.md|.txt|.rtf> [--project UEF-XXXX] [-o audit.md] [--references-out refs.txt] [--import] [--claims]
            --import adds DOI-verified references to the library; --import-all also adds the rest as written, unverified
            [--subproject S] files them in a sub-project; --claims also turns every cited sentence into a claim

  claims  Verify claims from a chat transcript (all need --project UEF-XXXX)
            import <chat.txt | claims.md | matrix.md> [--speaker NAME] [--self-domain a.com] [--subproject S]   (format detected automatically;
                                    a citation matrix's bibliography is added first, unverified where no DOI matches — --no-bibliography skips it)
            resolve                 link footnotes/links/titles to IDIs (exact matches only)
            list [--status S]       show <C#>
            link <C#> <IDI> [--for "<what the claim named>"]   attach a reference you located yourself
            set <C#> --status S [--reason r1,r2] [--note "…"]   an AI's judgment is a proposal unless the project allows otherwise
            accept <C#> | reject <C#> [--note "…"]   a person accepts or declines a pending proposal
            flag <C#> --reason R [--note "…"]   question a claim (independent of its status);  resolve-flag <C#> [--note "…"]
            comment <C#> --text "…"    history <C#> [--json]   the claim's attributed review trail
            add --text "…"          add a claim by hand
            export [-o claims.md]   hand-off report
            import-notes <edited.md>  keep notes you typed into an exported report (stored on each claim)
            evidence <C#> [--record N]  candidate supporting passages from the linked PDFs; record one as an IDI-Q
  capture Send a page, PDF link, or DOI to the library — metadata plus the PDF (or a dated web snapshot)
            <url> [--project UEF-XXXX] [--claim C#] [--replace]
            --missing                every record with a link but no PDF
  status  Stats & Status for a project (or sub-project): PDFs, verified claims, exports, build hits
  nohit   [--last] [--quotes]   records (or IDI-Qs) never cited in a cite/ref build (or not in the last one)
  project list | create UEF-XXXX [--subproject S] | add-subproject UEF-XXXX "S"
          policy UEF-XXXX [--ai-may-finalize yes|no]   may an AI's judgment set a claim's status? (default: no — it's a proposal)
  freeze  [--note "as submitted"]   lock the library read-only (builds still work);  unfreeze  to unlock
  open    Open the RefWare library window (also: launch RefWare from the Dock or Spotlight)
  worklist [--json]             what RefWare Review shows: duplicates, placeholders, unverified, shared PDFs, stale quotes
  recheck [<IDI>… | --all]      re-verify recorded quotes against each record's current PDF (stale ones are flagged, never deleted)
  refresh <IDI> [--apply KEY]   suggestions from the record's PDF (properties, cover, DOI), the registry, the library
  recent  [--hours 24]          what happened lately — captures, quotes, builds, merges — and who did it
  review  Open the RefWare Review window (placeholders, unverified records, duplicates)
  identify <IDI> [--apply KEY] suggest what a placeholder's PDF really is; apply a suggestion
  merge   <IDI> --into <IDI> [--take-details] [--prefer-incoming-pdf]   combine two records; the first number is retired
            --take-details: keep the second number but use the first record's details and PDF (e.g. a fixed broken link)
  confirm <IDI>… [--checked-by SMH]   you've checked author/year/title against the source (= Mark as Checked); unconfirm to undo
  distinct <IDI> <IDI>…        same title, different works — stop flagging as duplicates
  delete  <IDI> [--reason "…"] [--drop-claims]   remove a record (number retired; PDF kept in PDFs/deleted/)
  config  Defaults for capture and the RefWare Capture app
            [--library PATH] [--project UEF-XXXX] [--mailto EMAIL] [--reviewer SMH]
  pdf     fetch <IDI> | --all       download arXiv / open-access PDFs into PDFs/ next to the library
          attach <IDI> <file.pdf> [--move]   add a PDF (the previous one is kept in PDFs/merged/)
          orphans                   PDFs in the library folder that no record points to
  quote   check <IDI> --text "…"    is this exact passage in the PDF?
          add <IDI> --text "…" --project P [--claim C#]   verify and record as IDI #-Q#

global options:
  --by NAME        who is acting, recorded in the history (default: $REFWARE_ACTOR) — agents should set this
  --actor-type human|ai   (default: $REFWARE_ACTOR_TYPE; a named actor without a type is taken to be an AI agent)
                   AI agents may also set $REFWARE_MODEL (recorded on review events)
  --json           machine-readable output (show, list, status, worklist, refresh, recent, claims list/evidence)
  --library PATH   library file (default: $REFWARE_LIBRARY or ./library.json)
  --mailto EMAIL   contact address for Crossref (default: $REFWARE_MAILTO)

publication types: \(PublicationType.allCases.map(\.rawValue).joined(separator: ", "))
claim statuses: \(ClaimStatus.allCases.map(\.rawValue).joined(separator: ", "))
"""

// Launched by Chrome as a native-messaging host (first argument is the extension's origin).
if CommandLine.arguments.dropFirst().first?.hasPrefix("chrome-extension://") == true { nativeHost() }

do {
    var argv = Array(CommandLine.arguments.dropFirst())
    guard !argv.isEmpty else { print(usage); exit(0) }
    let command = argv.removeFirst()
    if ["--help", "-h", "help", "-help"].contains(command) { print(usage); exit(0) }
    let args = try Arguments(argv)
    if args.flags.contains("help") { print(usage); exit(0) }
    // Who is acting — recorded on every logged action (agents: set REFWARE_ACTOR or pass --by).
    if let by = args.options["by"] { HistoryEvent.defaultActor = by }
    if let t = args.options["actor-type"] { Reviewer.typeOverride = ReviewEvent.ReviewerType(rawValue: t.lowercased()) }
    let changesThings = ["add", "set", "claims", "pdf", "quote", "capture", "identify", "merge", "confirm", "unconfirm", "delete",
                         "project", "freeze", "unfreeze", "recheck", "distinct", "refresh", "tag"].contains(command)
    let readOnlyClaims = command == "claims" && ["list", "show", "history", "export"].contains(args.positionals.first ?? "")
    if changesThings, !readOnlyClaims, HistoryEvent.defaultActor == nil, isatty(STDIN_FILENO) == 0 {
        FileHandle.standardError.write(Data("note: no actor set — changes are logged without a name. Agents: export REFWARE_ACTOR=\"<your name>\" or pass --by.\n".utf8))
    }

    switch command {
    case "add": try await add(args)
    case "set": try set(args)
    case "cite": try cite(args)
    case "claims": try await claims(args)
    case "pdf": try await pdf(args)
    case "quote": try quote(args)
    case "audit": try await audit(args)
    case "capture": try await capture(args)
    case "identify": try await identify(args)
    case "merge": try merge(args)
    case "confirm": try confirm(args)
    case "unconfirm": try unconfirm(args)
    case "delete": try delete(args)
    case "project": try project(args)
    case "freeze": try freeze(args, on: true)
    case "unfreeze": try freeze(args, on: false)
    case "status": try status(args)
    case "worklist": try worklist(args)
    case "recheck": try recheck(args)
    case "refresh": try await refresh(args)
    case "recent": try recent(args)
    case "nohit": try nohit(args)
    case "distinct": try distinct(args)
    case "open", "gui", "library":
        _ = Process.launchedProcess(launchPath: "/usr/bin/open", arguments: ["refware://library"])
    case "review":
        guard let url = URL(string: "refware://review") else { break }
        _ = Process.launchedProcess(launchPath: "/usr/bin/open", arguments: [url.absoluteString])
    case "config": try configure(args)
    case "tag": try await tagManuscript(args)
    case "list":
        let library = try Library.load(from: libraryURL(args))
        let refs = library.references.values.sorted { $0.id < $1.id }
        if args.flags.contains("json") { try printJSON(refs); break }
        let f = CitationFormatter(references: refs)
        if refs.isEmpty { print("Library is empty.") }
        for ref in refs { print("[IDI \(ref.id)] \(f.inline([ref]))  \(ref.title)") }
    case "show":
        guard let raw = args.positionals.first, let id = Int(raw) else { throw UsageError(description: "show needs an IDI") }
        let library = try Library.load(from: libraryURL(args))
        guard let ref = library[id] else { throw LibraryError.unknownIDI(id) }
        if args.flags.contains("json") { try printJSON(ref); break }
        print(describe(ref, in: library))
    case "help", "-h": print(usage)
    default: throw UsageError(description: "unknown command \"\(command)\"\n\n\(usage)")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
