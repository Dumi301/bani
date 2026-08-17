import SwiftUI
import SwiftData

/// A project's Documents pane: the attachments of this project's transactions,
/// using the existing attachment infrastructure (`AttachmentPreview`), filtered by
/// `projectID`. Tapping a row opens the transaction it belongs to.
struct ProjectDocumentsView: View {
    @Environment(\.metrics) private var metrics
    @Environment(\.locale) private var locale

    let projectID: UUID

    @Query(sort: \Transaction.date, order: .reverse) private var allTransactions: [Transaction]
    @Query private var customCategories: [CustomCategory]

    private var documented: [Transaction] {
        allTransactions.filter { $0.projectID == projectID && $0.attachmentID != nil }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: metrics.rowSpacing) {
                if documented.isEmpty {
                    emptyState
                } else {
                    ForEach(documented, id: \.id) { tx in
                        NavigationLink(value: tx) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(tx.descriptionText.isEmpty ? String(localized: "confirm.noDescription") : tx.descriptionText)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Palette.ink)
                                    Spacer()
                                    Text(tx.date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale)))
                                        .font(.caption2)
                                        .foregroundStyle(Palette.secondaryInk)
                                }
                                if let attachmentID = tx.attachmentID {
                                    AttachmentPreview(attachmentID: attachmentID)
                                }
                            }
                            .padding(metrics.cardPadding)
                            .metalSurface(cornerRadius: Radius.card)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, metrics.screenPadding)
            .padding(.vertical, metrics.elementSpacing)
        }
        .accessibilityIdentifier("project.documents.list")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 32))
                .foregroundStyle(Palette.secondaryInk)
            Text("project.documents.empty")
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryInk)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityIdentifier("project.documents.emptyState")
    }
}
