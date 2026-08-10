# Build notes — v1.1 Workstream 1: Excel/CSV history import

Adds a self-contained import module (`Bani/Import/` + `Bani/Views/Settings/Import/`)
that lets the client pick a years-long Excel/CSV expense file, map columns once,
preview, import thousands of rows in the background, and undo the whole batch.
Minimal diff outside the new module; the only refactor is the AmountLexer
extraction; frozen seams stay frozen except the two documented additions.

## CoreXLSX dependency — the one sanctioned new dependency

**Pinned exactly `0.14.2`** (`exactVersion` in `project.yml`). Why this version:
- `0.14.2` (2023-03) is the **latest** CoreXLSX release — no newer tag exists.
- It is the first/only line exposing BOTH `XLSXFile(data:)` (read from the picked
  file's bytes, no temp file) AND `Cell.dateValue` (OLE-serial → `Date`), the two
  APIs the importer needs.
- Transitive deps are old but pure-Swift and build in their own Swift-5 language
  mode (`swift-tools-version:5.1`), so they raise **no strict-concurrency errors**
  in our Swift-6 target: XMLCoder `.upToNextMinor(0.14.0)`, ZIPFoundation
  `.upToNextMinor(0.9.11)`.
- **Exact pin** (not `from:`) because the resolver has no `Package.resolved`
  committed (branch-pinned WhisperKit) — `project.yml` is the CI cache key, and an
  exact pin keeps the xlsx dependency from silently drifting between runs.

CSV is parsed with **Foundation only** (`CSVParser`) — no dependency: quoted
fields with embedded delimiters/newlines/`""` escapes, `,`/`;`/tab auto-detected
from the header line, UTF-8 + UTF-16(LE/BE) BOM, CRLF/LF/CR endings.

`project.yml` changed → **CI cache key changed → one cold-cache resolve/build
cycle is expected** on this run (intended, not a regression). `.gitattributes`
gains `*.xlsx binary` so the bundled test fixture survives the LF-normalization
round-trip byte-for-byte.

## Frozen-seam additions — migration-safety check (both PASS)

Two documented additions to the frozen `Transaction`, mirroring the
`customCategoryID` precedent, proven by `ImportModelMigrationTests`:

1. **`TransactionSource` gains `.imported`.** SwiftData persists this `String`-raw
   `Codable` enum **as its rawValue**, so the addition only widens the set of
   *valid* values — it never rewrites the `"voice"`/`"manual"` strings existing
   rows hold, and those still decode unchanged (`testSourceEnumRawValuesStable`).
2. **`Transaction.importBatchID: UUID?`** — a nullable, additive scalar (NOT a
   relationship), so existing rows migrate to `nil` and are untouched; a container
   declaring only `Transaction.self` still persists it (`SmokeTests` unchanged).
3. **New entity `ImportBatch`** (id, fileName, importedAt, rowCount, skippedCount,
   contextChoice, notes) — a separate additive `@Model`, same lightweight
   migration as `CustomCategory`. Registered in `BaniApp`'s container via the
   controlled orchestrator edit. `testAdditiveFieldsCoexist` proves legacy +
   imported rows + a batch record coexist with no data loss.

## AmountLexer extraction — the one allowed refactor

The separator-disambiguation core moved **verbatim** from
`RuleBasedParser.digitValue` into `AmountLexer.value(forDigitToken:)` (plus
`isPureDigits`, `posix`). `RuleBasedParser` now calls into it — behavior is
byte-for-byte identical, so the `ParserTests` table stays green (regression), and
the parser + the import now share ONE decimal/thousands disambiguator.
`AmountLexer.parseCell` adds the import-only front end: strips a currency
word/symbol and internal (space-grouped) separators, and reads negativity from a
leading minus / Unicode-minus / accounting parentheses, returning a non-negative
magnitude + a sign flag. Touched files: `RuleBasedParser.swift` (delegation only),
new `AmountLexer.swift`; nothing else.

## Header auto-guess table (RO + EN, diacritic-folded via `Categorizer.normalize`)

Guesses pre-select but never lock — the user overrides every one. Fields assigned
in priority order; a column is never double-claimed.

| Bani field | Matched header keywords (normalized) |
|---|---|
| date (required) | data, date, ziua, perioada |
| amount (required) | suma, valoare, amount, total, value, pret, cost, cheltuiala, debit |
| description (required) | descriere, detalii, description, denumire, explicatie, comentariu, comment, note, detail, beneficiar, furnizor |
| category | categorie, category, categ |
| currency | moneda, valuta, currency, deviza, curr |
| context | context, type |

Category-column *values* match preset display names (RO + EN) + enum raw values +
custom category names, all folded (`CategoryMatcher`): e.g. Alimente/Groceries →
groceries, Combustibil/Benzina/Fuel → fuel, Utilitati → utilities. Unmatched
values go to a per-value screen (map / create custom / leave uncategorized).

Date format is detected from samples: ISO (`yyyy-MM-dd`), day-first dot
(`dd.MM.yyyy`, Romanian reality), or slash — with a **day/month ambiguity flag**:
if every slash date has both leading numbers ≤ 12 the order is unknowable, so the
wizard forces an explicit choice **defaulting to day-first**; a component > 12
resolves it automatically. `.xlsx` date-formatted numeric cells resolve to real
serial dates via CoreXLSX styles. Rows lacking a time land at **12:00**.

## Dedup guard — batch-level, advisory (D)

Per-row silent dedup is deliberately NOT done (legit duplicate expenses exist).
Instead, each row is fingerprinted `day + amount + normalized-description`; before
writing, the incoming fingerprints are compared against every previously-imported
transaction. If **≥ 80 %** overlap, the wizard warns
("Looks already imported — import anyway / cancel") — advisory only, the user can
proceed. `< 80 %` imports silently. (`ImportFingerprint`, threshold `0.80`.)

## Execution, undo, and scope guards

- **Background `@ModelActor ImportRunner`**: chunked inserts (200/save), progress
  ticks, `Task.isCancelled` honored. **Cancel = rollback this run's rows via the
  batch id** (and any custom categories the run created) — never half-visible.
  The main `@Query` context sees the writes through SwiftData store propagation;
  the wizard is a full-screen cover, so the list/charts effectively refresh once.
- **Undo** (summary + Settings → Import history, per batch): delete all
  transactions with that `importBatchID` + the batch record, behind a count
  confirmation.
- **Scope guards (E)**: imported rows carry **no `rawTranscript`**, feed **no
  DecisionRecords** (the Categorizer guess at import is a guess, correctable later
  like any transaction — corrections THEN teach normally), and otherwise
  participate fully in charts/search/grouping/FX totals.

## Tests

`AmountLexerTests` (+ the `ParserTests` regression), `CSVParserTests`
(quoted/`;`/BOM/CRLF), `XLSXReaderTests` (bundled `sample.xlsx` — CoreXLSX read +
serial dates), `HeaderGuessTests` (RO+EN), `DateFieldParserTests` (detection incl.
ambiguity + noon rule), `CategoryMatcherTests`, `ImportRowParserTests` (skips +
negatives policy + currency/context), `ImportFingerprintTests` (threshold),
`ImportBatchTests` (import→undo round-trip, cancel-rollback invariant, create-custom
decision), `ImportModelMigrationTests`. UI: `ImportWizardUITests` reaches preview
with the CSV fixture via the `-importUITest` seam (non-blocking screenshots job).

## Out of scope (logged, moved on)

Report exports — next run.

---

# v1.1 "Auto-Logging" run — Part A (Apple Pay auto-capture)

## Frozen-seam exception: `TransactionSource.autoLogged` (approved)

Additive `String`-raw `Codable` enum case (`Transaction.swift`). Adding a case
only widens the valid set — stored `"voice"/"manual"/"imported"` strings decode
unchanged, no heavyweight migration. **Decode proof** (`TransactionSourceMigrationTests`,
on a REAL on-disk store, close + reopen): a store holding only the old cases
decodes clean and no row spuriously becomes `.autoLogged`; an `.autoLogged` row
round-trips with its value intact alongside an old-case row. Both the Apple Pay
intent AND the share-sheet capture (Part B) reuse this ONE case — origin is
distinguished by the `rawTranscript` prefix (`[intent]` vs `[share]`), never a
second source case.

## No `Double` touchpoint (money path stays `Decimal`-only)

`LogPaymentIntent.amountText` is bound as a **`String`** `@Parameter` (the
Shortcuts Transaction trigger passes its amount as text). It is parsed by the
hardened `AmountLexer.classifyCell`, inheriting the float-dust rounding + the
plausibility cap. The documented `Double` fallback was **not needed** — String
binding works — so no `Double` enters the money path and the Double-in-money grep
stays clean.

## Shared container (controlled `BaniApp` integration edit)

`BaniModelContainer.shared` is the single on-disk `ModelContainer`. The background
`LogPaymentIntent` launch (`openAppWhenRun == false`) and the foreground app both
resolve to it, so there is exactly one container over the default store. `BaniApp`
now takes its on-disk container from `BaniModelContainer.shared` (UI tests keep a
throwaway in-memory one). The store URL is unchanged (`ModelConfiguration(isStoredInMemoryOnly:)`
only) → existing users' data preserved; schema unchanged except the additive enum case.

## Card-contract compliance (never invisible, never un-resolvable)

Auto-logged entries save immediately (real payments), carry a distinct **"auto"
badge** everywhere they render (via `TransactionRow`), and surface an **"N auto-logged
— review" chip** on the Log tab. "Unreviewed" is DERIVED (an `.autoLogged` row with
no `DecisionRecord` referencing it) — no new field on the frozen `Transaction`.
Each resolution writes exactly one `DecisionRecord` feeding `TrustEngine`, exactly
like a voice card: Confirm → `confirmedExplicit` (+ rule reinforce), Edit →
`corrected` (+ changed fields, learns the category correction), Discard → real
delete + `discarded` record + restorable Undo toast.

## Dedup

`.autoLogged` rows join the existing-fingerprint set alongside `.imported`
(`ImportBatchStore.existingImportFingerprints`), so a later statement import of the
same payment is caught by the existing batch-level dedup flow (grouped choice,
default skip). No stored fingerprint on the frozen `Transaction` — it is derived
from the persisted day+amount+description (`DedupCollisionTests`). Voice/manual
rows are deliberately excluded (legit duplicate hand-entered spend is expected).

## Settings guide + test-intent row

Settings → "Auto-logging" (`AutoLoggingGuideView`): numbered ro+en Shortcuts-setup
steps (matching iOS 26 Shortcuts wording) + a **"Log a test payment"** row that
fires the SAME write path (`AutoLogWriter.log`) with a sample payload, so on-device
setup is verifiable without a real payment (the sample lands in the review chip).

## Part A tests (gate)

`TransactionSourceMigrationTests` (decode proof, on disk), `LogPaymentIntentTests`
(payload → persisted `Transaction`: Decimal amount, categorizer applied, verbatim
`rawTranscript`, RON default, EUR mapping, garbage/zero/implausible → throws with
NO row saved), `DedupCollisionTests` (auto-logged vs later import collides; scoping
excludes voice/manual), `AutoLogReviewTests` (unreviewed count; confirm/edit/discard
→ one `DecisionRecord` each; discard deletes + Undo restores). New localized keys
added to `Localizable.xcstrings` in both en+ro (parity kept for
`LocalizationCompletenessTests`).

---

# v1.1 "Auto-Logging" run — Part B (share-sheet capture)

## The single approved project.yml edit (Share Extension target + App Groups)

ONE batched edit: a new `BaniShare` `app-extension` target (embedded in the app),
plus the `com.apple.security.application-groups` (`group.com.dumi.bani`) entitlement
on BOTH targets (`Support/Bani.entitlements`, `Support/BaniShare.entitlements`,
generated by XcodeGen from `properties`). Expect ONE cold-cache resolve/build cycle
(project.yml is the CI cache key). The extension has an EMPTY dependency set (no SPM
products) so the cache + signing surface stays small. The SwiftData store is NOT
relocated to the App Group — the extension hands off plain JSON+blob files only, so
there is no store migration.

## Deliberately-dumb extension

`BaniShare/ShareViewController.swift`: accepts an image (1) or plain text, writes it
to the App Group container via `SharedPayloadStore`, shows "Trimis către Bani ✓", and
completes. NO SwiftData / OCR / WhisperKit / model code inside the extension
(memory limits). `SharedPayloadStore` (App-Group file IO, pure Foundation) is the ONLY
shared source, compiled into both the extension and the app.

## Main-app pickup

On foreground (Log tab), `SharePickup.drain()` drains the App Group OFF the main
actor: image → the existing Vision OCR ladder (`OCRService`); text → straight through.
`BankNotificationParser` (new, Parsing/) extracts amount (via `AmountLexer.parseCell`
→ inherits float-dust + plausibility cap), merchant/counterparty, currency, and
direction (incoming markers → `.income`) from Raiffeisen-shaped RO fixtures + generic
RO/EN patterns. Each capture surfaces a pre-filled `ShareCaptureCard`; unparseable →
the card opens with the amount blank and the OCR text visible (silent-card-bail
contract). Confirm writes an `.autoLogged` transaction with the `[share]`
rawTranscript prefix (reusing the ONE seam, differentiated from `[intent]`) and
resolves it in the ledger (badge everywhere, feeds TrustEngine). Dedup applies via
Part A's fingerprint scheme (a shared payment + later statement import collapse).

## Revision hatch

`BankNotificationParser` is tuned on SYNTHETIC phrasing. When D supplies a real
Raiffeisen notification, a small follow-up run tunes the parser fixtures only (no
structural change).

## AltStore / on-device — MUST VERIFY ON DEVICE (CI cannot prove it)

CI proves the extension compiles, archives, and packages into the unsigned IPA. It
CANNOT prove: (1) the share sheet shows "Bani" after AltStore sideload, (2) AltStore's
App-Group-ID rewrite keeps the extension and app pointed at the SAME container, (3) a
real bank notification screenshot/text round-trips. In the CI simulator the App Group
is unprovisioned, so `SharedPayloadStore.directory` is nil and drain/writes no-op
(handled) — the round-trip is proven on the directory-injectable core in
`AppGroupRoundTripTests`. If the extension structurally breaks CI signing/IPA
packaging within 2 cycles, Part B is reverted cleanly and Part A (v1.0.34) stands.

## Part B tests (gate)

`BankNotificationParserTests` (fixture table: RO/EN amounts incl. "1.234,56",
merchant/counterparty extraction, income detection, implausible → nil, unparseable →
nil), `AppGroupRoundTripTests` (extension-side write → drain → parse on a temp dir;
drain removes processed files, oldest-first). New card keys added en+ro (parity kept).
