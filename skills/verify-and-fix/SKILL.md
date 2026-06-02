---
name: verify-and-fix
description: Verify the current plan phase's test-plan.md, fix genuine failures with a bounded warm loop, and defer human-only checks. Use when invoked via the /verify-and-fix slash command (typically by the headless implementation loop) to drive a phase's test plan to an all-pass-or-human-only state, or block.
disable-model-invocation: true
---

# Verify and Fix

Own one contract: make the current phase's `test-plan.md` reach an **all-pass-or-human-only** state, or block. When this skill reports success, every test case is either verified-passing (checked off) or genuinely human-only (left unchecked) — no real failure survives unannounced.

**Expected input**: `<path-to-plan>` (e.g., `plan.md`), with an optional `--status <path>` flag that activates **Loop Mode** (see the section at the end). The plan path is the first positional argument; the status-file path is the value following `--status`.

If the plan-path argument is missing, ask for it before proceeding.

## 1. Locate the phase and its test plan

- Read the plan file completely.
- Find the phase whose heading ends with `🔄` (in-progress) — this is the phase under verification.
  - If no heading ends with `🔄`, there is nothing to verify: stop and report (Loop Mode: block).
- Read that phase's section fully, then read `test-plan.md` in the project root.
  - If `test-plan.md` is missing, the prior implement step never produced one: stop and report (Loop Mode: block).

## 2. Classify every case — the trichotomy

Fan out **one subagent per unchecked test case** to keep this coordinator's context lean. Each subagent verifies its single case by actually exercising it — running commands, inspecting output and files — never by guessing, and returns exactly one verdict with evidence:

- **PASS** — programmatically verifiable and currently working. → Check it off (`- [x]`) in `test-plan.md`.
- **FAIL** — programmatically verifiable and genuinely broken. → Feeds the fix loop (step 3). Leave unchecked for now.
- **NEEDS-HUMAN** — verifying it genuinely requires human perception or judgement (visual fidelity, UX feel, browser-only flows, unreachable external systems). → Leave unchecked, **never** fix it, **never** let it block.

Classification turns on *verifiability*, not on the verdict: if a case can be exercised programmatically, do so and record PASS or FAIL — reserve NEEDS-HUMAN for cases a human alone can judge, not merely inconvenient ones. Treat already-checked items as PASS. Record each verdict and its evidence — you reuse this memory in step 3.

## 3. Bounded warm fix loop (N = 10)

If any FAIL survives, fix it here, in this same call, so you keep warm memory of every attempt and never repeat a dead-end fix.

Repeat, counting attempts **per phase** (shared across all surviving FAILs):

1. Diagnose a surviving FAIL using the subagent's evidence plus your memory of prior attempts.
2. Apply a fix to the code.
3. Re-verify that case (fan out a fresh subagent). If it now PASSes, check it off and drop it from the FAIL set.

- The cap is **10 attempts total per phase**; one attempt is a single diagnose → fix → re-verify cycle.
- Never repeat a fix you have already tried and seen fail — keeping the loop warm is what makes that possible.
- When the FAIL set empties, you are done (success). After **10** unsuccessful attempts with a FAIL still surviving, stop and block.

## 4. Outcome

- **Success** — no FAIL survives: every case is either a checked-off PASS or a left-unchecked NEEDS-HUMAN. Those unchecked NEEDS-HUMAN items are left deliberately for `close-phase` to archive and `final-verification` to aggregate later.
- **Blocked** — a FAIL survives the 10-attempt budget: name the surviving case(s) and why the attempts failed.

Do **not** mark the phase `✅` and do **not** commit — that is `close-phase`'s job.

## 5. Report

Summarize what passed (and what you fixed), what is left for human verification, and any case still failing. In Loop Mode this is replaced by the status-file write below.

## Loop Mode

Loop Mode is an **additive, opt-in** override for unattended (headless) runs. It activates **only** when this skill is invoked with a `--status <path>` argument, e.g.:

```
/verify-and-fix plan.md --status .git/loopityloop/status.json
```

When the flag is **absent**, ignore this entire section — the steps above behave exactly as written, and you may surface results to the user and ask for guidance on a genuinely ambiguous case. Loop Mode changes nothing about hand-invocation.

When `--status <path>` **is** present, apply these overrides on top of the steps above:

- **No interactive prompts, ever.** There is no human watching. Never ask the user anything and never block waiting on input — classify every case yourself per the step-2 criteria, and either finish or write a `blocked` status below.
- **Final action — write the status file.** As the very last thing you do, write the status file at the `--status` path. Create its parent directory first if needed. Write it **last** and write it **once**:
  - On **success** — no FAIL survives (every case is PASS-and-checked or NEEDS-HUMAN-and-unchecked) — write exactly:

    ```json
    { "status": "ok" }
    ```

  - On a **block** — a FAIL survives the 10-attempt budget, or there is no `🔄` phase / no `test-plan.md` to act on — write:

    ```json
    { "status": "blocked", "reason": "<one-line human-readable explanation>" }
    ```

  This file is the orchestrator's sole signal. A **missing** file is treated as `blocked` (fail-closed), so never skip the write.
