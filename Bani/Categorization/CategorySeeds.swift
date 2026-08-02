import Foundation

/// The seed keyword → category table inserted on first launch (see
/// `CategoryRuleStore.seedIfNeeded`). Keywords are ALREADY normalized
/// (lowercased + diacritic-folded) to match `Categorizer.normalize` at match
/// time — "benzină" is stored as "benzina".
///
/// Grounded in Romanian day-to-day spending (chains, fuel brands, utilities)
/// with the common English equivalents alongside, so both a Romanian and an
/// English utterance land in the same bucket. ~80 seeds, balanced across the
/// nine presets.
enum CategorySeeds {
    static let table: [(keyword: String, category: TransactionCategory)] = [
        // fuel
        ("benzina", .fuel), ("motorina", .fuel), ("carburant", .fuel),
        ("omv", .fuel), ("petrom", .fuel), ("mol", .fuel), ("rompetrol", .fuel),
        ("lukoil", .fuel), ("diesel", .fuel), ("fuel", .fuel),
        ("peco", .fuel), ("combustibil", .fuel), ("plin", .fuel),

        // groceries
        ("lidl", .groceries), ("kaufland", .groceries), ("mega", .groceries),
        ("carrefour", .groceries), ("profi", .groceries), ("penny", .groceries),
        ("auchan", .groceries), ("piata", .groceries), ("supermarket", .groceries),
        ("cumparaturi", .groceries), ("groceries", .groceries),
        ("alimente", .groceries), ("mancare", .groceries), ("selgros", .groceries),

        // dining
        ("restaurant", .dining), ("pizza", .dining), ("cafea", .dining),
        ("shaorma", .dining), ("kfc", .dining), ("mcdonalds", .dining),
        ("burger", .dining), ("cafenea", .dining), ("starbucks", .dining),
        ("dining", .dining), ("coffee", .dining), ("bar", .dining), ("bistro", .dining),

        // transport
        ("taxi", .transport), ("uber", .transport), ("bolt", .transport),
        ("stb", .transport), ("metrou", .transport), ("parcare", .transport),
        ("autobuz", .transport), ("tren", .transport), ("bilet", .transport),
        ("transport", .transport), ("rovinieta", .transport), ("cfr", .transport),

        // utilities
        ("enel", .utilities), ("engie", .utilities), ("digi", .utilities),
        ("factura", .utilities), ("chirie", .utilities), ("curent", .utilities),
        ("gaz", .utilities), ("apa", .utilities), ("internet", .utilities),
        ("intretinere", .utilities), ("utilities", .utilities),
        ("gunoi", .utilities), ("salubritate", .utilities), ("rca", .utilities),

        // shopping
        ("emag", .shopping), ("altex", .shopping), ("flanco", .shopping),
        ("ikea", .shopping), ("decathlon", .shopping), ("zara", .shopping),
        ("haine", .shopping), ("pantofi", .shopping), ("mall", .shopping),
        ("shopping", .shopping), ("mobila", .shopping), ("mofturi", .shopping),

        // health
        ("farmacie", .health), ("catena", .health), ("sensiblu", .health),
        ("dona", .health), ("doctor", .health), ("medic", .health),
        ("spital", .health), ("dentist", .health), ("health", .health),
        ("clinica", .health), ("analize", .health), ("stomatolog", .health),

        // entertainment
        ("cinema", .entertainment), ("netflix", .entertainment), ("spotify", .entertainment),
        ("film", .entertainment), ("hbo", .entertainment), ("disney", .entertainment),
        ("concert", .entertainment), ("teatru", .entertainment), ("joc", .entertainment),
        ("entertainment", .entertainment),
    ]
}
