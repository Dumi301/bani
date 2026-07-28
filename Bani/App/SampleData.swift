import Foundation
import SwiftData

/// Deterministic sample transactions for UI-test screenshots. Phase-0 FROZEN.
/// Seeds via a fresh `ModelContext` (not `mainContext`) so it is safe to call
/// from `App.init` under Swift 6 strict concurrency.
enum SampleData {
    static func seed(into container: ModelContainer) {
        let ctx = ModelContext(container)

        let base = Date(timeIntervalSince1970: 1_753_000_000) // fixed for reproducible screenshots
        let samples: [Transaction] = [
            Transaction(amount: 52, currency: .ron, context: .personal, category: .fuel,
                        descriptionText: "benzină", merchant: "OMV",
                        date: base, rawTranscript: "cincizeci și doi de lei benzină", source: .voice),
            Transaction(amount: 18.5, currency: .ron, context: .personal, category: .dining,
                        descriptionText: "cafea", merchant: "Origo",
                        date: base.addingTimeInterval(-3600), rawTranscript: "optsprezece cincizeci lei cafea", source: .voice),
            Transaction(amount: 120, currency: .eur, context: .work, category: .transport,
                        descriptionText: "taxi aeroport", merchant: nil,
                        date: base.addingTimeInterval(-86_400), source: .manual),
            Transaction(amount: 240, currency: .ron, context: .work, category: .utilities,
                        descriptionText: "internet birou", merchant: "RCS",
                        date: base.addingTimeInterval(-172_800), source: .manual),
            Transaction(amount: 76.9, currency: .ron, context: .personal, category: .groceries,
                        descriptionText: "cumpărături", merchant: "Mega",
                        date: base.addingTimeInterval(-259_200), rawTranscript: "șaptezeci și șase nouăzeci lei cumpărături", source: .voice),
        ]

        for s in samples { ctx.insert(s) }
        try? ctx.save()
    }
}
