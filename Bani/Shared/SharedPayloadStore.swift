import Foundation

/// One capture handed from the share extension to the main app. PURE Foundation —
/// NO SwiftData / model code — so it is safe to compile into the deliberately-dumb
/// extension. Serialized as JSON into the App Group container (image bytes go in a
/// sibling blob file); the app drains + parses it on next foreground.
enum SharedCaptureKind: String, Codable, Sendable {
    case image
    case text
}

struct SharedCapturePayload: Codable, Sendable, Equatable {
    let id: UUID
    let kind: SharedCaptureKind
    let text: String?
    let imageFilename: String?
    let receivedAt: Date
}

/// The App Group handoff store. Compiled into BOTH the share extension (writes) and
/// the main app (drains). The App-Group-facing API resolves the shared container;
/// the directory-injectable core is what `AppGroupRoundTripTests` exercises with a
/// temp directory (the container is unavailable in the simulator, so the round-trip
/// is proven on the pure function).
enum SharedPayloadStore {
    static let appGroupID = "group.com.dumi.bani"

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// The captures directory inside the App Group container, or `nil` when the
    /// group is not provisioned (e.g. the CI simulator) — callers no-op safely.
    static var directory: URL? {
        containerURL?.appendingPathComponent("SharedCaptures", isDirectory: true)
    }

    // MARK: - App-Group-facing API (extension writes / app drains)

    @discardableResult
    static func writeText(_ text: String) -> Bool {
        guard let dir = directory else { return false }
        return writeText(text, to: dir)
    }

    @discardableResult
    static func writeImage(_ data: Data) -> Bool {
        guard let dir = directory else { return false }
        return writeImage(data, to: dir)
    }

    static func drain() -> [Drained] {
        guard let dir = directory else { return [] }
        return drain(from: dir)
    }

    // MARK: - Directory-injectable core (unit-tested)

    struct Drained: Equatable {
        let payload: SharedCapturePayload
        let imageData: Data?
    }

    @discardableResult
    static func writeText(_ text: String, to dir: URL) -> Bool {
        write(SharedCapturePayload(id: UUID(), kind: .text, text: text, imageFilename: nil, receivedAt: Date()),
              imageData: nil, to: dir)
    }

    @discardableResult
    static func writeImage(_ data: Data, to dir: URL) -> Bool {
        let filename = "\(UUID().uuidString).img"
        return write(SharedCapturePayload(id: UUID(), kind: .image, text: nil, imageFilename: filename, receivedAt: Date()),
                     imageData: data, to: dir)
    }

    @discardableResult
    static func write(_ payload: SharedCapturePayload, imageData: Data?, to dir: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let imageData, let filename = payload.imageFilename {
                try imageData.write(to: dir.appendingPathComponent(filename))
            }
            let json = try JSONEncoder().encode(payload)
            try json.write(to: dir.appendingPathComponent("\(payload.id.uuidString).json"))
            return true
        } catch {
            return false
        }
    }

    /// Read AND remove every pending capture (processed once), oldest first.
    static func drain(from dir: URL) -> [Drained] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [Drained] = []
        for jsonURL in files where jsonURL.pathExtension == "json" {
            defer { try? FileManager.default.removeItem(at: jsonURL) }
            guard let data = try? Data(contentsOf: jsonURL),
                  let payload = try? JSONDecoder().decode(SharedCapturePayload.self, from: data)
            else { continue }
            var imageData: Data?
            if let filename = payload.imageFilename {
                let imgURL = dir.appendingPathComponent(filename)
                imageData = try? Data(contentsOf: imgURL)
                try? FileManager.default.removeItem(at: imgURL)
            }
            out.append(Drained(payload: payload, imageData: imageData))
        }
        return out.sorted { $0.payload.receivedAt < $1.payload.receivedAt }
    }
}
