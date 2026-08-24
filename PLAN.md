# PLAN.md — Bani "commit everything at once" master plan

Written 2026-08-24 by Fable (orchestrator). Source of truth for the next big push.
Ground truth pulled from: repo history, `build-notes.md`, `pipeline/*.md` (local-only),
vault logs 2026-07-28 → 2026-08-21, `Claude/Skills/repos/bani.md`.

## Context

Bani is at **build 42 (v1.2a Projects Core, merged 2026-08-17)**. Working tree clean,
no stashes, no unmerged code — everything written is committed and shipped. "Left to
commit" therefore means **planned-but-unbuilt**, not sitting-in-the-tree.

Two real users: Dumi + one Romanian real-estate-investor client (49-file Excel corpus,
two phones on AltStore). "Useful" = the client can switch off Excel and both users can
trust the liquidity number daily. This plan (a) maps the backlog, (b) records the gap
exercise — what's missing even after the current roadmap ships — and (c) proposes the
phase split for one consolidated push.

## A. Committed and shipped (build 42)

Voice logging RO/EN (Whisper on-device) · manual entry · deterministic categorizer +
learning loop (DecisionRecord → TrustEngine) · custom categories (8 color slots) ·
BNR FX · Finances analytics/search/charts · full RO i18n · Excel/CSV/PDF/docx/image
import with dedup + undo (top-5 corpus audit bugs fixed) · money directions + People
view · Apple Pay auto-capture (LogPaymentIntent) · share-sheet bank-notification
capture (BaniShare + App Group) · Projects tab: liquidity 30/60/90, ScheduledItem,
reminders (default OFF), project assignment on every entry surface.

## B. Planned but NOT built (the real "left to commit" list)

| # | Item | Where promised | State |
|---|---|---|---|
| B1 | v1.2b loans + rate-splits | build-notes v1.2a; `LiquidityCalculator.loanAdjustment` seam | seams ready, zero code |
| B2 | Report exports (5 shapes from client corpus; Centralizator pivot = highest value) | WS1 "next run", repo skill, client-format-spec §3 | specced only, deferred twice |
| B3 | §4.3 client decisions: category capacity (client needs ≥12, app has 8 color slots), comision disambiguation, cash/loan classification, EUR-row storage, income-model fit | client-format-spec §4.3 | **blocked on D** |
| B4 | Sub-units / houses-split | build-notes v1.2a out-of-scope | later run |
| B5 | Per-row import project assignment | build-notes v1.2a | batch-level only shipped |
| B6 | Person registry (counterparty = free text) | build-notes v1.2a | not built |
| B7 | Voice project-name parsing | build-notes v1.2a | deliberately skipped (NLU risk) |
| B8 | Real-Raiffeisen parser tuning ("revision hatch") | build-notes auto-log B | waiting on a real notification from D |
| B9 | Housekeeping debt: AltStore feed `"version": "1.0"` (breaks update detection), stale build-42 changelog, missing tags v1.0.37–42, local `main` 2 behind origin | 2026-08-17 log (left unfixed by choice) | trivial, unshipped |
| B10 | On-device verification pass: share sheet shows Bani, App-Group rewrite, Whisper end-to-end (perpetually SKIPPED in CI) | build-notes "MUST VERIFY ON DEVICE" | never done |

## C. Gap exercise — what's STILL missing after all of B ships

Assume B1–B10 done. Would the app actually be relied on? No — four holes remain that
no roadmap item covers.

### Tier 1 — existential (data or trust can be lost outright)
- **G1. Backup / export / restore does not exist.** On-device only, no iCloud, no
  backend, sideloaded. Lost phone, deleted app, or AltStore re-sign hiccup =
  years of financial data gone, permanently, for both users. Report exports (B2)
  are NOT backup — they're lossy views. Needs: full-fidelity archive export
  (JSON/zip incl. attachments) via share sheet/Files + import-restore path, so the
  "no backend" law survives intact. **Single biggest gap in the product.**
- **G2. No balance anchoring / reconciliation.** Liquidity = netLoggedPosition +
  scheduled ± loans. Every missed expense silently corrupts the 30/60/90 forecast
  forever — and the whole Projects tab exists to serve that number. Needs: "actual
  balance today is X" anchor entry + drift display + one-tap adjustment transaction.
- **G3. Cross-source duplicate risk.** The same real payment can arrive as Apple Pay
  auto-capture AND a shared bank notification AND a voice log. Auto-log dedup
  exists (DedupCollisionTests) but there is no unified cross-source guarantee.
  Double-counted spend = wrong liquidity = G2 gets worse. Needs a fingerprint
  check across sources at save time with a merge prompt.

### Tier 2 — workflow-completing (client can't leave Excel without these)
- **G4. Recurring scheduled items.** ScheduledItem is single-shot; rent, salary and
  loan rates are monthly. Without recurrence the schedule demands manual re-entry
  every month and will be abandoned. (Natural companion to B1 — loan rates ARE
  recurring items.)
- **G5. B2+B3 actually shipping.** Reports and category capacity are already on the
  list — flagged here because they are the two items the client's Excel workflow
  literally cannot be replaced without.

### Tier 3 — trust and durability
- **G6. Spec corpus is local-only.** `pipeline/*.md` (spec, client-format-spec,
  import-bug-audit, review-verdict…) is git-ignored — the app's entire product
  memory exists on one Windows machine. Commit to the repo (private) or file into
  the vault. One-line .gitignore decision.
- **G7. B9 update-detection bug is quietly existential for the client**: with
  `"version"` stuck at "1.0", their AltStore may never offer updates — they could
  be stranded on a build with known import bugs and nobody would notice.

### Deliberately NOT gaps (respect existing scope law)
Widgets, iPad, iCloud sync, open banking, semantic search, multi-bank parser
farm — out of scope per spec; the seams (rawTranscript, DocumentUnderstanding)
already reserve their future.

## D. Proposed phase split for the consolidated push

Order = risk-killing first. Each phase is one commit, one worker, one executable gate
(fable-orchestrator law). ≤3 concurrent workers only where files are disjoint.

| Ph | Scope | Worker | Gate |
|---|---|---|---|
| 0 | B9 + G6/G7 hygiene: feed version format, changelog line in ci.yml, un-ignore pipeline/, sync local main | sonnet-coder | source.json validates; AltStore version parses as 1.0.N |
| 1 | G1 backup/export/restore (archive + share sheet + restore wizard) | sonnet-coder | round-trip test: export → wipe store → restore → row-identical |
| 2 | G4 recurrence on ScheduledItem (additive optional fields only — migration law) | sonnet-coder | unit tests: next-occurrence generation incl. overdue rollover |
| 3 | B1 v1.2b loans + rate-splits, on the loanAdjustment + ScheduledItem seams | **opus-solver** (financial logic) | LiquidityCalculator tests with loan schedules; migration test |
| 4 | G2 balance anchor + reconciliation | **opus-solver** (design-sensitive) | anchor→drift→adjustment integration test |
| 5 | B3 decisions implemented (category capacity, comision, EUR, income) | sonnet-coder | **blocked until D answers §4.3** |
| 6 | B2 report exports — Centralizator pivot first, then monthly matrix, running balance, P&L, budget-variance | sonnet-coder | golden-file export tests vs client corpus fixtures |
| 7 | G3 cross-source dedup | sonnet-coder | collision-matrix tests (voice×autolog×share×import) |
| — | B10 device checklist: D verifies share sheet, App Group, Whisper e2e, real Raiffeisen fixture (B8) | **D on device** | screenshots back to repo |

Every phase: verifier run (build + tests + screenshots 375/1440 where visual) before
its commit; max 2 fix cycles then stop and surface.

## E. Decisions D must make before phases 5–6 unblock

1. §4.3 five judgment calls (client-format-spec) — esp. **custom-category capacity**
   (recommend: lift to ≥16 slots by cycling the 8 colors with distinct symbols).
2. Backup destination for G1 (recommend: zip archive via share sheet → Files/iCloud
   Drive as a *file*, keeping the no-backend law).
3. Scope cut: ship Phases 0–4 first (all unblocked today) or wait and truly commit
   everything at once including 5–7?
4. B8: supply one real Raiffeisen notification (screenshot + text) for parser tuning.

## F. Explicitly deferred beyond this push

B4 houses-split · B5 per-row assignment · B6 person registry · B7 voice project
parsing · v2 items (semantic search, open banking). Logged, moved on.
