import XCTest
import Foundation
@testable import Bani

/// P10 gate — the interpretation seam (`InterpretationService`). Pure logic, no
/// SwiftData, the Foundation Models pass behind an injected `MockUnderstanding`
/// (CI has no FM runtime). Proves the hard laws:
///   • FM-assisted annotations pre-fill from a fixture corpus (RO+EN voice,
///     Raiffeisen-shaped share text, import rows).
///   • A remembered user correction (learned rule / injected memory) BEATS the model.
///   • A proposed project/person that does not exist is DROPPED (anti-hallucination).
///   • Confidence gating: < 0.5 is offered, never pre-filled.
///   • Fallback-identical: FM unavailable ⇒ output is the deterministic pipeline.
///   • Non-blocking: a hung/slow FM times out ⇒ the entry is unchanged.
final class InterpretationServiceTests: XCTestCase {

    // MARK: - Mock FM seam (the CI injection point)

    /// The single test double for `AnnotationRefining`. `available` toggles the
    /// gate; `annotation` is the canned proposal; `delay` simulates a slow/hung
    /// model for the non-blocking test (cancellation-aware via `Task.sleep`).
    struct MockUnderstanding: AnnotationRefining {
        var available: Bool = true
        var annotation: ModelAnnotation?
        var delay: Duration?

        var isAvailable: Bool { available }
        func refine(_ request: AnnotationRequest) async -> ModelAnnotation? {
            if let delay { try? await Task.sleep(for: delay) }
            return annotation
        }
    }

    // MARK: - Fixtures

    private var seedSnapshots: [CategoryRuleSnapshot] {
        CategorySeeds.table.map {
            CategoryRuleSnapshot(keyword: $0.keyword, category: $0.category, origin: .seed, hitCount: 0)
        }
    }

    private func learned(_ keyword: String, _ category: TransactionCategory) -> CategoryRuleSnapshot {
        CategoryRuleSnapshot(keyword: keyword, category: category, origin: .learned, hitCount: 1)
    }

    private func project(_ name: String, archived: Bool = false) -> ProjectSnapshot {
        ProjectSnapshot(id: UUID(), name: name, status: .active, colorIndex: 0,
                        sortOrder: 0, archived: archived, createdAt: Date())
    }

    private func person(_ name: String) -> PersonSnapshot {
        PersonSnapshot(id: UUID(), name: name, normalizedName: Categorizer.normalize(name),
                       kind: nil, notes: nil, createdAt: Date())
    }

    private let unavailable = UnavailableAnnotator()

    // MARK: - Corpus: deterministic categorization (RO + EN voice)

    func testVoiceRomanianFuelCategorized() async {
        let interp = await InterpretationService.annotate(
            .voiceTranscript("50 de lei benzină"),
            rules: seedSnapshots, projects: [], people: [], annotator: unavailable
        )
        XCTAssertEqual(interp.category, .fuel)
        XCTAssertEqual(interp.categoryAnnotator, .rule)
        XCTAssertNil(interp.projectID)
        XCTAssertNil(interp.counterparty)
    }

    func testVoiceEnglishTransportCategorized() async {
        let interp = await InterpretationService.annotate(
            .voiceTranscript("uber ride home"),
            rules: seedSnapshots, projects: [], people: [], annotator: unavailable
        )
        XCTAssertEqual(interp.category, .transport)
    }

    func testVoiceRomanianUtilitiesCategorized() async {
        let interp = await InterpretationService.annotate(
            .voiceTranscript("factură curent 200 lei"),
            rules: seedSnapshots, projects: [], people: [], annotator: unavailable
        )
        XCTAssertEqual(interp.category, .utilities)
    }

    // MARK: - Corpus: Raiffeisen-shaped share text (direction + counterparty)

    func testShareExpenseReadsExpenseDirection() async {
        let interp = await InterpretationService.annotate(
            .sharedText("Ai efectuat o plata de 45,00 RON la MEGA IMAGE cu cardul"),
            rules: seedSnapshots, projects: [], people: [], annotator: unavailable
        )
        XCTAssertEqual(interp.direction, .expense)
        XCTAssertEqual(interp.directionAnnotator, .rule)
    }

    func testShareIncomeReadsIncomeAndVerifiedCounterparty() async {
        let interp = await InterpretationService.annotate(
            .sharedText("Ai primit un transfer de 500,00 RON de la ION POPESCU"),
            rules: seedSnapshots, projects: [], people: [person("Ion Popescu")], annotator: unavailable
        )
        XCTAssertEqual(interp.direction, .income)
        XCTAssertEqual(interp.counterparty, "Ion Popescu", "an existing person is matched from the transfer text")
        XCTAssertEqual(interp.counterpartyAnnotator, .rule)
        XCTAssertGreaterThanOrEqual(interp.counterpartyConfidence, Interpretation.preFillThreshold)
    }

    // MARK: - Corpus: import row (project inference)

    func testImportRowInfersExistingProject() async {
        let crangasi = project("Crângași")
        let interp = await InterpretationService.annotate(
            .importRow("Chirie apartament Crângași 1200"),
            rules: seedSnapshots, projects: [crangasi], people: [], annotator: unavailable
        )
        XCTAssertEqual(interp.projectID, crangasi.id)
        XCTAssertEqual(interp.projectAnnotator, .rule)
        XCTAssertTrue(interp.shouldPreFillProject, "a confident containment match pre-fills")
    }

    func testArchivedProjectIsNeverInferred() async {
        let archived = project("Crângași", archived: true)
        let interp = await InterpretationService.annotate(
            .importRow("Chirie apartament Crângași 1200"),
            rules: seedSnapshots, projects: [archived], people: [], annotator: unavailable
        )
        XCTAssertNil(interp.projectID, "an archived project is not a live suggestion target")
    }

    // MARK: - FM refinement

    func testModelRefinesCategoryWhenDeterministicHasNoOpinion() async {
        // "programare la specialist" matches no seed → deterministic .other; the
        // model supplies .health, which pre-fills (0.7 ≥ 0.5).
        let mock = MockUnderstanding(annotation: ModelAnnotation(
            category: .health, projectName: nil, counterparty: nil, direction: nil,
            confidence: FoundationModelsAnnotator.modelConfidence))
        let interp = await InterpretationService.annotate(
            .voiceTranscript("programare la specialist"),
            rules: seedSnapshots, projects: [], people: [], annotator: mock
        )
        XCTAssertEqual(interp.category, .health)
        XCTAssertEqual(interp.categoryAnnotator, .fm)
        XCTAssertEqual(interp.categoryConfidence, FoundationModelsAnnotator.modelConfidence, accuracy: 0.0001)
    }

    func testModelProposesVerifiedProject() async {
        let villa = project("Villa Aurora")
        // The text does NOT contain the project name → deterministic finds nothing;
        // the model proposes it and it EXISTS → offered as an FM annotation.
        let mock = MockUnderstanding(annotation: ModelAnnotation(
            category: nil, projectName: "Villa Aurora", counterparty: nil, direction: nil,
            confidence: 0.7))
        let interp = await InterpretationService.annotate(
            .voiceTranscript("materiale de constructii 3000 lei"),
            rules: seedSnapshots, projects: [villa], people: [], annotator: mock
        )
        XCTAssertEqual(interp.projectID, villa.id)
        XCTAssertEqual(interp.projectAnnotator, .fm)
    }

    // MARK: - Anti-hallucination (verification disposes)

    func testHallucinatedProjectIsDropped() async {
        let real = project("Villa Aurora")
        let mock = MockUnderstanding(annotation: ModelAnnotation(
            category: nil, projectName: "Skyline Penthouse Tower", counterparty: nil,
            direction: nil, confidence: 0.9))
        let interp = await InterpretationService.annotate(
            .voiceTranscript("plata 1000 lei"),
            rules: seedSnapshots, projects: [real], people: [], annotator: mock
        )
        XCTAssertNil(interp.projectID, "a proposed project that does not exist is never offered")
        XCTAssertNil(interp.projectAnnotator)
    }

    func testHallucinatedCounterpartyIsDropped() async {
        let mock = MockUnderstanding(annotation: ModelAnnotation(
            category: nil, projectName: nil, counterparty: "Imaginary Client SRL",
            direction: nil, confidence: 0.9))
        let interp = await InterpretationService.annotate(
            .sharedText("Ai primit 500 RON"),
            rules: seedSnapshots, projects: [], people: [person("Ion Popescu")], annotator: mock
        )
        XCTAssertNil(interp.counterparty, "a proposed person not in the registry is never offered")
        XCTAssertNil(interp.counterpartyAnnotator)
    }

    // MARK: - Correction-memory override beats the model

    func testLearnedRuleOverridesModelSuggestion() async {
        // The user once corrected "benzină" → Shopping; the model now says Health.
        // The remembered correction wins (user corrections are ground truth).
        let rules = seedSnapshots + [learned("benzina", .shopping)]
        let mock = MockUnderstanding(annotation: ModelAnnotation(
            category: .health, projectName: nil, counterparty: nil, direction: nil, confidence: 0.9))
        let interp = await InterpretationService.annotate(
            .voiceTranscript("benzină 50 lei"),
            rules: rules, projects: [], people: [], annotator: mock
        )
        XCTAssertEqual(interp.category, .shopping, "the learned correction beats the model")
        XCTAssertEqual(interp.categoryAnnotator, .memory)
        XCTAssertEqual(interp.categoryConfidence, InterpretationService.learnedConfidence, accuracy: 0.0001)
    }

    func testInjectedRememberedCorrectionOverridesModel() async {
        let mock = MockUnderstanding(annotation: ModelAnnotation(
            category: .health, projectName: nil, counterparty: nil, direction: nil, confidence: 0.9))
        let interp = await InterpretationService.annotate(
            .voiceTranscript("ceva necategorisit"),
            rules: seedSnapshots, projects: [], people: [],
            remembered: RememberedCorrection(categoryRef: .preset(.groceries)),
            annotator: mock
        )
        XCTAssertEqual(interp.category, .groceries)
        XCTAssertEqual(interp.categoryAnnotator, .memory)
    }

    // MARK: - Confidence gating

    func testLowConfidenceModelProjectIsOfferedNotPreFilled() async {
        let villa = project("Villa Aurora")
        let mock = MockUnderstanding(annotation: ModelAnnotation(
            category: nil, projectName: "Villa Aurora", counterparty: nil, direction: nil,
            confidence: 0.3))   // below the pre-fill threshold
        let interp = await InterpretationService.annotate(
            .voiceTranscript("plata 200 lei"),
            rules: seedSnapshots, projects: [villa], people: [], annotator: mock
        )
        XCTAssertEqual(interp.projectID, villa.id, "the suggestion still exists (verified)…")
        XCTAssertEqual(interp.projectConfidence, 0.3, accuracy: 0.0001)
        XCTAssertFalse(interp.shouldPreFillProject, "…but a < 0.5 confidence is offered, never pre-filled")
    }

    // MARK: - Fallback-identical (FM unavailable ⇒ deterministic pipeline)

    func testFallbackIsByteIdenticalToDeterministicPipeline() async {
        let crangasi = project("Crângași")
        let people = [person("Ion Popescu")]
        let corpus: [RawInput] = [
            .voiceTranscript("50 de lei benzină"),
            .voiceTranscript("uber ride home"),
            .voiceTranscript("factură curent 200 lei"),
            .sharedText("Ai efectuat o plata de 45,00 RON la MEGA IMAGE cu cardul"),
            .sharedText("Ai primit un transfer de 500,00 RON de la ION POPESCU"),
            .importRow("Chirie apartament Crângași 1200"),
        ]
        for input in corpus {
            let interp = await InterpretationService.annotate(
                input, rules: seedSnapshots, projects: [crangasi], people: people, annotator: unavailable)

            // Independently recompute each deterministic field from the shipped
            // components — the FM-off output must equal the pre-P10 pipeline exactly.
            let base = InterpretationService.deterministicBase(for: input)
            let expectedCategory: CategoryRef? = Categorizer.categoryRef(for: base.categorizationText, rules: seedSnapshots)
            let expectedProject: UUID? = InterpretationService.inferProject(text: input.text, projects: [crangasi])?.id
            let expectedCounterparty: String? = InterpretationService.inferCounterparty(text: input.text, people: people)?.name

            XCTAssertEqual(interp.categoryRef, expectedCategory, "category matches the deterministic categorizer")
            XCTAssertEqual(interp.projectID, expectedProject, "project matches deterministic containment")
            XCTAssertEqual(interp.counterparty, expectedCounterparty, "counterparty matches deterministic registry match")
            XCTAssertEqual(interp.direction, base.direction, "direction matches the source parser")

            // No field may claim an FM origin when FM is unavailable.
            XCTAssertNotEqual(interp.categoryAnnotator, .fm)
            XCTAssertNotEqual(interp.projectAnnotator, .fm)
            XCTAssertNotEqual(interp.counterpartyAnnotator, .fm)
            XCTAssertNotEqual(interp.directionAnnotator, .fm)
        }
    }

    func testUnavailableModelNeverChangesTheResult() async {
        // Even a model bursting with (unavailable) opinions changes nothing.
        let loud = MockUnderstanding(available: false, annotation: ModelAnnotation(
            category: .entertainment, projectName: "Whatever", counterparty: "Nobody",
            direction: .neutral, confidence: 1.0))
        let input = RawInput.voiceTranscript("50 de lei benzină")
        let off = await InterpretationService.annotate(input, rules: seedSnapshots, projects: [], people: [], annotator: unavailable)
        let loudOff = await InterpretationService.annotate(input, rules: seedSnapshots, projects: [], people: [], annotator: loud)
        XCTAssertEqual(off, loudOff, "an unavailable model is byte-identical to no model")
        XCTAssertEqual(loudOff.category, .fuel)
    }

    // MARK: - Non-blocking (a hung model times out, the entry is unchanged)

    func testSlowModelTimesOutAndEntryIsUnchanged() async {
        // A model that would say .health, but hangs 10 s. With a 20 ms timeout the
        // deterministic result (.fuel from the seed) stands — the entry is saved
        // exactly as today; interpretation NEVER gates or delays the write.
        let hung = MockUnderstanding(annotation: ModelAnnotation(
            category: .health, projectName: nil, counterparty: nil, direction: nil, confidence: 1.0),
            delay: .seconds(10))
        let input = RawInput.voiceTranscript("50 de lei benzină")

        let start = Date()
        let interp = await InterpretationService.annotate(
            input, rules: seedSnapshots, projects: [], people: [], annotator: hung,
            timeout: .milliseconds(20))
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(interp.category, .fuel, "the deterministic result stands; the slow model is ignored")
        XCTAssertNotEqual(interp.categoryAnnotator, .fm)

        // The same input with FM simply unavailable — proves "timeout == unchanged".
        let baseline = await InterpretationService.annotate(
            input, rules: seedSnapshots, projects: [], people: [], annotator: unavailable)
        XCTAssertEqual(interp, baseline, "a timed-out FM pass yields the exact deterministic entry")
        XCTAssertLessThan(elapsed, 2.0, "annotation returns promptly — it never waits out a hung model")
    }
}
