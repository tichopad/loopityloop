---
name: implement-phase
description: Implement a phase of technical plan with verification
disable-model-invocation: true
---

# Implement Phase

Implement a single phase of an approved implementation plan, verify the work, and produce a manual test checklist.

**Expected input**: `<path-to-plan>` (e.g., `plan.md`), with an optional `--status <path>` flag that activates **Loop Mode** (see the section at the end). The plan path is the first positional argument; the status-file path is the value following `--status`.

If the plan-path argument is missing, ask for it before proceeding.

## 1. Read & Understand

- Read the plan file completely — never partially.
- Determine the target phase:
  - If a phase heading ends with `🔄`, it is in-progress — resume that phase from the first unchecked item.
  - Otherwise, pick the first phase heading ending with `⏳` (waiting).
  - If no `⏳` phases remain (all are `✅`), tell the user all phases are complete and stop.
- Display which phase you selected and ask the user to confirm before proceeding.
- Check for `✅` on earlier phase headings — trust completed phases and start from the target.
- Read the original ticket/issue if referenced in the plan.
- Read **all files mentioned** in the target phase fully — no limit/offset.
- Think about how the changes fit into the broader codebase before writing any code.

## 2. Mark Phase In-Progress

- In the plan file, replace the `⏳` suffix on the target phase heading with `🔄` to indicate work is underway.
- If the phase is already marked `🔄`, it was partially implemented in a prior conversation — continue from the first unchecked item.

## 3. Implement

- Follow the plan's intent while adapting to what you actually find in the code.
- Implement changes methodically — complete one file or logical unit before moving to the next.
- Track progress with todos as you go.

### When Reality Doesn't Match the Plan

If something doesn't match what the plan describes, **stop and present the mismatch clearly**:

```
Issue in Phase [N]:
Expected: [what the plan says]
Found: [actual situation]
Why this matters: [impact on the implementation]

Suggested resolution: [your recommendation]
```

Wait for user input before proceeding past the mismatch.

## 4. Verify Automatically

After implementing, run all automated checks you can:

- `pnpm check` (covers typecheck + lint)
- Any phase-specific verification commands from the plan's Verification section
- Fix issues yourself — iterate until automated checks pass

## 5. Update the Plan

Reflect your progress in the implementation plan document:

- Check off (`- [x]`) completed items within the phase's Changes and automated Verification items.
- Do **not** mark the phase itself as complete — that's for the close-phase command after manual verification.
- Do **not** check off manual verification items.

## 6. Compose Manual Test Plan

Write a `test-plan.md` file with a concise checklist of what needs human verification.

Rules:

- **5–8 checkbox lines max**, one line per test — no headings, no descriptions.
- Only include tests that genuinely require a human (UI behavior, visual checks, flows that need a browser).
- Every check that can be done programmatically should already be done in step 3 — don't duplicate those here.

Example format:

```markdown
- [ ] Product page shows updated price format
- [ ] Cart updates correctly when quantity changes
- [ ] Mobile nav menu opens and closes smoothly
```

## 7. Report

Summarize what was done:

```
Phase [N] implemented — automated checks passing.

Changes made:
- [Brief list of what changed]

Please verify the manual test plan in test-plan.md.
Let me know when testing is complete so I can mark the phase as done.
```

## Loop Mode

Loop Mode is an **additive, opt-in** override for unattended (headless) runs. It activates **only** when this skill is invoked with a `--status <path>` argument, e.g.:

```
/implement-phase plan.md --status .loop/status.json
```

When the flag is **absent**, ignore this entire section — every step above behaves exactly as written, including the interactive confirmation and the wait-for-input on a mismatch. Loop Mode changes nothing about hand-invocation.

When `--status <path>` **is** present, apply these overrides on top of the steps above:

- **Step 1 — no confirmation.** Do **not** ask the user to confirm the selected phase. Auto-select the target phase from the markers (resume a `🔄` phase, otherwise the first `⏳`) and proceed straight into the work. Everything else in step 1 still applies — read the plan and all referenced files fully.
- **Step 3 — resolve mismatches yourself.** Replace the "stop, present the mismatch, and wait for user input" behaviour. When reality doesn't match the plan, **resolve it yourself**: adapt the implementation to what you find, and **edit `plan.md` directly** when the plan text itself is what's wrong (leave the phase markers intact). Block **only** when the mismatch threatens the plan's *core assumptions* — a design-level contradiction that makes the phase's goal unachievable as planned. That is the human's call to re-plan; a code-level or detail-level mismatch is always yours to fix.
- **No interactive prompts, ever.** In Loop Mode there is no human watching to answer questions. Never block waiting on user input. Either resolve the situation, or write a `blocked` status (below) with a clear reason and stop.
- **Final action — write the status file.** As the very last thing you do (after completing steps 1–7, whether you succeeded or are blocking), write the status file at the `--status` path. Create its parent directory first if needed. Write it **last** and write it **once**:
  - On **success** — phase implemented, automated checks pass, and `test-plan.md` written — write exactly:

    ```json
    { "status": "ok" }
    ```

  - On a **block** — a core-assumption mismatch, or an unrecoverable failure you cannot fix — write:

    ```json
    { "status": "blocked", "reason": "<one-line human-readable explanation>" }
    ```

  This file is the orchestrator's sole signal. A **missing** file is treated as `blocked` (fail-closed), so never skip the write.