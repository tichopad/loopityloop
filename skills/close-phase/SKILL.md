---
name: close-phase
description: Close an implemented phase of technical plan
disable-model-invocation: true
---

# Close Phase

**Expected input**: `<path-to-plan>` (e.g., `plan.md`), with an optional `--status <path>` flag that activates **Loop Mode** (see the section at the end). The plan path is the first positional argument; the status-file path is the value following `--status`.

If the plan-path argument is missing, ask for it before proceeding.

## 1. Determine Current Phase

- Read the plan file completely.
- Find the phase whose heading ends with `🔄` (in-progress).
  - This is the phase being closed.
  - If no phase heading ends with `🔄`, tell the user there is no in-progress phase to close and stop.
  - If all phase headings end with `✅`, tell the user all phases are complete and stop.

## 2. Verify Test Plan

- Read `test-plan.md`.
- Check whether every item is marked done (`- [x]`).
- For each **unchecked** item, ask the user (using the available tool) whether it passed — phrase it as a yes/no question including the test description.
  - If the user confirms it passed, check it off in `test-plan.md`.
  - If the user says it did **not** pass, stop the close process and tell the user the phase cannot be closed until the failing item is resolved.

## 3. Archive Test Plan

- Rename `test-plan.md` to `test-plan-phase-<N>.md` where `<N>` is the phase number being closed.

## 4. Mark Phase Complete

- In the plan file, replace the `🔄` suffix on the phase heading with `✅`.

## 5. Commit

- Stage **all** changed and renamed files related to this close (plan file, archived test plan, any other files modified during the phase).
- Create a commit following repository commit conventions. The short (title) line **must** include the phase number (e.g., `feat: complete phase 1 — CTA block config`).
- Do **not** push unless the user explicitly asks.

## Loop Mode

Loop Mode is an **additive, opt-in** override for unattended (headless) runs. It activates **only** when this skill is invoked with a `--status <path>` argument, e.g.:

```
/close-phase plan.md --status .git/loopityloop/status.json
```

When the flag is **absent**, ignore this entire section — every step above behaves exactly as written, including asking the user about each unchecked item. Loop Mode changes nothing about hand-invocation.

When `--status <path>` **is** present, apply these overrides on top of the steps above:

- **Step 2 — ask no one anything.** Do **not** prompt the user about unchecked `test-plan.md` items. By the time the loop reaches close, `verify-and-fix` has already resolved every genuine failure (fixed → checked off, or unfixable → it already blocked the loop *before* close ran). Therefore **any item still unchecked at close time is, by construction, a human-only (NEEDS-HUMAN) check.** Leave it unchecked and proceed — do not check it off, do not try to fix it, do not block on it.
- **Steps 3–5 — unchanged.** Archive `test-plan.md` → `test-plan-phase-<N>.md`, mark the phase `✅`, and commit (the commit title must include the phase number). Continue to **never push**.
- **No interactive prompts, ever.** In Loop Mode there is no human watching. Never block waiting on user input — either complete the close or write a `blocked` status (below) and stop.
- **Final action — write the status file.** As the very last thing you do, write the status file at the `--status` path. Create its parent directory first if needed. Write it **last** and write it **once**:
  - On a **successful close** — archived, marked `✅`, and committed — write exactly:

    ```json
    { "status": "ok" }
    ```

  - **Only** if the close genuinely cannot complete (e.g. no `🔄` phase to close, or nothing to commit) — write:

    ```json
    { "status": "blocked", "reason": "<one-line human-readable explanation>" }
    ```

  This file is the orchestrator's sole signal. A **missing** file is treated as `blocked` (fail-closed), so never skip the write.