import SwiftUI
import SwiftData

/// A counterparty text field with PersonStore-backed suggestion chips (v1.3
/// "People registry"). Registered people surface FIRST, then distinct
/// historical counterparty strings not already in the registry
/// (`PersonStore.suggestions`); tapping a chip fills the string. Typed text
/// that doesn't (yet) match a registered person offers an explicit "add to
/// people" tap — the ONE deliberate, non-automatic way a free-text
/// counterparty becomes a registered `Person`.
///
/// Used at every counterparty entry surface: `ManualEntrySheet`,
/// `ScheduledItemEditSheet`, `TransactionEditSheet`.
struct PersonCounterpartyField: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var text: String
    /// Registered people's display names, resolved by the caller via `@Query`
    /// — this view stays a plain function of its inputs, no duplicate `@Query`
    /// per call site.
    let people: [String]
    /// Distinct historical counterparty strings (Transaction + ScheduledItem),
    /// resolved by the caller (`PersonStore.historicalCounterparties`).
    let historicalCounterparties: [String]
    /// The field's placeholder / label key — callers keep their prior copy.
    var placeholderKey: LocalizedStringKey = "field.counterparty"

    @State private var justAdded = false

    private var suggestions: [String] {
        PersonStore.suggestions(prefix: text, people: people, historicalCounterparties: historicalCounterparties)
    }

    /// The typed text doesn't match any REGISTERED person yet (it may still
    /// match a historical, unformalized counterparty — that's exactly the
    /// case "add to people" formalizes).
    private var offersAddPerson: Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        let key = PersonStore.normalizedKey(clean)
        return !people.contains { PersonStore.normalizedKey($0) == key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(placeholderKey, text: $text)
                .accessibilityIdentifier("counterpartyField")
                .onChange(of: text) { _, _ in justAdded = false }

            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { name in
                            Button(name) { text = name }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Palette.accent.opacity(0.12), in: Capsule())
                                .foregroundStyle(Palette.accent)
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("counterparty.suggestion")
                        }
                    }
                }
            }

            if offersAddPerson {
                Button {
                    PersonStore.findOrCreate(name: text, in: modelContext)
                    justAdded = true
                } label: {
                    Label(
                        justAdded ? String(localized: "people.addPerson.added") : String(localized: "people.addPerson.cta"),
                        systemImage: justAdded ? "checkmark.circle.fill" : "person.badge.plus"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(justAdded ? Palette.secondaryInk : Palette.accent)
                .disabled(justAdded)
                .accessibilityIdentifier("counterparty.addPersonButton")
            }
        }
    }
}
