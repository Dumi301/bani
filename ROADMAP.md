# Bani — Roadmap (V2 push edition, 2026-08-24)

Three lanes: shipped · in the V2 push · after V2. Destination: [VISION.md](VISION.md).
Execution detail for the push: PLAN.md (orchestrator) + pipeline/prompts-v2/.

```
SHIPPED   ████████████████████  build 42 (v1.2a, 2026-08-17)
V2 PUSH   ░░░░░░░░░░░░░░░░░░░░  12 phases, 7 waves — in flight
AFTER V2  parking lot + desktop peer
```

## ✅ Shipped (build 42)

| Date | Builds | Shipped |
|---|---|---|
| Jul 29 | v1.0.7–18 | v1 in one day: voice RO/EN, confirmation card, categorizer, Finances, analytics, feedback ledger |
| Jul 30 | v1.0.20 | Interactive charts · RO i18n · custom categories · Appetize preview |
| Jul 31 | v1.0.25–26 | Cold Metal UI · transcription constraint + large amounts |
| Aug 2 | v1.0.29–31 | Excel/CSV import · 49-file client corpus study · directions · People · one-tap all-format import |
| Aug 5 | v1.0.32 | Migration-law fix · phantom-millions fix |
| Aug 10 | v1.0.34–36 | Apple Pay auto-capture · share-sheet bank-notification capture |
| Aug 17 | build 42 | v1.2a Projects Core: Projects tab, liquidity 30/60/90, scheduled money, reminders, assignment everywhere |

## 🚀 The V2 push (branch `v2-teardown` → Bani 2.0)

| Wave | Phase | What | Why |
|---|---|---|---|
| 1 | P0 | AltStore version-field + changelog fix → main NOW | Client can't even detect updates until this ships |
| 1 | P1 | Backup / export / restore | The 30-year data contract; today one lost phone = everything gone |
| 1 | P2 | Recurring ScheduledItems | Rent/rates/salary are monthly; one-shot schedule dies of re-entry |
| 2 | P3 | Loans (Board 2 full spec): amortization split, bank interest → project expense, investor interest → cost-of-capital off project P&L | Leveraged client; liquidity without loans is fiction |
| 2 | P5 | §4.3 corpus decisions: capacity ≥16, comision split, EUR original, income via direction | Client's taxonomy physically didn't fit |
| 3 | P4 | Balance anchoring / reconciliation | A forecast you can't anchor to reality drifts silently forever |
| 3 | P6 | Person registry + receivables ("who owes ME") + new-project interview | Raport Custom line items need them |
| 4 | P7 | **Raport Hub teardown** — tabs become Raport · Log · Projects · Settings; Board 2 as a living screen; Finances becomes drill-downs; one-way xlsx relay | The report stops being output and becomes the app's face |
| 5 | P8 | Cross-source dedup + merge prompt | Same payment arrives 3 ways; double-count = wrong liquidity |
| 5 | P10 | LLM interpretation layer (Foundation Models on the DocumentUnderstanding seam; annotates, never gates) | The vision's processing unit — self-learning via TrustEngine |
| 6 | P9 | Open banking (GoCardless; secrets in Keychain, no backend) | Automated input, the vision's missing channel |
| 6 | P11 | Smart NL search ("electricianul de la Crângași, primăvara trecută") | The vision's search engine, on stored rawTranscript |
| 7 | — | Seal: full sweep, migration ladder from v1.0.36, 2.0.N version, review packet, HANDOFF, PR | One merge, one release, both phones |

Decisions locked 2026-08-24: investor interest = cost-of-capital line off project
P&L · relay = one-way xlsx · hub replaces Finances · §4.3 per Fable's
recommendations, flagged for D's end review.

## 🔭 After V2
Houses-split/sub-units · per-row import project assignment · voice project-name
parsing · desktop beyond xlsx (viewer; two-way explicitly rejected for now) ·
what-if liquidity scenarios · additional bank sources beyond GoCardless.

## Device checklist (D, after merge — CI cannot prove these)
Share sheet shows Bani · App-Group container intact after AltStore re-sign ·
Whisper end-to-end on device · real Raiffeisen notification round-trip (then
parser tuning) · real GoCardless bank link · restore-from-backup on second phone.
