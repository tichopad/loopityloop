# loopityloop

A bash orchestrator that runs an approved, phased `plan.md` to completion **unattended** via Claude Code headless mode. For every pending phase it runs `implement → verify-and-fix → close` — each in a fresh `claude -p` session — committing each phase atomically. It only stops to call you back when a phase is genuinely blocked.

It owns the tedious middle of the workflow. You keep the judgement calls: planning, hard blocks, final verification, and the PR.

## What you need

- **Claude Code CLI** (`claude`), `jq`, `git`, GNU `timeout` (`coreutils`).
- **Skills**: `implement-phase`, `verify-and-fix`, `close-phase`, `final-verification`. These ship in this repo under `skills/` and `install.sh` links them into `~/.claude/skills/` for you.
- An approved **`plan.md`** with phase headings ending in a status marker:
  - `⏳` waiting · `🔄` in-progress · `✅` done
- A **git repo on a feature branch** (not `main`/`master`), **clean working tree**.

## Setup on a new machine

Clone over SSH and run the installer. It does two things, both via symlink so the
clone stays the single source of truth:

1. Links `loop.sh` into a `PATH` directory (`~/.local/bin` by default); `loop.sh`
   resolves that symlink back to the clone, so its helper scripts
   (`deny-check.sh`, `format-stream.sh`) keep working from the one link.
2. Links the four skills under `skills/` into `~/.claude/skills/` so `claude`
   finds them by name.

```bash
git clone git@github.com:tichopad/loopityloop.git
cd loopityloop
./install.sh
```

- If `~/.local/bin` isn't on your `PATH`, the installer prints the line to add to your shell rc.
- Install elsewhere: `BIN_DIR=~/bin ./install.sh`; link skills elsewhere: `SKILLS_DIR=... ./install.sh`.
- Remove the links: `./install.sh --uninstall` (only removes links pointing back into this clone — a hand-managed skill dir is left untouched).
- A skill that already exists in `~/.claude/skills/` as a real directory is **skipped, not overwritten** — remove it yourself and re-run if you want the bundled version.
- Prefer no install? Just run `./loop.sh` from the clone, but you must still make the skills reachable to `claude` (link or copy `skills/*` into `~/.claude/skills/`).

`loop.sh` checks the CLI tools (`claude`, `jq`, `git`, `timeout`) and the deny-check
hook at startup and refuses to run if anything is missing.

## Usage

```bash
loop.sh [plan.md]        # installed (on PATH); defaults to ./plan.md
./loop.sh [plan.md]      # or run directly from a clone
```

That's it. The loop selects the next `⏳` phase, works it, commits it, and moves on. Watch the live output, or walk away — you get a desktop notification (if `notify-send` exists) when it blocks or finishes.

**Resume** after a block: fix the plan/code, then just re-run `./loop.sh`. State lives entirely in `plan.md`'s markers — no separate resume tooling.

## What it produces

- **Commits** — one atomic commit per completed phase (the skills commit; the script never does). It **never pushes**.
- `.git/loopityloop/logs/phase-N-<step>.jsonl` — full transcript per phase/step.
- `.git/loopityloop/logs/approvals.log` — one line per ask-tier decision (timestamp · phase/step · rule · command · allowed/denied), when any approvals were prompted.
- `human-verification.md` — on success, a consolidated checklist of human-only checks, grouped by phase with "how to verify" hints. Work through it, then run `/pr-create` yourself.

(Loop state and logs live under `.git/loopityloop/` — inside the git dir, so git never tracks them and formatters/editors never see them, with no per-project ignore-file upkeep. Because that path resolves per worktree, linked worktrees stay isolated automatically. `human-verification.md` is auto-added to `.git/info/exclude` so it, too, is never committed.)

## When it stops

It **fails closed**: any abnormal outcome (crash, exceeding the 40-minute active-time budget, max-turns, a `blocked` status, a missing status write) stops the loop with a loud handback banner naming the **phase, step, reason, and log path**. The phase is left `🔄` with partial work uncommitted for you to inspect. The loop never advances on a false success.

The 40-minute budget is **active time** — it excludes any time the loop spends parked on an interactive approval prompt. A coarse 4-hour `timeout` still wraps each call as an absolute backstop, but it only fires if the supervising watch-loop itself wedges; the active-time budget is the real per-call limit.

## Safety

Runs under `--dangerously-skip-permissions`, so containment is layered:

- **Structural (primary):** feature-branch-only + per-phase commits = every phase boundary is a clean restore point.
- **Tri-state gate (`deny-check.sh`):** a single `PreToolUse` hook vets every Bash command, even under bypass (a hook denial wins over `--dangerously-skip-permissions`). Three outcomes:
  - **Hard-deny — never offered:** `git push`, `git reset --hard`. Always blocked; a stray approval can never reach these.
  - **Ask-the-human:** `rm -rf`, `curl`, `wget`. Pauses the loop and asks for a one-time approval (see below). Deleting only Markdown is exempt: an `rm` (even `rm -rf`) whose every target ends in `.md` runs silently.
  - **Allow:** everything else runs silently.

  The loop refuses to start if this hook is missing or non-executable.
- **Bounds:** per-call max-turns (80) and a **40-minute active-time budget** (excluding any time spent waiting on a human approval), plus a coarse 4-hour absolute backstop and an overall iteration ceiling derived from the plan.

### Interactive approvals (the ask tier)

When the agent tries an ask-tier command (`rm -rf`, `curl`, `wget`), the loop pauses, rings the terminal bell, fires a desktop notification (if `notify-send` exists), and prompts you on the terminal:

```
⚠️  Approval needed — Phase 3 / verify
  Rule    : rm -rf  (ask-tier)
  Command : rm -rf node_modules/.cache
  Claude  : "Clearing stale build cache before reinstalling"
Approve? [y/N]   (Enter/anything = deny · Ctrl+C = abort whole loop)
```

- `y` / `yes` (case-insensitive, trimmed) **approves** just that one command. Anything else, a bare Enter, or Ctrl+D **denies**. Ctrl+C aborts the whole loop.
- The wait is **indefinite** and your deliberation time is **free** — it does not count against the 40-minute budget.
- Approval is **per-invocation**: nothing is remembered. The next `rm -rf` asks again.
- **Markdown deletes are exempt:** an `rm` (even `rm -rf`) whose targets are all `*.md` files runs without a prompt. Any non-`.md` target, a directory, or a chained command (`&&`, `|`, …) still asks.
- Every decision is appended to `.git/loopityloop/logs/approvals.log`.

**No terminal? No problem — it fails closed.** With no usable controlling terminal (cron, CI, `nohup`, a pipe), interactive approval is impossible, so the loop prints a non-fatal startup warning and **silently denies every ask-tier command** — exactly the old behaviour, with no risk of hanging on a prompt nobody can answer.

## Where this fits

```
/grill-me → /to-prd → /create-plan  →  commit plan.md on a feature branch
                                        ↓
                                    ./loop.sh   ← you are here (unattended)
                                        ↓
              work through human-verification.md  →  /pr-create
```

## Layout

| File | Role |
|------|------|
| `loop.sh` | The orchestrator — pure control flow, no prompts. |
| `deny-check.sh` | PreToolUse deny-list hook (irreversible-command guard). |
| `format-stream.sh` | Renders raw stream-json into a readable terminal feed. |
| `install.sh` | Symlinks `loop.sh` onto your `PATH` and the skills into `~/.claude/skills/` (see Setup). |
| `skills/` | The four skills the loop invokes (`implement-phase`, `verify-and-fix`, `close-phase`, `final-verification`). |
| `implement-loop-prd.md` | The PRD this was built from. |
| `plan.md` | The implementation plan for loopityloop itself. |
| `tests/` | `run.sh` harness, stub `claude`, fixtures, deny-check tests. |

## Tests

```bash
tests/run.sh
```
