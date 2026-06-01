# Headless Implementation Loop — Implementation Plan

## Overview

Build a project-agnostic bash orchestration script (`loop.sh`) that runs the per-phase **implement → verify-and-fix → close** cycle unattended via Claude Code headless mode (`claude -p`), advancing through every pending phase of an approved `plan.md` and committing each phase atomically. The script owns control flow only; all prompt intelligence lives in skills. The loop fails closed — every abnormal outcome converges on "stop and hand back," never on "advance" — and pulls the human back in only when a phase is genuinely blocked or the plan's core assumptions are threatened.

This plan implements the design in `implement-loop-prd.md`.

## Current State

- **Project dir** `/home/tichopad/loopityloop/` contains only `implement-loop-prd.md`. It is **not yet a git repo**; the script's pre-flight assumes the *target* repo is already initialised and on a feature branch.
- **`implement-phase`** (`~/.claude/skills/implement-phase/SKILL.md`): selects the target phase from markers and resumes a `🔄` phase (`SKILL.md:18-22, 31`), but **asks the user to confirm** the selection (`:22`), **waits for user input on a plan/reality mismatch** (`:41-52`), and **writes no status file**. Frontmatter has `disable-model-invocation: true` (`:4`).
- **`close-phase`** (`~/.claude/skills/close-phase/SKILL.md`): **asks the user about every unchecked `test-plan.md` item** (`:25-27`), archives `test-plan.md` → `test-plan-phase-<N>.md` (`:31`), marks the heading `✅` (`:35`), commits with the phase number in the title (`:38-41`), and **never pushes** (`:41`). It writes **no status file**. `disable-model-invocation: true` (`:4`).
- **`verify-and-fix`** and **`final-verification`** do not exist.
- Tooling present: `jq`, `timeout`, `notify-send`, `tee`, `git`, `claude 2.1.156`.

### Verified Claude Code mechanics (load-bearing)

1. **Deny-list under bypass works.** `PreToolUse` hooks still execute under `--dangerously-skip-permissions`, and a hook denial **wins** over bypass. A hook denies by emitting stdout JSON `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"…"}}` (exit 0), or by `exit 2` with stderr.
2. **Per-invocation hooks** ship via `--settings '<json>'`; CLI-arg settings merge above project/user settings.
3. **Slash commands work headless** (`claude -p "/implement-phase …"`), including for skills with `disable-model-invocation: true`.
4. **`--output-format stream-json` requires `--verbose`** in `-p` mode; the final `result` event carries `is_error`, `terminal_reason`, `num_turns`.
5. **Exit codes:** normal `0`; `timeout(1)` SIGTERM `124`; `--max-turns` hit → non-zero. With `set -o pipefail`, `claude`'s code survives the `tee` pipe (also read via `${PIPESTATUS[0]}`).

## Desired End State

From the project root, on a feature branch with `plan.md` committed and a clean tree, the developer runs `./loop.sh`. It works through every non-`✅` phase — implementing, verifying, fixing failures (bounded to 10 attempts), and committing each phase — streaming live output and saving a per-phase/per-step transcript. It stops loudly and exits non-zero only on a genuine block (phase unfixable within budget, core-assumption mismatch, or any abnormal/fail-closed outcome), leaving partial work uncommitted for inspection. On full success it writes a consolidated `human-verification.md` checklist and prints its count, then exits. Re-running the script resumes from wherever the `plan.md` markers left off.

**Verification of the whole:** the control-flow test suite (Phase 1) passes; the `deny-check` unit tests (Phase 2) pass; a capstone end-to-end run (Phase 5) on a toy multi-phase repo drives both the block path and the success path correctly.

## Key Design Decisions

- **Override delivery → opt-in Loop Mode in the skills.** `implement-phase` and `close-phase` gain an additive, opt-in **Loop Mode** triggered by a `--status <path>` argument. Bash passes only a flag + path (pure control flow, zero prose); the behavioural override lives in versioned skill text; default interactive behaviour is unchanged when the flag is absent, preserving hand-invocation. This honours the PRD's primary principle ("no prompt prose in bash; all intelligence in skills") and the "still runnable by hand" requirement.
- **Status contract.** Every loop-relevant call writes `.loop/status.json` = `{ "status": "ok"|"blocked", "reason": "…" }` as its final action. Bash deletes it before each call and requires a fresh one after. Missing ⇒ `blocked` (fail-closed).
- **Loop artifacts** (`.loop/` for status + logs, and `human-verification.md`) are ignored via **`.git/info/exclude`** — never tracked, never committed, never dirtying the tree or tripping `pr-create`. Archived `test-plan-phase-<N>.md` files **are** committed (existing `close-phase` behaviour).
- **Minimal deps:** `jq` for status parsing; plain-bash test runner (no `bats`).
- **Safety is structural + a thin deny-list:** dedicated feature branch + atomic per-phase commits + a `PreToolUse` deny-list hook (`git push`, `git reset --hard`, `rm -rf`, `curl`, `wget`).

## Out of Scope

- Steps 1–3 of the broader workflow (`/grill-me`, `/to-prd`, `/create-plan`) and `/pr-create` — remain human-driven.
- Pushing to the remote — forbidden to the loop.
- Git worktree isolation — v1 runs in the current checkout.
- Promoting `loop.sh` to a shared/`PATH` location — stays project-local for now.
- A non-`jq` status parser; richer-than-binary status vocabulary; auto-discard/auto-stash of partial work on block.

---

## Phase 1: Orchestration script + control-flow test suite ✅

### Overview

Build `loop.sh` end-to-end as pure control flow, and the deterministic stub-`claude` + fixture-`plan.md` test suite that proves every control-flow decision. The three per-phase calls are wired as real slash-command invocations, but the tests substitute a stub `claude` on `PATH`, so this phase is fully testable without the skills existing yet.

### Changes

- **`loop.sh`** (new, project root):
  - `set -euo pipefail`.
  - **Config constants** (no project specifics): `PLAN=${1:-plan.md}`, `STATUS_FILE=.loop/status.json`, `LOG_DIR=.loop/logs`, `MAX_TURNS=80`, `CALL_TIMEOUT=40m`, and the three step definitions `(name, slash-invocation)`: `implement → /implement-phase`, `verify → /verify-and-fix`, `close → /close-phase`.
  - **Pre-flight** (abort with a clear message + non-zero on any failure):
    - Not a git repo → abort.
    - On the default branch → abort. Detect via `git symbolic-ref --short refs/remotes/origin/HEAD | sed 's@^origin/@@'`, falling back to `git config --get init.defaultBranch`, then `main`; also treat `master` as default. Compare to `git rev-parse --abbrev-ref HEAD`.
    - `$PLAN` missing, **or** contains no pending phase (no heading matching `^#{1,6} .*(⏳|🔄)`) → abort.
    - Dirty working tree (`git status --porcelain` non-empty) → abort.
    - Ensure `.loop/` and `human-verification.md` are in `.git/info/exclude` (append if absent — never touches a tracked file); `mkdir -p "$LOG_DIR"`.
  - **Marker helpers** (grep, not jq):
    - `phase_count` = `grep -cE '^#{1,6} .*(⏳|🔄|✅)' "$PLAN"`.
    - `has_pending` = `grep -qE '^#{1,6} .*(⏳|🔄)' "$PLAN"`.
    - `current_phase_num` = phase number parsed from the first heading matching `^#{1,6} .*(⏳|🔄)` (used for log naming and handback; falls back to the iteration counter if unparseable).
  - **`run_step <phase_num> <step_name> <slash_invocation>`** — the single choke point:
    ```bash
    rm -f "$STATUS_FILE"
    local log="$LOG_DIR/phase-${phase_num}-${step_name}.jsonl"
    timeout "$CALL_TIMEOUT" \
      claude -p "${slash} ${PLAN} --status ${STATUS_FILE}" \
        --output-format stream-json --verbose \
        --max-turns "$MAX_TURNS" \
        --dangerously-skip-permissions \
        --settings "$DENY_SETTINGS" \
      2>&1 | tee "$log"
    local ec=${PIPESTATUS[0]}
    # fail-closed, in order:
    (( ec != 0 ))                     && handback "$phase_num" "$step_name" "claude exited $ec (crash/timeout/max-turns)" "$log"
    [[ -f "$STATUS_FILE" ]]           || handback "$phase_num" "$step_name" "no status file written (fail-closed)" "$log"
    [[ "$(jq -r .status "$STATUS_FILE")" == "ok" ]] \
                                      || handback "$phase_num" "$step_name" "$(jq -r .reason "$STATUS_FILE")" "$log"
    ```
    (`$DENY_SETTINGS` is supplied by Phase 2; in Phase 1 it is an empty `{}` placeholder so the suite runs.)
  - **Outer loop:**
    ```bash
    cap=$(( $(phase_count) + 1 )); iter=0
    while has_pending; do
      (( ++iter > cap )) && { echo "Iteration cap ($cap) exceeded — marker-logic bug; bailing."; exit 3; }
      n=$(current_phase_num)
      run_step "$n" implement /implement-phase
      run_step "$n" verify    /verify-and-fix
      run_step "$n" close     /close-phase
    done
    # success path (all ✅): Phase 5 wires final-verification here.
    echo "All phases complete."
    ```
  - **`handback <phase> <step> <reason> <log>`** — prints a loud, framed banner naming phase/step/reason/log path, rings the bell (`printf '\a'`), fires `notify-send` **if present** (absence never breaks the loop), and `exit 1`. The blocked phase is left `🔄` with partial work uncommitted (nothing auto-discarded).

- **`tests/stub-claude`** (new): a fake `claude` honouring env vars — `STUB_STATUS` (`ok`/`blocked`/`none`), `STUB_REASON`, `STUB_EXIT` (default 0), and an optional per-call script so the three steps of a phase can return different scripted results. Writes `$STATUS_FILE` (or not, for `none`), emits a minimal stream-json `result` line, and exits `STUB_EXIT`.
- **`tests/fixtures/`** (new): `plan.md` files in known marker states — all-`⏳`, one `🔄` mid-plan, all-`✅`, empty/no-phases, multi-phase.
- **`tests/run.sh`** (new): plain-bash runner that prepends `tests/stub-claude` to `PATH`, sets up a throwaway git repo + fixture per case, runs `loop.sh`, and asserts exit code + observable effects. Cases (one per PRD Testing-Decisions bullet):
  - `ok` advances to next call / next phase.
  - `blocked` stops immediately, exits non-zero, surfaces the reason.
  - **Missing** status file ⇒ treated as `blocked`.
  - Non-zero stub exit ⇒ stops; `pipefail` propagates it through `tee`.
  - Terminates success when no non-`✅` phase remains.
  - A `🔄` phase on startup is picked (resumed), not skipped/duplicated.
  - Iteration cap bails loudly (a stub that never updates markers).
  - Pre-flight refuses: default branch, missing/empty plan, dirty tree.

### Verification

- [x] `tests/run.sh` passes every case above (exit codes + surfaced reasons asserted). — 43/43 assertions pass.
- [x] `bash -n loop.sh` and `shellcheck loop.sh` (if available) are clean. — both clean (shellcheck 0.11.0; `SCRIPT_DIR` annotated as a Phase-2 forward-reference).
- [ ] **Manual**: run `loop.sh` against an all-`✅` fixture → prints "All phases complete." and exits 0; against a dirty tree → aborts with the dirty-tree message and non-zero. — _also covered programmatically in `tests/run.sh` and demonstrated directly._

> Pause after this phase for manual confirmation before proceeding.

---

## Phase 2: Safety layer — deny-list hook + artifact isolation ✅

### Overview

Make `--dangerously-skip-permissions` safe by structure plus a thin deny-list enforced via a `PreToolUse` hook, and ensure loop artifacts never enter commits.

### Changes

- **`deny-check.sh`** (new): a `PreToolUse` hook command. Reads the tool-call JSON on stdin, extracts `.tool_input.command` for `Bash` calls, and if it matches any deny pattern — `git push`, `git reset --hard`, `rm -rf`, `curl`, `wget` (whitespace-tolerant) — emits the deny JSON `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"<cmd> blocked by loop deny-list"}}` and exits 0; otherwise prints nothing and exits 0 (proceed). Documented as best-effort defence-in-depth — the feature-branch + per-phase-commit structure is the primary containment, per PRD.
- **`loop.sh`**: define `DENY_SETTINGS` as the JSON wiring the hook —
  `{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"<abs-path>/deny-check.sh"}]}]}}` — and pass it via `--settings` on every `run_step` call (replacing the Phase 1 placeholder). Resolve `<abs-path>` from the script's own location (`SCRIPT_DIR`) so the loop stays project-agnostic; build the JSON with `jq` so the path is always JSON-safe.
  - **Added beyond the literal plan (fail-closed hardening):** a pre-flight guard aborts if `deny-check.sh` is missing or non-executable. Without it, the loop would run under `--dangerously-skip-permissions` with **no deny-list** — a fail-*open* hole that contradicts the loop's fail-closed contract.
- **`.git/info/exclude`**: already handled in Phase 1 pre-flight; confirmed here for `.loop/` and `human-verification.md`.

### Verification

- [x] **`tests/deny-check.bats`-style plain-bash unit tests**: feed `deny-check.sh` JSON for each denied command (asserts `permissionDecision":"deny"`) and for benign commands like `ls`, `pnpm check`, `git commit` (asserts empty output / proceed). — `tests/deny-check-test.sh`, 30/30 assertions pass (incl. jq-escaping of quoted commands, word-boundary non-matches, non-Bash tool calls).
- [x] `tests/run.sh` still passes (now with the real `DENY_SETTINGS`). — 43/43 assertions pass; `bash -n` + `shellcheck` clean on `loop.sh`, `deny-check.sh`, and the new test.
- [ ] **Manual**: `claude -p "run: git push" --dangerously-skip-permissions --settings "$DENY_SETTINGS" …` → the push is blocked by the hook (observable in the transcript); `git commit` is allowed. — _hook verified in isolation (denies `git push`, allows `git commit`) and `DENY_SETTINGS` confirmed valid JSON; live-`claude` integration left for human confirmation._

> Pause after this phase for manual confirmation before proceeding.

---

## Phase 3: `implement-phase` + `close-phase` Loop Mode ✅

### Overview

Add an additive, opt-in **Loop Mode** to both existing skills, triggered by a `--status <path>` argument. Default (no-flag) behaviour is unchanged, preserving hand-invocation exactly as before.

### Changes

- **`~/.claude/skills/implement-phase/SKILL.md`**: add a **"Loop Mode"** section. When invoked with `--status <file>`:
  - Skip the confirmation in step 1 (`:22`) — auto-select the target phase from markers and proceed.
  - Replace the "wait for user input" mismatch behaviour (`:41-52`): **resolve plan/reality mismatches itself, editing `plan.md` when appropriate**. Block **only** when the mismatch threatens the plan's core assumptions.
  - As the **final action**, write the status file: `{"status":"ok"}` on success (phase implemented, automated checks pass, `test-plan.md` written), or `{"status":"blocked","reason":"…"}` on a core-assumption mismatch or unrecoverable failure.
- **`~/.claude/skills/close-phase/SKILL.md`**: add a **"Loop Mode"** section. When invoked with `--status <file>`:
  - Skip the "ask the user about each unchecked item" behaviour (`:25-27`) — by construction every unchecked item at close time is NEEDS-HUMAN; archive, mark `✅`, and commit as today (`:31-41`).
  - As the **final action**, write `{"status":"ok"}` (or `blocked` + reason if the close genuinely cannot complete).
  - Continue to **never push** (`:41`).

### Verification

- [ ] **Manual**: in a scratch repo, `claude -p "/implement-phase plan.md --status .loop/status.json" …` selects + implements a phase with **no interactive prompt** and writes a fresh `ok` status; injecting a core-assumption mismatch produces `blocked` + reason. — _skill edit applied; status-write contract (`ok`/`blocked` + reason, written last/once, fail-closed) is spec'd in the new **Loop Mode** section. Live-`claude` empirical run left for human confirmation._
- [ ] **Manual**: `/close-phase plan.md --status …` archives, marks `✅`, commits with the phase number, writes `ok`, asks nothing. — _skill edit applied; the "ask no one" override + `ok`/`blocked` status-write spec'd in the new **Loop Mode** section. Live-`claude` run left for human confirmation._
- [ ] **Manual (regression)**: invoking both skills **without** `--status` still prompts interactively exactly as before. — _verified by construction: edits are purely additive (one trailing `## Loop Mode` section + an Expected-input pointer); steps 1–7 / 1–5 are byte-for-byte unchanged, and Loop Mode is explicitly gated on the flag being present. Live confirmation still recommended._

> Pause after this phase for manual confirmation before proceeding.

---

## Phase 4: `verify-and-fix` skill ✅

### Overview

Create the new deep-module skill that owns the entire verify+fix responsibility behind one contract: *make the current phase's `test-plan.md` reach an all-pass-or-human-only state, or block.*

### Changes

- **`~/.claude/skills/verify-and-fix/SKILL.md`** (new; `disable-model-invocation: true`, mirroring the pipeline skills). Expected input `<path-to-plan> --status <file>`. Operates on the current `🔄` phase's `test-plan.md`.
  - **Trichotomy** — classify each test case:
    - **PASS** — verified working → check it off.
    - **FAIL** — verified genuinely broken → feeds the fix loop.
    - **NEEDS-HUMAN** — cannot be agent-verified (visual/UX/external) → left unchecked, never fixed, never blocks.
  - **Subagent fan-out**, one per case, to keep the coordinator's context lean.
  - **Bounded warm fix loop**, N=10 attempts per phase, run inside this single call so it remembers and avoids dead-end fixes. After 10 unsuccessful attempts on a surviving FAIL, block.
  - **Final action — write status:** `{"status":"ok"}` when no FAIL survives (all PASS or NEEDS-HUMAN remain unchecked); `{"status":"blocked","reason":"…"}` when a FAIL survives the budget. (The all-passed-vs-human-only nuance is intentionally invisible to bash — both → `ok`; it is preserved as unchecked items in `test-plan.md` and surfaced later by `final-verification`.)
- Split into `REFERENCE.md` only if `SKILL.md` exceeds ~100 lines (per `write-a-skill` guidance).

### Verification

- [ ] **Manual/empirical**: on a real phase whose `test-plan.md` has a deliberately-broken programmatic case + a genuine human-only case, the skill fixes the broken one (checks it off), leaves the human-only one unchecked, and writes `ok`.
- [ ] **Manual/empirical**: an unfixable FAIL is blocked after the bounded attempts, writing `blocked` + a useful reason.
- [x] Skill structure lint: valid frontmatter; description includes "Use when…"; references one level deep. — 84 lines (< ~100, so no `REFERENCE.md` split); frontmatter valid (`name` / `description` / `disable-model-invocation: true`); description contains "Use when…" (299 chars, < 1024); zero nested references. `tests/run.sh` (43/43) and `tests/deny-check-test.sh` (30/30) still pass — no regression.

> Pause after this phase for manual confirmation before proceeding.

---

## Phase 5: `final-verification` skill + success-path integration + end-to-end validation ✅

### Overview

Create the success-path aggregation skill, wire it into `loop.sh`, and validate the whole system end-to-end on a toy multi-phase repo (both block and success paths).

### Changes

- **`~/.claude/skills/final-verification/SKILL.md`** (new; `disable-model-invocation: true`). Runs **only on the success path**. Reads all archived `test-plan-phase-<N>.md` files + `plan.md` and produces a consolidated **`human-verification.md`**: deferred human-only items **grouped by phase**, **deduplicated**, each annotated with a one-line **how-to-verify** hint. Prints a terminal summary including the **count**. **Report-only and uncommitted** — neither gates nor commits.
- **`loop.sh`**: on the success exit (loop ended with all `✅`), invoke `/final-verification plan.md` best-effort (`run_step`-style but **non-gating** — a failure here prints a warning, not a handback, since all phases are already committed). Then print the `human-verification.md` count and path. The success path runs **only** when every phase is `✅` — a block never reaches it.
  - **Refinements made during implementation:** (1) the call is gated on `iter > 0`, so the success path invokes `/final-verification` only when this run actually completed a phase; re-running an already-`✅` plan stays a true no-op with **no** `claude` call (this preserves the existing "all-✅ at startup → claude never invoked" control-flow test). (2) `/final-verification` is invoked **without** `--status` (matching the plan's own example invocation): it is report-only and non-gating, so there is no status file to honour — `run_final` judges the outcome by the call's exit code and whether the checklist file appears, never by a status file. The `human-verification.md` filename is lifted to a `HUMAN_VERIFICATION` config constant shared by pre-flight's `.git/info/exclude` entry and the success-path count.

### Verification

- [ ] **Manual/empirical (success path)**: a toy repo with a 2–3 phase `plan.md` runs to completion — each phase committed atomically, `human-verification.md` produced with grouped/deduped/annotated items, count printed, exit 0, nothing pushed.
- [ ] **Manual/empirical (block path)**: a phase with an unfixable FAIL stops immediately with the framed handback (phase/step/reason/log); the phase stays `🔄`; partial work remains uncommitted; re-running `loop.sh` resumes that phase.
- [ ] **Manual**: `human-verification.md` and `.loop/` do not appear in `git status` (excluded) and do not trip a subsequent `/pr-create`.
- [x] `tests/run.sh` and the `deny-check` unit tests still pass. — `tests/run.sh` 48/48 (added a non-gating success-path section: final-verification runs on success, and its failure never blocks the loop) and `tests/deny-check-test.sh` 30/30; `bash -n` + `shellcheck` clean on `loop.sh`, `tests/run.sh`. `final-verification/SKILL.md` lint: 63 lines (< ~100, no split), valid frontmatter (`name`/`description`/`disable-model-invocation`), description 436 chars with "Use when…", zero nested references.

> Pause after this phase for manual confirmation before proceeding.

---

## References

- PRD: `implement-loop-prd.md`
- Existing skills: `~/.claude/skills/implement-phase/SKILL.md`, `~/.claude/skills/close-phase/SKILL.md`, `~/.claude/skills/pr-create/SKILL.md`, `~/.claude/skills/write-a-skill/SKILL.md`
- Verified Claude Code mechanics: see **Current State → Verified Claude Code mechanics** above.
