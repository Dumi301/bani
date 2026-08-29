# HANDOFF — Bani

Updated: 2026-08-29 (v2.2 fix-all pass; supersedes the stale 08-24 handoff that
still listed P1 backup as parked — backup shipped in 2.1.64 on 08-25).

## Shipped state
- **main @ 04d4540 — "Bani 2.2"** (squash of PR #4, branch `v2.2-bugfix`):
  fixes ALL 12 findings of the 2026-08-29 full diagnostic (2 HIGH, 5 MED,
  5 LOW) + D-approved launch-tab flip.
- **Release v2.2.70 LIVE on AltStore — verified 2026-08-30**: Pages feed
  `version` 2.2.70 (HTTP 200) == release tag v2.2.70 == IPA
  `CFBundleShortVersionString` 2.2.70 / `CFBundleVersion` 70; Bani.ipa
  downloads HTTP 200, 3,155,226 bytes (matches the release asset exactly).
- Previous: 2.1.64 live on AltStore since 08-25 (full backup/restore).

## The v2.2 pass (one commit per phase on the PR)
| Phase | Fixes | Commit |
|---|---|---|
| A banking | H1 6h foreground sync throttle (GoCardless ~4/day quota), last-sync + error in settings, manual bypass; L4 AmountLexer-hardened bank amount parsing | c1c4ddd |
| B backup | H2 atomic restore: erase+insert in ONE save, blobs staged & swapped post-commit — failed restore leaves data intact | 6cab58f |
| C loans | M1 markDone/undoDone idempotence; M3 schedule-row stamps (out-of-order/edit-proof exact splits); M4 preview from stamps; M5 non-amortizing terms rejected + isTruncated flag | 182d34c |
| D smalls | M2 dedup docs match code; L1 DateFieldParser ternary; L2 merge repoints refs; L3 anchor-only residual recorded+shown; L5 exact Decimal FX everywhere displayed; gate timestamp bit-exact (refDate) | 6fb9b3e + 2beed1a |
| E launch | Launch tab Log→Raport (D sign-off 08-29), UI suites self-navigate; PeopleAnalytics Decimal FX; comision confirmed as-shipped | 8ac9569 (2nd PC session) |

Fix cycles: 2 (gate ULP date round-trip → refDate persistence; test arg order).
CI evidence: run 33264007766 full green (gate, screenshots, ipa, whisper).

## Open items
- **D on-device checklist** (needs both phones on 2.2): share sheet shows Bani ·
  Whisper e2e · real Raiffeisen notification text into the parser hatch ·
  GoCardless real bank link · cross-phone backup/restore.
- `seenKeys` full-store fetch in `BankSyncService.sync` — correct but
  unbounded; a `#Predicate` narrowing is flagged inline for a toolchain session.
- Loan-aware undo for booked loan payments (generic undoDone deletes only the
  interest tx) — flagged in `ScheduledItemStore.undoDone` comment.
- `syncPendingPayment` regeneration after out-of-order booking + subsequent
  loan edit (UI can't reach it today) — noted in phase C report.
- `pipeline/` still git-ignored (specs/prompts local-only) — standing PLAN item.

## Known context
- Two sessions worked this pass on 08-29 (this one + a second PC Fable session
  that shipped phase E during a rate-limit gap). Coordination notes in
  `<vault>/pc/pc-note-bani-*.md`.
- Frozen-seam discipline: additive optional-backed columns only
  (`ScheduledItem.scheduleIndexRaw`, `BalanceAnchor.unresolvedResidualRaw` are
  the newest examples). Backup DTOs carry both.
