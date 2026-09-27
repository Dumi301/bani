# HANDOFF — Bani

Updated: 2026-09-27 (v0.3 push — "Bancă / numerar / avans"; supersedes the
08-29 v2.2 handoff).

## Version line reset (D, 2026-09-27)
The app is "not functional yet" for the client → new integer line **0.3**
(`BANI_MARKETING_VERSION` in `ci.yml`; CI stamps `0.3.<run>`). Last live
release before the reset: **2.3.72** (AltStore, 2026-09-02).
**AltStore only offers an update when the version compares HIGHER, so 0.3.N
will NOT appear as an update on a phone running 2.3.72.** Install path for both
phones: Settings → Backup → export archive · delete Bani · install 0.3.N from the
AltStore source · Settings → Backup → restore. Backup DTOs carry every 0.3 column
(optional → older archives restore too).

## Shipped in this push (branch `v0.3`, PR #7, one commit per phase)
| Ph | What | Gate |
|---|---|---|
| 0 | `BankSyncGate.runs` — last 20 sync outcomes (UserDefaults JSON) + "Istoric sincronizări" list in Settings → Bank | `BankSyncThrottleTests` run-history tests |
| 1 | `Transaction.paymentMethodRaw` (bank/cash, optional) + `PaymentMethodInference` at init (autoLogged→bank · numerar/cash→cash · card/pos/transfer→bank · imported→bank · else nil=bank); Bancă/Numerar picker on voice card, manual entry, edit sheet | `PaymentMethodInferenceTests` |
| 2 | `BalanceAnchor.potRaw` (nil=bank, "cash"); pot-aware `ReconciliationStore/Sheet`; Raport "Unde sunt banii" card Bancă · Numerar · Total, cash tile = "Adaugă numerar" until anchored | `PotBalanceTests` |
| 3 | Proxy whitelists `GET /accounts/{id}/balances` (deployed 2026-09-27, health 200, route 401-gated); `EnableBankingClient.balances`; `BankLink.balancesJSON`; sync stores the CLBD-first balance per account; `liveBalanceRON` (≤6h fresh) IS the bank pot when present | proxy `node --test` 18/18 · `BankSyncTests` balances tests · `EnableBankingClientTests` |
| 4 | Raport "Avans disponibil la <horizon>" = max(0, freeLiquidity − reserve), reserve default = horizon outgoings, stepper (`@AppStorage raportReserve`); project rows: Încasat · Net · first → last date | `PlanningCardTests` |
| 5 | version 0.3, this file, ROADMAP, LATEST | CI green on main; source.json == IPA version |

## Open items
- **D on-device checklist** (unchanged since 08-29, never run): share sheet shows
  Bani · Whisper e2e · real Raiffeisen notification → parser · real bank link (now
  Enable Banking) · cross-phone backup/restore. Plus new: one manual "Sync now"
  showing an account balance under Settings → Bank; anchor cash once on Raport.
- **Client conversation** — 6 questions in
  `<vault>/Claude/AI outputs/2026-08-29 bani-client-verdict-pack.md`; gates App Store.
- Sidelined by D (2026-09-27): project milestones (precontract → contract → sale),
  typical-duration estimate, budget vs Depășire. `ponytail:` payment-method
  learning loop (merchant → method memory) — add when the client corrects the
  same vendor twice.
- Older debts: `seenKeys` unbounded fetch in `BankSyncService.sync` · loan-aware
  undo · `syncPendingPayment` regen · `pipeline/` still git-ignored.

## Known context
- Frozen-seam discipline: additive optional columns only. 0.3 added
  `Transaction.paymentMethodRaw`, `BalanceAnchor.potRaw`, `BankLink.balancesJSON`.
- Unknown payment method reads as bank everywhere (`Transaction.pot`), ONE place.
- Reserve semantics: freeLiquidity already nets the horizon's expected in/out; the
  reserve is an extra cushion on top, D-adjustable.
