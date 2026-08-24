# HANDOFF — Bani V2 teardown push (2026-08-24)

Status at write time: all feature phases committed to `v2-teardown` (PR #3);
final CI + seal commits pending. Full evidence + ⚑ flags:
`pipeline/prompts-v2/REVIEW-PACKET.md`. Destination doc: `VISION.md` ·
lanes: `ROADMAP.md` · execution plan: `PLAN.md`.

## What shipped in this push (one commit per phase)

| Commit | Phase | One-liner |
|---|---|---|
| cb948c5 → main | P0 | AltStore update detection fixed + dynamic release notes (v1.0.43 live, verified in prod) |
| 44c3d22 | P2 | Recurring ScheduledItems (additive, DST/month-end-safe, series) |
| 6ab5b3a | P5 | §4.3 corpus decisions — found already shipped in v1.1; test gates added |
| f618285 | P3 | Loans: exact-Decimal amortization, bank interest→project expense, investor cost-of-capital, markDone delegation |
| b25b043 | P6 | Person registry + owed-to-me receivables + project interview |
| 8097b6e | P4 | Balance anchoring/reconciliation (neutral-excluded drift, same-currency law) |
| fc041da | P7 | **Raport Hub teardown** — tabs Raport·Log·Projects·Settings, Finances demoted, xlsx relay (Raport Custom + Centralizator) |
| adfe5a6 | P8 | Cross-source dedup (flag-never-drop, merge review) + fix cycle adding bank origin |
| 9400843 | P10 | Interpretation layer (FM annotates-never-gates, fallback byte-identical) |
| 29cec2c | P9 | Open banking (GoCardless, Keychain-only secrets, no backend) |
| dd0a5cc | P11 | Smart NL search on the hub (closed-vocabulary date compiler, verified filters) |
| (seal) | — | 2.0.N versioning, foreground bank sync, screenshot seed |

## NOT shipped
- **P1 backup/export/restore — PARKED.** Full approved design at
  `pipeline/prompts-v2/p1-design-notes.md`; blocked by the hook bug (below).
  MUST be built before 2.0 is declared data-safe; it will cover the FINAL
  schema (Loan, Person, BalanceAnchor, BankLink included) when dispatched.
- LLM annotator async wiring inside live cards (deterministic path wired;
  FM path seam-tested, adoption = on-device follow-up).
- Post-V2 parking lot: houses-split, per-row import assignment, voice project
  parsing, desktop peer, what-if scenarios.

## Open items for D (ordered)
1. **Fix `.claude/fable_code_guard.mjs`** (task #14; diagnosis + suggested
   one-liner in the task) → then say the word and P1 dispatches.
2. **"merge it"** on PR #3 once CI is green and you've eyeballed the hub
   screenshots — the squash subject becomes the client-visible 2.0 release
   note; write it accordingly.
3. Review-packet ⚑ flags: launch-tab (Log vs Raport), comision mechanism
   (family-of-origin), P5 stale-docs note.
4. **Device checklist** (CI cannot prove): share sheet shows Bani · App Group
   survives AltStore re-sign · Whisper end-to-end · real Raiffeisen
   notification round-trip (then parser tuning) · GoCardless real bank link
   (enter secret pair in Settings → Bank) · after P1 ships: backup
   export/restore across both phones.
5. `pipeline/` specs are still git-ignored (classifier refused workers on
   .gitignore) — un-ignore by hand when convenient; everything referenced
   here lives in the working copy.

## Verification trail
- Run 32723483525 (main): 6/6 green, release v1.0.43, feed verified in prod.
- Run 32735870483 (8097b6e): green — loans/people/reconciliation suites.
- Final run at the seal head: pending at write time — see PR #3 checks and
  REVIEW-PACKET for the verifier's job-level evidence.
