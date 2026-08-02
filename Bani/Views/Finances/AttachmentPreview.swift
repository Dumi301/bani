import SwiftUI
import QuickLook
import PDFKit

/// The imported-document attachment section on a transaction's detail (E2): a
/// tappable preview card (opens full screen via QuickLook) + the 2–3 sentence
/// extraction summary beneath it. Renders nothing when the attachment file is
/// missing (e.g. deleted out from under us).
struct AttachmentPreview: View {
    @Environment(\.metrics) private var metrics
    let attachmentID: UUID

    @State private var isFullScreen = false

    private var url: URL? { AttachmentStore.originalURL(id: attachmentID) }
    private var summary: String? { AttachmentStore.summary(id: attachmentID) }
    private var fileName: String { AttachmentStore.originalFileName(id: attachmentID) ?? String(localized: "detail.attachment") }

    var body: some View {
        if let url {
            VStack(alignment: .leading, spacing: metrics.elementSpacing) {
                Text("detail.attachment")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.secondaryInk)

                Button { isFullScreen = true } label: {
                    HStack(spacing: 12) {
                        thumbnail(url)
                            .frame(width: 46, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(fileName)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1)
                            Text("detail.attachment.tapToView")
                                .font(.caption)
                                .foregroundStyle(Palette.accent)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .foregroundStyle(Palette.secondaryInk)
                    }
                    .padding(metrics.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .metalSurface(cornerRadius: Radius.card)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("detail.attachmentButton")

                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("detail.attachmentSummary")
                }
            }
            .fullScreenCover(isPresented: $isFullScreen) {
                QuickLookView(url: url) { isFullScreen = false }
                    .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private func thumbnail(_ url: URL) -> some View {
        if let image = AttachmentThumbnail.make(url: url) {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Palette.canvas
                Image(systemName: "doc.text.fill").foregroundStyle(Palette.secondaryInk)
            }
        }
    }
}

/// Renders a small thumbnail for the attachment (first PDF page or the image).
enum AttachmentThumbnail {
    static func make(url: URL, size: CGSize = CGSize(width: 92, height: 120)) -> UIImage? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf", let doc = PDFDocument(url: url), let page = doc.page(at: 0) {
            return page.thumbnail(of: size, for: .mediaBox)
        }
        if ["png", "jpg", "jpeg", "heic", "heif"].contains(ext), let data = try? Data(contentsOf: url) {
            return UIImage(data: data)
        }
        return nil
    }
}

/// A minimal `QLPreviewController` wrapper for the full-screen document preview.
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(url: url, onDismiss: onDismiss) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: context.coordinator, action: #selector(Coordinator.dismiss)
        )
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        let onDismiss: () -> Void
        init(url: URL, onDismiss: @escaping () -> Void) { self.url = url; self.onDismiss = onDismiss }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
        @objc func dismiss() { onDismiss() }
    }
}
