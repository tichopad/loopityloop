#!/usr/bin/env bash
#
# loop.sh — headless per-phase implementation loop.
#
# Drives the implement -> verify-and-fix -> close cycle unattended via Claude
# Code headless mode (`claude -p`), advancing through every pending phase of an
# approved plan and committing each phase atomically (the skills commit; this
# script never does). This file is PURE CONTROL FLOW: it contains no prompt
# prose — all intelligence lives in the skills it invokes.
#
# The loop fails closed: every abnormal outcome (crash, timeout, max-turns, a
# forgotten status write, a `blocked` status) converges on "stop and hand back",
# never on "advance". Re-running resumes from wherever plan.md's markers left off.
#
# Usage: ./loop.sh [plan.md]

set -euo pipefail

# Job control: each claude call below runs as a backgrounded subshell, which
# under `set -m` becomes its own process-group leader. That is what makes the
# whole call tree (claude → node → any MCP children) killable as a group, and
# what lets a trapped SIGINT actually fire — bash defers trap handlers while
# blocked on a *foreground* command, but `wait` on a background job is
# interruptible. Job-control "Done" chatter is sent to /dev/null via the
# subshell, so it never pollutes the readable feed.
set -m

# ---- Config constants (no project specifics) -------------------------------
PLAN="${1:-plan.md}"
STATUS_FILE=".loop/status.json"
LOG_DIR=".loop/logs"
HUMAN_VERIFICATION="human-verification.md"
MAX_TURNS=80
CALL_TIMEOUT=40m

# Process-group id of the in-flight claude call's subshell (set in run_step /
# run_final, cleared after each call). The signal trap reads this to tear down
# the right group. 0 means "no call in flight".
CURRENT_PGID=0
# Guard so the interrupt handler runs exactly once even if SIGINT and SIGTERM
# both arrive (or arrive twice).
INTERRUPTED=0
# Human-readable label of the current phase/step, for the interrupt notice.
CURRENT_PHASE=""
CURRENT_STEP=""

# Script's own directory, so the loop stays project-agnostic: the deny-check hook
# is resolved relative to this script, not the target repo it operates on. Resolve
# through symlinks so an install that drops a `loop.sh` symlink on PATH still finds
# its sibling scripts (deny-check.sh, format-stream.sh) in the real repo directory.
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_SOURCE" ]; do
	SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
	SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
	[[ "$SCRIPT_SOURCE" != /* ]] && SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"

# Per-invocation hook settings passed via --settings on every call: a PreToolUse
# deny-list that blocks irreversible actions (git push, git reset --hard, rm -rf,
# curl, wget) even under --dangerously-skip-permissions, since a hook denial wins
# over bypass. Built with jq so the absolute hook path is always JSON-safe. This
# is best-effort defence-in-depth; the feature-branch + per-phase-commit structure
# is the primary containment.
DENY_HOOK="${SCRIPT_DIR}/deny-check.sh"

# Terminal-feed formatter: the tail of every call pipeline turns raw stream-json
# into a readable feed. Resolved relative to this script (like DENY_HOOK) so the
# loop stays project-agnostic. The raw log is still captured upstream by tee;
# the formatter only shapes what reaches the terminal.
FORMATTER="${SCRIPT_DIR}/format-stream.sh"
DENY_SETTINGS="$(
	jq -cn --arg cmd "$DENY_HOOK" \
		'{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$cmd}]}]}}'
)"

# Iteration counter (global so current_phase_num can fall back to it).
iter=0

# ---- Small helpers ---------------------------------------------------------

abort() {
	printf 'loop.sh: %s\n' "$1" >&2
	exit 2
}

# Append a pattern to .git/info/exclude if absent. Never touches a tracked file.
ensure_excluded() {
	local pattern="$1" exclude_file=".git/info/exclude"
	touch "$exclude_file"
	grep -qxF "$pattern" "$exclude_file" 2>/dev/null || printf '%s\n' "$pattern" >>"$exclude_file"
}

# ---- Process-tree teardown -------------------------------------------------
# Kill an entire process tree and any setsid'd strays under it. Used by three
# callers: the interrupt trap, the 40-minute timeout path (timeout only TERMs
# its *direct* child, orphaning node/MCP grandchildren), and a cheap post-call
# backstop (a no-op when the tree is already gone). MUST be totally
# error-swallowing: it runs under `set -e` and is handed PIDs that may already
# be dead, so every kill is guarded and the function always returns 0.
#
# Subtlety that drives the design: under `set -m` the backgrounded call is its
# own process-group leader, but the *pipeline it runs* (timeout|tee|formatter)
# is placed by job control in a SEPARATE child group led by the pipeline's head
# (timeout). So claude/node/MCP actually live in that pipeline group, not the
# leader's. A single `kill -- -<leader>` therefore misses the real tree. Worse,
# killing the leader first reparents the survivors to init, so a *post*-kill
# descendant walk finds nothing. We therefore SNAPSHOT the whole descendant set
# (and the distinct groups it spans) up front, while the tree is still intact,
# then TERM → grace → KILL both the groups and the snapshotted PIDs.
#
# terminate_tree <leader_pid>
terminate_tree() {
	local leader="$1"
	# Nothing to do for an unset / zero leader.
	[[ -n "$leader" && "$leader" != 0 ]] || return 0

	# Subshell-scoped set +e: never let a failing kill (already-dead PID, races)
	# abort the script under set -e, and leave the caller's mode untouched.
	(
		set +e

		# Snapshot the descendant PIDs (deepest-first) and the set of process
		# groups they span, BEFORE any kill — once the leader dies its children
		# reparent and the tree can no longer be walked. Best-effort: if pgrep is
		# missing we fall back to just the leader's own group.
		local pids="" groups="$leader" p g
		if command -v pgrep >/dev/null 2>&1; then
			pids="$(_descendants "$leader")"
			for p in $leader $pids; do
				g="$(_pgid_of "$p")"
				[[ -n "$g" ]] && groups="$groups $g"
			done
			# De-dup the group list.
			groups="$(printf '%s\n' $groups | sort -u | tr '\n' ' ')"
		fi

		# Graceful: TERM every group (negative pid = the whole group), give a
		# 2-second grace window, then KILL groups and any snapshotted survivors.
		for g in $groups; do kill -TERM -- "-${g}" 2>/dev/null; done
		sleep 2
		for g in $groups; do kill -KILL -- "-${g}" 2>/dev/null; done
		# Backstop for setsid'd strays that left their group: KILL each snapshot
		# PID directly (deepest-first), then the leader.
		for p in $pids $leader; do kill -KILL "$p" 2>/dev/null; done
		return 0
	) || true
	return 0
}

# Echo every descendant PID of <pid>, deepest-first (children before parents).
# Relies on pgrep -P; assumes the set +e context of terminate_tree.
_descendants() {
	local parent="$1" child
	for child in $(pgrep -P "$parent" 2>/dev/null); do
		_descendants "$child"
		printf '%s\n' "$child"
	done
}

# Echo the process-group id of <pid> (empty if the process is already gone).
_pgid_of() {
	ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '
}

# ---- Interrupt handling ----------------------------------------------------
# Disarm-on-entry SIGINT/SIGTERM handler. claude (a Node app) swallows SIGINT in
# headless mode, so we cannot rely on the signal propagating down the pipe — we
# must actively tear the group down. Behaviour:
#   1. Immediately disarm both signals so a second Ctrl+C can't re-enter us.
#   2. Acknowledge instantly (the teardown's 2s grace would otherwise feel hung).
#   3. terminate_tree the in-flight call's process group.
#   4. Print a calm, distinct notice (NOT the handback banner) and exit 130.
# Deliberately quiet on the failure channels handback uses: no terminal bell,
# no notify-send. An interrupt is the human's choice, not a block.
on_interrupt() {
	trap '' INT TERM           # disarm first, before anything else can re-enter
	[[ "$INTERRUPTED" == 0 ]] || exit 130
	INTERRUPTED=1
	set +e                     # nothing below may abort under set -e

	printf '\n⛔ Interrupting — stopping Claude and all child processes…\n'
	terminate_tree "$CURRENT_PGID"

	local bar="────────────────────────────────────────────────────────────────"
	local phase="${CURRENT_PHASE:-?}" step="${CURRENT_STEP:-?}"
	printf '\n%s\n' "$bar"
	printf '  🛑  Interrupted\n'
	printf '%s\n' "$bar"
	printf '  Phase : %s\n' "$phase"
	printf '  Step  : %s\n' "$step"
	printf '  The phase is left 🔄 with partial work uncommitted.\n'
	printf '  Re-run ./loop.sh to resume from here.\n'
	printf '%s\n\n' "$bar"
	exit 130
}
trap on_interrupt INT TERM

# ---- Marker helpers (grep, not jq) -----------------------------------------

# Total number of phase headings (any marker).
phase_count() {
	local n
	n="$(grep -cE '^#{1,6} .*(⏳|🔄|✅)' "$PLAN" 2>/dev/null || true)"
	printf '%s' "${n:-0}"
}

# True if at least one phase is still pending (⏳ waiting or 🔄 in-progress).
has_pending() {
	grep -qE '^#{1,6} .*(⏳|🔄)' "$PLAN" 2>/dev/null
}

# Phase number parsed from the first pending heading; used for log naming and
# the handback banner. Falls back to the iteration counter if unparseable.
current_phase_num() {
	local line num
	line="$(grep -m1 -E '^#{1,6} .*(⏳|🔄)' "$PLAN" 2>/dev/null || true)"
	num="$(printf '%s' "$line" | sed -nE 's/.*Phase[[:space:]]+([0-9]+).*/\1/p' | head -n1 || true)"
	[[ -n "$num" ]] || num="${iter:-0}"
	printf '%s' "$num"
}

# ---- Handback (loud, framed, fail-closed) ----------------------------------

handback() {
	local phase="$1" step="$2" reason="$3" log="$4"
	local bar="════════════════════════════════════════════════════════════════"
	printf '\a' # ring the terminal bell
	printf '\n%s\n' "$bar"
	printf '  ⛔  LOOP BLOCKED\n'
	printf '%s\n' "$bar"
	printf '  Phase : %s\n' "$phase"
	printf '  Step  : %s\n' "$step"
	printf '  Reason: %s\n' "$reason"
	printf '  Log   : %s\n' "$log"
	printf '%s\n' "$bar"
	printf '  The phase is left 🔄 with partial work uncommitted for inspection.\n'
	printf '  Fix the plan and/or code, then re-run this script to resume.\n'
	printf '%s\n\n' "$bar"
	# Optional desktop notification — its absence must never break the loop.
	if command -v notify-send >/dev/null 2>&1; then
		notify-send "Loop blocked: phase ${phase} / ${step}" "$reason" 2>/dev/null || true
	fi
	exit 1
}

# ---- Section header --------------------------------------------------------
# Plain control-flow output: a one-line banner before each call showing pipeline
# position — which phase of how many, which step (1..3). Keeps the operator
# oriented in the readable feed without any prompt prose.
# section_header <phase_num> <step_name> <step_index>
section_header() {
	local phase_num="$1" step_name="$2" k="$3" total
	total="$(phase_count)"
	printf '\n━━ Phase %s/%s · %s · step %s of 3 ━━\n' \
		"$phase_num" "$total" "$step_name" "$k"
}

# ---- The single choke point ------------------------------------------------
# run_step <phase_num> <step_name> <slash_invocation>
run_step() {
	local phase_num="$1" step_name="$2" slash="$3"
	rm -f "$STATUS_FILE"
	local log="${LOG_DIR}/phase-${phase_num}-${step_name}.jsonl"

	# Expose the phase/step to the interrupt handler so its notice can name them.
	CURRENT_PHASE="$phase_num"
	CURRENT_STEP="$step_name"

	# Run the call without set -e so a non-zero exit (pipefail through tee) is
	# captured into $ec rather than killing the script before we can hand back.
	#
	# The pipeline runs as a backgrounded subshell so that (a) under `set -m` it
	# is its own process group — killable as a whole by the interrupt trap — and
	# (b) we block in `wait`, which is interruptible, instead of a foreground
	# pipeline, which would defer the trap. The subshell re-exits with the
	# pipeline head's status (timeout/claude), so the existing exit-code logic
	# (124 timeout, 130 sigint, etc.) is unchanged. tee still writes the raw,
	# ANSI-free JSONL log upstream of the formatter.
	set +e
	(
		timeout "$CALL_TIMEOUT" \
			claude -p "${slash} ${PLAN} --status ${STATUS_FILE}" \
			--output-format stream-json --verbose \
			--max-turns "$MAX_TURNS" \
			--dangerously-skip-permissions \
			--settings "$DENY_SETTINGS" \
			2>&1 | tee "$log" | "$FORMATTER"
		exit "${PIPESTATUS[0]}"
	) &
	local pid=$!            # subshell = process-group leader under set -m
	CURRENT_PGID="$pid"
	wait "$pid"; local ec=$?
	# timeout TERMs only its direct child, orphaning node/MCP grandchildren, and a
	# clean exit can still leave detached strays — sweep the group either way. A
	# no-op once nothing survives.
	terminate_tree "$CURRENT_PGID"
	CURRENT_PGID=0
	set -e

	# Fail-closed, in order: crash/timeout/max-turns -> missing status -> not-ok.
	(( ec != 0 )) && handback "$phase_num" "$step_name" "claude exited ${ec} (crash/timeout/max-turns)" "$log"
	[[ -f "$STATUS_FILE" ]] || handback "$phase_num" "$step_name" "no status file written (fail-closed)" "$log"
	[[ "$(jq -r '.status' "$STATUS_FILE" 2>/dev/null)" == "ok" ]] \
		|| handback "$phase_num" "$step_name" "$(jq -r '.reason // "no reason provided"' "$STATUS_FILE" 2>/dev/null)" "$log"
}

# ---- Success-path aggregation (best-effort, NON-GATING) --------------------
# Invokes /final-verification to consolidate every deferred human-only check into
# the human-verification checklist. Unlike run_step this NEVER hands back: by the
# time it runs every phase is already committed, so a failure here is a warning,
# not a block. There is no status-file gating — final-verification is report-only;
# the caller judges success by whether the checklist file appears.
run_final() {
	local log="${LOG_DIR}/final-verification.jsonl"

	CURRENT_PHASE="final"
	CURRENT_STEP="final-verification"

	# Same backgrounded-subshell shape as run_step: own process group under
	# set -m, interruptible wait, formatter on the tail, raw log via tee.
	set +e
	(
		timeout "$CALL_TIMEOUT" \
			claude -p "/final-verification ${PLAN}" \
			--output-format stream-json --verbose \
			--max-turns "$MAX_TURNS" \
			--dangerously-skip-permissions \
			--settings "$DENY_SETTINGS" \
			2>&1 | tee "$log" | "$FORMATTER"
		exit "${PIPESTATUS[0]}"
	) &
	local pid=$!
	CURRENT_PGID="$pid"
	wait "$pid"; local ec=$?
	terminate_tree "$CURRENT_PGID"
	CURRENT_PGID=0
	set -e

	(( ec == 0 )) || printf 'loop.sh: warning — final-verification exited %d (see %s); run "/final-verification %s" by hand to produce the checklist.\n' "$ec" "$log" "$PLAN" >&2
}

# ---- Pre-flight ------------------------------------------------------------

preflight() {
	# Must be inside a git work tree.
	git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
		|| abort "not a git repository — run the loop from inside the target repo"

	# Refuse the default branch so per-phase commits never land on it.
	local default_branch current_branch
	default_branch="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)"
	[[ -n "$default_branch" ]] || default_branch="$(git config --get init.defaultBranch 2>/dev/null || true)"
	[[ -n "$default_branch" ]] || default_branch="main"
	current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
	if [[ "$current_branch" == "$default_branch" || "$current_branch" == "main" || "$current_branch" == "master" ]]; then
		abort "on the default branch ('${current_branch}') — switch to a feature branch first"
	fi

	# Plan must exist and contain at least one phase marker.
	[[ -f "$PLAN" ]] || abort "plan file '${PLAN}' not found"
	[[ "$(phase_count)" -gt 0 ]] \
		|| abort "plan '${PLAN}' contains no phase markers (⏳/🔄/✅) — nothing to orchestrate"

	# Working tree must be clean so each phase commit holds only loop-produced changes.
	[[ -z "$(git status --porcelain)" ]] \
		|| abort "working tree is dirty — commit or stash changes first"

	# The deny-list hook must be present and executable. Running under
	# --dangerously-skip-permissions without it would fail OPEN — the opposite of
	# this loop's fail-closed contract — so refuse rather than run unprotected.
	[[ -x "$DENY_HOOK" ]] \
		|| abort "deny-list hook missing or not executable: ${DENY_HOOK}"

	# The terminal-feed formatter must be present and executable: it is the tail
	# of every call pipeline, so a missing/non-exec formatter would break output
	# rendering (and, via pipefail, the call). Refuse rather than run degraded.
	[[ -x "$FORMATTER" ]] \
		|| abort "stream formatter missing or not executable: ${FORMATTER}"

	# Keep loop artifacts out of every commit (never touches a tracked file).
	ensure_excluded ".loop/"
	ensure_excluded "$HUMAN_VERIFICATION"
	mkdir -p "$LOG_DIR"
}

# ---- Outer loop ------------------------------------------------------------

main() {
	preflight

	local cap n
	cap=$(( $(phase_count) + 1 ))
	iter=0
	while has_pending; do
		iter=$(( iter + 1 ))
		if (( iter > cap )); then
			printf 'loop.sh: iteration cap (%d) exceeded — marker-logic bug; bailing.\n' "$cap" >&2
			exit 3
		fi
		n="$(current_phase_num)"
		section_header "$n" implement 1; run_step "$n" implement /implement-phase
		section_header "$n" verify    2; run_step "$n" verify    /verify-and-fix
		section_header "$n" close     3; run_step "$n" close     /close-phase
	done

	# Success path: the loop exited because no phase is pending — every phase is
	# ✅. Consolidate the deferred human-only checks into one checklist, but only
	# when this run actually completed work (iter > 0); re-running an already-
	# finished plan is a no-op that needs no re-aggregation. Best-effort and
	# non-gating — all phases are committed, so nothing here can block.
	(( iter > 0 )) && run_final

	echo "All phases complete."

	if [[ -f "$HUMAN_VERIFICATION" ]]; then
		local count
		count="$(grep -cE '^[[:space:]]*- \[ \]' "$HUMAN_VERIFICATION" 2>/dev/null || true)"
		printf 'Human verification: %s item(s) to check — %s/%s\n' "${count:-0}" "$(pwd)" "$HUMAN_VERIFICATION"
	elif (( iter > 0 )); then
		printf 'loop.sh: note — no %s was produced; run "/final-verification %s" by hand if you need the checklist.\n' "$HUMAN_VERIFICATION" "$PLAN" >&2
	fi
}

main "$@"
