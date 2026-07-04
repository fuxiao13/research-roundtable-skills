---
name: research-roundtable
description: Run a Codex-led research review loop in which Codex is the sole executor and editor while Kimi Code and DeepSeek through Claude Code independently review Codex's proposal advice or experiment diagnosis. Use when the user gives Codex a research plan for revision, asks Codex to run programs or experiments against a plan, wants Kimi and DeepSeek to recheck Codex's conclusions, or wants Codex to adjudicate multi-model feedback before applying changes.
---

# Research Roundtable

Keep Codex as the only executor, adjudicator, and file editor. Give Kimi and
DeepSeek only a compact text packet; never give them source paths or edit tools.

## Route the task

Choose exactly one workflow:

- `Plan`: the user provides a research plan or idea and wants revision advice.
- `Experiment`: Codex runs a program or experiment against a research plan and
  wants the outputs and diagnosis independently rechecked.

## Plan workflow

1. Read the original plan and the user's intent.
2. Write Codex's independent suggestions first. Assign stable IDs: `[CX1]`,
   `[CX2]`, and so on. Do not modify the plan yet unless the user explicitly
   asked for immediate editing. Keep each item to one problem, one reason, and
   one proposed action.
3. Build a compact packet with the original objective, essential plan content,
   constraints, and uncertainties. If the plan is long, include its structure
   and only the passages needed to evaluate `[CX#]`; do not resend the full plan.
   Pass Codex suggestions separately.
4. Invoke the script with `-ReviewType Plan`.
5. Have reviewers verify each Codex suggestion and identify high-value
   omissions. They must reference `[CX#]` or label a new issue `NEW`.
6. Merge duplicates, adjudicate, record reasons, then revise the plan as Codex.

Use `references/plan-review-packet-template.md`.

## Experiment workflow

1. Extract the objective, acceptance criteria, required command, and constraints
   from the research plan.
2. Run the program as Codex. Preserve the exact command, exit state, decisive
   metrics, only the shortest diagnostic error excerpts, and relevant change
   summary. Never send full stdout, stderr, traces, or repeated epochs.
3. Write Codex's independent diagnosis and next-step proposals with IDs
   `[CX1]`, `[CX2]`, and so on.
4. Build a compact evidence packet and pass the diagnosis separately.
5. Invoke the script with `-ReviewType Experiment`.
6. Have reviewers check whether the evidence supports the diagnosis and whether
   every proposed next step is justified.
7. Merge duplicates and adjudicate, but do not edit code or rerun yet.
8. Report the decision table, proposed file-level changes, expected benefit,
   risks, and verification command to the user. Ask whether to execute.
9. Stop and wait for explicit user approval.
10. Only after approval, apply the authorized changes as Codex, rerun the
    command, and compare before/after evidence. If the user rejects or narrows
    the changes, follow that decision.

Use `references/experiment-review-packet-template.md`. User approval authorizes
only the presented change set and verification run; obtain approval again for
any materially different follow-up change.

## Review modes

- `Lean` (default): report only `MUST_FIX`; return
  `NO_MATERIAL_CHANGE` if none exists.
- `Standard`: report `MUST_FIX` and `RECOMMENDED`, clearly separated.

Classify by impact, not count. Never omit a must-fix issue for brevity.

## Token economy

- Default to `Lean`; use `Standard` only when the user requests normal review
  or recommended improvements are decision-relevant.
- Send each fact once: shared evidence belongs in the packet; Codex conclusions
  belong in the separate `[CX#]` file.
- Reviewers report only disagreements, corrections, and omissions. Pure
  agreement without added value is omitted.
- Codex reads only final review files, merges duplicates, and summarizes each
  accepted action once. Do not paste both reviews verbatim into the user reply.
- Preserve every `MUST_FIX` finding. Save tokens by removing repetition, not
  by suppressing material criticism.

## Invoke reviewers

```powershell
& "<skill-dir>\scripts\Invoke-ResearchRoundtable.ps1" `
  -ReviewType Plan `
  -ReviewPacketPath ".roundtable\review-packet.md" `
  -CodexAdvicePath ".roundtable\codex-first-pass.md" `
  -UserIdeasPath ".roundtable\user-ideas.md" `
  -Mode Lean
```

Use `-ReviewType Experiment` for experiments. User ideas are optional. Reviews
go to `.roundtable/reviews/<timestamp>/`; the terminal prints only their paths.

Before the first Kimi review:

```powershell
& "<skill-dir>\scripts\Initialize-RoundtableKimi.ps1"
```

## Adjudicate

Use `references/decision-template.md`. Never accept feedback merely because two
reviewers agree. Check it against the plan, evidence, cost, and user objective.

For experiment work, end the adjudication turn with:

1. accepted, partially accepted, rejected, and deferred findings;
2. exact files or components proposed for modification;
3. expected benefit and regression risk;
4. proposed verification command and success criterion;
5. a direct request for user authorization.

Do not treat the user's original request to review or run an experiment as
authorization for post-review code changes.

## Guardrails

- Never send secrets, raw private data, weights, full logs, or unnecessary paths.
- Never load reviewer sessions, caches, stderr, or model reasoning into Codex.
- Never let reviewer feedback apply changes automatically.
- Never modify code, configuration, or experiment parameters after adjudication
  until the user explicitly approves the presented change set.
- Disclose a failed reviewer instead of inventing its feedback.
