---
name: research-roundtable
description: Run a cost-controlled, traceable Codex-led roundtable for research plans, procedures, and executed experiments. Supports BudgetLean, Lean, Standard, Full/Diff scope, preflight blocking, exact review and isolation caches, focused packets, JSONL findings, issue ledgers, manifests, and authorization gates. Codex remains sole executor and adjudicator; Kimi and DeepSeek are read-only reviewers.
---

# Research Roundtable

Keep Codex as sole executor, adjudicator, and potential editor. Treat Kimi and
DeepSeek as read-only reviewers. Never let them inspect project files, run
project commands, or apply changes.

## Select one workflow

- `Plan`: review research questions, novelty, falsifiability, baselines,
  leakage, ablations, statistics, validation, constraints, and publication
  viability. Do not execute or edit.
- `Procedure`: decide whether an experiment procedure is directly executable.
  Review ordering, frozen parameters, records, reproducibility, safety,
  leakage, stop conditions, and fallback paths. Do not execute or edit.
- `Experiment`: Codex executes and debugs an authorized experiment, then sends
  only its compact execution record and evidence to reviewers.

Use the matching packet template in `references/`. Add concise source anchors
such as `[S1]`, `[S2]`; keep each factual claim, constraint, metric, or decision
traceable. Reviewers may retain an unanchored finding, but Codex must give it
less weight until verified against the packet.

## Run the review

1. Build a self-contained packet. Reviewers receive no source paths.
2. For `Plan`, form Codex's opinion privately; do not prime reviewers.
3. For `Experiment`, include Codex's command/decision timeline, summarized
   logs, diagnosis, and proposed changes because those are being audited.
4. Invoke `scripts/Invoke-ResearchRoundtable.ps1`.
5. Check `roundtable-manifest.json` before adjudication.
6. Use only valid entries in each normalized review. Inspect raw output when
   status is `partially_valid` or `invalid`; never promote
   `UNPARSED_REVIEW_ITEM` to `MUST_FIX` without independent verification.
7. If isolation failed, exclude that reviewer. If one reviewer failed, label
   the result `partial`. If both failed, provide Codex self-check only and state
   that multi-reviewer review failed.
8. Adjudicate by evidence and problem type, not voting.
9. Present the decision using `references/decision-template.md`, include the
   manifest path, then stop at the authorization gate.

## Reviewer roles

- Kimi: engineering feasibility, step completeness, hardware constraints,
  reproducibility, debugging path, cost, and execution risk.
- DeepSeek: causal gaps, leakage, statistics, metric mismatch, falsifiability,
  overstated novelty, controls, and publication viability.

Kimi finding a plan executable does not establish scientific validity.
DeepSeek finding a logical flaw does not establish engineering infeasibility.
Classify each finding as `engineering feasibility`, `scientific validity`,
`statistical validity`, `publication viability`, or `execution risk`; state
whether a `MUST_FIX` blocks execution, blocks publication, or only affects
presentation.

## Modes

- `BudgetLean`: cheapest daily check; preflight plus one most relevant reviewer,
  `MUST_FIX` only. Never present it as full roundtable coverage.
- `Lean` (default): every `MUST_FIX`, no optional improvement.
- `Standard`: every `MUST_FIX` plus all material `RECOMMENDED` findings and a
  deeper cross-field, reproducibility, and viability audit.

Never impose a finding-count cap or shorten raw reviewer output.

Use `Standard` as the Final Gate before execution, submission, or publication.
Recheck unresolved `MUST_FIX`, stop conditions, records, reproducibility, and
failure criteria; inspect raw output when normalized evidence is degraded.

## Full and Diff scope

- `Full`: first review, major restructuring, changed objective/design/metrics/
  hardware, or final gate.
- `Diff`: small revisions only. Use
  `references/diff-review-packet-template.md`; include the previous summary,
  unresolved `MUST_FIX`, current diff, intent, and focus questions.

Always label Diff output: `Review scope: Diff - changed content and unresolved
issues only.` If the diff is incomplete or structural change exceeds roughly
30%, return to Full.

## Cost controls

- Run local preflight first. `PRECHECK_BLOCKED` means no reviewer call.
- Cache passed isolation tests for 24 hours using CLI, prompt, permissions,
  sandbox strategy, script version, and user fingerprint.
- Reuse reviews only on exact hash-key matches; never use similarity matching.
- For Plan/Procedure, have Codex create one anchor-preserving deduplicated
  packet. Preserve constraints, hardware, metrics, baselines, labels,
  statistics, leakage controls, failures, and unresolved `MUST_FIX`.
- Lean/BudgetLean may pass focused packets with `-KimiPacketPath` and
  `-DeepSeekPacketPath`; use Full packets for cross-domain questions and
  Standard when focus would omit decisive evidence.
- Read manifest, normalized JSONL, and issue ledger by default. Read raw only
  for invalid/partial/inconsistent output, tool failure, overlong output, user
  request, or Standard verification of a decisive `MUST_FIX`.
- Never retry formatting automatically in Lean/BudgetLean.

## Isolation and traceability

The invocation script:

- runs or safely reuses a fingerprinted isolation smoke test;
- uses a new empty sandbox and deletes it afterward;
- passes DeepSeek text through stdin and keeps the full Kimi packet out of the
  process command line by using a random temporary prompt file;
- saves complete `*.raw.md` and parsed `*.normalized.jsonl` files;
- validates item IDs, severity, anchor/location, evidence, and action;
- maintains `roundtable-issue-ledger.jsonl` so unresolved `MUST_FIX` survives
  Diff rounds and fixed/rejected issues remain traceable;
- records every cache, compression, focused-packet, skipped-call, and raw-read
  decision in `roundtable-manifest.json`.

Do not use a reviewer whose isolation test failed. A raw file is evidence, not
automatically admissible advice.

## Long packets

Never silently truncate. If input exceeds the mode limit, create a compressed
packet that preserves objectives, source anchors, decisive evidence,
constraints, contradictions, and acceptance criteria. Pass both
`-CompressedReviewPacketPath` and `-CompressionStrategy`. The manifest retains
the original and effective hashes.

## Invocation

```powershell
& "<skill-dir>\scripts\Invoke-ResearchRoundtable.ps1" `
  -ReviewType Procedure `
  -ReviewPacketPath ".roundtable\procedure-packet.md" `
  -Mode Lean `
  -ReviewScope Full
```

Use `-ReviewType Plan`, `Procedure`, or `Experiment`. Before first Kimi use:

```powershell
& "<skill-dir>\scripts\Initialize-RoundtableKimi.ps1"
```

Run local diagnostics without model calls:

```powershell
& "<skill-dir>\scripts\Invoke-ResearchRoundtable.ps1" -SelfTest
```

## Authorization gate

Review and execution requests do not authorize post-review changes. Always
produce a concrete `Pending Change Set` with exact paths, modifications,
verification commands, risks, and status `pending`. Do not modify a plan,
procedure, code, configuration, template, or parameter until the user explicitly
approves that set.

If the user explicitly requests direct modification of an important research
file, preserve a reversible backup before editing and report its path. Approval
covers only the presented scope; ask again for materially different work.
