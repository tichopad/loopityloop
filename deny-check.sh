#!/usr/bin/env bash
#
# deny-check.sh — PreToolUse deny-list / ask-list hook for the headless loop.
#
# Best-effort defence-in-depth. The PRIMARY containment is structural: the loop
# runs only on a dedicated feature branch with atomic per-phase commits, so any
# damage is recoverable from a restore point. This hook is the thin extra layer
# that gates the handful of dangerous actions an agent should never take blindly
# while running under --dangerously-skip-permissions. It is TRI-STATE:
#
#   HARD-DENY (never offered to the human):
#     git push          — pushing is the human's explicit decision, not the loop's
#     git reset --hard   — destroys uncommitted work below the restore points
#
#   ASK-THE-HUMAN (pause the loop, let the human approve per-invocation):
#     rm -rf            — recursive force-delete is unrecoverable, EXCEPT when
#                         every target ends in .md: deleting only Markdown files
#                         is allowed silently (docs/notes are cheap to regenerate
#                         and re-creatable from the commit history).
#     curl / wget       — outbound network calls (exfiltration / fetch-and-run)
#
#   Everything else runs silently.
#
# A PreToolUse hook denial WINS over --dangerously-skip-permissions: hooks still
# run under bypass, and a deny decision is honoured. The deny is signalled by
# emitting the decision JSON on stdout and exiting 0; an allow is signalled by
# printing nothing and exiting 0 (the bypass then lets the command run). Anything
# not matched also prints nothing and exits 0 (proceed). The hook never blocks on
# its own errors — it fails open only for malformed/non-Bash input, which carries
# no shell command.
#
# ── How the ask tier coordinates with loop.sh ──────────────────────────────
# This hook runs inside the loop's BACKGROUNDED call pipeline, i.e. in a
# background process group, so it CANNOT read the controlling terminal (it would
# get SIGTTIN and stop, or a read would fail EIO). The foreground loop.sh must do
# the actual TTY read. We coordinate through files in the loop's state dir
# (LOOP_APPROVAL_DIR — the git-dir loopityloop/ directory).
#
# The hook learns two things from a single inherited environment variable that
# loop.sh exports (claude inherits loop.sh's env, and this hook inherits claude's):
#
#   LOOP_APPROVAL_DIR — absolute path to the loop's state directory (the
#                       git-dir loopityloop/ directory).
#
# Its meaning is overloaded on purpose, the simplest robust signal:
#   * UNSET or EMPTY  → interactive approvals are DISABLED (no usable TTY, or the
#                       hook was invoked outside the loop). Ask-tier commands
#                       degrade to an immediate deny — identical to the old
#                       behaviour, no files, no blocking, no deadlock.
#   * SET (non-empty) → interactive approvals are ENABLED and this is where to
#                       drop the request / read the response.
#
# Protocol when enabled and an ask-tier command is seen:
#   1. Write the request to  $LOOP_APPROVAL_DIR/pending-approval.json
#      (matched rule, full command, and Claude's .tool_input.description if any).
#   2. Block-poll for         $LOOP_APPROVAL_DIR/approval-response (a one-word
#      "allow" or "deny" written by loop.sh after the human answers).
#   3. Delete BOTH files, then emit allow (silent) or the deny JSON.
# Time spent polling here is the human's free deliberation time — loop.sh excludes
# it from the active-time budget. A pre-existing response file is honoured on the
# first poll, which keeps the unit tests non-blocking.
#
# Contract (Claude Code PreToolUse hook):
#   stdin  : the tool-call JSON, including .tool_name and .tool_input
#   stdout : on deny, {"hookSpecificOutput":{...,"permissionDecision":"deny",...}}
#   exit   : always 0

set -uo pipefail

# Poll cadence (seconds) while blocking on the human's response. The wait itself
# is unbounded — the human's deliberation time is free — so this only trades a
# little latency for near-zero CPU.
APPROVAL_POLL_INTERVAL=0.2

input="$(cat)"

# Only Bash tool calls carry a shell command to vet; everything else proceeds.
tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[[ "$tool" == "Bash" ]] || exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[[ -n "$cmd" ]] || exit 0

# Emit the standard deny decision JSON for <rule> and exit 0. Built with jq so the
# reason is always correctly escaped.
emit_deny() {
	jq -cn --arg r "$1 blocked by loop deny-list" \
		'{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
	exit 0
}

# Match $cmd against each HARD-DENY pattern; echo a short rule label on the first
# hit, return 1 on no match.
hard_deny_rule() {
	local c="$1"
	# git push (with or without remote/refspec)
	if grep -qE '(^|[^[:alnum:]_])git[[:space:]]+push([^[:alnum:]_]|$)' <<<"$c"; then
		printf 'git push'
		return 0
	fi
	# git reset --hard — soft/mixed resets stay allowed; --hard may sit anywhere.
	if grep -qE '(^|[^[:alnum:]_])git[[:space:]]+reset([^[:alnum:]_]|$)' <<<"$c" \
		&& grep -qE '(^|[[:space:]])--hard([[:space:]]|$)' <<<"$c"; then
		printf 'git reset --hard'
		return 0
	fi
	return 1
}

# Whether a matched rm command deletes ONLY *.md files. Deliberately conservative
# and best-effort: it returns 0 (allow, skip the ask) only for a single, simple rm
# whose every non-flag target ends in `.md`. Any shell chaining/redirection
# (& | ; < > ` $( ), or any target that is not a *.md file (a directory, a
# differently-suffixed file, a quoted name with spaces), returns 1 so the command
# falls back to the ask tier. read -ra is used (not `for w in $c`) precisely so the
# words are NOT glob-expanded against the cwd.
rm_targets_all_md() {
	local c="$1"
	# Bail on anything that could chain a second command or redirect output — we
	# only vouch for a lone rm, never `rm a.md && curl …` or `rm a.md > /etc/x`.
	grep -qE '[&|;<>`]|\$\(' <<<"$c" && return 1
	local -a words
	read -ra words <<<"$c"
	local saw_rm=0 targets=0 w
	for w in "${words[@]}"; do
		if ((!saw_rm)); then
			[[ "$w" == rm || "$w" == */rm ]] && saw_rm=1
			continue
		fi
		[[ "$w" == -* ]] && continue   # a flag bundle (-rf, --, …): skip
		[[ "$w" == *.md ]] || return 1 # a non-.md target → not a pure-Markdown rm
		targets=$((targets + 1))
	done
	((saw_rm && targets >= 1))
}

# Match $cmd against each ASK-THE-HUMAN pattern; echo a short rule label on the
# first hit, return 1 on no match. `(^|[^[:alnum:]_])` / `([^[:alnum:]_]|$)` act
# as portable word boundaries (no reliance on \b), and [[:space:]]+ tolerates
# extra spacing. Patterns are matched anywhere so `cd x && curl …` is caught.
ask_rule() {
	local c="$1"
	# rm with a bundled recursive+force flag: -rf, -fr, -Rf, -rfv, … (split flags
	# like `rm -r -f` are intentionally not chased — this is best-effort). Deleting
	# only *.md files is exempt and runs silently; everything else asks.
	if grep -qE '(^|[^[:alnum:]_])rm[[:space:]]+-[[:alnum:]]*([rR][[:alnum:]]*[fF]|[fF][[:alnum:]]*[rR])' <<<"$c"; then
		if ! rm_targets_all_md "$c"; then
			printf 'rm -rf'
			return 0
		fi
	fi
	# Outbound network calls.
	if grep -qE '(^|[^[:alnum:]_])curl([^[:alnum:]_]|$)' <<<"$c"; then
		printf 'curl'
		return 0
	fi
	if grep -qE '(^|[^[:alnum:]_])wget([^[:alnum:]_]|$)' <<<"$c"; then
		printf 'wget'
		return 0
	fi
	return 1
}

# ── Hard-deny tier — never offered to the human ──────────────────────────────
rule="$(hard_deny_rule "$cmd")"
[[ -n "$rule" ]] && emit_deny "$rule"

# ── Ask tier ─────────────────────────────────────────────────────────────────
rule="$(ask_rule "$cmd")"
if [[ -n "$rule" ]]; then
	# Interactivity disabled (no usable TTY, or invoked outside the loop): degrade
	# to an immediate deny — identical to the legacy behaviour, with no files and
	# no blocking, so a headless/cron/CI run can never deadlock.
	[[ -n "${LOOP_APPROVAL_DIR:-}" && -d "${LOOP_APPROVAL_DIR}" ]] || emit_deny "$rule"

	local_req="${LOOP_APPROVAL_DIR%/}/pending-approval.json"
	local_resp="${LOOP_APPROVAL_DIR%/}/approval-response"

	# Carry Claude's own rationale (.tool_input.description) through to the prompt
	# if it sent one; empty otherwise (loop.sh omits the line gracefully).
	desc="$(printf '%s' "$input" | jq -r '.tool_input.description // empty' 2>/dev/null || true)"

	# Publish the request for the foreground loop to render. Built with jq so the
	# command/description are always JSON-safe. Written to a temp then mv'd so the
	# loop never reads a half-written file.
	jq -cn --arg rule "$rule" --arg command "$cmd" --arg description "$desc" \
		'{rule:$rule, command:$command, description:$description}' \
		>"${local_req}.tmp" 2>/dev/null && mv -f "${local_req}.tmp" "$local_req" 2>/dev/null

	# Block-poll for the human's decision. Unbounded by design (free deliberation
	# time); a pre-existing response is honoured on the first iteration, which is
	# what keeps the unit tests non-blocking.
	decision=""
	while :; do
		if [[ -f "$local_resp" ]]; then
			decision="$(tr -d '[:space:]' <"$local_resp" 2>/dev/null || true)"
			break
		fi
		sleep "$APPROVAL_POLL_INTERVAL" 2>/dev/null || sleep 1
	done

	# Clean up BOTH files so the next invocation starts from a blank slate and a
	# stale response can never auto-answer a future prompt.
	rm -f "$local_req" "$local_resp" 2>/dev/null

	# Fail closed: anything that is not an explicit "allow" denies.
	[[ "$decision" == "allow" ]] && exit 0
	emit_deny "$rule"
fi

exit 0
