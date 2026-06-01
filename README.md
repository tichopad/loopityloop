# loopityloop

A bash orchestrator that runs an approved, phased `plan.md` to completion **unattended** via Claude Code headless mode. For every pending phase it runs `implement → verify-and-fix → close` — each in a fresh `claude -p` session — committing each phase atomically. It only stops to call you back when a phase is genuinely blocked.

It owns the tedious middle of the workflow. You keep the judgement calls: planning, hard blocks, final verification, and the PR.

## What you need

- **Claude Code CLI** (`claude`), `jq`, `git`, GNU `timeout` (`coreutils`).
- **Skills** installed in `~/.claude/skills/`: `implement-phase`, `verify-and-fix`, `close-phase`, `final-verification`.
- An approved **`plan.md`** with phase headings ending in a status marker:
  - `⏳` waiting · `🔄` in-progress · `✅` done
- A **git repo on a feature branch** (not `main`/`master`), **clean working tree**.

## Setup on a new machine

Clone over SSH and run the installer. It symlinks `loop.sh` into a `PATH`
directory (`~/.local/bin` by default); `loop.sh` resolves that symlink back to the
clone, so its helper scripts (`deny-check.sh`, `format-stream.sh`) keep working
from the one link.

```bash
git clone git@github.com:tichopad/loopityloop.git
cd loopityloop
./install.sh
```

- If `~/.local/bin` isn't on your `PATH`, the installer prints the line to add to your shell rc.
- Install elsewhere: `BIN_DIR=~/bin ./install.sh`. Remove the link: `./install.sh --uninstall`.
- Prefer no install? Just run `./loop.sh` from the clone, or add the clone dir to `PATH` yourself.

You still need the prerequisites above — in particular the four **skills** under
`~/.claude/skills/` (`implement-phase`, `verify-and-fix`, `close-phase`,
`final-verification`), which are **not** bundled in this repo. `loop.sh` checks the
CLI tools and the deny-check hook at startup and refuses to run if anything is missing.

## Usage

```bash
loop.sh [plan.md]        # installed (on PATH); defaults to ./plan.md
./loop.sh [plan.md]      # or run directly from a clone
```

That's it. The loop selects the next `⏳` phase, works it, commits it, and moves on. Watch the live output, or walk away — you get a desktop notification (if `notify-send` exists) when it blocks or finishes.

**Resume** after a block: fix the plan/code, then just re-run `./loop.sh`. State lives entirely in `plan.md`'s markers — no separate resume tooling.

## What it produces

- **Commits** — one atomic commit per completed phase (the skills commit; the script never does). It **never pushes**.
- `.loop/logs/phase-N-<step>.jsonl` — full transcript per phase/step.
- `human-verification.md` — on success, a consolidated checklist of human-only checks, grouped by phase with "how to verify" hints. Work through it, then run `/pr-create` yourself.

(`.loop/` and `human-verification.md` are auto-added to `.git/info/exclude` — never committed.)

## When it stops

It **fails closed**: any abnormal outcome (crash, timeout, max-turns, a `blocked` status, a missing status write) stops the loop with a loud handback banner naming the **phase, step, reason, and log path**. The phase is left `🔄` with partial work uncommitted for you to inspect. The loop never advances on a false success.

## Safety

Runs under `--dangerously-skip-permissions`, so containment is layered:

- **Structural (primary):** feature-branch-only + per-phase commits = every phase boundary is a clean restore point.
- **Deny-list hook (`deny-check.sh`):** blocks irreversible commands even under bypass — `git push`, `git reset --hard`, `rm -rf`, `curl`, `wget`. The loop refuses to start if this hook is missing or non-executable.
- **Bounds:** per-call max-turns (80) and wall-clock timeout (40m), plus an overall iteration ceiling derived from the plan.

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
| `install.sh` | Symlinks `loop.sh` onto your `PATH` (see Setup). |
| `implement-loop-prd.md` | The PRD this was built from. |
| `plan.md` | The implementation plan for loopityloop itself. |
| `tests/` | `run.sh` harness, stub `claude`, fixtures, deny-check tests. |

## Tests

```bash
tests/run.sh
```
