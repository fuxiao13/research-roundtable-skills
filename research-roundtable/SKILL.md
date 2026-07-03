---
name: research-roundtable
description: Run a controlled research or technical review roundtable in which Codex is the sole executor and file editor, while Kimi Code and a DeepSeek model accessed through Claude Code act as read-only reviewers. Use when the user asks for a roundtable review, multi-model review, Kimi and DeepSeek review, independent review of a research plan, experiment, program output, metrics, logs, manuscript plan, or proposed code change, especially when only Codex may apply accepted changes.
---

# Research Roundtable

Keep Codex as the sole executor and editor. Give reviewers only a compact text
packet, never source paths. Kimi checks method closure and feasibility; DeepSeek
stress-tests evidence, statistics, and hidden assumptions.

## Workflow

1. Inspect or run the user-scoped project.
2. Write a short packet: objective, expected/observed result, decisive metrics,
   minimal log excerpts, relevant change summary, and open risks. Exclude
   information already obvious from these fields.
3. Write Codex's first-pass assessment.
4. Run `scripts/Invoke-ResearchRoundtable.ps1`; default to `-Mode Lean`.
5. Read only the two review files. Merge duplicates before adjudication.
6. Record only material decisions:
   `ID | source | accept/partial/reject | short reason | target | verification`.
7. Apply accepted changes as Codex and verify with before/after evidence.

## Modes

- `Lean` (default): lightweight gate. Report only issues that must be fixed
  because they invalidate the goal, evidence, feasibility, safety, or claimed
  conclusion. Return `NO_MATERIAL_CHANGE` when no must-fix issue exists.
- `Standard`: normal review. Report every must-fix issue plus recommended
  improvements that materially strengthen rigor, clarity, efficiency, or
  reproducibility. Label the two levels explicitly.

Classify by decision impact, not by finding count. Never omit a must-fix issue
to meet a length target.

## Run

```powershell
& "<skill-dir>\scripts\Invoke-ResearchRoundtable.ps1" `
  -ReviewPacketPath ".roundtable\review-packet.md" `
  -CodexAdvicePath ".roundtable\codex-first-pass.md" `
  -UserIdeasPath ".roundtable\user-ideas.md" `
  -Mode Lean
```

Omit user ideas when unavailable. Reviews go to
`.roundtable/reviews/<timestamp>/`; the terminal prints only paths. Before the
first Kimi review, run:

```powershell
& "<skill-dir>\scripts\Initialize-RoundtableKimi.ps1"
```

## Guardrails

- Never send secrets, raw private data, weights, full logs, or unnecessary paths.
- Never enable reviewer tools or let feedback trigger automatic edits.
- Do not load sessions, caches, stderr, or model reasoning into Codex context.
- Accept `NO_MATERIAL_CHANGE` as a valid review; do not ask for filler.
- If one reviewer fails, disclose it and use the other or stop based on risk.
