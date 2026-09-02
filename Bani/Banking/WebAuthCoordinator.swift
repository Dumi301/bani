import AuthenticationServices
import UIKit

/// v2.3 — the `ASWebAuthenticationSession` bridge for the Enable Banking consent
/// hop (the app's ONLY web-auth seam; there was no prior pattern for it here).
/// Wraps the system's one-shot auth session in an `async` API and returns the
/// key window as its presentation anchor. NOT ephemeral
/// (`prefersEphemeralWebBrowserSession = false`): a bank's SCA step benefits
/// from existing session cookies, so a fresh private session would only add
/// friction.
///
/// Modelled on the house `QLPreviewController.Coordinator` pattern — a PLAIN
/// `NSObject` delegate (no actor annotation on the type) so the nonisolated
/// `presentationAnchor(for:)` protocol requirement is satisfied with no Swift 6
/// isolation mismatch, and it merely hands back an anchor captured up-front on
/// the MainActor (never touching `UIApplication.shared` from the nonisolated
/// callback). `authenticate(url:)` is `@MainActor` because
/// `ASWebAuthenticationSession` must be created and `start()`ed on the main
/// thread. `BankLinkView` makes one per link attempt and `await`s it.
final class WebAuthCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {

    /// Retains the in-flight session — `ASWebAuthenticationSession` holds only a
    /// WEAK `presentationContextProvider`, so without this the session (and its
    /// sheet) would be torn down the instant `authenticate` suspends.
    private var session: ASWebAuthenticationSession?
    /// Captured on the MainActor inside `authenticate` (before `start()`), so the
    /// nonisolated `presentationAnchor` callback never has to reach for a
    /// MainActor-isolated `UIApplication.shared`.
    private var anchor: ASPresentationAnchor!

    /// Present `url` in a system auth session bound to the `bani` callback
    /// scheme; resolves with the full callback URL
    /// (`bani://oauth/callback?code=…&state=…`). Surfaces the session's own
    /// `ASWebAuthenticationSessionError.canceledLogin` on user dismiss (the
    /// caller treats that as a silent reset), and `WebAuthError.couldNotStart`
    /// if the session refuses to present.
    @MainActor
    func authenticate(url: URL) async throws -> URL {
        anchor = Self.keyWindow()
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "bani") { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? WebAuthError.couldNotStart)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: WebAuthError.couldNotStart)
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }

    /// The current foreground key window (fallbacks: any window of the active
    /// scene, then a throwaway window). MainActor-isolated — only ever called
    /// from `authenticate`.
    @MainActor
    private static func keyWindow() -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? scene?.windows.first ?? UIWindow()
    }
}

/// The single non-cancel failure the coordinator raises itself (the session
/// refused to present); every other error is surfaced verbatim from the system.
enum WebAuthError: Error {
    case couldNotStart
}
