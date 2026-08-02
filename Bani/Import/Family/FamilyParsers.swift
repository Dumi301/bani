import Foundation

/// The outcome of parsing one family sheet.
struct FamilyParseOutcome: Sendable, Equatable {
    var drafts: [DraftTransaction]
    var skipped: [SkippedImportRow]
    var negativesFound: Bool = false
}

/// Shared category resolution for the family parsers: the OBSERVATII/description
/// vocabulary first (→ a seeded custom, assertable in the pure oracle), then the
/// preset seed keywords, else defer to by-description categorization at commit.
enum FamilyCategory {
    static func resolve(_ text: String) -> DraftCategory {
        let n = Categorizer.normalize(text)
        if let sc = ObservatiiVocabulary.match(n) { return .seededCustom(sc) }
        if let preset = presetSeedMatch(n) { return .preset(preset) }
        return .byDescription
    }

    /// A preset category when a token of `normalized` equals a `CategorySeeds`
    /// keyword (longest token wins for determinism).
    static func presetSeedMatch(_ normalized: String) -> TransactionCategory? {
        let tokens = Set(Categorizer.tokenize(normalized))
        var best: (String, TransactionCategory)?
        for seed in CategorySeeds.table where tokens.contains(seed.keyword) {
            if seed.keyword.count > (best?.0.count ?? 0) { best = (seed.keyword, seed.category) }
        }
        return best?.1
    }
}

/// Common helpers over a raw sheet's header row.
private extension RawSheet {
    /// 0-based column whose header cell folds to exactly `name`.
    func column(exact name: String, in headerRow: Int) -> Int? {
        guard headerRow < rows.count else { return nil }
        return rows[headerRow].cells.firstIndex { Categorizer.normalize($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) == name }
    }
    /// 0-based column whose folded header cell contains `substr`.
    func column(contains substr: String, in headerRow: Int) -> Int? {
        guard headerRow < rows.count else { return nil }
        return rows[headerRow].cells.firstIndex { Categorizer.normalize($0.text).contains(substr) }
    }
}

// MARK: - Dispatcher

enum FamilyParser {
    static func parse(sheet: RawSheet, family: ImportFamily, headerRow: Int) -> FamilyParseOutcome {
        switch family {
        case .a: return FamilyAParser.parse(sheet, headerRow: headerRow)
        case .b: return FamilyBParser.parse(sheet, headerRow: headerRow)
        case .c: return FamilyCParser.parse(sheet, headerRow: headerRow)
        case .d: return FamilyDParser.parse(sheet, headerRow: headerRow)
        }
    }
}

// MARK: - Family A — Investment Tracker

enum FamilyAParser {
    /// Footer labels that end the transaction block (excluded from rows).
    static let footerLeads: Set<String> = ["total", "pret vanzare", "profit"]

    static func parse(_ sheet: RawSheet, headerRow: Int) -> FamilyParseOutcome {
        let dateCol = sheet.column(contains: "data", in: headerRow) ?? 0
        let amountCol = sheet.column(contains: "investitii", in: headerRow)
            ?? sheet.column(contains: "cheltuieli", in: headerRow) ?? 1
        let obsCol = sheet.column(contains: "observatii", in: headerRow) ?? 4

        var drafts: [DraftTransaction] = []
        var skipped: [SkippedImportRow] = []
        var negatives = false
        var lastDate: Date?

        for row in sheet.rows where row.sourceRow > sheet.rows[headerRow].sourceRow {
            let lead = Categorizer.normalize(row.text(at: 0))
            let obs = row.text(at: obsCol).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawAmount = row.text(at: amountCol)
            // Footer / totals rows.
            if footerLeads.contains(where: { lead.hasPrefix($0) }) { continue }
            if row.isBlank { continue }

            // Forward-fill the date [bug #1] + comma dates [bug #3].
            if let d = FamilyDates.parse(row.cell(at: dateCol) ?? SheetCell(text: "")) { lastDate = d }
            guard let date = lastDate else {
                skipped.append(SkippedImportRow(sourceRow: row.sourceRow, reason: .missingDate, rawDate: row.text(at: dateCol), rawAmount: rawAmount, rawDescription: obs))
                continue
            }
            guard let amt = AmountLexer.parseCell(rawAmount) else {
                if rawAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    skipped.append(SkippedImportRow(sourceRow: row.sourceRow, reason: .missingAmount, rawDate: row.text(at: dateCol), rawAmount: rawAmount, rawDescription: obs))
                } else {
                    skipped.append(SkippedImportRow(sourceRow: row.sourceRow, reason: .unparseableAmount, rawDate: row.text(at: dateCol), rawAmount: rawAmount, rawDescription: obs))
                }
                continue
            }
            if amt.isNegative { negatives = true }
            let description = obs.isEmpty ? String(localized: "import.row.noLabel") : obs

            // Category: A is real-estate → 'comision' means AGENCY commission (C3).
            var category = FamilyCategory.resolve(obs)
            if case .seededCustom(.comisioaneBancare) = category { category = .seededCustom(.comisionAgentie) }

            drafts.append(DraftTransaction(
                date: date, amount: amt.magnitude, currency: .ron,
                direction: .expense, descriptionText: description,
                counterparty: nil, context: .work, category: category, sourceRow: row.sourceRow
            ))
        }
        return FamilyParseOutcome(drafts: drafts, skipped: skipped, negativesFound: negatives)
    }
}

// MARK: - Family B — Raiffeisen statement

enum FamilyBParser {
    static func parse(_ sheet: RawSheet, headerRow: Int) -> FamilyParseOutcome {
        let dateCol = sheet.column(contains: "data tranzactiei", in: headerRow)
            ?? sheet.column(contains: "data inregistrare", in: headerRow) ?? 0
        let debitCol = sheet.column(contains: "suma debit", in: headerRow) ?? 2
        let creditCol = sheet.column(contains: "suma credit", in: headerRow) ?? 3
        let descCol = sheet.column(contains: "descrierea", in: headerRow) ?? (sheet.rows[headerRow].cells.count - 1)
        let partyCol = sheet.column(contains: "nume", in: headerRow)

        var drafts: [DraftTransaction] = []
        var skipped: [SkippedImportRow] = []
        var lastDate: Date?

        for row in sheet.rows where row.sourceRow > sheet.rows[headerRow].sourceRow {
            if row.isBlank { continue }
            let desc = row.text(at: descCol).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawDebit = row.text(at: debitCol)
            let rawCredit = row.text(at: creditCol)
            let debit = AmountLexer.parseCell(rawDebit)
            let credit = AmountLexer.parseCell(rawCredit)

            if let d = FamilyDates.parse(row.cell(at: dateCol) ?? SheetCell(text: "")) { lastDate = d }
            guard let date = lastDate else {
                skipped.append(SkippedImportRow(sourceRow: row.sourceRow, reason: .missingDate, rawDate: row.text(at: dateCol), rawAmount: "\(rawDebit)/\(rawCredit)", rawDescription: desc))
                continue
            }
            guard let amount = (debit ?? credit)?.magnitude else {
                skipped.append(SkippedImportRow(sourceRow: row.sourceRow, reason: .missingAmount, rawDate: row.text(at: dateCol), rawAmount: "\(rawDebit)/\(rawCredit)", rawDescription: desc))
                continue
            }
            let direction = DirectionResolver.resolve(debit: debit != nil, credit: credit != nil, marker: desc)
            let party = partyCol.map { row.text(at: $0).trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            let description = desc.isEmpty ? String(localized: "import.row.noLabel") : desc

            // Bank family → 'comision' is a BANK FEE (default vocab already maps there).
            let category = FamilyCategory.resolve(desc)
            drafts.append(DraftTransaction(
                date: date, amount: amount, currency: .ron,
                direction: direction, descriptionText: description,
                counterparty: party, context: .work, category: category, sourceRow: row.sourceRow
            ))
        }
        return FamilyParseOutcome(drafts: drafts, skipped: skipped)
    }
}

// MARK: - Family C — Centralizator ledger

enum FamilyCParser {
    static func parse(_ sheet: RawSheet, headerRow: Int) -> FamilyParseOutcome {
        let monedaCol = sheet.column(exact: "moneda", in: headerRow) ?? 1
        let dataCol = sheet.column(exact: "data", in: headerRow) ?? sheet.column(contains: "data", in: headerRow) ?? 2
        let explicatiiCol = sheet.column(contains: "explicatii", in: headerRow) ?? 3
        let debitValutaCol = sheet.column(exact: "debit valuta", in: headerRow) ?? 4
        let creditValutaCol = sheet.column(exact: "credit valuta", in: headerRow) ?? 5
        let debitRonCol = sheet.column(exact: "debit", in: headerRow) ?? 7
        let creditRonCol = sheet.column(exact: "credit", in: headerRow) ?? 8
        let categorieCol = sheet.column(exact: "categorie", in: headerRow) ?? 9

        var drafts: [DraftTransaction] = []
        var skipped: [SkippedImportRow] = []

        for row in sheet.rows where row.sourceRow > sheet.rows[headerRow].sourceRow {
            if row.isBlank { continue }
            let moneda = ImportRowParser.parseCurrency(row.text(at: monedaCol)) ?? .ron
            let explicatii = row.text(at: explicatiiCol).trimmingCharacters(in: .whitespacesAndNewlines)
            let categorieRaw = row.text(at: categorieCol).trimmingCharacters(in: .whitespacesAndNewlines)

            // H3 — EUR rows use the native VALUTA columns; RON rows the RON columns.
            let debitCol = moneda == .eur ? debitValutaCol : debitRonCol
            let creditCol = moneda == .eur ? creditValutaCol : creditRonCol
            let debit = AmountLexer.parseCell(row.text(at: debitCol))
            let credit = AmountLexer.parseCell(row.text(at: creditCol))

            guard let date = FamilyDates.parse(row.cell(at: dataCol) ?? SheetCell(text: "")) else {
                skipped.append(SkippedImportRow(sourceRow: row.sourceRow, reason: .missingDate, rawDate: row.text(at: dataCol), rawAmount: "", rawDescription: explicatii))
                continue
            }
            guard let amount = (debit ?? credit)?.magnitude else {
                skipped.append(SkippedImportRow(sourceRow: row.sourceRow, reason: .missingAmount, rawDate: row.text(at: dataCol), rawAmount: "", rawDescription: explicatii))
                continue
            }

            let mapped = mapCategorie(categorieRaw)
            let direction: TransactionDirection = mapped.neutral
                ? .neutral
                : (credit != nil && debit == nil ? .income : .expense)
            let description = explicatii.isEmpty ? categorieRaw : explicatii

            drafts.append(DraftTransaction(
                date: date, amount: amount, currency: moneda,
                direction: direction, descriptionText: description,
                counterparty: mapped.counterparty, context: .work,
                category: mapped.category, sourceRow: row.sourceRow
            ))
        }
        return FamilyParseOutcome(drafts: drafts, skipped: skipped)
    }

    /// Map a `CATEGORIE` value → (category token, counterparty, neutral flag).
    /// Per-counterparty singletons collapse to Plăți/Încasări/Împrumuturi (C4)
    /// with the person moved to the counterparty field (B2).
    static func mapCategorie(_ raw: String) -> (category: DraftCategory, counterparty: String?, neutral: Bool) {
        let upper = raw.uppercased()
        func tail(after prefix: String) -> String? {
            let name = String(raw.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
        if upper.hasPrefix("RESTITUIRE IMPRUMUT ") { return (.seededCustom(.imprumuturi), tail(after: "RESTITUIRE IMPRUMUT "), true) }
        if upper == "RESTITUIRE IMPRUMUT" || upper == "IMPRUMUT" { return (.seededCustom(.imprumuturi), nil, true) }
        if upper.hasPrefix("IMPRUMUT ") { return (.seededCustom(.imprumuturi), tail(after: "IMPRUMUT "), true) }
        if upper.hasPrefix("INCASARE ") { return (.seededCustom(.incasariPersoane), tail(after: "INCASARE "), false) }
        if upper.hasPrefix("PLATA ") { return (.seededCustom(.platiPersoane), tail(after: "PLATA "), false) }
        let n = Categorizer.normalize(raw)
        if n == "transfer" { return (.seededCustom(.transferNumerar), nil, true) }
        if n.contains("retragere numerar") || n.contains("depunere numerar") { return (.seededCustom(.transferNumerar), nil, true) }
        if n == "comision" { return (.seededCustom(.comisioaneBancare), nil, false) }
        if n.contains("cheltuieli personale") { return (.seededCustom(.cheltuieliPersonale), nil, false) }
        if n == "salariu" || n.hasPrefix("salariu") { return (.seededCustom(.salariuIncasari), nil, false) }
        if n == "incasare" { return (.seededCustom(.salariuIncasari), nil, false) }
        if n == "dobanda" { return (.seededCustom(.dobanda), nil, false) }
        return (FamilyCategory.resolve(raw), nil, DirectionResolver.isNeutral(n))
    }
}

// MARK: - Family D — Cheltuieli lunare (monthly detail)

enum FamilyDParser {
    static let footerLeads: Set<String> = ["total", "buget estimat", "depasire"]

    static func parse(_ sheet: RawSheet, headerRow: Int) -> FamilyParseOutcome {
        let header = sheet.rows[headerRow]
        let obsCol = header.cells.firstIndex { Categorizer.normalize($0.text).contains("observatii") } ?? (header.cells.count - 1)
        let dateCol = 0

        // column → category map (skip col 0 = DATA and the Observatii col).
        var columnCategory: [Int: TransactionCategory] = [:]
        for (idx, cell) in header.cells.enumerated() where idx != dateCol && idx != obsCol {
            columnCategory[idx] = categoryForColumn(Categorizer.normalize(cell.text))
        }

        var drafts: [DraftTransaction] = []
        var skipped: [SkippedImportRow] = []
        var lastDate: Date?

        for row in sheet.rows where row.sourceRow > header.sourceRow {
            if row.isBlank { continue }
            let lead = Categorizer.normalize(row.text(at: 0))
            if footerLeads.contains(where: { lead.hasPrefix($0) }) { continue }

            if let d = FamilyDates.parse(row.cell(at: dateCol) ?? SheetCell(text: "")) { lastDate = d }
            let obs = row.text(at: obsCol).trimmingCharacters(in: .whitespacesAndNewlines)

            // The amount lands in exactly one bucket column.
            var amountCol: Int?
            var amount: Decimal?
            for idx in columnCategory.keys.sorted() {
                if let a = AmountLexer.parseCell(row.text(at: idx)) { amountCol = idx; amount = a.magnitude; break }
            }
            guard let amount, let amountCol else { continue }   // a non-amount detail row
            guard let date = lastDate else {
                skipped.append(SkippedImportRow(sourceRow: row.sourceRow, reason: .missingDate, rawDate: row.text(at: dateCol), rawAmount: "\(amount)", rawDescription: obs))
                continue
            }
            let category = columnCategory[amountCol] ?? .other
            let headerName = header.text(at: amountCol)
            let description = obs.isEmpty ? headerName : obs

            drafts.append(DraftTransaction(
                date: date, amount: amount, currency: .ron,
                direction: .expense, descriptionText: description,
                counterparty: nil, context: .personal,       // H1 — Family D → Personal
                category: .preset(category), sourceRow: row.sourceRow
            ))
        }
        return FamilyParseOutcome(drafts: drafts, skipped: skipped)
    }

    static func categoryForColumn(_ folded: String) -> TransactionCategory {
        if folded.contains("utilitati") { return .utilities }
        if folded.contains("combustibil") { return .fuel }
        if folded.contains("mancare") { return .groceries }
        if folded.contains("diverse") { return .shopping }
        if folded.contains("necesare") { return .other }
        return .other
    }
}
