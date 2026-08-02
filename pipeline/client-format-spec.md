# Client Corpus — Format Spec, Report Templates & Category Mapping

**Scope.** Study of the client's real Excel corpus (49 files, read locally, never
committed). This document is the import + export-template source of truth for the
implementation run. Every value here is **synthetic or aliased** — no real name,
amount, date, IBAN, or merchant appears. Person/firm names are `PersonA…`,
`FirmA…`, `RetailerA…`. Generic Romanian category words (notariat, comision,
materiale, TRANSFER…) are kept verbatim because they carry no identity.

Corpus language: **Romanian**. Domain: a **real-estate investor** (buys land/
apartments, renovates, sells; also personal/household spending and private
lending). Fixtures that encode each family live in `BaniTests/Fixtures/`
(`client-logA/B`, `client-reportC/D-expected`, `client-otherE`).

---

## 1. Family map (what the corpus is)

| Family | Kind | Files | Sheets | Tx rows (approx) | Span | Fixture |
|---|---|--:|--:|--:|---|---|
| **A — Investment Tracker** | raw log | 13 | 213 | ~20,400 | 2020–2026 | `client-logA.xlsx` |
| **B — Raiffeisen statement** | raw log | 33 | 33 | ~5,700 | 2021-12 → 2023-09 | `client-logB.xlsx` |
| **C — Centralizator** | finished report | 1 | 3 | ~3,330 | 2018 → 2023 | `client-reportC-expected.xlsx` |
| **D — Cheltuieli lunare** | finished report | 1 | 20 | n/a (matrix) | 2013 → 2025 | `client-reportD-expected.xlsx` |
| **E — PROPUNERE IT** | other (exclude) | 1 | 16 | 0 | 2025 | `client-otherE.xlsx` |

**How the families relate.** They are one financial life seen at three altitudes:

- **B (raw bank) → C (categorized report).** Family C's `CENTRALIZATOR GENERAL`
  is the client *by hand* doing exactly what Bani's import+categorize should
  automate: she pulls Raiffeisen (+ CEC) statement rows and stamps each with a
  `CATEGORIE`. **C is the oracle for "what a good import of B produces."**
- **A (per-asset ledgers)** track the investment side of those same cash flows,
  one sheet per asset (apartment, land, car, loan, person).
- Two **master** workbooks snapshot A at different times: a 2023 master (97
  sheets) and a 2026 master (105 sheets) that is its evolved superset (adds
  front-matter asset sheets). The **standalone** A files (per-asset `.xlsx`) are
  working copies later folded into the master ⇒ **the same asset/tx recurs across
  files and dates** — de-duplication and versioning matter.
- The Raiffeisen set overlaps itself: per-month statements **plus** cumulative
  year-slice dumps that re-contain those months ⇒ **duplicate rows across files**.
  `ImportFingerprint`/dedup (already in Bani) is load-bearing here.

---

## 2. Import spec — LOG families

### 2.1 Family A — Investment Tracker (`client-logA.xlsx`)

**Layout.** A short preamble, one canonical header, then transaction rows; wide
sheets add cost-bucket roll-up columns and a P&L footer.

```
r1  (blank)
r2  DETALII APARTAMENT: teren 100 mp          ← asset descriptor (free text)
r3  ADRESA : Bucuresti, Strada Exemplu 1      ← PRIVATE address line
r4  (blank)
r5  DATA | INVESTITII/ CHELTUIELI | CURS BNR | PRET EURO | OBSERVATII   ← header
r6  2021-01-12 | 48000 | 4.87 | 9855  | achizitie      [| Achizitie | AC | Materiale]  ← bucket labels echo here on wide sheets
r7           | 600   | 4.87 | 123.2 | notariat        ← BLANK date = same day as r6 (continuation)
r8  13.01.2021| 400  | 4.87 | 82.1  | cadastru
r9  10,08,2024| 60   | 4.97 | 12.07 | lacat           ← COMMA date form
...
rN  TOTAL | 194360.28 |     | 39000 |                 ← footer (also PRET VANZARE / PROFIT)
```

**Columns (canonical 5, 0-based):**

| # | Header | Meaning | Type |
|--:|---|---|---|
| 0 | `DATA` | transaction date (often blank = carry down) | mixed date encodings / blank |
| 1 | `INVESTITII/ CHELTUIELI` | **amount in RON** | number, usually integer, dot-decimal |
| 2 | `CURS BNR` | BNR FX rate that day | number, 4 decimals |
| 3 | `PRET EURO` | EUR equivalent = col1 ÷ col2 | **formula** (long float) |
| 4 | `OBSERVATII` | free-text label = the category signal | text |

**Preamble:** 0–5 rows (`DETALII…`, `ADRESA :`, a title, blanks), sometimes
merged banner cells. The **real header is NOT row 0.**

**Date encodings actually used (20,421 rows):**

| Encoding | Count | Share | Example |
|---|--:|--:|---|
| **blank (continuation)** | 14,161 | **69.3%** | `` (same day as row above) |
| **`DD,MM,YYYY` comma** | 4,132 | 20.2% | `10,08,2024` |
| `DD.MM.YYYY` dot | 1,274 | 6.2% | `13.01.2021` |
| ISO real Excel serial | 291 | 1.4% | styled date cell |
| non-date labels/other | ~560 | 2.7% | `TOTAL` |

⇒ **Import MUST (a) forward-fill blank dates from the row above, and (b) accept
the comma separator.** Without both, ~89% of rows are lost (see bug audit).

**Amounts:** dot decimal, **no thousands separators**; `INVESTITII/ CHELTUIELI`
is RON; `PRET EURO` is a computed EUR figure (do **not** import it as the amount —
it is a derived value). **Negatives exist (~671)** = reversals (`stornare`),
withdrawals (`retragere`), pay-outs — treat per negatives policy.

**Category/context encoding:** there is **no category column.** Category lives in
`OBSERVATII` free text (+ the sheet name = the asset, + the wide-sheet bucket
columns). Top `OBSERVATII` terms (generic verbatim; `*`=aliased proper noun):
`materiale`, `PersonA*`, `RetailerA*`, `PersonB*`, `manopera`, `beton`, `motorina`,
`notariat`, `anunturi`, `gard`, `necalificat`, `transport`, `impozit`, `gunoi`,
`intretinere`, `avans`, `comision`, `nisip`, `instalatii`, `curent`, `achizitie`,
`cadastru`, `intabulare`. Cost-bucket column labels (wide sheets): `Achizitie`,
`AC`, `Gard`, `Casa rosu`, `Materiale`, `Designer`, `Mobila`, `Amenajare`,
`Sanitare`, `Electrice`, `general`, + subcontractor-name buckets.

**Sub-layouts inside the masters (≈15 sampled):** full property tracker (most);
compact **car ledger** (`Bmw X5`-style: date | amount | note, no CURS); **loan
calc** (`Credite`); **ownership %-share matrix** (`Calcul Procente`,
cross-references person sheets); **person-lending ledger**
(`DATA | Suma adusa | CURS BNR | Euro | Observatii | Procent`); side-by-side
multi-unit blocks; appended **rent schedules** (`Nr.Crt | Luna | Data | Suma euro
| Suma lei`). One standalone tracker workbook (aliased `AssetX-2024.xlsx`) has a
**style block that breaks openpyxl** (`PatternFill … extLst`) — reads only via a
raw-XML fallback;
CoreXLSX is unaffected, but note it as a fragile-styles example.

**Detection signature (A):** a row within the first ~14 whose cells (case/
diacritic/space-folded) include **≥3 of** {`investitii`, `cheltuieli`, `curs bnr`,
`pret euro`, `observatii`}. Person-ledger variant: {`suma adusa`, `curs bnr`,
`euro`, `observatii`}. Corroborate with a `DETALII`/`ADRESA :` preamble and a
`TOTAL`/`PRET VANZARE`/`PROFIT` footer. A workbook is Family A when most sheets
match.

### 2.2 Family B — Raiffeisen "Extras de cont" (`client-logB.xlsx`)

**Layout.** A 16-row metadata block, a one-row balance summary, the transaction
header (row 17–18 depending on export type), a blank row, then transactions.

```
r1  Data generare extras: | 25/02/22            (monthly exports lead with this;
r2  Perioada: | de la … la …                     cumulative dumps lead with Perioada)
r3  Numar extras: | 2
r7  Nume client: | PERSOANA EXEMPLU              ← PII
r8  Adresa: | | Strada … | | BUCURESTI | B,RO    ← PII
r9  Numar client: | 0000000000                   ← PII
r10 Cod BIC Raiffeisen Bank: | RZBRROBU
r11 Unitate Bancara: | RAIFFEISEN BANK S.A. | …
r13 Cod IBAN: | RO00RZBR… | Tip cont: | curent | Valuta: | LEI   ← PII (IBAN)
r15 Sold initial | Rulaj debitor | Rulaj creditor | Sold final
r16 10000.00 | 4200.50 | 615.00 | 6414.50
r18 Data inregistrare | Data tranzactiei | Suma debit | Suma credit | Nr. OP |
    Cod fiscal beneficiar | Ordonator final | Beneficiar final |
    Nume/Denumire ordonator/beneficiar | Denumire Banca ordonator/ beneficiar |
    Nr. cont in/din care se efectueaza tranzactiile | Descrierea tranzactiei
r19 (blank)
r20 28/01/2022 | 28/01/2022 | 1400.0 |        | 1 | … | FirmA | … | OPIB/1 |plata …
r21 31/01/2022 | 31/01/2022 |        | 615.28 |   | … | PersonB | … | INCASARE …   ← credit-only
```

**Key facts.**
- **Amount is SPLIT across two columns:** `Suma debit` (money out) and
  `Suma credit` (money in), **mutually exclusive** (across the whole corpus:
  debit-only 4,987, credit-only 677, both 0, neither 0). There is no signed
  column. **Import must fold two columns → one signed amount** (or direction).
- **Dates `DD/MM/YYYY`.** `Data inregistrare` == `Data tranzactiei` in every row
  checked; the generation-date in the metadata uses `DD.MM.YYYY` (dots).
- **Amounts** dot decimal, no thousands separators. Cells are `inlineStr` typed.
- **Broken `<dimension ref="A1"/>`** in every file while the sheet truly holds
  23–1,275 rows (the `client-logB.xlsx` fixture reproduces this on purpose).
  CoreXLSX reads `<sheetData>` rows regardless, so **Bani is not broken by it**,
  but any parser that trusts the declared dimension (openpyxl read-only, some
  fast/streaming readers) sees ~1 row.
- **Accounts / periods:** `…730` RON current (27 files: ~monthly Dec-2021→Sep-2023
  + 4 cumulative year-slices), `…790` EUR current (3 year-slices), `…792` RON
  savings (3; two are empty `Nu exista tranzactii`, a 7-column shape). The 7-vs-12
  column difference is **emptiness, not currency.**
- Footer = balance-note + legal terms text, **no numeric total row**.

Top `Descrierea` type-tokens (aliased): `Card`, `OPIB`, `PLATA`, `RATA`,
`SCHIMB VALUTAR`, `DEPUNERE`, `COMISION`, `TRANSFER`, `INTRETINERE`, `TAXA`,
`INCASARE`, `POS`, + reference prefixes `OPINS/OPHT/MFM/ATM/AUC/TERT`.

**Detection signature (B):** sheet `Pagina 1` + `<dimension ref="A1"/>` with many
real rows + `inlineStr` cells; metadata `Cod BIC … = RZBRROBU` and an IBAN
`RO..RZBR…`; the `Sold initial | Rulaj debitor | Rulaj creditor | Sold final`
row; and a transaction header carrying **both** `Suma debit` and `Suma credit`
and ending in `Descrierea tranzactiei`.

### 2.3 What the importer must gain to handle A + B (cross-family)

1. **Header-row detection / preamble skip** — the header is not row 0 in A or B.
2. **Multi-sheet batch import** — A masters have 97–105 asset sheets; importing
   one-at-a-time is unusable (see bug audit §UX).
3. **Date forward-fill** — blank date = previous row's date (A: 69% of rows).
4. **Comma date separator** `DD,MM,YYYY` (A: 20% of rows).
5. **Dual debit/credit columns → signed amount** (B and C).
6. **Direction / income vs expense** — B and C carry money-in rows; Bani's model
   is expense-only (positive magnitude). See §4 flags.
7. **Per-column currency** — A is RON with an FX rate; B has RON/EUR accounts.

---

## 3. Report-template spec — FINISHED-REPORT families (export source of truth)

### 3.1 Family C — Centralizator (`client-reportC-expected.xlsx`)

Three sheets; together the client's **consolidated bank book**.

**Sheet `CENTRALIZATOR GENERAL`** — flat categorized ledger, one header row, no
structural totals. Header (note trailing space on `DATA `):
`IBAN | MONEDA | DATA  | EXPLICATII | DEBIT VALUTA | CREDIT VALUTA | CURS | DEBIT | CREDIT | CATEGORIE`
- RON rows: value in `DEBIT`/`CREDIT`; VALUTA/CURS empty.
- EUR rows: value in `DEBIT VALUTA`/`CREDIT VALUTA`, `CURS` a flat **4.5**
  constant, and `DEBIT`/`CREDIT` = VALUTA × CURS (the RON figure). ⇒ **use the
  `DEBIT`/`CREDIT` (RON) columns as the amount**, not the VALUTA columns.
- `MONEDA`: RON ≈ 2,900, EUR ≈ 432, no USD. ~11 IBANs (CEC + Raiffeisen), one
  account ≈ 76% of rows. Date is a real Excel serial. Debit/credit split as in B.
- `CATEGORIE` = the client's hand-assigned taxonomy (see §4).

**Sheet `Sheet4`** — a real PivotTable: Row Labels = `CATEGORIE`; measures =
`Count of DEBIT`, `Count of CREDIT`; a Grand-Total row; cache over the ledger.
This is the **"category summary" report shape** (category × count, trivially
extended to sum).

**Sheet `Sheet1`** — cash ledger `DATA | desc | incasare | plata | sod`, running
balance `sod_n = sod_(n-1) + incasare − plata` (`E4 = C4 − D4` …), chronological.
This is the **"running-balance statement" report shape**.

### 3.2 Family D — Cheltuieli lunare (`client-reportD-expected.xlsx`)

Personal/household (a ~4-person family), **not** real estate. Two report shapes:

**Yearly matrix `Total <year>`** — rows = months (jan→dec), columns = expense
categories, a `Total` column per month, a `SUM` total row, then an **EUR row =
RON ÷ 4.45** (fixed constant). Header shape drifted over time:
- 2013–15: `DATA | Global | Utilitati | Combustibil | PersonA | Mancare | Necesare | Diverse PersonB | Diverse PersonC | Total`
- 2016–17: same minus `Global`
- 2018–19: `DATA | Utilitati | Combustibil | PersonD | PersonA | Mancare | Necesare | Diverse PersonB | Diverse PersonC | Total`
(`Global` dropped after 2015; a per-person column `PersonD` added 2018; 2025
monthlies add a `MOFTURI` bucket.) Person-named columns are aliased.

**Monthly detail `<Month>`** — chronological line items: DATA (only on each day's
first row — same forward-fill convention as A) + one amount into a category column
+ free-text `Observatii`; footer `TOTAL` → `Buget estimat` → `Depasire`
(**budget variance** — a feature signal). An `Audi` sheet is a one-off car tally.

**Report-template takeaways for Bani export:** (1) monthly matrix (month × category
with per-month + per-category totals + a currency-conversion row); (2) category-
count/sum pivot; (3) running-balance ledger; (4) per-asset P&L (Family A footer:
`TOTAL / PRET VANZARE / PROFIT`); (5) budget-vs-actual variance (Family D).

### 3.3 Family E — excluded

`client-otherE.xlsx`. An IT-equipment procurement proposal: one BOM summary sheet
(`NR.CRT | DENUMIRE | BUCATI | PRET/BUCATA | TOTAL | INFO`) + per-product 2-column
spec sheets (`Categorie | Specificatii`, "Minim…" requirements). **No date-stamped
transaction rows** anywhere ⇒ not an import target. Detection: filename
`PROPUNERE/OFERTA/configuratii`, ≥10 equipment-noun sheets, dominant 2-col
key/value shape, a lone `Total:` row, no per-row date column ⇒ Bani should
politely decline / route to a non-transaction bucket.

---

## 4. Category vocabulary → Bani mapping  ⚠ EVERY ROW IS A PROPOSAL FOR YOUR REVIEW

Bani presets: `fuel, groceries, dining, transport, utilities, shopping, health,
entertainment, other`. The corpus has **two taxonomies**: personal spending
(fits presets) and real-estate/finance (needs customs).

### 4.1 Maps cleanly onto existing PRESETS (extend the seed keywords)

| Client term (RO) | → Bani preset | Note |
|---|---|---|
| curent, apa, gaz, intretinere, factura, chirie, internet | **utilities** | already seeded; add `intretinere`, `gunoi`? (see flag) |
| motorina, combustibil, benzina, carburant | **fuel** | seeded |
| transport, taxi, parcare, tren, bilet | **transport** | seeded |
| mancare, alimente, piata | **groceries** | seeded |
| restaurant, cafea, cafenea | **dining** | seeded |
| mobila, mofturi, haine | **shopping** | `mofturi`=treats/impulse (D) — judgment |
| farmacie, medic, doctor, spital | **health** | seeded |

### 4.2 Needs NEW CUSTOM categories (real-estate + finance) — proposed

| Proposed custom | Absorbs (client terms) | Source families |
|---|---|---|
| **Achiziție** | achizitie, avans, dif plata | A, C |
| **Notariat & taxe legale** | notariat, notar, taxe notar, taxa PV, taxa CU, avize, ocpi | A |
| **Cadastru & intabulare** | cadastru, intabulare, topo, primarie | A |
| **Materiale construcții** | materiale, beton, nisip, gard, sanitare, electrice, instalatii | A |
| **Manoperă** | manopera, necalificat, + subcontractor-name buckets | A |
| **Amenajare & mobilier** | amenajare, designer, mobila, curatare | A |
| **Impozite & taxe** | impozit, taxe, taxa | A, C |
| **Comision** | comision (agency + bank fee — see flag) | A, B, C |
| **Transfer / numerar** | TRANSFER, DEPUNERE NUMERAR, RETRAGERE NUMERAR, SCHIMB VALUTAR | B, C |
| **Împrumut / Restituire** | IMPRUMUT, RESTITUIRE IMPRUMUT (per-counterparty) | C |
| **Dobândă** | DOBANDA | C |
| **Salariu / Încasări** | SALARIU, INCASARE, RETUR CHELTUIELI PERSONALE | C |
| **Cheltuieli personale** | CHELTUIELI PERSONALE (card POS at retailers) | C |

Client `CATEGORIE` frequency (Family C, aliased): `CHELTUIELI PERSONALE` 2172 ·
`TRANSFER` 545 · `COMISION` 162 · `DEPUNERE NUMERAR` 102 · `RETRAGERE NUMERAR` 93 ·
`PLATA {Person}` 90 · `DOBANDA` 24 · `RETUR CHELTUIELI PERSONALE` 24 · `SALARIU`
12 · `IMPRUMUT {Firm}` 11 · then a long tail of per-counterparty
`PLATA/INCASARE/IMPRUMUT/RESTITUIRE {Person/Firm}` singletons (~32 of them).

### 4.3 Judgment calls — ⚠ NEED YOUR DECISION

1. **Income & credits don't fit an expense-only model.** Bani stores a positive
   magnitude and treats every row as spending. But B/C are full of money-**in**
   rows (SALARIU, INCASARE, DOBANDA, credit-side). Options: (a) add a
   direction/sign concept, (b) a dedicated "Income/Transfer" context excluded from
   spend analytics, (c) skip credit rows on import. **Recommend (a or b); (c) loses
   the client's incoming rent/sale/loan money.** — *biggest decision.*
2. **`comision` is overloaded** — bank fee (small, recurring, B/C) vs real-estate
   **agency commission** (large, A). Same word, different category. Disambiguate by
   family/amount, or keep one "Comision" custom and let context carry it?
3. **Cash movements & loans are not expenses** (TRANSFER, DEPUNERE/RETRAGERE,
   IMPRUMUT, RESTITUIRE). Category, or excluded transfer type?
4. **Per-counterparty explosion** — ~32 singleton `PLATA/INCASARE {Person}`
   categories. Recommend **collapse** to generic `Plăți` / `Încasări` /
   `Împrumuturi` customs and keep the counterparty in the description, not 32
   categories.
5. **Custom-category capacity** — need ≥12 customs for real estate; Bani ships 8
   custom color slots (`BaniCustom0–7`). Verify whether customs are capped at 8 or
   colors merely recycle. If capped, presets+8 is insufficient for this client.
6. **No category column in Family A** — category must come from `OBSERVATII` via
   the by-description categorizer. Recommend **seeding the RO real-estate keywords**
   above so `materiale → Materiale construcții`, `notariat → Notariat`, etc.,
   auto-fire. Otherwise every A row lands in `other`.
7. **`intretinere`/`gunoi`** — building-maintenance/garbage: utilities preset, or a
   property-cost custom? **`necesare`** (D) is vague (household essentials) —
   groceries or its own bucket?
8. **EUR rows in C** — import the **RON `DEBIT`/`CREDIT`**, not `DEBIT VALUTA`
   (already converted at CURS 4.5). Confirm this is the desired behavior vs storing
   original-currency + rate.

---

## 5. Open questions
- Which asset-sheet sub-layouts (car ledger, loan calc, %-share, person-lending)
  are in-scope for import vs "leave in Excel"? Recommend: import the standard
  tracker + rent schedules; treat calc/share sheets as out of scope.
- Should the two A masters be imported as **one batched multi-sheet job** (per-asset
  batches) with dedup against the standalone files?
- Report export: which of the five report shapes (§3.2 takeaways) does the client
  actually want Bani to regenerate first? (Centralizator pivot is the highest-value
  guess.)
