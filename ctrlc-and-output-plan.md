# loop.sh — Ctrl+C teardown + legible output (agreed design)

Status: IMPLEMENTED. Branch A + Branch B landed in loop.sh / format-stream.sh,
tests extended in tests/, full suite green (65/65). Not committed.

## Two bugs
1. **Ctrl+C does nothing.** `claude` (Node) swallows SIGINT in headless mode, so the
   foreground pipeline never dies; and bash defers trapped-signal handlers while
   waiting on a foreground command. Output keeps flowing, loop keeps running.
2. **Terminal output is illegible raw stream-json** dumped to both log and terminal.

## Branch A — killable process tree
- `set -m`; run each call's pipeline as a backgrounded subshell that re-exits with
  `${PIPESTATUS[0]}` (the real timeout/claude code, e.g. 124/130), then `wait` on it
  so the trap is interruptible:
  ```bash
  set -m
  ( timeout "$CALL_TIMEOUT" claude … 2>&1 | tee "$log" | "$FORMATTER"; exit "${PIPESTATUS[0]}" ) &
  pid=$!            # subshell = process-group leader under set -m
  wait "$pid"; ec=$?
  ```
- `trap` on INT/TERM, **disarm-on-entry** (`trap '' INT TERM` first), set guard flag,
  print immediate `⛔ Interrupting — stopping Claude and all child processes…`,
  then call shared `terminate_tree`, print calm notice, `exit 130`.
- `terminate_tree <pgid>`: `kill -TERM -- -<pgid>` → 2s grace → `kill -KILL -- -<pgid>`
  → recursive descendant sweep via `pgrep -P` (backstop for setsid'd strays, e.g. MCP
  servers). All kills error-swallowing (`set +e` / `|| true`).
- Same teardown also covers the **40m timeout path** (timeout only TERMs its direct
  child, orphaning the tree) and runs as a cheap **post-call backstop**.
- Interrupt UX: calm distinct notice (NOT handback banner) naming phase/step, "left 🔄
  uncommitted, re-run ./loop.sh to resume", exit 130. No bell, no notify-send.

## Branch B — legible output
- Keep `--output-format stream-json --verbose`. Split the stream:
  `… 2>&1 | tee "$log" | "$FORMATTER"`. Raw JSONL still goes to the log (full-fidelity
  debugging transcript); only the terminal is prettified.
- New executable `format-stream.sh` next to loop.sh: a single long-lived
  `jq -R --unbuffered 'fromjson? | …'` (tolerates partial/garbage lines on Ctrl+C).
  Rules: thinking → suppressed; tool_use → prominent (`🔧 Bash › cmd`, `✏️ Edit › file`,
  `📖 Read`, `📝 Write`, `🤖 Task`); assistant text → dimmed, width-truncated;
  tool_result → one-line ✓/✗ + first line; final `result` → `✓ done · N turns`.
  TTY/NO_COLOR aware (ANSI+emoji only on TTY; else plain `[bash]`/`[edit]` tags).
  Log never gets ANSI. Resolve `$FORMATTER` from `$SCRIPT_DIR`; preflight-check it
  exists+executable (mirror DENY_HOOK).
- `loop.sh` prints a section header before each run_step:
  `━━ Phase N/total · <step> · step k of 3 ━━` (total from `phase_count`,
  implement=1/verify=2/close=3).

## Tests
- Extend `tests/stub-claude` to emit a realistic multi-event stream (init → assistant
  text → assistant tool_use → user tool_result → result), keeping all existing
  env-var behavior + marker side-effects.
- Add to `tests/run.sh`: (a) formatter test — raw log still full JSON, piping log
  through format-stream.sh yields readable output without raw `{"type":`; (b) interrupt
  test — stub that ignores TERM and sleeps; SIGINT loop.sh; assert exit 130 within a few
  seconds and no surviving children.
- `bash -n loop.sh && bash -n format-stream.sh`; run `tests/run.sh` until green.

## Invariants to preserve (do NOT change)
Fail-closed `handback`, status-file gating in `run_step`, deny-list hook plumbing,
preflight checks, resume-from-plan.md-markers model, pure-control-flow style of loop.sh
(tabs, comment density/tone). Don't commit/push.
