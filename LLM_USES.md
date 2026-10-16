# Lumos for LLMs and AI agents

Agents that work on a user's Mac (Claude Code, Cursor, Codex, and similar) spend a lot of time and tokens just finding files. `lumos` turns that into one cheap command.

## The problem

- **`find` and `ls -R`** walk the disk on every call. Over a home folder that takes seconds to minutes, prints thousands of lines the model has to read, and can trigger macOS privacy prompts for Desktop, Documents, and Downloads. `ls -R` cannot skip folders, so it also wanders through `~/Library`, which holds most of the files on a typical Mac.
- **`mdfind`** depends on Spotlight. Files that Spotlight has not indexed yet, or folders it skips, are silently missing, and an empty result never says which.
- **Guessing paths** ("it's probably in `~/Documents/Clients`") leads to retries, and "no results" never means the file really does not exist.

## Measured

A real home folder with about 420,000 indexed files, on an M1 Pro. Every tool searched the same folders. `lumos` times are the median of 3 runs.

| Search | `lumos` | `find` | `rg --files` | `mdfind` |
| --- | --- | --- | --- | --- |
| Names containing "readme" | 0.10 s, 3,514 | 8.0 s, 3,546 | 0.94 s, 3,536 | 0.20 s, **1,590** |
| All PDFs | 0.04 s, 568 | 6.7 s, 574 | 0.96 s, 574 | 0.27 s, 584 |
| Files modified today | 0.03 s, 36 | 6.7 s, 36 | can't filter by date | 0.32 s, 159 (includes other changes) |
| A file created a moment earlier | 0.03 s, found | 4.8 s, found | not tested | 0.08 s, **missed** |

- **Searching for "resume" documents:** `lumos` 0.23 s and `mdfind` 0.10 s found the same 55 documents. `ls -R` over the same folders took 5.0 s and found the same files. Over the whole home folder, `ls -R` was stopped after 2 minutes.
- **Where the gaps came from:** every file `find` saw that `lumos` did not was inside a `.app` bundle, which Lumos skips on purpose. Nothing `lumos` returned was missing from `find`.
- **Cold start:** with nothing running, the first `lumos` call started the background indexer from its saved index and answered in 0.3 s.

## When other tools are fine

- **Document folders Spotlight indexed long ago:** `mdfind -name` is fast and usually complete.
- **File contents:** use `rg` or Spotlight's content search. Lumos never reads inside files.
- **Inside one code project:** the agent's own file search or `rg --files` is fast and respects `.gitignore`.

Use `lumos` when the answer has to be complete and current: "does this exist", "what changed today", a file the user just saved, or a search across the whole home folder.

## What `lumos` gives an agent

- **Milliseconds per query** over the whole indexed disk (30–100 ms in the tests below, against 5–8 s for `find`), so the agent can search freely instead of rationing calls.
- **Small output.** 50 paths by default, with the total count and the next `--offset` in `#` lines. `--count` returns a single number.
- **A trustworthy "no".** Each answer says `# Index exact` when every change on disk has been applied, so "no matches" means the file is not in the indexed folders. The agent does not need to re-check with `find`.
- **Structured output** with `--json`, and stable exit codes: 0 matches, 1 no matches, 2 error.
- **No setup per call.** If the Lumos app is not open, `lumos` starts its own background indexer and stops it after 15 idle minutes.

## Use cases

Find a document from a vague description:

```bash
lumos find acme nda 'ext:pdf;docx' --newest -n 5
```

Gather every copy of a document scattered across Downloads and Documents (tailored versions, `(1)` duplicates, files in odd folders), newest first:

```bash
lumos find resume 'ext:pdf;docx;pages' --newest -n 100
```

Common words also match code: "resume" hits files like `RESUME_EVENT.js` inside `node_modules`. Add `ext:` or `--in` to keep only documents, and `--files` to leave out folders with the same name.

List every version of a file before editing one, so the agent picks the latest:

```bash
lumos find "engagement letter" --in ~/Documents/Clients/Acme --long
```

See what the user worked on recently:

```bash
lumos find --files dm:today --newest -n 20
lumos find 'ext:pdf;docx;xlsx' dm:thisweek --newest
```

Size up a folder before reading it, instead of listing it:

```bash
lumos find --in ~/Documents/Matters/2024 --files --count
lumos find --in ~/Documents/Matters/2024 --folders -n 100
```

Find what is taking up space:

```bash
lumos find --files 'size:>1gb' --largest -n 20
```

Confirm a file does not exist before creating it:

```bash
lumos find "Q3 board deck" --count    # 0 with "Index exact" means it is not there
```

Hand paths to content tools. Lumos finds names; tools like `rg`, `pdftotext`, or the agent's own file reader handle contents:

```bash
lumos find 'ext:md;txt' --in ~/Notes -n 1000 | grep -v '^#' | xargs -I{} rg -l "indemnification" "{}"
```

Feed structured results to a script:

```bash
lumos find invoice ext:pdf dm:thismonth --json
```

## Setting up an agent

```bash
make install-cli            # puts lumos on PATH via ~/.local/bin
lumos guide >> AGENTS.md    # or CLAUDE.md, or a Cursor rule
```

`lumos guide` prints a short usage note written for models: query syntax, options, how to read `Index exact`, and what is not indexed. Agents that read `AGENTS.md` or `CLAUDE.md` will then reach for `lumos` instead of `find`.

Tell the agent to keep `find`, `mdfind`, or its own file search as a fallback for when `lumos` is missing, errors, or the folder is not indexed. Content searches stay with `rg`.

**Sandboxed agents.** Some agents run shell commands in a sandbox that blocks the Lumos socket and the background indexer. `lumos` then reports that no index is running. Allow `lumos` to run outside the sandbox; in Cursor, add it to the command allowlist (Settings → Agents → Auto-Run).

## Limits

- File and folder names only, not file contents.
- Only the indexed folders (`lumos status` lists them). `~/Library`, caches, Trash, the inside of app bundles, and macOS recents lists are skipped.
- Network volumes have no reliable change journal and are re-checked every 10 minutes, so very recent changes there can be missing.

## Cost and privacy

Everything runs on the user's Mac. There is no server, account, API key, or network call. Queries travel over a local Unix socket that only the user's account can open, and queries and results are never logged or stored.
