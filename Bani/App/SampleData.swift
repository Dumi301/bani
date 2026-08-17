import Foundation
import SwiftData

/// Deterministic sample transactions for UI-test screenshots. Anchored to the
/// launch date (not a fixed epoch) and spread across ~4 months so the Finances
/// analytics view (D) always has data in the default Month timeframe — a rich
/// donut, non-empty bars, and a previous-period line — regardless of when CI
/// runs. Seeds via a fresh `ModelContext` (not `mainContext`) so it is safe to
/// call from `App.init` under Swift 6 strict concurrency.
///
/// A current-month `benzină` / Personal entry is always present: the detail-view
/// UI test taps it to open the read-first detail screen.
enum SampleData {
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

        try? ctx.save()
    }
}
