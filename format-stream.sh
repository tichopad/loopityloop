#!/usr/bin/env bash
#
# format-stream.sh — turn Claude Code's stream-json into a legible terminal feed.
#
# Reads line-delimited stream-json on stdin (the same bytes the raw log captures)
# and writes a human-readable feed to stdout. It is the tail of the loop's call
# pipeline: `claude … | tee "$log" | format-stream.sh`. The raw log is written
# upstream by `tee`, so this filter NEVER touches it and the log stays pure JSONL.
#
# Design: a SINGLE long-lived `jq` process (no per-line subshell fork), fed with
# `-R` (raw input, one JSON doc per line) and `fromjson?` so a malformed or
# half-written line — e.g. a JSONL row truncated mid-flush by a Ctrl+C — is
# silently skipped rather than aborting the stream. `--unbuffered` keeps the feed
# live so output appears as Claude works, not in one burst at the end.
#
# Rendering rules:
#   thinking blocks      -> suppressed entirely
#   tool_use blocks      -> prominent icon line (🔧 Bash › cmd, ✏️ Edit › file, …)
#   assistant text       -> dimmed, truncated to terminal width
#   tool_result (user)   -> one-line ✓/✗ outcome, large content truncated
#   result event         -> closing summary (✓ done · N turns · duration)
#
# TTY / NO_COLOR aware: emits ANSI colour + emoji only when stdout is a TTY and
# NO_COLOR is unset; otherwise plain ASCII tags ([bash], [edit], [text], [done]).

set -uo pipefail

# Terminal width for truncation/wrapping; fall back to 80 if undetectable.
COLS="$(tput cols 2>/dev/null || true)"
[[ "$COLS" =~ ^[0-9]+$ ]] && (( COLS > 0 )) || COLS=80

# Colour + emoji only on an interactive TTY without NO_COLOR. The raw log path is
# unaffected — tee already wrote it upstream, ANSI-free.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
	FANCY=1
else
	FANCY=0
fi

# A single jq program does all rendering. It receives $fancy and $cols so the
# same program serves both the pretty and the plain code paths.
exec jq -Rr --unbuffered \
	--argjson fancy "$FANCY" \
	--argjson cols "$COLS" \
	'
	# ---- helpers -----------------------------------------------------------
	# Collapse whitespace/newlines into a single readable line.
	def oneline: gsub("[[:space:]]+"; " ") | gsub("^ +| +$"; "");

	# Truncate to a width, appending an ellipsis marker when cut.
	def clip($w): . as $s
		| if ($s | length) > $w then ($s[0:($w-1)]) + "…" else $s end;

	# ANSI wrappers (no-ops when $fancy is 0).
	def dim:    if $fancy == 1 then "[2m" + . + "[0m" else . end;
	def bold:   if $fancy == 1 then "[1m" + . + "[0m" else . end;
	def green:  if $fancy == 1 then "[32m" + . + "[0m" else . end;
	def red:    if $fancy == 1 then "[31m" + . + "[0m" else . end;

	# Icon-or-tag pair: pick the emoji on fancy, the bracket tag otherwise.
	def mark($emoji; $tag): if $fancy == 1 then $emoji else $tag end;

	# Render one tool_use block to a single prominent line.
	def render_tool:
		(.name // "tool") as $tool
		| (.input // {}) as $in
		| if   $tool == "Bash"  then (mark("🔧"; "[bash]")  + " Bash › "  + (($in.command // "") | oneline))
		  elif $tool == "Edit"  then (mark("✏️ "; "[edit]")  + " Edit › "  + (($in.file_path // "") | oneline))
		  elif $tool == "Write" then (mark("📝"; "[write]") + " Write › " + (($in.file_path // "") | oneline))
		  elif $tool == "Read"  then (mark("📖"; "[read]")  + " Read › "  + (($in.file_path // "") | oneline))
		  elif $tool == "Task"  then (mark("🤖"; "[task]")  + " Task › "  + (($in.description // $in.subagent_type // "") | oneline))
		  else (mark("🔧"; "[tool]") + " " + $tool)
		  end
		| clip($cols);

	# Render one tool_result block (lives in a user-role message) to one line.
	def render_result:
		(.is_error // false) as $err
		| (
			# content may be a string or an array of {type,text} blocks.
			if (.content | type) == "string" then .content
			elif (.content | type) == "array"
				then ([.content[] | (.text // "")] | join(" "))
			else "" end
		  ) as $body
		| ($body | oneline) as $line
		| (if $err then mark("✗"; "[x]") else mark("✓"; "[ok]") end) as $icon
		| ($icon + " " + ($line | clip($cols - 2)))
		| if $err then red else dim end;

	# ---- main dispatch -----------------------------------------------------
	(fromjson? // empty) as $e
	| $e
	| if .type == "assistant" then
		# Walk the assistant message content blocks in order.
		( .message.content // [] )[]
		| if   .type == "thinking"     then empty                       # suppressed
		  elif .type == "redacted_thinking" then empty
		  elif .type == "tool_use"     then render_tool
		  elif .type == "text"         then
			(.text // "" | oneline) as $t
			| if ($t | length) > 0
				then (mark(""; "[text] ") + ($t | clip($cols))) | dim
				else empty end
		  else empty end

	  elif .type == "user" then
		# User-role messages carry tool_result blocks (and nothing we echo).
		( .message.content // [] )[]
		| if .type == "tool_result" then render_result else empty end

	  elif .type == "result" then
		# Closing summary line. Duration is optional — include only when present.
		(.is_error // false) as $err
		| (.num_turns // 0) as $turns
		| ( if (.duration_ms | type) == "number"
			then " · " + ((.duration_ms / 1000) | floor | tostring) + "s"
			else "" end
		  ) as $dur
		| if $err
			then (mark("✗"; "[done]") + " failed · " + ($turns|tostring) + " turns" + $dur) | red
			else (mark("✓"; "[done]") + " done · " + ($turns|tostring) + " turns" + $dur) | green
		  end

	  else empty end
	'
