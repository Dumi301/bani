import SwiftUI
import SwiftData
import UIKit

/// The Log tab. Two large Personal / Work buttons fill most of the screen;
/// tapping either starts recording IMMEDIATELY — no intermediate screen. A
/// keyboard icon opens `ManualEntrySheet` (zero Whisper dependency).
///
/// Owns Unit C's cross-unit integration seam end to end:
/// `Recorder` (constructed here) → `WhisperService` (injected) →
/// `TransactionParsing` (constructed here) → `ConfirmationCard` → save.
struct LogView: View {
    @Environment(WhisperService.self) private var whisper
    @Environment(\.modelContext) private var modelContext

    /// Constructed once per view identity. `-forceRuleParser` (test seam,
    /// see interfaces.md) forces the deterministic rule-based parser + refiner;
    /// otherwise Foundation Models with a silent rule-based fallback.
    private let parser: any TransactionParsing
    /// The A1 refinement stage — same availability selection as the parser.
    private let refiner: any TranscriptRefiner

    @State private var stage: Stage = .idle
    @State private var recorder: Recorder?
    @State private var activeContext: TransactionContext = .personal
    @State private var showManualEntry = false

    init() {
        if ProcessInfo.processInfo.arguments.contains("-forceRuleParser") {
            parser = RuleBasedParser()
            refiner = RuleBasedRefiner()
        } else {
            parser = FoundationModelsParser(fallback: RuleBasedParser())
            refiner = FoundationModelsRefiner(fallback: RuleBasedRefiner())
        }
    }

    /// Everything the confirmation card needs, pre-computed on the main actor when
    /// the pipeline finishes so the card's chip, context, and trust flow are all
    /// resolved the instant it appears.
    private struct ConfirmationSetup: Equatable {
        var result: VoicePipelineResult
        var categoryRef: CategoryRef
        var context: TransactionContext
        var autoContextApplied: Bool
        var firedRuleID: UUID?
        var trusted: Bool
    }

    /// Local flow state. `Equatable` so `.onChange`/`.animation` can key off it.
    /// `.confirming` carries the categorizer's guess so the card's chip is
    /// pre-filled from the moment it appears (Q2 — never blank).
    private enum Stage: Equatable {
        case idle
        case recording
        case processing
        case micDenied
        case confirming(ConfirmationSetup)
    }

    var body: some View {
        ZStack {
            Color("BaniCanvas").ignoresSafeArea()

            VStack(spacing: 16) {
                header
                Spacer(minLength: 12)
                recordButton(for: .personal)
                recordButton(for: .work)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 20)
        }
        .fullScreenCover(isPresented: recordingSheetBinding) {
            if let recorder {
                RecordingView(recorder: recorder, context: activeContext, isProcessing: stage == .processing)
            }
        }
        .sheet(isPresented: $showManualEntry) {
            ManualEntrySheet()
        }
        .overlay(alignment: .bottom) {
            if case .confirming(let setup) = stage {
                ConfirmationCard(
                    parsed: setup.result.parsed,
                    transcript: setup.result.transcript,
                    errorMessage: setup.result.errorMessage,
                    context: setup.context,
                    categoryRef: setup.categoryRef,
                    autoContextApplied: setup.autoContextApplied,
                    firedRuleID: setup.firedRuleID,
                    trusted: setup.trusted,
                    refinedText: setup.result.cleanText,
                    onComplete: { stage = .idle }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
                .padding(.bottom, 8)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: stage)
        .alert("Microphone Access Needed", isPresented: micDeniedBinding) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                stage = .idle
            }
            Button("Cancel", role: .cancel) { stage = .idle }
        } message: {
            Text("Bani needs microphone access to record voice entries. You can still add transactions manually using the keyboard icon.")
        }
        .onChange(of: recorder?.state) { _, newState in
            handle(recorderState: newState)
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Text("Bani")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(Color("BaniInk"))
            Spacer()
            Button {
                showManualEntry = true
            } label: {
                Image(systemName: "keyboard")
                    .font(.title2)
                    .foregroundStyle(Color("BaniInk"))
            }
            .accessibilityIdentifier("logView.manualEntryButton")
            .accessibilityLabel("Add transaction manually")
        }
        .padding(.top, 8)
    }

    private func recordButton(for ctx: TransactionContext) -> some View {
        Button {
            startRecording(context: ctx)
        } label: {
            VStack(spacing: 12) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Color(ctx.tagColorName))
                Text(ctx.label)
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color("BaniCanvas"))
            }
            .frame(maxWidth: .infinity, minHeight: 180)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color("BaniAccent"))
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(ctx == .personal ? "logView.personalButton" : "logView.workButton")
        .accessibilityLabel("Record \(ctx.label) transaction")
        .accessibilityHint("Starts recording immediately")
    }

    // MARK: - Bindings

    private var recordingSheetBinding: Binding<Bool> {
        Binding(
            get: { stage == .recording || stage == .processing },
            set: { presented in
                if !presented {
                    // The cover is presented ONLY during .recording/.processing.
                    // When the pipeline advances the stage (→ .confirming, or
                    // → .micDenied), the cover's derived isPresented flips to
                    // false and SwiftUI writes back through THIS setter during
                    // its programmatic dismissal. Resetting stage here would
                    // clobber the just-presented ConfirmationCard (and the
                    // mic-denied alert) back to .idle — the exact bug that was
                    // silently dropping every voice entry. Only tear down when
                    // we are still inside the recording flow.
                    if stage == .recording || stage == .processing {
                        stage = .idle
                    }
                    recorder = nil
                }
            }
        )
    }

    private var micDeniedBinding: Binding<Bool> {
        Binding(
            get: { stage == .micDenied },
            set: { presented in if !presented { stage = .idle } }
        )
    }

    // MARK: - Flow

    private func startRecording(context ctx: TransactionContext) {
        activeContext = ctx
        let newRecorder = Recorder()
        recorder = newRecorder
        stage = .recording
        Task {
            await newRecorder.requestPermissionAndStart()
        }
    }

    private func handle(recorderState: Recorder.RecordingState?) {
        switch recorderState {
        case .finished(let url):
            stage = .processing
            Task { await transcribeAndParse(url: url) }
        case .denied:
            stage = .micDenied
            recorder = nil
        default:
            break
        }
    }

    /// The integration seam: stop → transcribe (Unit B) → parse (Unit A/F,
    /// via the frozen protocol) → confirmation card. A transcribe error, an
    /// empty transcript, or a nil-amount parse all open the card in edit mode
    /// (with the raw error and/or transcript visible) — never inventing an
    /// amount and never dropping the flow. See `runVoicePipeline`.
    private func transcribeAndParse(url: URL) async {
        // Grab the capture signal-chain note before the recorder is torn down.
        let captureNote = recorder?.captureChainNote
        var result = await runVoicePipeline(
            audioFileURL: url,
            transcribe: { try await whisper.transcribe(audioFileURL: $0) },
            refine: { await refiner.refine($0) },
            parse: { await parser.parse($0) }
        )
        // A3: surface the outcome + recording forensics for on-device debugging
        // (Settings row) — including the A1 capture chain and the A2 segment-gate
        // result. The file is closed by `finish()` before `.finished(url)` is
        // published, so it is fully readable here.
        VoiceSessionLog.record(
            result,
            audioFileURL: url,
            captureNote: captureNote,
            segmentDiagnostics: whisper.lastSegmentDiagnostics
        )

        // B3: if this exact (normalized) transcript has been corrected before,
        // reuse that description before categorizing — the memory forming.
        if result.errorMessage == nil,
           let remembered = CorrectionMemoryStore.lookup(rawTranscript: result.transcript, in: modelContext) {
            result.parsed.descriptionText = remembered
        }

        // C: pre-compute the category guess so the confirmation card's chip is
        // filled the instant it appears (falls back to Other). A learned custom
        // category (C3) resolves here too via `guessRef`.
        let guess = CategoryRuleStore.guessRef(
            description: result.parsed.descriptionText,
            merchant: result.parsed.merchant,
            in: modelContext
        )
        // B4: the rule that fired (trust key) + whether it is trusted right now.
        let firedRuleID = CategoryRuleStore.firedRuleID(
            description: result.parsed.descriptionText,
            merchant: result.parsed.merchant,
            in: modelContext
        )
        let trusted = DecisionLedger.isTrusted(ruleID: firedRuleID, in: modelContext)
        // B3: a learned context rule can pre-select the context regardless of the
        // Personal/Work button that was tapped.
        let autoContext = ContextRuleStore.preselectedContext(
            description: result.parsed.descriptionText,
            merchant: result.parsed.merchant,
            in: modelContext
        )
        let effectiveContext = autoContext ?? activeContext

        stage = .confirming(ConfirmationSetup(
            result: result,
            categoryRef: guess,
            context: effectiveContext,
            autoContextApplied: autoContext != nil,
            firedRuleID: firedRuleID,
            trusted: trusted
        ))
        recorder = nil
    }
}
