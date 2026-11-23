# RefWare for AI agents

RefWare is built to be operated by people and AI agents together, on the same library, with the same checks. People mostly use the RefWare app; agents use the `refware` command line. Both go through one engine and one `library.json`, so neither can get ahead of the other. Every logged action records who took it.

## Setup

```sh
export REFWARE_ACTOR="Claude Opus 5.5"     # who you are — recorded on everything you do (or pass --by on each command)
export REFWARE_ACTOR_TYPE=ai               # a named actor is assumed to be an AI; people running the CLI set "human"
export REFWARE_MODEL="claude-opus-5-5"     # optional; recorded on your review events
refware config                             # shows the library and project the human lead has set; don't change these unasked
```

`REFWARE_PROJECT=UEF-XXXX` sets the project for your session only (MAVIS sets it for each session's project). Without it, commands that need a project use the configured default, which may be a different paper: pass `--project` when in doubt. A project that doesn't exist is an error, never an empty report.

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
6. **Never type an accession from memory.** BioProject, SRA, BioSample, GEO and dbGaP numbers are checked the same way as DOIs: `refware dataset add <ACC> --expect "what you think it is"` refuses an accession whose archive record contradicts what you said it is. Cite datasets with `[IDI n]` tags, and run `refware accessions <files>` over anything you write that names accessions.
7. **Results rest on files, not memory.** A number from an analysis is bound to the output file that produced it (`claims output` or `claims add --output`). When a rerun changes that file and the number is gone, `refware recheck` marks it stale: re-derive and rebind it, or revise the claim.
8. **Report what you changed.** `refware recent --hours 2` lists your actions with your actor name. Include it when you hand back.

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
| Add a public dataset | `refware dataset add PRJNA516684 --project P --paper 12 --expect "Kisumu couples, penile and vaginal 16S"` (archive-checked; run table saved, dated and fingerprinted) |
| Check accessions in any text | `refware accessions draft.md notes/ -o accessions.md` — not found (with one-keystroke neighbours), wrong kind ("BioProject GSE…"), a run beside the wrong study, an SRA study paired with the wrong BioProject, stated run counts that don't match |
| Check a sample manifest | `refware manifest samples.tsv -o manifest-check.md` — every run exists, is in the project and sample the row says, read counts match; typos that hit another study's run are traced to the run you meant |
| Check downloaded reads | `refware fastq reads/` — `.fastq.gz`: size and MD5 against the archive; plain FASTQ: record structure and read count (complete / partial / truncated / corrupt) |
| Record how sample names split into keys | `refware dataset key PRJNA516684 --name couple --pattern '(\d{2}-\d{2}-\d{2})-(\d{5})(\d)' --groups date,couple,member --note "why"`, then `dataset keys … -o crosswalk.tsv` (runs per key are reported, so a wrong split shows) |
| Has the archive changed? | `refware dataset runs <ACC> --refresh` (diffs against the last run table) · `dataset diff <ACC>` |
| Bind a computed result | `refware claims output C12 out/couples.txt --text "15 of 67 (22.4%)" --dataset PRJNA516684`, or `claims add --text "…" --output FILE --excerpt "…" --dataset …` |
| Supplementary data table | `refware dataset table --project P -o S1.md` (or `.tsv`) |
| Hand files to collaborators without the CLI | `refware export --project P --to <folder>` — references.md, datasets.tsv, claims.md, PDFs, run tables (copies) |

## Working with public sequence data

RefWare treats accessions the way it treats DOIs: looked up, never typed from memory, never trusted when the archive disagrees.

1. **Add each dataset once**, with what you believe it is:
   `refware dataset add PRJNA922536 --project UEF-2607 --expect "duodenal aspirates, SIBO, 16S"`.
   RefWare reads the archive (ENA, which mirrors NCBI SRA), saves the run table as `datasets/<ACC>/runs_<date>_<sha>.tsv` next to the library, and asks Europe PMC which papers cite the accession. It refuses the record if the archive contradicts `--expect`, for example an archaeology genome project given as SIBO data. `--paper IDI` links the paper the data comes from and says whether any index confirms the link. An SRA study (SRP…) is filed under its BioProject; a GEO series keeps its GSE and records its BioProject.
2. **Cite datasets with `[IDI n]`**: `refware cite` writes APA data-set entries with the accession, and `dataset table` builds the supplementary table. Don't retype accessions in prose.
3. **Before analysing**, run `refware manifest` on your sample manifest, and `refware fastq` on your downloads. Both work from the stored run tables, so everyone checks against the same, fingerprinted version.
4. **Write key rules down.** How sample names map to participants, couples, visits or sites is recorded with `dataset key`: attributed, dated, and kept when replaced (marked retired). `dataset keys` applies it and reports how many runs fall in each group, so "couples with seven samples" stands out.
5. **Bind results to output files** (`claims output`). After any rerun, `refware recheck --outputs` lists the claims whose numbers are no longer in their files. Stale bindings are kept, never deleted, and stop counting as support until a person re-checks them.
6. **Before handing back**, run `refware accessions` over the files you wrote, and `refware status` (stale outputs, datasets with warnings).

RefWare checks identity, links and whether files changed. It doesn't judge whether an analysis is right; that stays with the people and agents doing it. Keep personal data (a participant's own test results, clinical notes) out of the library: it's shared across every project.
