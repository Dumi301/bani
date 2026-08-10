import UIKit
import UniformTypeIdentifiers

/// The deliberately-dumb share extension (Part B). Accepts a shared image (a bank
/// notification screenshot) or plain text, serializes it into the App Group
/// container via `SharedPayloadStore`, shows a minimal "Trimis către Bani ✓"
/// confirmation, and completes. NO SwiftData / OCR / WhisperKit / model code runs
/// here (extension memory limits); the main app drains + parses on next foreground.
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let label = UILabel()
        label.text = "Trimis către Bani ✓"
        label.font = .preferredFont(forTextStyle: .title3)
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])

        Task { await processAndFinish() }
    }

    @MainActor
    private func processAndFinish() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        for provider in providers {
            await store(provider)
        }
        // Let the confirmation land visibly before dismissing.
        try? await Task.sleep(for: .seconds(0.6))
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Serialize one attachment (image OR text) into the App Group container.
    @MainActor
    private func store(_ provider: NSItemProvider) async {
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = try? await provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) {
            SharedPayloadStore.writeImage(data)
            return
        }
        for type in [UTType.plainText, UTType.utf8PlainText, UTType.text, UTType.url] {
            guard provider.hasItemConformingToTypeIdentifier(type.identifier),
                  let data = try? await provider.loadDataRepresentation(forTypeIdentifier: type.identifier),
                  let text = String(data: data, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            SharedPayloadStore.writeText(text)
            return
        }
    }
}
