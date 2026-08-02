import SwiftUI

/// Segmented expense / income / neutral picker (A3). Shared by the manual sheet,
/// the confirmation card's edit mode, and the transaction edit sheet, so every
/// entry point sets direction identically.
struct DirectionPicker: View {
    @Binding var selection: TransactionDirection

    var body: some View {
        Picker("Direction", selection: $selection) {
            ForEach(TransactionDirection.allCases, id: \.self) { direction in
                Text(direction.label).tag(direction)
            }
        }
        .pickerStyle(.segmented)
        .tint(Palette.accent)
        .accessibilityIdentifier("directionPicker")
    }
}

/// A counterparty text field with tap-to-fill suggestions from the parties already
/// used (B2). Empty is fine — counterparty is optional everywhere.
struct CounterpartyField: View {
    @Binding var text: String
    let suggestions: [String]

    private var matches: [String] {
        let q = Categorizer.normalize(text)
        let pool = suggestions.filter { !$0.isEmpty }
        guard !q.isEmpty else { return Array(pool.prefix(6)) }
        return pool.filter { Categorizer.normalize($0).contains(q) && Categorizer.normalize($0) != q }.prefix(6).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(String(localized: "field.counterparty"), text: $text)
                .accessibilityIdentifier("counterpartyField")
            if !matches.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(matches, id: \.self) { name in
                            Button(name) { text = name }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Palette.accent.opacity(0.12), in: Capsule())
                                .foregroundStyle(Palette.accent)
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}
