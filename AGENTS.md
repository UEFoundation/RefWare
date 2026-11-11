# RefWare for AI agents

RefWare is built to be operated by people and AI agents together, on the same library, with the same checks. People mostly use the RefWare app; agents use the `refware` command line. Both go through one engine and one `library.json`, so neither can get ahead of the other. Every logged action records who took it.

## Setup

```sh
export REFWARE_ACTOR="Claude Opus 5.5"     # who you are — recorded on everything you do (or pass --by on each command)
export REFWARE_ACTOR_TYPE=ai               # a named actor is assumed to be an AI; people running the CLI set "human"
export REFWARE_MODEL="claude-opus-5-5"     # optional; recorded on your review events
refware config                             # shows the library and project the human lead has set; don't change these unasked
```

Use `--json` on read commands for parseable output: `list`, `show`, `status`, `worklist`, `refresh`, `recent`, `claims list`, `claims evidence`, `claims history`.

## Ground rules

1. **Never write a citation by hand.** In drafts, cite with tags and let `refware cite` produce (Author, Year) and the reference list:
   - `[IDI 12]`, `[IDI 12, 7]`, `[IDI 12, p. 4]`, `[IDI 12, narrative]`
   - `[IDI 12-Q1]` cites a verified quote, page included.
   - `[IDI # - ALLREF]` produces the reference list.

   If a source isn't in the library, add it (`refware add --doi …` or `refware capture <url>`); don't approximate it.
2. **Quotes are verified, not typed.**
   - `refware claims evidence <C#>` suggests passages from the source PDF.
   - `--record N` (or `refware quote add`) checks the exact words against the PDF and refuses anything that isn't there. Numbers, decimals, signs and `% < > =` must match exactly; the stored quote is the PDF's own wording.
   - Each quote is bound to its PDF's SHA-256. If a record's PDF is replaced, its quotes are rechecked; any no longer in the new PDF are marked **stale** (kept, never deleted) and stop counting as support. `refware recheck --all` re-runs the check; `refware worklist` lists stale quotes and shared PDFs.
3. **RefWare finds; people judge.** Whether a passage *supports* a claim is an editorial decision.
   - Your `claims set <C#> --status S --reason r1,r2 --note "…"` is recorded as a **proposal**, attributed to you. The status changes only when a person accepts it (`claims accept`, or Accept in the app). The human lead can delegate with `refware project policy UEF-XXXX --ai-may-finalize yes`.
   - `supported` is refused without a current verified quote from one of the claim's own sources — even as a proposal.
   - Doubt about a claim, whatever its status: `claims flag <C#> --reason overclaim --note "…"`. Discussion: `claims comment <C#> --text "…"`. The whole trail: `claims history <C#>`.
4. **Don't merge or confirm on a guess.**
   - `refware refresh <IDI>` and `refware identify <IDI>` list suggestions with their evidence and a stable key (`doi:…`, `idi:12`, `details:…`). Apply with `--apply <key>` — list numbers aren't accepted, since results can change between runs. Apply only *confident* ones, or ones the human lead approves. If author, year and title all change, RefWare warns that the PDF is a different work — stop and ask.
   - `refware confirm <IDI>` records a check you made yourself. Record a person's check with `--checked-by SMH` only when they did it. Editing a record's author, year or title removes its old check.
   - Same title is not proof of the same work. Check year and DOI, and use `refware distinct` for different works.
5. **A frozen library is read-only.** If a command reports the library is frozen, stop and tell the human lead. Builds still work.
   - If a command reports that the library changed on disk, someone saved meanwhile. Nothing was written; run the command again.
6. **Report what you changed.** `refware recent --hours 2` lists your actions with your actor name. Include it when you hand back.

## Common tasks

| Task | Command |
|---|---|
| What needs attention | `refware worklist` · `refware status` |
| Add a source | `refware add --doi D` · `refware capture <url>` (PDF or dated web snapshot) |
| Fix a record from its PDF | `refware refresh <IDI>` then `--apply <key>` · `refware set <IDI> --authors "Family, Given; …" --year Y …` |
| Fetch missing PDFs | `refware capture --missing` · `refware pdf orphans` · `refware pdf attach <IDI> <file> [--move]` |
| Check a manuscript's citations | `refware audit draft.docx -o audit.md` |
| Import anything that lists works | `refware import file.md` — bibliographies, reading lists and annotated lists (references checked; what each item says becomes a claim), claims lists, citation matrices, chat transcripts. A DOI or arXiv ID that resolves to a different work is reported, never trusted. |
| Add a reference list | `refware audit refs.md --project P --import-all [--subproject S]` (registry-checked; the rest as written, unverified) |
| Find and record evidence | `refware claims evidence C31` then `--record N` |
| Propose a judgment | `refware claims set C31 --status supported --reason direct-quote --note "…"` (a person accepts) |
| Question or discuss a claim | `refware claims flag C31 --reason overclaim --note "…"` · `claims comment C31 --text "…"` · `claims history C31` |
| Link the right source | `refware claims link C41 30 --for "WHO, 2024"` (says which unresolved citation it resolves) |
| Re-verify quotes after PDF changes | `refware recheck --all` |
| Build citations | `refware cite draft_tagged.docx -o draft_cited.docx` (logged as a C/R build, with every IDI and IDI-Q cited) |
| Uncited sources | `refware nohit [--last] [--quotes]` |
