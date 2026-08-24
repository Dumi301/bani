import Foundation
import SwiftData

/// Deterministic sample transactions for UI-test screenshots. Anchored to the
/// launch date (not a fixed epoch) and spread across ~4 months so the Finances
/// analytics view (D) always has data in the default Month timeframe — a rich
/// donut, non-empty bars, and a previous-period line — regardless of when CI
/// runs. Seeds via a fresh `ModelContext` (not `mainContext`) — `@MainActor`
/// because the v2 SEAL loan seed below drives `LoanStore` (itself
/// `@MainActor`); its only caller (`BaniApp.init`) is already `@MainActor`, so
/// this stays safe to call from `App.init` under Swift 6 strict concurrency.
///
/// A current-month `benzină` / Personal entry is always present: the detail-view
/// UI test taps it to open the read-first detail screen.
enum SampleData {
    @MainActor
    static func seed(into container: ModelContainer) {
        let ctx = ModelContext(container)

        let calendar = Calendar.current
        let now = Date()
        func daysAgo(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: now) ?? now }

        let samples: [Transaction] = [
            // ── Current month (visible in the default Month timeframe) ──
            Transaction(amount: 52, currency: .ron, context: .personal, category: .fuel,
                        descriptionText: "benzină", merchant: "OMV",
                        date: daysAgo(1), rawTranscript: "cincizeci și doi de lei benzină", source: .voice),
            Transaction(amount: 18.5, currency: .ron, context: .personal, category: .dining,
                        descriptionText: "cafea", merchant: "Origo",
                        date: daysAgo(2), rawTranscript: "optsprezece cincizeci lei cafea", source: .voice),
            Transaction(amount: 120, currency: .eur, context: .work, category: .transport,
                        descriptionText: "taxi aeroport", merchant: nil,
                        date: daysAgo(3), source: .manual),
            Transaction(amount: 240, currency: .ron, context: .work, category: .utilities,
                        descriptionText: "internet birou", merchant: "RCS",
                        date: daysAgo(4), source: .manual),
            Transaction(amount: 76.9, currency: .ron, context: .personal, category: .groceries,
                        descriptionText: "cumpărături", merchant: "Mega",
                        date: daysAgo(6), rawTranscript: "șaptezeci și șase nouăzeci lei cumpărături", source: .voice),
            Transaction(amount: 63, currency: .ron, context: .personal, category: .health,
                        descriptionText: "farmacie", merchant: "Catena",
                        date: daysAgo(8), source: .manual),
            Transaction(amount: 55, currency: .ron, context: .personal, category: .entertainment,
                        descriptionText: "abonament Netflix", merchant: nil,
                        date: daysAgo(10), source: .manual),
            Transaction(amount: 189, currency: .ron, context: .personal, category: .shopping,
                        descriptionText: "haine", merchant: "Zara",
                        date: daysAgo(12), source: .manual),
            Transaction(amount: 32, currency: .ron, context: .personal, category: .dining,
                        descriptionText: "shaorma", merchant: nil,
                        date: daysAgo(15), rawTranscript: "treizeci și doi lei shaorma", source: .voice),
            Transaction(amount: 24, currency: .ron, context: .work, category: .transport,
                        descriptionText: "parcare", merchant: nil,
                        date: daysAgo(18), source: .manual),

            // ── Direction + counterparty variety (A1/B — feeds income line + People) ──
            Transaction(amount: 4500, currency: .ron, context: .work, category: nil,
                        descriptionText: "salariu", merchant: nil, date: daysAgo(5),
                        source: .manual, direction: .income, counterparty: "Firma ACME"),
            Transaction(amount: 300, currency: .ron, context: .personal, category: nil,
                        descriptionText: "chirie primită", merchant: nil, date: daysAgo(11),
                        source: .manual, direction: .income, counterparty: "Maria"),
            Transaction(amount: 800, currency: .ron, context: .personal, category: nil,
                        descriptionText: "împrumut", merchant: nil, date: daysAgo(7),
                        source: .manual, direction: .neutral, counterparty: "Andrei"),
            Transaction(amount: 250, currency: .ron, context: .personal, category: nil,
                        descriptionText: "plată Andrei", merchant: nil, date: daysAgo(9),
                        source: .manual, direction: .expense, counterparty: "Andrei"),

            // ── Previous month (feeds the trend comparison + 6M bars) ──
            Transaction(amount: 61, currency: .ron, context: .personal, category: .fuel,
                        descriptionText: "benzină", merchant: "Petrom",
                        date: daysAgo(38), rawTranscript: "șaizeci și unu lei benzină", source: .voice),
            Transaction(amount: 142, currency: .ron, context: .personal, category: .groceries,
                        descriptionText: "cumpărături", merchant: "Lidl",
                        date: daysAgo(42), source: .manual),
            Transaction(amount: 310, currency: .ron, context: .personal, category: .utilities,
                        descriptionText: "factură curent", merchant: "Enel",
                        date: daysAgo(46), source: .manual),

            // ── Older (2–4 months back; 6M / Year timeframes) ──
            Transaction(amount: 45, currency: .ron, context: .personal, category: .entertainment,
                        descriptionText: "cinema", merchant: nil,
                        date: daysAgo(75), source: .manual),
            Transaction(amount: 520, currency: .ron, context: .personal, category: .shopping,
                        descriptionText: "laptop", merchant: "eMAG",
                        date: daysAgo(110), source: .manual),
        ]

        for s in samples { ctx.insert(s) }

        // ── v1.2a Projects Core: two business projects, their assigned
        //    transactions, and scheduled money (one overdue) so the Projects tab
        //    renders a real portfolio header, cards, and an overdue badge. Cash is
        //    ONE pot — these transactions also count in the whole-portfolio totals.
        let manhattan = Project(name: "Proiect Manhattan", status: .active, colorIndex: 3, sortOrder: 0)
        let renovare = Project(name: "Renovare apartament", status: .active, colorIndex: 5, sortOrder: 1)
        ctx.insert(manhattan)
        ctx.insert(renovare)

        let projectTx: [Transaction] = [
            Transaction(amount: 8000, currency: .ron, context: .work, category: .utilities,
                        descriptionText: "avans constructor", date: daysAgo(20),
                        source: .manual, direction: .expense, counterparty: "Ion", projectID: manhattan.id),
            Transaction(amount: 15000, currency: .ron, context: .work,
                        descriptionText: "tranșă client", date: daysAgo(14),
                        source: .manual, direction: .income, counterparty: "Client SRL", projectID: manhattan.id),
            Transaction(amount: 3200, currency: .ron, context: .work, category: .shopping,
                        descriptionText: "materiale", merchant: "Dedeman", date: daysAgo(9),
                        source: .manual, direction: .expense, projectID: renovare.id),
            Transaction(amount: 500, currency: .eur, context: .work, category: .shopping,
                        descriptionText: "gresie import", date: daysAgo(5),
                        source: .manual, direction: .expense, projectID: renovare.id),
        ]
        for t in projectTx { ctx.insert(t) }

        func daysAhead(_ n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: now) ?? now }
        let scheduled: [ScheduledItem] = [
            ScheduledItem(direction: .outgoing, amount: 6000, currency: .ron,
                          title: "Plată Ion", counterparty: "Ion", dueDate: daysAgo(3),
                          projectID: manhattan.id),
            ScheduledItem(direction: .incoming, amount: 12000, currency: .ron,
                          title: "Avans client", counterparty: "Client SRL",
                          dueDate: daysAhead(10), projectID: manhattan.id),
            ScheduledItem(direction: .outgoing, amount: 2500, currency: .ron,
                          title: "Materiale suplimentare", counterparty: "Dedeman",
                          dueDate: daysAhead(20), projectID: renovare.id),
        ]
        for s in scheduled { ctx.insert(s) }

        // ── v2 SEAL: loans + a balance anchor + more receivables, so the
        //    Raport hub's bank Debt, investor Debt, and Owed-to-me sections all
        //    render populated in the screenshot matrix. Loans go through
        //    `LoanStore` (not hand-inserted) so the payment series and the
        //    booked interest/principal split are generated exactly as the real
        //    feature would.
        let bankLoan = Loan(
            name: "Credit ipotecar",
            lender: "Banca Transilvania",
            kind: .bank,
            principal: 250_000,
            currency: .ron,
            annualRatePercent: 7.9,
            startDate: calendar.date(byAdding: .month, value: -6, to: now) ?? now,
            termMonths: 240,
            projectID: manhattan.id
        )
        let bankPaymentItems = LoanStore.createLoan(bankLoan, calendar: calendar, in: ctx)
        // Book the first few payments so "sum owed left" / "% left" show real
        // progress instead of a fresh, untouched 100% loan.
        for item in bankPaymentItems.sorted(by: { $0.dueDate < $1.dueDate }).prefix(3) {
            LoanStore.bookPayment(item, loan: bankLoan, date: item.dueDate, calendar: calendar, in: ctx)
        }

        let investorLoan = Loan(
            name: "Capital privat",
            lender: "Mihai Ionescu",
            kind: .investor,
            principal: 80_000,
            currency: .ron,
            annualRatePercent: 12,
            startDate: calendar.date(byAdding: .month, value: -3, to: now) ?? now,
            termMonths: 36
        )
        LoanStore.createLoan(investorLoan, calendar: calendar, in: ctx)

        // Cash-truth anchor so the reconciliation-aware Position block has a
        // baseline to report against.
        ctx.insert(BalanceAnchor(
            amount: 18_450,
            currency: .ron,
            anchoredAt: daysAgo(2),
            note: "Sold verificat cont curent"
        ))

        // More pending, incoming, counterparty-bearing receivables (on top of
        // "Avans client" above) so Owed-to-me renders a multi-row list.
        let moreReceivables: [ScheduledItem] = [
            ScheduledItem(direction: .incoming, amount: 1500, currency: .ron,
                          title: "Rest chirie", counterparty: "Maria",
                          dueDate: daysAhead(5)),
            ScheduledItem(direction: .incoming, amount: 400, currency: .ron,
                          title: "Rest împrumut", counterparty: "Andrei",
                          dueDate: daysAhead(15)),
            ScheduledItem(direction: .incoming, amount: 950, currency: .ron,
                          title: "Decont deplasare", counterparty: "Firma ACME",
                          dueDate: daysAhead(2)),
        ]
        for r in moreReceivables { ctx.insert(r) }

        try? ctx.save()
    }
}
