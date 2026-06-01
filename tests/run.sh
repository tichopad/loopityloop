#!/usr/bin/env bash
#
# run.sh — plain-bash control-flow test suite for loop.sh.
#
# Each case sets up a throwaway git repo from a fixture plan.md, prepends a stub
# `claude` to PATH, runs loop.sh, and asserts the exit code + observable effects
# (surfaced reasons, plan markers, per-step log files). No bats, no set -e — the
# runner must survive loop.sh's non-zero exits.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LOOP="$ROOT/loop.sh"
STUB="$HERE/stub-claude"
STUB_HANG="$HERE/stub-claude-hang"
FORMATTER="$ROOT/format-stream.sh"
FIXTURES="$HERE/fixtures"

# Expose the stub on PATH under the name `claude`.
STUB_BIN="$(mktemp -d)"
ln -sf "$STUB" "$STUB_BIN/claude"

TMP_PATHS=("$STUB_BIN")
cleanup() {
	(( ${#TMP_PATHS[@]} )) && rm -rf "${TMP_PATHS[@]}"
	return 0
}
trap cleanup EXIT

PASS=0
FAIL=0
pass() {
	printf '  \033[32m✓\033[0m %s\n' "$1"
	PASS=$((PASS + 1))
}
fail() {
	printf '  \033[31m✗\033[0m %s\n' "$1"
	FAIL=$((FAIL + 1))
}
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# make_repo <fixture-basename> <branch> -> echoes the repo dir
make_repo() {
	local fixture="$FIXTURES/$1" branch="$2" dir
	dir="$(mktemp -d)"
	TMP_PATHS+=("$dir")
	git init -q "$dir" 2>/dev/null
	git -C "$dir" config user.email t@t.t
	git -C "$dir" config user.name "Loop Test"
	# Put the repo on the requested (unborn) branch before the first commit.
	git -C "$dir" symbolic-ref HEAD "refs/heads/$branch"
	cp "$fixture" "$dir/plan.md"
	git -C "$dir" add plan.md
	git -C "$dir" commit -qm "init plan" 2>/dev/null
	printf '%s' "$dir"
}

# Result of the most recent invoke().
OUT=""
RC=0
# invoke <dir> [ENV=VAL ...]
invoke() {
	local dir="$1"
	shift
	OUT="$(cd "$dir" && env PATH="$STUB_BIN:$PATH" "$@" bash "$LOOP" plan.md 2>&1)"
	RC=$?
}

assert_rc() { if [[ "$RC" == "$1" ]]; then pass "$2 (rc=$RC)"; else fail "$2 (want rc=$1, got rc=$RC)"; fi; }
assert_contains() { if [[ "$OUT" == *"$1"* ]]; then pass "$2"; else fail "$2 (output missing: '$1')"; fi; }
assert_file() { if [[ -e "$1" ]]; then pass "$2"; else fail "$2 (missing file: $1)"; fi; }
assert_no_file() { if [[ ! -e "$1" ]]; then pass "$2"; else fail "$2 (unexpected file: $1)"; fi; }
assert_plan_complete() {
	if grep -qE '^#+ .*(⏳|🔄)' "$1/plan.md"; then fail "$2 (plan still has pending markers)"; else pass "$2"; fi
}
assert_plan_pending() {
	if grep -qE '^#+ .*(⏳|🔄)' "$1/plan.md"; then pass "$2"; else fail "$2 (plan has no pending markers)"; fi
}

# ─────────────────────────────────────────────────────────────────────────────

section "ok status advances through every call and phase to success"
dir="$(make_repo all-pending.md feature/work)"
invoke "$dir" STUB_STATUS=ok
assert_rc 0 "all-ok run exits 0"
assert_contains "All phases complete." "prints the success message"
assert_plan_complete "$dir" "every phase ends marked ✅"
assert_file "$dir/.loop/logs/phase-1-implement.jsonl" "phase 1 implement log written"
assert_file "$dir/.loop/logs/phase-3-close.jsonl" "advanced all the way to phase 3 close"
assert_file "$dir/.loop/logs/final-verification.jsonl" "final-verification ran on the success path"

section "success-path final-verification is non-gating (its failure never blocks)"
script="$(mktemp)"
TMP_PATHS+=("$script" "$script.n")
# 3 phases × 3 steps = 9 ok calls, then the success-path final-verification call
# fails (blocked status + non-zero exit). Non-gating: the loop must still exit 0.
{ for _ in 1 2 3 4 5 6 7 8 9; do printf 'ok||0\n'; done; printf 'blocked|final-verification crashed|7\n'; } >"$script"
dir="$(make_repo all-pending.md feature/work)"
invoke "$dir" STUB_SCRIPT="$script"
assert_rc 0 "final-verification failure does not block the success exit"
assert_contains "All phases complete." "still reports success"
assert_file "$dir/.loop/logs/final-verification.jsonl" "the final-verification step did run"
assert_plan_complete "$dir" "every phase still ends ✅"

section "blocked status stops immediately and surfaces the reason"
dir="$(make_repo all-pending.md feature/work)"
invoke "$dir" STUB_STATUS=blocked STUB_REASON="core assumption no longer holds"
assert_rc 1 "blocked run exits 1"
assert_contains "LOOP BLOCKED" "prints the framed handback banner"
assert_contains "Step  : implement" "names the blocking step"
assert_contains "core assumption no longer holds" "surfaces the blocked reason"
assert_plan_pending "$dir" "leaves a pending phase (did not advance)"
assert_no_file "$dir/.loop/logs/phase-1-verify.jsonl" "stops before the verify step"

section "missing status file is treated as blocked (fail-closed)"
dir="$(make_repo all-pending.md feature/work)"
invoke "$dir" STUB_STATUS=none
assert_rc 1 "missing-status run exits 1"
assert_contains "no status file written" "surfaces the fail-closed reason"
assert_contains "LOOP BLOCKED" "prints the handback banner"

section "non-zero claude exit stops; pipefail propagates it through tee"
dir="$(make_repo all-pending.md feature/work)"
invoke "$dir" STUB_STATUS=ok STUB_EXIT=42
assert_rc 1 "crashed call exits 1"
assert_contains "claude exited 42" "exit code propagated through the tee pipe"

section "all-✅ plan at startup reports complete without calling claude"
dir="$(make_repo all-done.md feature/work)"
invoke "$dir" STUB_STATUS=blocked # would block if claude were ever invoked
assert_rc 0 "all-done plan exits 0"
assert_contains "All phases complete." "prints the success message"
assert_no_file "$dir/.loop/logs/phase-1-implement.jsonl" "claude was never invoked"

section "a 🔄 phase on startup is resumed, not skipped or duplicated"
dir="$(make_repo resume-mid.md feature/work)"
invoke "$dir" STUB_STATUS=ok
assert_rc 0 "resume run exits 0"
assert_plan_complete "$dir" "all phases end ✅"
assert_file "$dir/.loop/logs/phase-2-implement.jsonl" "in-progress phase 2 was worked (resumed)"
assert_no_file "$dir/.loop/logs/phase-1-implement.jsonl" "already-✅ phase 1 was not re-processed"
assert_file "$dir/.loop/logs/phase-3-close.jsonl" "continued on to phase 3"

section "iteration cap bails loudly when markers never advance"
dir="$(make_repo all-pending.md feature/work)"
invoke "$dir" STUB_STATUS=ok STUB_NOFLIP=1
assert_rc 3 "cap breach exits 3"
assert_contains "iteration cap" "names the iteration cap"
assert_contains "bailing" "bails loudly"

section "per-call scripting — blocked at the verify step mid-phase"
script="$(mktemp)"
TMP_PATHS+=("$script" "$script.n")
printf 'ok||0\nblocked|verify found an unfixable failure|0\n' >"$script"
dir="$(make_repo all-pending.md feature/work)"
invoke "$dir" STUB_SCRIPT="$script"
assert_rc 1 "mid-phase block exits 1"
assert_contains "Step  : verify" "blocks at the verify step"
assert_contains "verify found an unfixable failure" "surfaces the scripted reason"
assert_file "$dir/.loop/logs/phase-1-verify.jsonl" "the verify step did run"
assert_no_file "$dir/.loop/logs/phase-1-close.jsonl" "the close step was never reached"
assert_plan_pending "$dir" "phase left in-progress (close never ran)"

section "pre-flight refuses the default branch"
dir="$(make_repo all-pending.md main)"
invoke "$dir" STUB_STATUS=ok
assert_rc 2 "main branch aborts"
assert_contains "default branch" "explains the main refusal"
dir="$(make_repo all-pending.md master)"
invoke "$dir" STUB_STATUS=ok
assert_rc 2 "master branch aborts"
assert_contains "default branch" "explains the master refusal"

section "pre-flight refuses a missing plan"
dir="$(make_repo all-pending.md feature/work)"
rm -f "$dir/plan.md"
invoke "$dir" STUB_STATUS=ok
assert_rc 2 "missing plan aborts"
assert_contains "not found" "explains the missing-plan refusal"

section "pre-flight refuses an empty plan (no phase markers)"
dir="$(make_repo no-phases.md feature/work)"
invoke "$dir" STUB_STATUS=ok
assert_rc 2 "empty plan aborts"
assert_contains "no phase markers" "explains the empty-plan refusal"

section "pre-flight refuses a dirty working tree"
dir="$(make_repo all-pending.md feature/work)"
printf 'uncommitted\n' >"$dir/dirty.txt"
invoke "$dir" STUB_STATUS=ok
assert_rc 2 "dirty tree aborts"
assert_contains "dirty" "explains the dirty-tree refusal"

# ─────────────────────────────────────────────────────────────────────────────

section "raw log stays full JSONL; format-stream.sh renders it readable"
dir="$(make_repo all-pending.md feature/work)"
invoke "$dir" STUB_STATUS=ok
assert_rc 0 "formatter run exits 0"
log="$dir/.loop/logs/phase-1-implement.jsonl"
assert_file "$log" "raw phase log written"
# The raw log (written by tee, upstream of the formatter) must keep full JSON,
# including the result event and the tool_use/text events the stub now emits.
if grep -q '"type":"result"' "$log"; then pass "raw log still contains full JSON (result event)"; else fail "raw log missing result event JSON"; fi
if grep -q '"type":"tool_use"' "$log"; then pass "raw log contains the tool_use event"; else fail "raw log missing tool_use event"; fi
# Run that real log through the formatter (NO_COLOR -> plain ASCII tags) and
# assert it became readable and stripped of raw JSON envelopes.
fmt_out="$(NO_COLOR=1 "$FORMATTER" <"$log" 2>&1)"
if [[ "$fmt_out" == *"[bash]"* || "$fmt_out" == *"Bash"* ]]; then pass "formatter renders the tool_use as a readable Bash line"; else fail "formatter output missing Bash line: $fmt_out"; fi
if [[ "$fmt_out" == *"[text]"* ]]; then pass "formatter renders the assistant text block"; else fail "formatter output missing text line"; fi
if [[ "$fmt_out" == *"[done]"* ]]; then pass "formatter renders the closing result summary"; else fail "formatter output missing done summary"; fi
if [[ "$fmt_out" != *'{"type":'* ]]; then pass "formatter output contains no raw JSON envelopes"; else fail "formatter leaked raw JSON: $fmt_out"; fi

section "format-stream.sh skips malformed/partial lines instead of dying"
# A fixture mixing valid events with a truncated line (as a Ctrl+C mid-flush
# would leave) and pure garbage. fromjson? must skip the bad lines, not abort.
fixture_in='{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hidden"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"hello there"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/x/y.ts"}}]}}
this is not json
{"type":"result","is_err
{"type":"result","is_error":false,"num_turns":3}'
fmt_out="$(printf '%s\n' "$fixture_in" | NO_COLOR=1 "$FORMATTER" 2>&1)"
fmt_rc=$?
if [[ "$fmt_rc" == 0 ]]; then pass "formatter survives malformed input (rc=0)"; else fail "formatter died on malformed input (rc=$fmt_rc)"; fi
if [[ "$fmt_out" == *"hello there"* ]]; then pass "valid text line still rendered past the garbage"; else fail "valid line dropped: $fmt_out"; fi
if [[ "$fmt_out" == *"[edit]"* ]]; then pass "valid tool_use line still rendered"; else fail "edit line dropped: $fmt_out"; fi
if [[ "$fmt_out" != *"hidden"* ]]; then pass "thinking block suppressed entirely"; else fail "thinking content leaked: $fmt_out"; fi

section "interrupt tears down the whole call tree and exits 130"
# Use the hang stub: it ignores INT/TERM and keeps a sleep child alive, so ONLY
# a real process-group/tree kill (SIGKILL) brings it down — exactly the case the
# loop's terminate_tree must handle. We start loop.sh, signal it mid-call, and
# assert it (a) exits 130, (b) prints the calm interrupt notice (not the handback
# banner), and (c) leaves no surviving stub/sleep child.
#
# SIGNAL CHOICE — why TERM, not INT, in this harness:
#   The loop runs under `set -m` (job control), which it needs so each call's
#   pipeline becomes a killable process group. A documented quirk of non-
#   interactive bash with job control on Linux is that it forces SIGINT (and
#   SIGQUIT) to SIG_IGN at the shell level, and a `trap … INT` cannot reinstate a
#   handler over that — so SIGINT cannot be exercised here. SIGTERM has no such
#   restriction: its trap fires normally under `set -m`. The loop traps INT and
#   TERM with the SAME handler (on_interrupt), so a SIGTERM drives the identical
#   teardown + 130-exit + notice path. In a real interactive terminal a Ctrl+C
#   SIGINT exercises that same handler (interactive job control does not force
#   SIG_IGN), and additionally reaches the whole foreground process group
#   directly — so the live behaviour is at least as robust as this test proves.
#
# EXEC — why the subshell `exec`s the loop:
#   Without exec, `( cd … && env … bash loop.sh ) &` makes the subshell the
#   PARENT (it waits on env/bash), so $! is the wrapper, not the loop — signalling
#   it would kill the wrapper and orphan the loop. `exec` replaces the subshell
#   with the loop so $! is the loop bash itself.
HANG_BIN="$(mktemp -d)"; TMP_PATHS+=("$HANG_BIN")
ln -sf "$STUB_HANG" "$HANG_BIN/claude"
pidfile="$(mktemp)"; TMP_PATHS+=("$pidfile")
: >"$pidfile"
dir="$(make_repo all-pending.md feature/work)"
intout="$(mktemp)"; TMP_PATHS+=("$intout")
(
	cd "$dir" && exec env PATH="$HANG_BIN:$PATH" STUB_PIDFILE="$pidfile" \
		bash "$LOOP" plan.md >"$intout" 2>&1
) &
loop_pid=$!
# Wait until the hang stub has recorded its PIDs (call is in flight), then signal.
for _ in $(seq 1 80); do [[ -s "$pidfile" ]] && break; sleep 0.1; done
# Small settle so the loop is parked in `wait` (not mid-launch) when the signal lands.
sleep 0.4
kill -TERM "$loop_pid" 2>/dev/null
# Bounded wait for the loop to exit; capture its real rc. Budget comfortably
# exceeds terminate_tree's 2s TERM-grace plus pipe drain.
int_rc=""
for _ in $(seq 1 100); do
	if ! kill -0 "$loop_pid" 2>/dev/null; then wait "$loop_pid"; int_rc=$?; break; fi
	sleep 0.1
done
if [[ -z "$int_rc" ]]; then kill -KILL "$loop_pid" 2>/dev/null; fi
if [[ "$int_rc" == 130 ]]; then pass "interrupt exits 130"; else fail "interrupt exit code (want 130, got '${int_rc:-timeout}')"; fi
intnotice="$(cat "$intout")"
if [[ "$intnotice" == *"Interrupting"* ]]; then pass "prints the immediate interrupt acknowledgment"; else fail "missing interrupt ack: $intnotice"; fi
if [[ "$intnotice" == *"Interrupted"* && "$intnotice" == *"Re-run ./loop.sh to resume"* ]]; then pass "prints the calm resume notice"; else fail "missing calm interrupt notice"; fi
if [[ "$intnotice" != *"LOOP BLOCKED"* ]]; then pass "does NOT print the handback banner on interrupt"; else fail "interrupt wrongly showed the handback banner"; fi
# Process-group teardown: neither the stub nor its sleep child may survive.
read -r stub_pid sleep_pid <"$pidfile" 2>/dev/null || true
surv=0
for p in "$stub_pid" "$sleep_pid"; do
	[[ -n "$p" ]] || continue
	if kill -0 "$p" 2>/dev/null; then surv=$((surv + 1)); kill -KILL "$p" 2>/dev/null; fi
done
if [[ "$surv" == 0 ]]; then pass "no stub/sleep children survive the teardown"; else fail "$surv child process(es) survived the teardown"; fi

# ─────────────────────────────────────────────────────────────────────────────
printf '\n────────────────────────────────────────\n'
printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
