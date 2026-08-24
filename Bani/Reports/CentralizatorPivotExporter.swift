import Foundation

/// One-way export #2: the category count/sum pivot — the highest-value corpus shape
/// (`pipeline/client-format-spec.md` §3.1, Family C `Sheet4`: Row Labels =
/// `CATEGORIE`, measures = count of debit / credit, trivially extended to sum, with
/// a Grand-Total row). Debit = money out (expenses), Credit = money in (income);
/// neutral flows (transfers / loan principal) are excluded, exactly as they are from
/// every position total.
///
/// Pure: it pivots value-typed input rows into a cell grid, then hands off to
/// `XLSXWriter`. Golden-file + round-trip proven in `RaportExportTests`.
enum CentralizatorPivotExporter {

    /// One categorised flow: its resolved category display name, RON amount, and
    /// whether it is a credit (income) — an expense is a debit.
    struct Row: Equatable, Sendable {
        var category: String
        var amount: Decimal
        var isCredit: Bool
    }

    /// The worksheet tab name.
    static let sheetName = "Centralizator"

    /// The RO header row.
    static let header: [String] = ["CATEGORIE", "Nr. debit", "Nr. credit", "Debit", "Credit"]

    /// The label of the grand-total footer row.
    static let grandTotalLabel = "TOTAL GENERAL"

    private struct Bucket {
        var debitCount = 0
        var creditCount = 0
        var debitSum: Decimal = 0
        var creditSum: Decimal = 0
    }

    /// Pivot the input rows into the cell grid: header, one row per category (Row
    /// Labels ascending, deterministic), then a grand-total row.
    static func rows(_ input: [Row]) -> [[XLSXCell]] {
        var buckets: [String: Bucket] = [:]
        var order: [String] = []
        for row in input {
            if buckets[row.category] == nil { order.append(row.category) }
            var bucket = buckets[row.category] ?? Bucket()
            if row.isCredit {
                bucket.creditCount += 1
                bucket.creditSum += row.amount
            } else {
                bucket.debitCount += 1
                bucket.debitSum += row.amount
            }
            buckets[row.category] = bucket
        }

        var rows: [[XLSXCell]] = [header.map { XLSXCell.text($0) }]
        var grand = Bucket()
        for category in order.sorted() {
            guard let bucket = buckets[category] else { continue }
            rows.append([
                .text(category),
                .number(Decimal(bucket.debitCount)),
                .number(Decimal(bucket.creditCount)),
                .number(bucket.debitSum),
                .number(bucket.creditSum),
            ])
            grand.debitCount += bucket.debitCount
            grand.creditCount += bucket.creditCount
            grand.debitSum += bucket.debitSum
            grand.creditSum += bucket.creditSum
        }
        rows.append([
            .text(grandTotalLabel),
            .number(Decimal(grand.debitCount)),
            .number(Decimal(grand.creditCount)),
            .number(grand.debitSum),
            .number(grand.creditSum),
        ])
        return rows
    }

    /// The finished `.xlsx` bytes.
    static func xlsx(_ input: [Row]) -> Data {
        XLSXWriter.workbook(sheetName: sheetName, rows: rows(input))
    }
}
