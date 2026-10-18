# Lumos

Instant filename search for macOS. A native window, like Everything on Windows.

Lumos indexes file names, paths, sizes, and dates. It is not Spotlight and does not search file contents.

## Why

Finding a file on a Mac is slower than it should be.

- **Spotlight shows results you never asked for.** A search for one document comes back mixed with apps, web and Siri suggestions, mail, messages, and contacts. Lumos shows only files and folders from the folders you chose to index, sorted the way you ask.
- **Spotlight is slow to index.** It reads the contents of files, so after a fresh install or a large copy it can take hours before files show up, and nothing tells you whether a missing result means "not there" or "not indexed yet". Lumos indexes names only: about 1.1 million files in roughly 5 seconds on an M1 Pro, live updates after that, and every answer says whether the index is exact.

Measured on a real home folder (about 415,000 files, M1 Pro):

- `lumos` answered most name searches in 30–60 ms. `find` took 5–10 seconds for the same answers, and `ls -R` over the whole home folder was still running after 2 minutes.
- A file created a moment before the search was found by `lumos` and missed by Spotlight (`mdfind`).
- Spotlight found 1,468 of 3,497 files with "readme" in the name, because it skips or delays some folders. It did as well as Lumos on documents that had been sitting in Downloads for months.

Lumos is also a fast file finder for AI agents. See [LLM_USES.md](LLM_USES.md) for workflows and the full comparison.

## Run

```bash
make test
make run
```

Requires macOS 14+, Apple Silicon, and the Xcode Command Line Tools. `make test` compiles a command-line suite under `tests/` (query parser, formatters, privacy skips, in-memory index, search and sorting, directory scanner and diffs, snapshot integrity, live indexing and journal replay, the query socket used by `lumos`, the trigram index matching a full scan, the MCP server, and special-character queries). GitHub Actions runs the same target on `macos-14`.

The first launch scans your home folder and `/Applications` (skipping `Library`, `Pictures`, `Music`, and `Movies`). Later launches load `~/Library/Application Support/Lumos/index.lumos` in under a second and replay the macOS file system journal to pick up anything that changed while Lumos was closed.

## Use

| Action | How |
| --- | --- |
| Show or hide Lumos from any app | Option-Space (turn off in View → Option-Space Shows Lumos) |
| Open | Double-click or Return |
| Reveal in Finder | Double-click the Path column, or Command-Return |
| Sort | Click a column header |
| Copy path | Command-C |
| Hidden files | View → Show Hidden Files |
| Rebuild from scratch | File → Clear and Reindex (the status bar then shows how long the full index took) |

Search syntax: `report`, `foo|bar`, `*.pdf`, `ext:png;jpg`, `path:Documents`, `folder:`, `size:>10mb`, `dm:today`.

## Command line and AI agents

`lumos` lets scripts and AI agents search the same index in milliseconds, instead of walking the disk with `find`, `fd`, or `mdfind`.

```bash
make install-cli          # links ~/.local/bin/lumos to the copy inside Lumos.app
lumos find engagement letter --in ~/Documents/Clients --newest -n 10
lumos guide >> AGENTS.md  # usage notes written for agents
```

Example output:

```
# 3 matches for "engagement letter" in /Users/you/Documents/Clients, newest first, showing 1–3.
# Index exact · 419,653 objects · Lumos app
/Users/you/Documents/Clients/Acme Corp/2024/Engagement Letter.pdf
...
```

- **One command, no setup.** If the Lumos app is open, `lumos` asks it. Otherwise it starts a background indexer (`lumos-index --serve`) that loads the saved index, catches up on changes, and exits after 15 minutes without queries. Opening the app takes over from it automatically.
- **Exact answers.** Before answering, Lumos makes sure every change made on disk up to that moment has been applied (it waits up to `--wait` seconds, default 10). Each answer then says `Index exact`, so "no matches" really means the file isn't in the indexed folders. If Lumos is still catching up, the answer says `Index NOT exact` instead.
- **Output sized for agents.** Plain paths, 50 at a time, with the total count and a paging hint in `#` lines. Use `--json` for structured output, `--long` for date and size, and `--count` for just the number. Exit codes: 0 matches, 1 no matches, 2 error.
- **Useful filters.** `--in PATH`, `--files` / `--folders`, `--newest`, `--largest`, `--sort`, `--hidden`, plus the normal search syntax (`ext:pdf;docx`, `path:Acme`, `dm:thisweek`, `size:>10mb`).
- **Private by design.** Queries go over a Unix socket only your user account can open (`lumos.sock` in the Lumos folder). Queries and results are never logged or stored.

`lumos help` lists every option. `lumos status` shows which folders are indexed and who is serving them. `lumos stop` stops the background indexer. See [LLM_USES.md](LLM_USES.md) for concrete agent workflows.

### MCP server

`lumos mcp` runs a [Model Context Protocol](https://modelcontextprotocol.io/) server over stdio with two tools, `find_files` and `index_status`. The AI app starts it as a local process; nothing is hosted. Point the app at the installed CLI:

```bash
claude mcp add lumos -- ~/.local/bin/lumos mcp     # Claude Code
```

```json
{ "mcpServers": { "lumos": { "command": "/Users/you/.local/bin/lumos", "args": ["mcp"] } } }
```

The JSON goes in `~/.cursor/mcp.json` for Cursor, or `~/Library/Application Support/Claude/claude_desktop_config.json` for Claude Desktop. MCP servers run outside agent shell sandboxes, so this also avoids the sandbox problem described in [LLM_USES.md](LLM_USES.md).

## How it works

- **Index in memory.** File names are kept in compact arrays (under 100 bytes per file), and each query scans them in parallel across CPU cores. The status bar shows each query's time.
- **Trigram index.** A background-built index of every three-letter chunk of every name (about 80 more bytes per file) narrows a search to the few entries that can match. The normal matcher still checks each one, so results are identical to a full scan. On about 415,000 files, name searches dropped from 1–3 ms to 0.03–1 ms. Queries with no word of three or more letters, such as `a` or `dm:today`, use the full scan. Files added since the last build are scanned until the next background rebuild.
- **Fast scanning.** Folders are read with `getattrlistbulk` on several threads. A cold scan of about 1.1 million files takes roughly 5 seconds on an M1 Pro.
- **Live updates.** macOS FSEvents reports which folders changed, and Lumos re-reads only those folders. If events are dropped, the affected tree is re-checked.
- **Saved snapshot.** The index is saved atomically to `index.lumos` (with a checksum) at most every 20 seconds and on quit. A missing or corrupt snapshot triggers a rescan instead of showing wrong results.
- **Network volumes** have no reliable change journal, so they are re-checked every 10 minutes.

## Stress test

Lumos is meant to handle a million files appearing or disappearing at once. There are two ways to test that.

### Automated (no window)

```bash
make cli
python3 scripts/stress_index.py --root ~/Documents --count 1000000 --workers 8 --timeout 900
```

This runs `build/lumos-index`, the same engine the app uses without the window, and measures how long the index takes to become exactly right after each scenario:

1. a cold scan of the root
2. adding 1M files while the engine runs
3. deleting them while it runs
4. adding them while it is stopped (journal replay on relaunch)
5. deleting them while it is stopped
6. `kill -9` in the middle of a live add, then relaunch
7. a drift check comparing the long-running index with a fresh scan

Each scenario prints an `[ok]` or failure line with timings, plus search latency during the live phases. A full run takes about 15–20 minutes; use `--count 20000` for a quick check. Test files go into `ROOT/Lumos Stress Live` and are removed during the run. The harness keeps its own index in a temporary folder, so it never touches the app's index. Quit Lumos first for clean timings, since the app would index the same churn.

### Manual (with the app)

```bash
make run
python3 scripts/stress_files.py generate --workers 8   # add 1M files
python3 scripts/stress_files.py delete --workers 8     # remove them
```

By default these create and remove `~/Documents/Stress Test Lumos`. Use `--folder PATH` to choose another location and `--count N` to change the number of files. `python3 scripts/stress_files.py status` prints the current count.

While files are being added or removed, check that:

- the object count and status at the bottom of the window keep updating, and the app stays responsive
- selecting a row and pressing Return, Command-Return, or Command-C acts on the row you selected, even while results refresh
- Command-A then Command-C copies every result
- Command-A, Command-C, and Command-V work in the search field

To test changes made while Lumos is closed, quit it, run `generate` or `delete`, then relaunch and watch it catch up.

## What is stored

On disk, only a filename catalog:

| Location | Contents |
| --- | --- |
| `~/Library/Application Support/Lumos/index.lumos` | For each file: name, parent folder, size, modification date, and flags (folder, hidden, symlink, package). Plus the indexed folders, the last processed file system event id, and volume ids so changes made while Lumos was closed can be replayed. |
| Same folder, `index.lock` | Process id of the running Lumos, so two copies never index at once. |
| Same folder, `lumos.sock` and `barrier/` | The query socket for `lumos` (exists only while Lumos runs) and empty marker files used to confirm answers are exact. |
| Same folder, `daemon.log` | Start and stop messages from the background indexer. Never queries or results. |
| UserDefaults | Folders you chose to index, the search delay setting, and whether Option-Space is on. |

Lumos does **not** store:

- what you type in the search box
- which rows came back
- files you opened
- frequently visited or recent locations (Finder recents, macOS shared-file lists)

Those stay in RAM for the session and are dropped on quit. Recents that NSOpenPanel might write are cleared. macOS recents databases (`com.apple.sharedfilelist`, `*.sfl*`) are never added to the index.

The old Everything catalog at `~/Library/Application Support/Everything/` is unused.

## License

MIT. See `LICENSE`.
