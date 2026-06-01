---
name: final-verification
description: Aggregate every deferred human-only check from a completed plan's archived test plans into one consolidated human-verification.md checklist — grouped by phase, deduplicated, and annotated with how to verify each. Use when invoked via the /final-verification slash command (typically by the headless implementation loop on its success path, after every phase is ✅) to produce the single batch of manual checks to run before opening a PR.
disable-model-invocation: true
---

# Final Verification

Runs **only on the success path** — every phase in the plan is `✅`. Its one job: gather all the human-only verification checks that were deferred during the loop into a single, readable checklist, so the human can verify everything in one batch right before opening a PR.

This skill is **report-only**. It produces (overwriting) `human-verification.md` and prints a summary. It **never** edits the plan, checks anything off, commits, or pushes. It **never** prompts for input — it runs fully unattended.

**Expected input**: `<path-to-plan>` (e.g., `plan.md`) as the first positional argument. If it is missing, default to `plan.md` in the project root.

## 1. Confirm the success precondition

- Read the plan file completely.
- Confirm **every** phase heading ends with `✅`. If any phase is still `⏳` or `🔄`, the loop did not actually finish — stop, report that final verification was invoked prematurely, and do **not** write `human-verification.md`.

## 2. Gather the deferred human-only checks

- Find every archived `test-plan-phase-<N>.md` file in the project root.
- Read each one's checklist lines. By construction the surviving items are the human-only (NEEDS-HUMAN) checks: `close-phase` archives a phase's `test-plan.md` only after `verify-and-fix` has resolved every real failure, so anything left unchecked is a check only a human can perform.
- Collect the **unchecked** items (`- [ ]`); skip any already checked off (`- [x]`).
- Keep each item's phase number `<N>` with it — you group by it next.

## 3. Consolidate

Produce the checklist with three transformations:

- **Group by phase** — one section per phase, in ascending phase order, headed by the phase number and its title (read the titles from `plan.md`).
- **Deduplicate** — collapse items that verify the same thing into a single entry; near-duplicates phrased differently still count as duplicates. If a merged item spans phases, note which.
- **Annotate** — give each item a one-line *how to verify* hint so the human isn't re-deriving intent from a terse line (e.g. _"open the cart, change quantity; the subtotal should update without a reload"_).

## 4. Write `human-verification.md`

Write it (overwriting any prior copy) to the project root, in this shape:

```markdown
# Human verification

_N item(s) to verify before opening the PR._

## Phase 1 — <title>

- [ ] <check> — _how: <one-line hint>_

## Phase 2 — <title>

- [ ] <check> — _how: <one-line hint>_
```

Keep every item an unchecked `- [ ]` box — the human ticks them off while verifying.

## 5. Report

Print a short terminal summary whose headline is the **total item count** (it tells the human how much manual verification remains) plus the path to the file. Example:

```
Final verification: 7 human-only check(s) across 3 phase(s) → human-verification.md
```

This skill writes **no status file**. The loop invokes it non-gating — every phase is already committed by the time it runs, so whether it succeeds or fails never blocks the loop.
