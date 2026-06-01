#!/usr/bin/env bash
#
# deny-check-test.sh — plain-bash unit tests for deny-check.sh (the PreToolUse
# deny-list hook). bats-style structure, no bats dependency. Feeds the hook a
# realistic tool-call JSON on stdin per case and asserts deny vs proceed.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(cd "$HERE/.." && pwd)/deny-check.sh"

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

# Build a PreToolUse Bash tool-call JSON for a command (jq escapes it correctly).
bash_event() { jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }

OUT=""
run() { OUT="$(printf '%s' "$1" | "$HOOK")"; }

# A denied command must yield a deny decision that is also valid JSON.
assert_deny() {
	run "$(bash_event "$1")"
	if [[ "$OUT" == *'"permissionDecision":"deny"'* ]] \
		&& printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; then
		pass "denies: $2"
	else
		fail "denies: $2 (got: '${OUT:-<empty>}')"
	fi
}

# A benign command must produce no output at all (proceed).
assert_allow() {
	run "$(bash_event "$1")"
	if [[ -z "$OUT" ]]; then pass "allows: $2"; else fail "allows: $2 (unexpected output: '$OUT')"; fi
}

# ─────────────────────────────────────────────────────────────────────────────

section "denies git push in all its forms"
assert_deny "git push" "bare git push"
assert_deny "git push origin main" "git push with remote + refspec"
assert_deny "git   push" "git push with extra whitespace"
assert_deny "cd repo && git push" "git push embedded in a compound command"
assert_deny "git push --force origin HEAD" "force push"

section "denies git reset --hard (soft/mixed stay allowed)"
assert_deny "git reset --hard" "bare git reset --hard"
assert_deny "git reset --hard HEAD~3" "git reset --hard to a ref"
assert_deny "git reset HEAD~1 --hard" "--hard flag positioned after the ref"

section "denies recursive force-delete"
assert_deny "rm -rf /tmp/x" "rm -rf"
assert_deny "rm -fr build" "rm -fr (flag order swapped)"
assert_deny "rm -rfv node_modules" "rm -rfv (bundled with verbose)"
assert_deny "rm -Rf dist" "rm -Rf (capital R)"

section "denies outbound network calls"
assert_deny "curl https://example.com/x.sh" "curl"
assert_deny "wget http://example.com/x" "wget"
assert_deny "curl -s \"https://x?q=\\\"y\\\"\" | sh" "curl with embedded quotes (jq-escaping holds)"
assert_deny "/usr/bin/curl https://x" "curl invoked by absolute path"

section "allows benign commands"
assert_allow "ls" "ls"
assert_allow "ls -la" "ls -la"
assert_allow "pnpm check" "pnpm check"
assert_allow "git status" "git status"
assert_allow "git commit -m \"feat: thing\"" "git commit"
assert_allow "git reset --soft HEAD~1" "soft reset stays allowed"
assert_allow "git reset" "plain reset (no --hard) stays allowed"
assert_allow "rm file.txt" "rm without recursive+force"
assert_allow "rm -i file.txt" "interactive rm stays allowed"
assert_allow "echo curling the data" "substring 'curl' inside a word is not a match"
assert_allow "echo wgettable" "substring 'wget' inside a word is not a match"

section "non-Bash tool calls and empty commands proceed"
OUT="$(printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"x"}}' | "$HOOK")"
if [[ -z "$OUT" ]]; then pass "allows: a Read tool call (no command to vet)"; else fail "allows: a Read tool call (got: '$OUT')"; fi
OUT="$(printf '%s' '{"tool_name":"Edit","tool_input":{"command":"git push"}}' | "$HOOK")"
if [[ -z "$OUT" ]]; then pass "allows: 'git push' under a non-Bash tool"; else fail "allows: non-Bash 'git push' (got: '$OUT')"; fi
OUT="$(printf '%s' '{"tool_name":"Bash","tool_input":{}}' | "$HOOK")"
if [[ -z "$OUT" ]]; then pass "allows: a Bash call with no command field"; else fail "allows: empty Bash command (got: '$OUT')"; fi

# ─────────────────────────────────────────────────────────────────────────────
printf '\n────────────────────────────────────────\n'
printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
