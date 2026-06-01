#!/usr/bin/env bash
#
# deny-check.sh — PreToolUse deny-list hook for the headless implementation loop.
#
# Best-effort defence-in-depth. The PRIMARY containment is structural: the loop
# runs only on a dedicated feature branch with atomic per-phase commits, so any
# damage is recoverable from a restore point. This hook is the thin extra layer
# that blocks the handful of *irreversible* actions an agent should never take
# while running under --dangerously-skip-permissions:
#
#   git push          — pushing is the human's explicit decision, not the loop's
#   git reset --hard   — destroys uncommitted work below the restore points
#   rm -rf            — recursive force-delete is unrecoverable
#   curl / wget       — outbound network calls (exfiltration / fetch-and-run)
#
# A PreToolUse hook denial WINS over --dangerously-skip-permissions: hooks still
# run under bypass, and a deny decision is honoured. The deny is signalled by
# emitting the decision JSON on stdout and exiting 0. Anything not matched prints
# nothing and exits 0 (proceed). The hook never blocks on its own errors — it
# fails open only for malformed/non-Bash input, which carries no shell command.
#
# Contract (Claude Code PreToolUse hook):
#   stdin  : the tool-call JSON, including .tool_name and .tool_input
#   stdout : on deny, {"hookSpecificOutput":{...,"permissionDecision":"deny",...}}
#   exit   : always 0

set -uo pipefail

input="$(cat)"

# Only Bash tool calls carry a shell command to vet; everything else proceeds.
tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[[ "$tool" == "Bash" ]] || exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[[ -n "$cmd" ]] || exit 0

# Match $cmd against each deny pattern; echo a short rule label on the first hit,
# return 1 on no match. `(^|[^[:alnum:]_])` / `([^[:alnum:]_]|$)` act as portable
# word boundaries (no reliance on \b), and [[:space:]]+ tolerates extra spacing.
# Patterns are matched anywhere in the command so `cd x && git push` is caught.
matched_rule() {
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
	# rm with a bundled recursive+force flag: -rf, -fr, -Rf, -rfv, … (split flags
	# like `rm -r -f` are intentionally not chased — this is best-effort).
	if grep -qE '(^|[^[:alnum:]_])rm[[:space:]]+-[[:alnum:]]*([rR][[:alnum:]]*[fF]|[fF][[:alnum:]]*[rR])' <<<"$c"; then
		printf 'rm -rf'
		return 0
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

rule="$(matched_rule "$cmd")"
if [[ -n "$rule" ]]; then
	# Build the deny JSON with jq so the reason is always correctly escaped.
	jq -cn --arg r "${rule} blocked by loop deny-list" \
		'{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi

exit 0
