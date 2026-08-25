# Bani — Whiteboard Vision (2026-08-24)

Source: two whiteboard photos (blue marker), captured 2026-08. Board 1 sketches the app's end-state architecture; Board 2 specs the custom report the client actually wants. Together they define the destination the versioned roadmap is walking toward.

---

## 1. The core architecture (Board 1)

```
INPUT RAW ──────────────┐
                        ▼
        LLM / SELF-LEARNING PROCESSING UNIT
                        │
                        ▼
             CENTRALISED DATABASE
              │      │       │        │
              ▼      ▼       ▼        ▼
          SIMPLE  SEARCH   SIMPLE   INFO RELAY
          REPORT  ENGINE   DASH-    (Excel / PC
                  (smart)  BOARD     program)

AUTOMATED INPUT ────────► feeds the same pipeline
```

### The pipeline, in words

1. **Input raw** — the user throws unstructured data at the app: voice, typed text, photos, documents, spreadsheets. No pre-formatting demanded of the user. This is the founding principle of Bani: the app absorbs reality as it comes.
2. **LLM / self-learning processing unit** — an intelligence layer sits between raw input and storage. It interprets, categorizes, assigns direction and project context, and *improves over time* (the "self-learning" part: it learns the client's patterns — vendors, project vocabulary, recurring flows — so that categorization gets sharper with use). Nothing enters the database uninterpreted.
3. **Centralised database** — one canonical store. Every consumer downstream reads from the same source of truth. On a ~30-year, multi-investment dataset, this is a hard constraint, not a preference: data integrity and project context are non-negotiable.
4. **Four consumers of the database:**
   - **Simple report** — the human-readable output (specced in detail on Board 2).
   - **Search engine (smart)** — semantic search over the whole history. "What did I pay the electrician at the Crângași site last spring" should just work.
   - **Simple dashboard** — at-a-glance state: liquidity, current position. The seed of this is the portfolio liquidity header planned for v1.2a.
   - **Info relay → Excel / PC program** — the data must escape the phone. Export/relay into a spreadsheet-consumable form on the desktop.

### Automated input

Alongside manual raw input, there is an **automated input** channel feeding the same pipeline — bank feeds (open banking / GoCardless, planned v1.3), Apple Pay auto-logging (v1.1), and any other source that can push transactions in without the user typing. The bullets attached to this arrow on the board enumerate the data domains it must cover — the same domains the report consumes: current liquidity, owed people, bank loans, non-bank loans/investors.

### How this maps to the shipped roadmap

| Whiteboard element | Roadmap version |
|---|---|
| Input raw (multi-format import, voice) | Shipped (v1.0.31 / v1.1 Run 1) |
| Automated input — Apple Pay | v1.1 |
| Simple dashboard (liquidity header) + Project hub | v1.2a |
| Bank loan structure | v1.2b |
| Automated input — open banking | v1.3 |
| Simple report (Raport Custom) | v1.4 |
| LLM processing unit, search engine (smart) | post-v1.4 |
| Info relay / desktop | later |

The ordering logic the boards independently confirm: **almost nothing on Board 2 is computable without project context**, which is why Projects (v1.2a) leapfrogged the LLM assistant, and why Loans (v1.2b) precedes Reports (v1.4).

---

## 2. Raport Custom — the report spec (Board 2)

The report the client actually wants to read. Line items:

### Position
- **Current liquidity** — cash position now.
- **Cash flow** — movement over the period.
- **Owed people + sum (they owe ME)** — receivables. Direction is explicit: this is money owed *to* the client, per person, with amounts. (People registry, v1.3, is the structural dependency.)

### Debt — two distinct concepts, not one
- **Bank loan info:**
  - Current monthly payment, **split into interest vs. principal return**
  - Sum owed left
  - % left
  - **Interest = business expense, booked against the current project** — the interest slice of each payment flows automatically into that project's expenses ("de pus sub cheltuieli la proiectul curent"). This means bank loans carry a project assignment, and the loan model must know the amortization split per payment.
- **Non-bank loans / investors:**
  - Same tracking surface: sum owed left, % left, payments
  - **But interest/return here is NOT a project business expense.** Investor money is a different animal from bank debt and must not pollute project P&L.
  - *Decision (D, 2026-08-24):* investor interest/return is tracked as a **cost-of-capital line outside all project rollups** — visible in Raport Custom, never in project P&L.

### Projects
- **Amount invested in projects** — capital deployed per project.
- **Budgeting — for the business:**
  - **Unfinished payments on started projects**: amount paid + amount due, with %, date/time — the forward-looking commitments view, "useful for budgeting."
  - Explicitly noted: **this requires the Project tab**, including a **"new project" interview/form** flow for structured project creation.

### The structural conclusion (written on the board itself)
> **Project tab becomes the HUB — subdivision of project expense + earning.**

The Project tab is not a filter or a category. It is the organizing spine of the entire app: every expense and earning subdivides under a project, and the report is largely a per-project and cross-project rollup. This is the whiteboard's own justification for the v1.2a decision.

*V2 decision (D, 2026-08-24): the Raport itself becomes the app's hub — the report as a living overview screen replaces the costs-first Finances tab; transaction list/analytics become drill-downs inside it.*

---

## 3. The vision, in one paragraph

Bani is a system where a real-estate investor throws raw financial reality at his phone — a voice note, a photo of an invoice, a bank feed — and an intelligence layer turns it into clean, project-anchored records in one canonical database that will stay coherent for 30 years. Out the other side come exactly four things: a report that answers the questions he actually asks (liquidity, who owes me, what my loans really cost, what my projects have consumed and still demand), a search box that speaks his language, a dashboard he can read in three seconds, and an escape hatch to Excel on the PC. The project is the atom of meaning; the LLM is the translator; the database is the contract.

---

## 4. Open questions — resolved 2026-08-24

1. **Non-bank interest treatment** — RESOLVED: cost-of-capital line off project P&L (D's call).
2. **Info relay scope** — RESOLVED: one-way export (app → xlsx); desktop stays a viewer.
3. **Automated input sources** — GoCardless + Apple Pay confirmed; others unplanned.
