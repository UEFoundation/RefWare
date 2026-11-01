# RefWare

**A citation and reference engine that verifies before it cites.** RefWare keeps a library of papers and web sources with registry-checked metadata. It checks quotes word for word against the source PDFs, audits hand-built reference lists, and expands `[IDI #]` tags in drafts (text or Word) into APA citations and a reference list. Every claim stops where it should: at a person's judgment.

It is built to counter two failure modes at once: language-model hallucination of citations, and human transcription error.

- **Native macOS app.** A library window with stats, status, sorting, review and merge tools. It captures pages and PDFs from the browser.
- **Command line (`refware`).** Everything the app does, scriptable, so AI agents can use the same library safely.
- **One engine, one library file.** The app and the CLI never disagree.

RefWare was designed by S. M. Hykin (Universal Emergence Foundation) and built by Claude Code (Claude Opus 5.5, Anthropic) using Coherence-Based Collaboration. See [NOTICE](NOTICE) for the full attribution log and `Project Charter RefWare.txt` for the project charter.

**For AI agents:** see [AGENTS.md](AGENTS.md). Every action is logged with who took it (`REFWARE_ACTOR` / `--by`), and read commands support `--json`.

## Install

RefWare runs on **macOS 14 (Sonoma) or later**, on Apple Silicon and Intel Macs. It needs network access for lookups (Crossref, DataCite, arXiv, Unpaywall).

### Option A: download the app

1. From [Releases](../../releases), download `RefWare-<version>-macOS.zip` and unzip it.
2. Drag **RefWare.app** into Applications and open it. The first time, macOS says it can't verify the developer: this release isn't notarized by Apple yet. Open **System Settings ▸ Privacy & Security**, click **Open Anyway** next to RefWare, and confirm. You only do this once.
3. Follow `INSTALL.txt` in the zip to set your library, put the `refware` command on your PATH (for you and AI agents), and add the Chrome extension.

### Option B: build from source

Needs Apple's free Command Line Tools (`xcode-select --install`) or Xcode.

```sh
git clone https://github.com/UEFoundation/RefWare.git
cd RefWare
swift test                                    # optional: the test suite
./scripts/install-capture-app.sh              # ~/Applications/RefWare.app, and ~/.local/bin/refware
refware config --library ~/RefWare/library.json --project UEF-0001 --mailto you@example.org --reviewer ABC
refware open                                  # the library window
```

If `refware` isn't found, add `~/.local/bin` to your PATH (the installer prints the line to use).

### Chrome extension (optional)

The extension sends the page or PDF you're viewing to RefWare with one click or a right-click. In Chrome (or Brave, Edge or Arc), open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked**, and choose the `browser/chrome` folder (or "RefWare Chrome Extension" in the download). Then open RefWare once, so it can connect to the browser.

### Making a release

`./scripts/make-release.sh 1.0` builds `dist/RefWare-1.0-macOS.zip`: a universal app, the extension, and install notes. Attach it to a GitHub Release.

## Workflow

```sh
export REFWARE_LIBRARY=~/RefWare/library.json   # any path; iCloud Drive works
export REFWARE_MAILTO=you@example.org              # Crossref polite pool

refware add --doi 10.1038/s41586-021-03819-2 --project UEF-0001 --handle alphafold
refware add --url https://arxiv.org/abs/1706.03762
refware add --title "…" --author Smith          # fuzzy: prints candidates, adds nothing
refware set 2 --project UEF-0002 --type preprint --file IDI-0002.pdf
refware cite draft.txt -o final.txt --project UEF-0001
```

## The RefWare window

Open **RefWare** from the Dock, Spotlight or `~/Applications`, or run `refware open`. It's built from S. M. Hykin's GUI design (2026-10-12):

- **Title card / menu:** project picker, *Subdirectories?* (sub-projects), *Freeze?* (read-only library), and seven sections with +/−: **Stats, Sort, Status, Actions, Exports, Records, Projects**.
- **Submenus:** stack as colored cards beside the table, or collapse into tabs under it. ⇄ swaps the menu with the active card.
- **Resource View:** a sortable, searchable table. Clicking a number in Stats or Status filters it. Selecting a record opens its detail panel (edit fields, PDF preview, quotes, claims, C/R build hits, sub-projects, find-matches / merge / mark checked).
- **Shared with the CLI and agents.** Every edit re-reads `library.json`, applies the change and saves, and the window watches the file. Anything `refware` (or a Claude Code instance using it) changes appears within ~2 s, and the window never overwrites it with a stale copy.

New engine pieces behind it (also on the command line):

- **History** (`refware-history.json` + `Exports/` beside the library) logs C/R builds with every IDI and IDI-Q cited, claims-list and reference-list exports (archived), transcript imports, PDFs added, quotes verified, merges and freezes.
- **`[IDI 12-Q1]`** cites a verified quote, taking its page number from the quote record: (Smith, 2020, p. 4).
- **Sub-projects:** `refware project create UEF-0001 --subproject "Section 1.3"`, `refware set 37 --subproject "Section 1.3"`, `refware claims set C4 --subproject …`.
- **Freeze:** `refware freeze --note "as submitted"` / `refware unfreeze`. While frozen, every edit is refused; builds still work and are logged.
- **`refware status`, `refware nohit [--last] [--quotes]`:** the Stats/Status panels as text.

## One-click capture (pages, PDFs, DOIs → library)

```sh
./scripts/install-capture-app.sh                                   # builds ~/Applications/RefWare.app, registers refware://
refware config --library ~/RefWare/library.json --project UEF-0001 --mailto you@example.org
refware capture <url> [--claim C9]                                  # the same thing from the terminal
```

- **Chrome extension (`browser/chrome`).** Right-click a page: *Add this page to RefWare*. Right-click a link: *Add linked item to RefWare*. The toolbar button or ⌥⇧R adds the current tab, including PDFs in Chrome's viewer. Install it as described under [Install](#chrome-extension-optional).
- **Bookmarklet.** Save `javascript:(()=>{location.href='refware://capture?url='+encodeURIComponent(location.href)})()` as a bookmark named "Send to RefWare". One click sends the current page.
- **Front tab.** Launching *RefWare* (Spotlight, or a keyboard shortcut via Shortcuts ▸ Open App) captures the front tab of Safari, Chrome, Arc, Edge or Brave. This also works for PDFs open in the browser.
- **Claims report.** Sources without a PDF get a `📥 capture` link that also links the source to that claim.
- **What capture stores.** Metadata comes from the search cascade (DOI / arXiv / page metadata); existing entries are recognized. The document is the linked PDF, the arXiv PDF, an Unpaywall open-access copy, or — for web copy such as press releases — a dated WebKit snapshot (`…_web-YYYY-MM-DD.pdf`) that `quote add` can verify against. Bot-check pages are refused, never saved.
- **PDFs without metadata.** Capture reads the PDF's own first page. It checks for an existing record whose title is printed there, a DOI or arXiv stamp, a Crossref match (title *and* first author on the page), or a JSTOR cover sheet. Scanned PDFs are OCR'd on-device first. Exactly one confident match is applied automatically. Anything else opens **RefWare Review**.
- **RefWare Review** (`refware review`, or open the app when no browser tab is in front) works through possible duplicates, placeholders and unverified records. Each record shows a PDF preview and suggestions with their evidence, plus one-click *Merge into IDI n*, *Use this record* or *Use these details*. It also offers *Attach PDF…*, *Mark as Checked* (records who confirmed it, and when) and *Different works*.
- **Merging** (`refware merge 57 --into 37`) keeps the survivor's metadata and moves the PDF, quotes (renumbered) and claim links. It retires the old number permanently: `[IDI 57]` in a draft still resolves to 37, and 57 is never reissued.
- **Reviewer notes.** Notes typed into an exported claims report can be stored on the claims with `refware claims import-notes <file.md>`, so later exports keep them.

## Word (.docx) citations

```sh
refware tag draft.docx --project UEF-0001 -o draft_tagged.docx    # one-time: hand-typed citations → [IDI] tags
refware cite draft_tagged.docx -o draft_cited.docx --project UEF-0001 [--require-verified]
```

- **Never converts the document.** `cite` opens the package, edits only the text runs holding tags, and copies every other part byte-for-byte: images, styles, comments, footnotes. It works across Word's run splits (`[IDI ` · `12` · `]`), and in footnotes, endnotes and text boxes. The input file is never overwritten.
- **Tags:** `[IDI 12]`, `[IDI 12, 7]`, `[IDI 12, p. 4]`, `[IDI 12, narrative]` → Smith et al. (2020), `[IDI # - ALLREF]`.
- **ALLREF** becomes one paragraph per *cited* work, in the tag paragraph's style and font. Italics follow APA: journal and volume, or the title for standalone works such as preprints, reports and web pages. A 0.5″ hanging indent is added unless the paragraph already sets an indent (`--no-indent` to skip).
- **`tag` is conservative.** A citation is converted only when every item matches exactly one entry by first author (or organization acronym) and year. Anything else is left as typed and listed. The reference section is replaced only if every entry is in the library. Entries without a registry record are imported **unverified**, and `cite --require-verified` refuses them.
- **Keep the list in the library.** Once a draft carries tags, the reference list is rebuilt from the library on every `cite`, so a stale copy can't creep back in.

## Auditing a manuscript's citations

```sh
refware audit draft.docx --project UEF-0001 -o audit.md            # also .md .txt .rtf .odt (.pages → export to Word first)
refware audit draft.docx --project UEF-0001 -o audit.md --import   # + add DOI-matched references to the library
refware audit draft.docx --project UEF-0001 -o audit.md --claims   # + every cited sentence becomes a claim linked to its IDIs
refware audit draft.docx --project UEF-0001 -o audit.md --references-out refs.txt   # + the rebuilt list alone, ready to paste
```

- **Lookup order.** No DOI in an entry: ACL Anthology links resolve to their DOIs, arXiv links to the arXiv record, then exact title + author + year, then the linked page's own metadata (🌐). PDF-only links are confirmed to load (🔗), and dead links are reported (💀). Rate limits (429/503) are retried with backoff.
- **Formatting check.** The list is also checked as typed: missing "&", missing commas between authors, `Zhang.,`, year after title, period after a DOI, stray capitals. Repeated patterns are summarized at the top of the report.
- **Preprints.** An entry naming a venue (ICLR, NeurIPS) but linking the arXiv preprint gets one "version" note, not year/journal errors.

- **Reference entries.** Each entry is looked up by its DOI: Crossref, then DataCite for Zenodo, arXiv and figshare. Author count and order, family names, initials, year, title, journal, volume, issue, pages and article number are compared field by field. Capitalization and punctuation are ignored. A year that appears in the record as a print or online date is "minor", not an error.
- **Entries without a DOI** are matched only by exact title + first author + year, and are marked 🔎 to confirm. Same-title records from other years (re-deposits, junk copies) are listed but never matched.
- **In-text citations.** Every `(Author, Year)` and `Author (Year)` is checked against the list:
  - missing entries and wrong years;
  - `et al.` misuse (1 author → Smith; 2 → Smith & Jones; 3+ → Smith et al.);
  - citing a non-first author;
  - ambiguous same-author/same-year works without a/b suffixes;
  - entries that are never cited.
- **Rebuilt reference list.** Alphabetized, generated from the registry records; up to 10 authors named, then et al. (house style). Entries that weren't found are kept as written and marked ❓.

## Verifying claims from a chat transcript

```sh
refware claims import chat.txt --project UEF-0001 --self-domain my-lab.example
refware claims resolve --project UEF-0001        # footnotes/links → IDIs; unlinked titles → candidates only
refware pdf fetch --all                          # arXiv PDFs → PDFs/IDI-0002_Haller_2025.pdf
refware pdf attach 7 ~/Downloads/page.pdf        # anything else, downloaded by hand
refware claims list --project UEF-0001
refware quote check 13 --text "…exact passage…"  # is it really in the PDF?
refware quote add 13 --project UEF-0001 --claim C28 --text "…"   # records IDI 13-Q1 (page, line)
refware claims set C28 --project UEF-0001 --status supported     # refused without a verified quote
refware claims flag C28 --project UEF-0001 --reason overclaim --note "…"   # questioned, whatever the status
refware claims history C28 --project UEF-0001                    # who judged, flagged, commented — and when
refware claims export --project UEF-0001 -o claims.md            # hand-off report
refware recheck --all                                            # re-verify quotes if PDFs were replaced
```

- **Import** is mechanical. Footnotes are resolved per turn. A line becomes a candidate claim if it cites something, names a work, or says "research shows…" with no citation. Flags: `unlinked-title`, `contains-quotation`, `uncited-evidence`.
- **Quotes** match on the exact letters and digits in order. Line breaks, hyphenation, ligatures, case and punctuation between words are ignored. A changed word or number is not, and nor are decimal points, thousands separators, signs, ranges or `% < > = ≤ ≥ ±` ("4.3" ≠ "43", "p < .05" ≠ "p > .05"). The stored quote is the PDF's own wording. Page = PDF page; line = nth text line on that page.
- **Quotes are bound to their PDF** by SHA-256. Replacing a record's PDF rechecks its quotes; a quote no longer found is marked *stale* (kept on record, shown in Review and Stats) and no longer counts as support. A PDF already belonging to another record can't be attached to a second one — merge the records instead.
- **Statuses:** `supported` (needs ≥ 1 current verified quote from one of the claim's sources), `overstated`, `unsupported`, `source-not-found`, `self-citation`, `dropped`.
- **Review trail.** Every judgment, flag, comment and resolution is kept on the claim, attributed to a person or to an AI (with its model). An AI's judgment is a *proposal* until a person accepts it, unless the project allows otherwise (`refware project policy UEF-0001 --ai-may-finalize yes`). A *questioned* flag is independent of status: a supported claim can be questioned. The Claims window shows the trail, with filters for unreviewed, awaiting decision, questioned and stale quotes.
- The reference test case is `Tests/RefWareCoreTests/Fixtures/sample-transcript.txt (synthetic)`.

## Tags

| In the manuscript   | Output                                  |
|---------------------|-----------------------------------------|
| `[IDI 12]`          | `(Smith, 2020)`                         |
| `[IDI 12, 7]`       | `(Jones & Lee, 2019; Smith, 2020)`      |
| `[IDI 12, p. 4]`    | `(Smith, 2020, p. 4)`                   |
| `[IDI 12, narrative]` | `Smith (2020)`                        |
| `[IDI 12, possessive]` | `Smith’s (2020)`                     |
| `[IDI 12-Q1]`       | `(Smith, 2020, p. 4)` — page from verified quote Q1 |
| `[IDI # - ALLREF]`  | Alphabetized list of every work cited   |

`#` and `-` are optional (`[IDI #12]`, `[IDI-ALLREF]`). Style is APA 7: `et al.` for 3+ authors, `a`/`b` suffixes for same-author-same-year works, and first-author initials when two different authors share a surname and year ("J. Zhao et al., 2025" / "K. Zhao et al., 2025"). Tags inside `<!-- comments -->` are ignored.

## Verification rules

- **Search cascade:** DOI → URL → Title → Claim → Outlet → Author. It stops at the first step that returns anything.
- Only exact-key hits (DOI via Crossref, or metadata a URL declares about itself) are stored, marked `verified`. Fuzzy steps return candidates and add nothing until a human re-runs `add --doi` with the right one.
- `cite` is all-or-nothing: any unknown IDI or malformed `[IDI …]` tag aborts with line numbers, and no output is written. `--require-verified` also rejects unverified references.
- **Safe saves.** Every save is locked and checks the file on disk first. If the library is frozen, or someone else saved since it was loaded, nothing is written. An unreadable history file is set aside, never overwritten.
- Publication type is never inferred from "journal-article" (that doesn't establish peer review). It stays `unclassified` until set.

## Layout

- `Sources/RefWareCore/Model/` — Reference, Author, Library (JSON store), ProjectCitationIndex, QuoteRecord
- `Sources/RefWareCore/Search/` — Crossref client, web `citation_*` meta reader, cascade
- `Sources/RefWareCore/Parsing/` — tag parser, document processor
- `Sources/RefWareCore/Formatting/` — APA formatter
- `Sources/refware/` — CLI

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
