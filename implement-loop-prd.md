# Headless Implementation Loop — PRD

## Problem Statement

I drive feature work through a fixed, skill-based pipeline: `/grill-me` → `/to-prd` → `/create-plan` produce an approved, phased `plan.md`, and then — for every phase in that plan — I manually run the same five-step cycle by hand, each step in its own fresh Claude Code session:

- **A.** `/implement-phase` to implement the next un-implemented phase (it emits `test-plan.md`).
- **B.** A new session to verify the cases in `test-plan.md`, one subagent per case.
- **C.** If cases fail, a session to investigate, fix, re-test, and note what went wrong in the plan.
- **D.** `/close-phase` to mark the phase done and commit.
- **E.** Back to A for the next phase.

Steps A–E are mechanical. They are the same prompts, in the same order, opening and closing the same sessions, phase after phase. The genuine human value in my workflow lives at the *ends* — reaching alignment (`/grill-me`), shaping requirements (`/to-prd`), designing the plan (`/create-plan`), and opening the PR (`/pr-create`) — not in the repetitive middle. Babysitting the A–E cycle for a multi-phase plan is tedious, breaks my focus, and adds nothing the agent couldn't do itself, *except* in the rare cases where the work is genuinely blocked and needs my judgement.

## Solution

A simple bash orchestration script — kept in the current project directory — that runs the A–E loop unattended via Claude Code's headless mode (`claude -p`), and only pulls me back in when a phase is genuinely **blocked**.

From my perspective: I finish `/create-plan`, commit `plan.md` on a feature branch, and run one script. It works through every `⏳` phase on its own — implementing, verifying, fixing failures aggressively (but with a bound), and committing each phase as it completes. I watch live output if I want to. It stops and tells me clearly only when a phase can't be fixed within its budget, or when reality has drifted far enough from the plan that the plan itself needs rethinking. When it finishes all phases, it hands me a single consolidated checklist of the things only a human can verify, grouped and annotated with how to check each one. I do that batch of manual verification, then I drive `/pr-create` myself.

The loop owns the tedium. I keep the judgement calls — planning, hard blocks, final human verification, and the PR.

## User Stories

1. As a developer, I want the per-phase implement → verify → close cycle to run unattended, so that I don't have to open and babysit a session for every step of every phase.
2. As a developer, I want each step to run in a fresh headless session, so that per-step context stays clean exactly as it does in my manual rhythm.
3. As a developer, I want the loop to auto-select the next un-implemented phase from the plan's state markers, so that I never have to confirm which phase to work on.
4. As a developer, I want failing test cases to be fixed automatically, so that trivial misses self-correct without involving me.
5. As a developer, I want automated fixing to be aggressive but bounded (up to 10 attempts per phase), so that the agent solves hard-but-solvable problems while never looping indefinitely.
6. As a developer, I want the loop to stop and hand control back to me if a phase still fails after its fix budget is exhausted, so that I'm only pulled in for genuinely hard problems.
7. As a developer, I want the agent to distinguish a real test failure from a check only a human can perform, so that it never wastes fix attempts "fixing" a visual/UX check and never closes a phase that is actually broken.
8. As a developer, I want human-only verification checks deferred rather than blocking, so that the loop keeps making progress and I do all my manual verification in one batch at the end.
9. As a developer, I want all deferred human-only checks aggregated into a single checklist when the loop finishes, so that I verify everything at once right before opening the PR.
10. As a developer, I want each deferred check annotated with a short "how to verify" hint and grouped by phase, so that I'm not re-deriving the intent of each terse line.
11. As a developer, I want the agent to resolve minor plan/reality mismatches itself (including editing the plan), so that small plan drift doesn't stop the loop.
12. As a developer, I want the loop to stop and hand back to me when a mismatch threatens the plan's core assumptions, so that I can re-plan before more effort is wasted on a flawed plan.
13. As a developer, I want the verify-and-fix step to retain warm context across its fix attempts, so that it remembers and avoids dead-end fixes it already tried.
14. As a developer, I want the verify-and-fix step to fan out to subagents (one per case), so that the coordinating agent's context window stays lean and the step stays reliable.
15. As a developer, I want each completed phase committed atomically, so that every phase boundary is a clean restore point.
16. As a developer, I want the loop to never push to the remote, so that pushing and opening the PR remain my explicit decisions.
17. As a developer, I want the loop to refuse to run on the default branch, so that per-phase commits never land on `main`.
18. As a developer, I want the loop to refuse to start with a dirty working tree, so that each phase commit contains only loop-produced changes.
19. As a developer, I want to see agent output live while the loop runs, so that I can monitor progress in real time.
20. As a developer, I want a saved transcript per phase and step, so that I can investigate after a block without re-running anything.
21. As a developer, I want a loud, clearly framed handback message naming the phase, the step, the reason, and the log path when the loop stops, so that I know exactly what to look at.
22. As a developer, I want an optional desktop notification when the loop blocks or completes, so that I can walk away and be called back.
23. As a developer, I want the loop to be resumable simply by re-running the same script, so that I never need separate resume tooling or external state.
24. As a developer, I want partial work preserved (never auto-discarded) when a phase blocks, so that I can inspect exactly what the agent attempted before deciding how to proceed.
25. As a developer, I want per-call turn and wall-clock limits, so that a single runaway call cannot spin forever or hang the loop.
26. As a developer, I want an overall iteration ceiling derived from the plan, so that a marker-logic bug cannot loop infinitely.
27. As a developer, I want every abnormal outcome (crash, timeout, turn-limit, or a forgotten status write) to fail closed to a handback, so that the loop never advances on a false success.
28. As a developer, I want the consolidated human-verification checklist written to a file and also summarized in my terminal, so that I can both work through it and see the count immediately when the loop ends.
29. As a developer, I want the loop logic to live in bash and all prompt intelligence to live in skills, so that orchestration stays simple to read while prompts stay versioned and reusable.
30. As a developer, I want the new verify-and-fix and final-verification steps to exist as proper skills, so that I can also invoke them by hand (e.g. to re-run a single step after a block).
31. As a developer, I want the orchestration script to be project-agnostic, so that the project-specific commands stay in the plan and skills while I can run the same loop from any repo.
32. As a developer running unattended with permissions bypassed, I want a deny-list of irreversible commands enforced, so that an agent cannot push, hard-reset, or otherwise cause damage I can't recover from a per-phase commit.
33. As a developer, I want the loop to stop immediately on any blocked signal even though un-done phases remain, so that a blocked phase is never re-attempted in an endless cycle.
34. As a developer, I want the final aggregation step to run only when every phase has completed successfully, so that I never get a "go verify" checklist for an implementation that actually stopped early.

## Implementation Decisions

### Architecture

- The system is a **bash orchestration script** plus **skills**. Bash owns control flow only — it contains no prompt prose. All intelligence lives in skills. This separation is the primary design principle: the script stays trivially readable, and the prompts stay versioned, testable, and individually invokable.
- The script lives in the **current project directory** for now (project-local), though it is written to be project-agnostic so it can later be promoted to a shared location.
- Skills live at the user level alongside the existing pipeline skills.
- Loop state is **not** externalized. The only state is `plan.md`'s phase markers (`⏳` waiting, `🔄` in-progress, `✅` done) plus git history. This makes the loop inherently resumable: re-running the script continues from wherever the markers left off.

### Per-phase cycle — three headless calls

Each phase is processed by exactly three `claude -p` calls, in order:

1. **`implement-phase`** (existing skill) invoked with an appended **override** instructing it to auto-select the target phase from the plan's markers and not ask for confirmation.
2. **`verify-and-fix`** (new skill) — the warm coordinator.
3. **`close-phase`** (existing skill) invoked with an appended **override** instructing it not to ask about unchecked items.

### `verify-and-fix` skill (new, deep module)

- Encapsulates the entire verify+fix responsibility behind a single contract: *make the current phase's test plan reach an all-pass-or-human-only state, or block.*
- Classifies each test case into a **trichotomy**:
  - **PASS** — verified working; checked off.
  - **FAIL** — agent verified it and it is genuinely broken; feeds the fix loop.
  - **NEEDS-HUMAN** — agent cannot verify it (visual / UX / external); left unchecked, marked as human-only, never triggers a fix and never blocks.
- Owns an **internal fix-and-reverify loop**, bounded at **N = 10** attempts per phase. After 10 unsuccessful attempts on a surviving FAIL, it blocks.
- Retains **warm context across fix attempts** (this is the reason the retry loop lives inside one call rather than in bash) so it can remember and avoid dead-end fixes.
- **Fans out to subagents**, one per case, to keep the coordinator's context lean for reliability.
- The distinction between FAIL and NEEDS-HUMAN is a hard requirement: my current manual instruction lumps both into "leave unchecked," which is unacceptable for the loop.

### `close-phase` contract within the loop

- By the time `close-phase` runs, `verify-and-fix` has already resolved every FAIL (fixed → checked, or unfixable → blocked → loop already stopped before close). Therefore **any unchecked item at close time is, by construction, NEEDS-HUMAN.**
- Consequently `close-phase` in the loop **asks no one anything** — its "ask the user about each unchecked item" behaviour simply never fires. It archives the human-only items (rename to `test-plan-phase-<N>.md`), marks the phase `✅`, and commits.
- `close-phase` **never pushes** (consistent with the skill's existing rule).

### Plan / reality mismatch handling

- On a mismatch, `implement-phase` should attempt to **resolve it itself**, including **editing `plan.md`** when appropriate.
- It blocks **only** when the mismatch is severe enough to threaten the plan's core assumptions. A code-level mismatch is the agent's to fix; a design-assumption-level mismatch is mine to re-plan.

### Status signalling — the bash↔agent interface

- Every loop-relevant call writes a single canonical **status file** as its final action. Shape (from prototype; this schema encodes the contract precisely):

  ```json
  { "status": "ok" | "blocked", "reason": "human-readable explanation" }
  ```

- The vocabulary is deliberately **binary** for all three calls: the loop only ever needs "proceed" vs "stop." `verify-and-fix` distinguishing all-passed from human-only-remaining is irrelevant to bash (both → `ok` → proceed to close); that nuance is preserved in `test-plan.md` as unchecked items and surfaced later by `final-verification`.
- **Fail-closed rule:** bash deletes the status file before each call and requires a freshly written file after. A **missing** file — whether from a crash, a `--max-turns`/`timeout` cutoff, or a forgotten write — is treated as `blocked`. Only a fresh `ok` advances the loop.
- The `claude` process exit code is a secondary **infra-crash backstop** (a non-zero exit ⇒ stop), read via `set -o pipefail` since output is piped through `tee`.
- The `reason` field of a `blocked` status is what gets surfaced to me, so I learn *why* without reading a full transcript.

### Loop control

- Outer loop continues while `plan.md` contains a non-`✅` phase (any `⏳` or `🔄`).
- A `blocked` (or missing) status **breaks out immediately**, regardless of remaining phases — otherwise a blocked phase (left `🔄`) would be re-attempted forever. Two independent exits: *all phases `✅`* (success) and *a step signalled blocked* (handback).
- **Resume is free:** a `🔄` phase on a fresh run is resumed by `implement-phase` (the skill already does this); `⏳` phases follow.
- Outer iteration ceiling = `(phase count in plan.md) + 1`; exceeding it is a logic error and bails loudly.

### Permissions & safety

- Runs with permissions **bypassed** (`--dangerously-skip-permissions`) because a coding loop's value depends on the agent handling commands that cannot be enumerated in advance; a permission allow-list tight enough to be safe would be tight enough to cause constant spurious blocks.
- Blast radius is contained **structurally**, not per-command:
  - The loop runs only on a **dedicated feature branch** (pre-flight refuses the default branch).
  - **Atomic per-phase commits** are restore points (`git reset` recovers any phase).
  - A thin **deny-list** blocks the handful of irreversible actions — at minimum `git push`, `git reset --hard`, `rm -rf`, and outbound network calls (`curl`/`wget`).
- The loop runs in the **current checkout** (no git worktree isolation in v1; available as a later upgrade).

### Observability

- Each call runs as `claude -p … --output-format stream-json --verbose` piped through `tee` to a per-phase, per-step log file. This gives **live terminal output** and a **saved transcript** simultaneously.
- `set -o pipefail` is mandatory so the exit-code backstop survives the `tee` pipe (otherwise `$?` reflects `tee`, not `claude`).

### Guardrails

- Per call: `--max-turns 80` and a wall-clock `timeout` of ~40 minutes. Both are generous enough never to bite a legitimate phase but cap true runaways/hangs; hitting either yields no fresh status write ⇒ fail-closed ⇒ handback.

### Pre-flight (before the loop)

- Abort if on the default branch.
- Abort if `plan.md` is missing or contains no pending (`⏳`/`🔄`) phase.
- Abort if the working tree is dirty (I commit `plan.md` first; it is the loop's input). This guarantees every loop commit contains only loop-produced changes.

### Handback & recovery contract

- On block: print a **loud, framed message** — phase, step (implement / verify-and-fix / close), `reason`, and log path — ring the terminal bell, optionally fire `notify-send` if present (its absence never breaks the loop), and exit non-zero.
- **Leave-behind state:** the blocked phase stays `🔄`; partial/uncommitted changes (incomplete implementation or the failed fix attempts) remain in the working tree **uncommitted** (because `close-phase` never ran); the status file holds the reason; logs remain. Nothing is auto-discarded — inspectable failure beats a tidy one.
- I inspect, fix the plan and/or code, and **re-run the same script** to resume. If I want a clean slate for that phase I `git stash`/`git restore` myself.

### `final-verification` skill (new, deep module)

- Runs **only on the success path** (all phases `✅`); never runs if the loop blocked.
- Reads all archived `test-plan-phase-<N>.md` files plus `plan.md`, then produces a **consolidated `human-verification.md`**: deferred human-only items grouped by phase, deduplicated, each with a one-line **how-to-verify** hint. Also prints a terminal summary (including the count).
- **Report-only and uncommitted.** It neither gates nor commits. After I work through it, I drive `/pr-create` myself.

## Testing Decisions

- **What makes a good test here:** assert **external behaviour** of the orchestration layer — given a set of inputs (a fixture `plan.md` with particular markers, and a particular status-file content / exit code from a call), the script makes the correct control-flow decision (proceed, stop-and-handback, terminate-success, bail-on-cap). Do not assert internal implementation details of the script.
- **What is testable (and should be tested):** the **bash control-flow decisions**, because they are deterministic and regressable. These can be exercised by substituting a **stub `claude`** on `PATH` that writes a scripted status file (or no file) and returns a scripted exit code, combined with fixture `plan.md` files in known marker states. Cases worth covering:
  - `ok` status advances to the next call / next phase.
  - `blocked` status stops immediately and exits non-zero with the reason surfaced.
  - **Missing** status file (stubbed crash / forgotten write) is treated as `blocked` (the fail-closed contract).
  - Non-zero `claude` exit (infra crash) stops, and `pipefail` correctly propagates it through `tee`.
  - Termination when no non-`✅` phase remains.
  - A `🔄` phase on startup is resumed rather than skipped or duplicated.
  - The outer iteration cap bails loudly rather than looping.
  - Pre-flight refuses: default branch, missing/empty plan, dirty tree.
- **What is not unit-tested:** the **skills themselves** (`verify-and-fix`, `final-verification`, and the override behaviours) are prompt-driven; their behaviour is validated empirically by running them, not by unit tests. The trichotomy classification and the bounded fix loop are emergent agent behaviours, not deterministic functions.
- **Prior art:** the project directory is currently empty, so there is no existing test harness to mirror. The stub-`claude`-on-`PATH` + fixture-`plan.md` approach is the proposed pattern and should become the prior art for any future bash-orchestration tooling.

## Out of Scope

- **Steps 1–3 of the broader workflow** (`/grill-me`, `/to-prd`, `/create-plan`) — these remain human-driven; they are where human value concentrates.
- **PR creation** (`/pr-create`) — remains my explicit step after I've worked through the final human-verification checklist.
- **Pushing to the remote** — explicitly forbidden to the loop.
- **Git worktree isolation** — deferred; v1 runs in the current checkout. The structural safety (feature branch + per-phase commits + deny-list) stands without it.
- **Promoting the script to a shared/`PATH` location** — deferred; it lives in the current project directory for now.
- **A non-`jq` status-file parser** — v1 assumes `jq`; a greppable-lines fallback is a known, cheap future swap if a dependency-free loop is wanted.
- **Auto-discarding or auto-stashing partial work on block** — explicitly not done; partial state is preserved for inspection.
- **Modelling per-step status vocabulary richer than `ok`/`blocked`** — explicitly collapsed to a binary at the bash boundary.

## Further Notes

- The choice to put the fix-retry loop **inside** a single warm `verify-and-fix` call (rather than orchestrating each fix attempt as a separate bash-driven session) is deliberate and central: the fix loop is the one place where memory across attempts is a feature, not a liability. Subagent fan-out for per-case verification keeps that warm coordinator's context lean, which is what buys reliability at the larger context the warm loop implies.
- The whole design fails **closed**: every uncertain or abnormal outcome converges on "stop and hand back," never on "advance." This is intentional — a false handback costs me a glance; a false "proceed" corrupts the plan's progress markers and commits.
- The micro-defaults chosen where I deferred during alignment: `jq` for status parsing, no worktree, `--max-turns 80`, `timeout` ~40 minutes. All are easy to revisit.
- The loop deliberately mirrors my existing manual rhythm (fresh session per step, per-phase commit, deferred human verification) so that its behaviour is predictable to me and so that any single step can still be run by hand exactly as before.
