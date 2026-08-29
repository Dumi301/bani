import XCTest

/// Regression guard for the on-device crash where tapping Personal/Work on the
/// Log screen killed the app instantly (EXC_BREAKPOINT / SIGTRAP on the AVFAudio
/// "RealtimeMessenger.mServiceQueue"). Root cause: the `AVAudioEngine` input-tap
/// closure was inferred `@MainActor`-isolated, so Swift 6's dynamic executor
/// check trapped when AVFAudio invoked it on the realtime audio thread. The fix
/// makes that tap block `@Sendable` (nonisolated).
///
/// This test drives the real path: launch → navigate to Log (E1: Raport is
/// now the launch tab) → tap Personal → grant the mic permission alert →
/// record start, and asserts the app is STILL ALIVE ~2 s later — long enough
/// for the tap to fire real buffers on the audio thread, which is precisely
/// where the pre-fix build SIGTRAP'd.
///
/// NOTE: the iOS Simulator does NOT reliably reproduce realtime-audio-thread
/// isolation traps — it has no hardware render thread continuously driving the
/// tap — so a green run here is NOT, by itself, proof of the concurrency fix.
/// This test locks the launch / tap / permission / record-start wiring so it
/// can never silently regress; the concurrency fix itself is verified by code
/// review + the grep evidence recorded in `pipeline/build-notes.md` (the tap
/// closure is `@Sendable` / nonisolated and every cross-thread update hops
/// through `Task { @MainActor }`).
final class RecordingCrashRegressionUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTappingPersonalStartsRecordingAndSurvives() {
        let app = XCUIApplication()
        // `-modelAbsent` skips the first-launch download screen so the Log tab
        // (and its record buttons) is reachable immediately; `-forceRuleParser`
        // keeps any post-stop path deterministic. Recording START — where the
        // crash lived — needs no model at all.
        app.launchArguments = ["-uiTesting", "-modelAbsent", "-forceRuleParser"]

        // Apple-sanctioned handler for the system mic-permission alert. Registered
        // as the fallback; the Springboard drive below is the deterministic path.
        addUIInterruptionMonitor(withDescription: "Microphone permission") { alert in
            for label in ["Allow", "OK", "Allow While Using App"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }

        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))

        // E1: the launch tab flipped to Raport — navigate to Log (tab index 1)
        // to reach the Personal record button this regression guard drives.
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "tab bar should exist")
        tabBar.buttons.element(boundBy: 1).tap()

        let personalButton = app.buttons["logView.personalButton"]
        XCTAssertTrue(personalButton.waitForExistence(timeout: 10),
                      "Log screen with the Personal record button should be shown after navigating to the Log tab")
        personalButton.tap()

        // Grant the permission alert deterministically through Springboard — more
        // reliable than depending on the interruption monitor, which only fires on
        // the next app interaction (and every interaction inside the recording
        // screen is "tap to stop", which would cancel the recording we want to
        // observe). If mic access was already granted in a prior run, no alert
        // appears and we simply fall through.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let grantButton = springboard.buttons
            .matching(NSPredicate(format: "label IN %@", ["Allow", "OK", "Allow While Using App"]))
            .firstMatch
        if grantButton.waitForExistence(timeout: 8) {
            grantButton.tap()
        }

        // Reaching the recording screen proves beginRecording() ran and the audio
        // tap installed without trapping on entry.
        let recordingScreen = app.descendants(matching: .any)["recordingView.root"]
        XCTAssertTrue(recordingScreen.waitForExistence(timeout: 10),
                      "Recording screen should appear after granting microphone permission")

        // THE crash guard: give the render thread ~2 s to actually fire tap
        // buffers, then assert the process is still alive. Pre-fix, the app
        // SIGTRAP'd here the instant the first buffer hit the @MainActor tap.
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertEqual(app.state, .runningForeground,
                       "App must stay alive during recording — no audio-thread isolation trap")
    }
}
