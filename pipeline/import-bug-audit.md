# Import Bug Audit — current wizard vs the client's real files

**What this is.** The current import pipeline (`Bani/Import/*`, `Bani/Parsing/*`)
run against the client's real corpus and the synthetic fixtures, to find where the
"slow and buggy" experience comes from. All examples are synthetic/aliased.

**Method.** No Swift toolchain on this host, so the pipeline's row-level logic was
ported to Python **verbatim** — `XLSXReader` header selection, `HeaderGuesser`,
`DateFieldParser` (incl. `candidatePatterns`), `AmountLexer` (the shared
digit-token core), `ImportRowParser`, and `Categorizer.normalize/tokenize` — and
pinned against Bani's own documented expectations (the `AmountLexer` docstring
cases, the `DateFieldParser` behaviors) before use. It was then run in two modes
against every family:
- **DEFAULT** — exactly what the wizard does with no user help: header = first
  non-blank row (`XLSXReader.buildSheet`), `HeaderGuesser.guess`, auto date-format.
- **ORACLE** — a *perfectly* hand-corrected mapping (right header row, right
  columns), to isolate the losses that **no amount of user effort** can fix.

Counts below are the simulator's skip tallies on the real files. They are
directional (a faithful port, not the shipped binary), but the mechanisms are
exact — each is traceable to a specific line of the current code.

---

## Severity-ranked findings

### 1. ⛔ CRITICAL — Blank "continuation" dates are dropped, not carried down  *(Family A)*
- **Symptom.** In the trackers a blank `DATA` cell means "same day as the row
  above." `ImportRowParser.parse` requires a non-empty date per row and skips the
  rest as `.missingDate`.
- **Scale.** **14,161 of ~20,421 tracker rows (69.3%) are blank-date.** In the
  ORACLE run these all skip: e.g. one large asset sheet → `data_rows=1788,
  imported=92, missingDate=1294`. Aggregate ORACLE over sampled A sheets:
  **imported 362 / 6,752 rows (5.4%)**, `missingDate=4,783`.
- **Cause.** `ImportRowParser.parse` → `guard … !dateCell.isEmpty else
  { skip(.missingDate) }`; no forward-fill.
- **Fix.** Forward-fill the date column from the last non-empty value.

### 2. ⛔ CRITICAL — Header is hard-wired to the first non-blank row  *(A, B, C)*
- **Symptom.** `XLSXReader.buildSheet` sets `headers` = first non-blank row and the
  wizard has **no header-row picker** (`ImportWizardModel.selectSheet` feeds
  `sheet.headers` straight to `HeaderGuesser`). The client's files all have a
  preamble, so the "header" becomes `DETALII…` (A) / `Data generare extras:` (B),
  the real header row + preamble become data rows, and auto-map maps almost
  nothing.
- **Scale.** **DEFAULT imported 0 rows on 22/22 sampled A sheets, 33/33 B files,
  and the C ledger.** Out of the box the client's data imports as **nothing**.
- **Cause.** `buildSheet` (header = first non-blank) + no header-index UI.
- **Fix.** Detect the header row (score rows by known field keywords) or let the
  user choose it; skip preamble rows above it.

### 3. 🔴 HIGH — Comma date separator `DD,MM,YYYY` is unparseable  *(Family A)*
- **Symptom.** `DateFieldParser.candidatePatterns` only swaps among `.`, `/`, `-`.
  A comma date (`10,08,2024`) matches no formatter → `.unparseableDate`; `detect`
  also sees no known separator and mis-picks slash.
- **Scale.** **4,132 tracker rows (20.2%)** use the comma form (the dominant
  *typed* date). Simulator: `10,08,2024` → parse fails under every format.
- **Cause.** Separator set excludes `,`.
- **Fix.** Add `,` to the separator expansion (and to `detect`'s tally).

### 4. 🔴 HIGH — Split debit/credit: only one amount column mappable; credits vanish  *(B, C)*
- **Symptom.** `ImportFieldMapping.amountColumn` is a single index. Bank money-in
  rows have an empty `Suma debit` and a filled `Suma credit`; mapped to debit they
  skip as `.missingAmount`. `HeaderGuesser` even auto-picks `Suma debit` /
  `DEBIT VALUTA` (keyword "debit"), silently choosing the debit side.
- **Scale.** ORACLE (debit-only, the only option): **B loses 677 credit rows**
  (of 5,664); **C loses 373 credit rows** (of ~3,330). These are the client's
  incoming money (rent, sales, loan repayments, salary).
- **Cause.** Single `amountColumn`; no debit+credit pairing.
- **Fix.** Allow a debit-column + credit-column pair → one signed amount (and a
  direction). See model gap #9.

### 5. 🔴 HIGH — Multi-sheet workbooks import one sheet at a time  *(Family A masters)*
- **Symptom.** `ImportWizardModel.selectedSheet` is a single sheet; `> 1` sheet
  just shows a picker. The master workbooks have **97 and 105 asset sheets**, so a
  full import means running the wizard ~100 times, re-mapping each.
- **Cause.** No "import all sheets" / batched multi-sheet path.
- **Fix.** Multi-select sheets + one batched run (per-sheet mapping reuse). This is
  the single biggest **time** cost (below).

### 6. 🟠 MEDIUM — Auto-map chooses the wrong amount/description columns  *(all)*
- **Symptom / evidence** (auto-map on the *real* header rows):
  - **A** `DATA|INVESTITII/ CHELTUIELI|CURS BNR|PRET EURO|OBSERVATII` → amount
    picks **`PRET EURO`** (keyword "pret", the EUR column) not RON
    `INVESTITII/ CHELTUIELI`; description → **none** (`OBSERVATII` matches no
    keyword) ⇒ required-field gate fails.
  - **B** → amount `Suma debit`; description **`Cod fiscal beneficiar`** (keyword
    "beneficiar") instead of `Descrierea tranzactiei`.
  - **C** → amount **`DEBIT VALUTA`** (keyword "debit" hits VALUTA first) not RON
    `DEBIT`; description **none** (`EXPLICATII` ≠ keyword "explicatie").
- **Cause.** `HeaderGuesser.keywords` gaps (no `investitii`, `cheltuieli`,
  `observatii`, `explicatii`) + first-match order prefers VALUTA/EURO columns.
- **Fix.** Add the client's header vocab; prefer the base-currency amount column;
  bias description away from code/id columns.

### 7. 🟠 MEDIUM — By-description categorizer has no real-estate vocab → all `other`  *(Family A)*
- **Symptom.** Family A has **no category column**; category comes from
  `OBSERVATII` via `Categorizer`. `CategorySeeds` covers everyday consumer spending
  only, so `materiale`, `notariat`, `cadastru`, `manopera`, `beton`… all fall to
  `.other`.
- **Cause.** Seed table scope.
- **Fix.** Seed the RO real-estate/finance keywords (spec §4.2) and/or create the
  proposed custom categories.

### 8. 🟡 LOW — Robustness: fragile styles & broken dimension
- One standalone tracker file (aliased `AssetX-2024.xlsx`) throws on a `PatternFill … extLst` style (needs a
  raw-XML fallback in openpyxl; CoreXLSX appears tolerant — add a defensive test).
- Every Raiffeisen file declares `<dimension ref="A1"/>` while holding up to 1,275
  rows. **CoreXLSX reads `<sheetData>` regardless, so Bani is NOT currently broken
  by it** — but any move to a dimension-trusting/streaming reader would read ~1
  row. The `client-logB.xlsx` fixture encodes this quirk as a regression guard.

### 9. 🟡 LOW (model gap) — No representation for income / credits  *(B, C)*
Even after #4, `Transaction` stores a positive magnitude expense; SALARIU,
INCASARE, DOBANDA and every credit row have no home. Decision needed (spec §4.3
flag 1): direction/sign, an excluded transfer/income context, or drop.

---

## Where the "slow and buggy" perception comes from

**"Buggy" = parsing + model, not the UI.**
- **Default import = 0 rows** for the client's files (finding #2): the preamble is
  taken as the header, so nothing maps. The user's first impression is "it imported
  nothing."
- **Even after fixing the mapping by hand**, ~**89% of Family A rows** still vanish
  (blank dates 69% + comma dates 20%, findings #1 & #3) and ~**12% of bank rows**
  (credits, #4). The totals never match her Excel — the defining symptom of "buggy."
- Auto-map lands the amount on the **EUR/VALUTA** column (#6), so even the rows
  that do import can carry the **wrong number**.

**"Slow" = workflow, not compute.**
- The parser is O(rows) and `ImportRunner` chunks inserts at 200/save — that part
  is fine. The slowness is structural:
  1. **~100 wizard runs** for one master workbook (#5).
  2. **Re-mapping columns every run** because auto-map is wrong (#6/#7).
  3. **Full-workbook parse up front** — `XLSXReader.parse` walks **all** 97–105
    worksheets of a 2.7 MB workbook (shared-string + per-cell densify, twice for
    the width pass) just to populate the sheet picker, before the user does
    anything.
- So: **not chunking, not the DB.** It's re-work (multi-sheet + re-mapping) and an
  eager parse of a very large multi-sheet workbook.

---

## Top 5 to fix first (impact-ordered)

| # | Fix | Unlocks |
|--:|---|---|
| 1 | Forward-fill blank dates (#1) | +69% of Family A rows |
| 2 | Header-row detection / preamble skip (#2) | A, B, C import > 0 by default |
| 3 | Comma-date parsing (#3) | +20% of Family A rows |
| 4 | Debit+credit column pair → signed amount (#4) | the client's incoming money (B, C) |
| 5 | Multi-sheet batch import (#5) | the master workbooks become usable (speed) |

Then: header-keyword + amount-column fixes (#6), real-estate seeds (#7),
income/direction model (#9).
