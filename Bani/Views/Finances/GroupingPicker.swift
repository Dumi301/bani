import SwiftUI

/// How the Finances transaction list is grouped into sections.
/// Remembered across launches via `@AppStorage("financesGrouping")` (owned by `FinancesView`).
enum TransactionGrouping: String, CaseIterable, Identifiable, Sendable {
    case category
    case month
    case merchant

    var id: String { rawValue }

    var label: String {
        switch self {
        case .category: String(localized: "grouping.category")
        case .month: String(localized: "grouping.month")
        case .merchant: String(localized: "grouping.merchant")
        }
    }
}

/// Segmented picker for choosing how the Finances list is grouped.
struct GroupingPicker: View {
    @Binding var selection: TransactionGrouping

    var body: some View {
        Picker("Group by", selection: $selection) {
            ForEach(TransactionGrouping.allCases) { grouping in
                Text(grouping.label).tag(grouping)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("financesGroupingPicker")
    }
}

#Preview {
    GroupingPicker(selection: .constant(.category))
        .padding()
}
