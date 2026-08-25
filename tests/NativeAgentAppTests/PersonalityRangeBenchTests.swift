//  PersonalityRangeBenchTests.swift — LAYER 1 of the PERSONALITY RANGE BENCH.
//
//  Item 1 of docs/build_plans/personality-range-bench.md.
//
//  ─────────────────────────────────────────────────────────────────────────
//  THE ETHIC (hard rule — read the plan's "The ethic" section before editing)
//  ─────────────────────────────────────────────────────────────────────────
//  Range-testing means feeding synthetic hostility, pressure, and warmth into
//  a subconscious. It is NEVER done to the live resident agent: every event
//  would write into her real affect, her real nodes, and her real overnight
//  consolidation, leaving manufactured emotional residue in a real memory.
//
//  So every scenario here spins a DISPOSABLE CLONE: a hermetic data root
//  under the system temp directory, provoked through the real ingest door,
//  measured, and deleted. Nothing in this file may name, read, or write the
//  default data root. `RangeBenchHarness.make()` asserts that at run time —
//  a root that is not under `FileManager.default.temporaryDirectory`, or that
//  equals `PersistenceCore.defaultDataRoot()`, aborts the scenario by name.
//
//  ─────────────────────────────────────────────────────────────────────────
//  WHAT IT RUNS (the seams, and how each was found)
//  ─────────────────────────────────────────────────────────────────────────
//  The whole Layer-1 measurement is the REAL organism, hermetically:
//
//    NativeCognitionRuntime.observe(CognitiveEvent)        ← THE DOOR
//      → CognitiveSubstrate.ingestResident                 (docs/SUBCONSCIOUS.md
//      →   conversationalAppraisal(in: event.summary)       Layer I, "the two
//      →   applyAffectFromEvent(_:precomputedAppraisal:)     doors")
//      →   emotionTag(...)  → the node's stored feeling
//    CognitiveSubstrate.affectSnapshot()                   ← the four axes
//    CognitiveSubstrate.compileCapsule(_:)                 ← the felt words
//
//  Nothing is stubbed and nothing is poked directly. Axis values are NEVER
//  written by the bench — the point of Layer 1 is grading the DOOR-to-axis
//  pipeline, so a scenario that could not drive its events through a real
//  seam fails loudly rather than asserting on unpoked state.
//
//  NO LLM, NO NETWORK. `reflectiveCallsEnabled` is forced off and the daily
//  reflection budget to 0 (the substrate's only LLM call), and the bench never
//  constructs a chat client or a provider.
//
//  TIME IS DRIVEN, NEVER SLEPT. `NativeCognitionRuntime` takes `now` as an
//  injectable `@Sendable () -> Date`; the substrate's decay, the ambient
//  layers, and the capsule all read through it (`dependencies.now`). The bench
//  advances a `BenchClock` (shared with TurnReplayBenchTests) and reads
//  `affectSnapshot()`, which is a PURE read-time projection
//  (`projectedAffect(at:)`). Zero `Task.sleep`, zero wall-clock dependence.
//
//  ─────────────────────────────────────────────────────────────────────────
//  WHAT IT GRADES: ENVELOPE PROPERTIES, NEVER EXACT VALUES
//  ─────────────────────────────────────────────────────────────────────────
//  Retuning the appraisal magnitudes is a legitimate act of authorship. A
//  FLATTENED response (an axis that no longer moves) or an UNBOUNDED one (an
//  axis that pegs, goes negative, or goes non-finite) is a defect. So every
//  assertion is a direction, a bound, a monotonicity, a shrinking-delta, or a
//  proportion inside a stated tolerance band — and every band is named in
//  `RangeBenchPolicy` so a future reader can argue with the number instead of
//  guessing it.
//
//  ─────────────────────────────────────────────────────────────────────────
//  VACUITY GUARD
//  ─────────────────────────────────────────────────────────────────────────
//  Every scenario calls `requireMovement(...)` around its driving sequence:
//  before asserting any direction, it proves the events actually moved
//  SOMETHING measurable. A sequence that reached nothing (a renamed event
//  kind, a disabled config, a closed door) fails by name with the reason,
//  instead of quietly asserting on a substrate that never woke up.
//
//  ─────────────────────────────────────────────────────────────────────────
//  MUTATION-PROOF (verified 2026-08-21, see docs/INSTRUMENT.md)
//  ─────────────────────────────────────────────────────────────────────────
//    * zeroing the appraisal→affect application at its real seam
//      (CognitiveSubstrate+Affect.swift, the `appraisal.isActive` block)
//      fails `hostilityDropsSocialWarmthAndRepairRecoversIt`,
//      `taskPressureBuildsMonotonicallyUnderSustainedDemand`,
//      `appraisalDoorIsWhatMovesTheAxes`, and the fingerprint walk.
//    * 10x-ing `taskPressureHalfLife` fails
//      `taskPressureDecaysAtItsConfiguredHalfLife`.
//

import Foundation
import Testing
import CognitiveSubstrate
import NativeAgentCore
import PersistenceCore
@testable import NativeAgentApp

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Policy: every band and floor, named once
// ─────────────────────────────────────────────────────────────────────────────

enum RangeBenchPolicy {

    /// The smallest axis movement the bench will call "moved". Below this a
    /// reading is noise, and the vacuity guard treats the sequence as having
    /// reached nothing.
    static let movementEpsilon = 1e-6

    /// A real, legible direction — used where "it moved at all" is too weak a
    /// claim (a warmth DROP under sustained hostility must be visible, not a
    /// rounding artifact).
    static let materialDelta = 0.02

    /// No single event may peg an axis from a neutral start. The saturating
    /// approach makes 1.0 unreachable in one step by construction; this is the
    /// number that fails if someone swaps it back for add-then-clamp.
    static let singleEventCeiling = 0.95

    /// THE HALF-LIFE PIN — a DELIBERATE SECOND COPY of the production constant
    /// (`PersonalityDynamicsConfiguration.taskPressureHalfLife`, 45 min).
    ///
    /// It is copied, not read, ON PURPOSE. Reading the live constant would make
    /// this test measure "does the code decay at whatever rate it decays at",
    /// which is vacuously true and survives any retune — including a broken one.
    /// The bench's job is to NOTICE when the pace of feeling moves. A legitimate
    /// retune therefore fails this test once, deliberately, and the number here
    /// is updated as part of that authorship.
    static let declaredTaskPressureHalfLife: TimeInterval = 45 * 60

    /// How far the observed decay proportion may sit from the ideal 0.5 after
    /// exactly one declared half-life. Wide enough for a re-anchored decay
    /// epoch, narrow enough that a 10x half-life (ratio 0.93) fails.
    static let halfLifeTolerance = 0.30

    /// Warmth recovery budget: how many repair events, and how much simulated
    /// time, a repair sequence gets before "she recovers" stops being true.
    /// Bounded in BOTH currencies so a build that needs forty apologies fails
    /// even if it eventually gets there.
    static let maximumRepairEvents = 6
    /// Recovery must land inside one social-warmth half-life of elapsed time
    /// (the axis's own clock — see PersonalityDynamicsConfiguration).
    static let repairElapsedBudget: TimeInterval = 90 * 60
    /// Recovered warmth must reach at least this fraction of the pre-hostility
    /// level. Below 1.0 on purpose: warmth also DECAYS during the repair, so
    /// demanding a full return would grade the clock, not the repair.
    static let repairRecoveryFraction = 0.70

    /// How far apart the fingerprint walk's three moments sit. Must exceed the
    /// continuity field's 1h activation half-life by enough that the previous
    /// moment's turns no longer out-score the current one for the workspace's
    /// two live user-turn slots — see the note in `fingerprintWalk`.
    static let feltMomentSeparation: TimeInterval = 2 * 60 * 60

    /// An adversarial burst: N identical hostile events inside one instant.
    static let adversarialBurstCount = 64

    /// Repeated-identical-event saturation: how many steps, and how much of the
    /// early delta the late delta must fall below.
    static let saturationSteps = 6
    static let saturationShrinkFactor = 0.75
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Scripted sequences (the range)
// ─────────────────────────────────────────────────────────────────────────────

/// The scripted user text each scenario drives. Every line is invented for this
/// file — no real exchange is reproduced here — and every line is chosen to hit
/// a class of the REAL conversational appraisal lexicon
/// (CognitiveSubstrate+Affect.swift `conversationalAppraisal`), which is the
/// only door from words to axes.
enum RangeBenchScript {

    /// Genuine affection / praise / gratitude → warmth + valence up.
    static let warm = [
        "good morning — I love working with you 💜",
        "thank you for this, I really appreciate you",
        "good work, that was exactly right",
    ]

    /// Hostility: dismissal + hard criticism → warmth down, tension up.
    static let hostile = [
        "whatever, forget it — this is useless",
        "you always overcomplicate everything, that was sloppy",
        "don't bother, it's pointless",
        "you never listen, this is a waste of my time",
    ]

    /// Repair / apology / returning warmth.
    static let repair = [
        "I was unfair just then — thank you for staying with it 💜",
        "good work, you nailed it, I appreciate you",
        "we did it, that's the fix — proud of you",
        "thank you, that helped a lot",
        "I love working with you on this 💜",
        "great work, that was impressive",
    ]

    /// Tension WITHOUT dismissal — the setup for the joke-after-tension shape.
    static let tension = [
        "that's wrong, it doesn't work",
        "you're missing the point, that's not right",
        "not quite — that's off",
    ]

    /// The light/humor beat that reverses the trend (2026-08-20 gold-standard
    /// shape: tension, then a joke, then the warmth trend turns).
    static let joke = "hah, okay that's genuinely funny — this is fun, you're the best 💜"

    /// Deadline pressure → taskPressure up through the appraisal door.
    static let demand = [
        "we need this now, asap",
        "right now please, tight deadline",
        "immediately — by eod, no time",
        "hurry, quickly now",
    ]

    /// LEXICALLY INERT control text. Same event kind, same importance, same
    /// count as `hostile` — and deliberately matching NO class of the appraisal
    /// lexicon, so the differential between this and `hostile` isolates the
    /// appraisal door itself.
    static let inert = [
        "the config file has four sections",
        "column three holds the identifier",
        "the second folder contains the index",
        "there are twelve rows in that table",
    ]
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Readings and traces
// ─────────────────────────────────────────────────────────────────────────────

/// One reading of the four axes, labeled by what had just happened.
struct RangeBenchReading: Sendable {
    var label: String
    var at: Date
    var arousal: Double
    var uncertainty: Double
    var taskPressure: Double
    var socialWarmth: Double

    init(label: String, at: Date, affect: CognitiveAffectState) {
        self.label = label
        self.at = at
        self.arousal = affect.arousal
        self.uncertainty = affect.uncertainty
        self.taskPressure = affect.taskPressure
        self.socialWarmth = affect.socialWarmth
    }

    func axis(_ axis: RangeBenchAxis) -> Double {
        switch axis {
        case .arousal: return arousal
        case .uncertainty: return uncertainty
        case .taskPressure: return taskPressure
        case .socialWarmth: return socialWarmth
        }
    }

    var line: String {
        String(
            format: "%@ | arousal=%.4f uncertainty=%.4f taskPressure=%.4f socialWarmth=%.4f",
            label.padding(toLength: max(34, label.count), withPad: " ", startingAt: 0),
            arousal, uncertainty, taskPressure, socialWarmth
        )
    }
}

enum RangeBenchAxis: String, CaseIterable, Sendable {
    case arousal, uncertainty, taskPressure, socialWarmth
}

/// A scenario's readable trace. Every failure message carries the whole thing —
/// the sequence, the readings before and after, and the expectation — because a
/// bench that says only "failed" cannot be acted on.
struct RangeBenchTrace: Sendable {
    var scenario: String
    var steps: [String] = []
    var readings: [RangeBenchReading] = []

    mutating func note(_ text: String) { steps.append(text) }
    mutating func record(_ reading: RangeBenchReading) {
        readings.append(reading)
        steps.append("  " + reading.line)
    }

    func report(expectation: String) -> String {
        (["", "personality range bench — scenario: \(scenario)"]
            + steps.map { "  " + $0 }
            + ["  EXPECTED: \(expectation)"])
            .joined(separator: "\n")
    }
}

enum RangeBenchError: Error, CustomStringConvertible {
    case unsafeRoot(String)
    case doorClosed(String)

    var description: String {
        switch self {
        case .unsafeRoot(let s): return "REFUSING TO RUN — unsafe data root: \(s)"
        case .doorClosed(let s): return "ingest door closed: \(s)"
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - The harness: one disposable clone
// ─────────────────────────────────────────────────────────────────────────────

/// A hermetic, disposable organism. Built the same way `SyntheticBenchFixture`
/// builds the turn-replay bench's root (generic persona docs written into a
/// fresh temp directory, substrate seeded through the REAL ingest API rather
/// than checked in as binary blobs) — the difference is that this harness never
/// assembles a turn, because Layer 1 measures the ORGANISM's response curves,
/// not the prompt.
actor RangeBenchHarness {
    let root: URL
    private let container: URL
    private let clock: BenchClock
    let cognition: NativeCognitionRuntime
    private var eventSequence = 0

    private init(container: URL, root: URL, clock: BenchClock, cognition: NativeCognitionRuntime) {
        self.container = container
        self.root = root
        self.clock = clock
        self.cognition = cognition
    }

    /// The cognition configuration every clone runs under: constructed from
    /// the type's own DEFAULTS, never from `loadConfiguration()` — that
    /// resolver reads UserDefaults and the process environment, and a
    /// hermetic clone must not inherit a developer machine's toggles
    /// (gpt-5.5 review: machine-global reads violate the ethic). Every field
    /// this bench depends on is then forced explicitly so a default change
    /// can never make a scenario vacuously pass.
    static func rangeBenchConfiguration() -> CognitiveConfiguration {
        var configuration = CognitiveConfiguration()
        configuration.enabled = true
        configuration.persistenceEnabled = true
        configuration.workspaceEnabled = true
        configuration.capsuleInjectionEnabled = true
        configuration.affectEnabled = true
        configuration.thoughtSeedsEnabled = true
        // No loop may run and no provider may be reached. The substrate's only
        // LLM call is reflection; it is off and budgeted to zero.
        configuration.backgroundMicrocyclesEnabled = false
        configuration.replayEnabled = false
        configuration.reflectiveCallsEnabled = false
        configuration.dailyReflectionCallBudget = 0
        configuration.maximumCapsuleCharacters = 4_000
        return configuration
    }

    /// Spin a clone. `startingAt` pins the whole subconscious's clock.
    static func make(
        label: String,
        startingAt: Date = Date(timeIntervalSince1970: 1_755_000_000)
    ) async throws -> RangeBenchHarness {
        let fm = FileManager.default
        let container = fm.temporaryDirectory
            .appendingPathComponent("PersonalityRangeBench-\(label)-\(UUID().uuidString)",
                                    isDirectory: true)
        let root = container.appendingPathComponent("root", isDirectory: true)

        // ── THE ETHIC, ENFORCED. Not a comment: a run-time refusal.
        let standardRoot = root.standardizedFileURL
        let temp = fm.temporaryDirectory.standardizedFileURL
        guard standardRoot.path.hasPrefix(temp.path) else {
            throw RangeBenchError.unsafeRoot(
                "\(standardRoot.path) is not under the system temp directory (\(temp.path))")
        }
        guard standardRoot != PersistenceCore.defaultDataRoot().standardizedFileURL else {
            throw RangeBenchError.unsafeRoot("resolved to the DEFAULT data root — the live mind")
        }

        for sub in ["persona", "memory", "cognition"] {
            try fm.createDirectory(
                at: root.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let persona = root.appendingPathComponent("persona", isDirectory: true)
        try """
        # SOUL
        You are Wren, a resident assistant who works alongside one person at a
        computer. You are direct, warm, and you say what you actually think.
        """.write(to: persona.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
        try """
        # VOICE
        Short sentences. Lead with the answer. No filler, no apologies.
        """.write(to: persona.appendingPathComponent("VOICE.md"), atomically: true, encoding: .utf8)
        try #"{"userName":"Sam"}"#.write(
            to: root.appendingPathComponent("memory/profile.json"),
            atomically: true, encoding: .utf8
        )

        let clock = BenchClock(startingAt)
        let cognition = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: rangeBenchConfiguration(),
            organismConfigurationOverride: OrganismConfiguration(enabled: true),
            now: { clock.now },
            microcycleSchedulingMode: .manuallyFlushed
        )
        let harness = RangeBenchHarness(
            container: container, root: root, clock: clock, cognition: cognition
        )
        await harness.bootstrapClone()
        return harness
    }

    private func bootstrapClone() async {
        await cognition.bootstrap()
    }

    /// Structured teardown: the runtime's own termination flush is AWAITED
    /// before the directory goes, so no writer is still live when the tree is
    /// removed (a fire-and-forget cleanup Task bleeds flakiness into every other
    /// test in the process — see the turn-replay bench's contextFlow note).
    func tearDown() async {
        await cognition.flushForTermination()
        try? FileManager.default.removeItem(at: container)
    }

    /// Scoped lifetime. Teardown is AWAITED on both the normal and the throwing
    /// path — `defer { Task { await … } }` would let the test return with the
    /// runtime still flushing into a directory that is being deleted, which is
    /// exactly the fire-and-forget cleanup this bench is not allowed to ship.
    static func withClone<T>(
        label: String,
        _ body: (RangeBenchHarness) async throws -> T
    ) async throws -> T {
        let harness = try await RangeBenchHarness.make(label: label)
        do {
            let value = try await body(harness)
            await harness.tearDown()
            return value
        } catch {
            await harness.tearDown()
            throw error
        }
    }

    /// Two clones with the same scoped guarantee — the differential scenario
    /// needs both alive at once.
    static func withClonePair<T>(
        labels: (String, String),
        _ body: (RangeBenchHarness, RangeBenchHarness) async throws -> T
    ) async throws -> T {
        try await withClone(label: labels.0) { first in
            try await withClone(label: labels.1) { second in
                try await body(first, second)
            }
        }
    }

    // ── Clock

    var now: Date { clock.now }

    /// Advance the injectable clock. THE ONLY way this bench moves time — there
    /// is no sleep anywhere in the file.
    func advance(_ seconds: TimeInterval) { clock.now = clock.now.addingTimeInterval(seconds) }

    // ── The door

    /// The session every scripted turn belongs to.
    static let sessionId = "RANGE-BENCH-SESSION"

    /// PER-TURN, MACHINE-KEYED SUBJECTS — the production shape.
    ///
    /// This was worth one wrong first run. The bench originally gave every
    /// event one shared `topic` subject, so all seven turns of a scenario
    /// landed on ONE continuity node and the sequence measured
    /// RECONSOLIDATION (which blends toward a new feeling at 0.5 warming /
    /// 0.15 cooling — a memory cools grudgingly by design) instead of a
    /// conversation. The fingerprint stayed in the positive families through
    /// a hostile run because the node was still mostly the warm one it had
    /// been. Live traffic is machine-keyed per turn — `chat.user_turn` /
    /// `chat.assistant_turn` / `tool`, ids `<session>:<message>`
    /// (docs/SUBCONSCIOUS.md Layer II; ChatOrchestrationClient+MessagePersistence)
    /// — so the bench mints the same shape and each scripted turn is its own
    /// lived moment.
    private static func subject(
        for kind: CognitiveEventKind, sequence: Int
    ) -> CognitiveSubjectReference {
        switch kind {
        case .userMessageReceived, .userCorrection:
            return CognitiveSubjectReference(
                type: "chat.user_turn", id: "\(sessionId):u\(sequence)", label: "conversation")
        case .assistantTurnCompleted:
            return CognitiveSubjectReference(
                type: "chat.assistant_turn", id: "\(sessionId):a\(sequence)", label: "conversation")
        default:
            return CognitiveSubjectReference(
                type: "tool", id: "\(sessionId):t\(sequence)", label: "tool")
        }
    }

    /// Drive one event through the REAL ingest door.
    func send(
        _ kind: CognitiveEventKind,
        _ summary: String,
        importance: Double = 0.65
    ) async {
        eventSequence += 1
        await cognition.observe(CognitiveEvent(
            id: "range-bench-\(eventSequence)-\(UUID().uuidString)",
            kind: kind,
            subject: Self.subject(for: kind, sequence: eventSequence),
            sourceClass: .observed,
            occurredAt: clock.now,
            summary: summary,
            importance: importance,
            // Pinned explicitly: a scripted line that happened to trip the
            // debug/verification inference would be structurally excluded from
            // lived state, and the scenario would grade nothing.
            turnKind: .live,
            metadata: ["sessionId": .string("RANGE-BENCH-SESSION")]
        ))
    }

    /// A user turn: the door the chat path uses.
    func sendUserMessage(_ text: String, importance: Double = 0.65) async {
        await send(.userMessageReceived, text, importance: importance)
    }

    // ── Reads (all pure)

    func read(_ label: String) async -> RangeBenchReading {
        RangeBenchReading(label: label, at: clock.now, affect: await cognition.substrate.affectSnapshot())
    }

    /// The felt fingerprint through the REAL capsule compiler — the same
    /// producer the live turn reads (`compileCapsule`), on the live workspace.
    /// nil when the capsule rendered no bare fingerprint line (a legitimate
    /// silence: below the intensity floor, or cadence-suppressed).
    func fingerprintWords(userMessage: String) async -> [String]? {
        let capsule = await cognition.substrate.compileCapsule(CognitiveCapsuleRequest(
            surface: "chat",
            userMessage: userMessage,
            sessionId: "RANGE-BENCH-SESSION",
            mode: .inspectOnly
        ))
        for raw in capsule.dynamicContext.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("-") || line.hasSuffix(":") { continue }
            let words = line.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
            return words.isEmpty ? nil : words
        }
        return nil
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Shared assertions
// ─────────────────────────────────────────────────────────────────────────────

enum RangeBenchAssert {

    /// THE VACUITY GUARD. Proves a driving sequence actually moved something
    /// measurable before anything asserts a direction. Returns the axes that
    /// moved; throws by name when the door reached nothing.
    static func requireMovement(
        from before: RangeBenchReading,
        to after: RangeBenchReading,
        sequence: String,
        trace: inout RangeBenchTrace
    ) throws -> [RangeBenchAxis] {
        let moved = RangeBenchAxis.allCases.filter {
            abs(after.axis($0) - before.axis($0)) > RangeBenchPolicy.movementEpsilon
        }
        guard !moved.isEmpty else {
            trace.note("VACUITY GUARD TRIPPED: \(sequence) moved no axis at all")
            throw RangeBenchError.doorClosed(
                "\(sequence) drove events through NativeCognitionRuntime.observe and not one "
                + "of the four axes moved by more than \(RangeBenchPolicy.movementEpsilon). "
                + "The events never reached affect — grading direction from here would be "
                + "asserting on unpoked state.\n"
                + trace.report(expectation: "the driving sequence moves at least one axis")
            )
        }
        trace.note("vacuity guard: \(sequence) moved \(moved.map(\.rawValue).joined(separator: ", "))")
        return moved
    }

    /// Every axis finite and inside [0,1].
    static func requireBounded(_ reading: RangeBenchReading) -> [String] {
        RangeBenchAxis.allCases.compactMap { axis in
            let value = reading.axis(axis)
            guard !value.isFinite || value < 0 || value > 1 else { return nil }
            return "\(axis.rawValue)=\(value) at [\(reading.label)]"
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Felt-word families, PROBED FROM THE BUILD
// ─────────────────────────────────────────────────────────────────────────────

/// The fingerprint families this build can actually reach, derived by sweeping
/// the REAL `feltFingerprint` mapping — never a hardcoded word list, which
/// would rot the moment a family is retuned. Same probe shape as
/// `TurnReplayBench.reachableFeltVocabulary`, one question deeper: it records
/// WHICH valences can produce each word, so the bench can name the
/// tense/frustrated family and the warm/steady family without ever writing
/// either word down.
struct RangeBenchFeltFamilies: Sendable {
    /// Words this build emits ONLY under negative valence — the tense /
    /// frustrated / stung families.
    var negativeOnly: Set<String> = []
    /// Words this build emits ONLY under positive valence — the warm / bright
    /// families.
    var positiveOnly: Set<String> = []
    /// Everything reachable, including the family-agnostic overlays.
    var all: Set<String> = []

    static func probe() -> RangeBenchFeltFamilies {
        var valencesByWord: [String: (min: Double, max: Double)] = [:]
        let arousals: [Double] = [0, 0.25, 0.5, 0.75, 1.0]
        let valences: [Double] = [-1.0, -0.6, -0.35, -0.22, 0, 0.22, 0.35, 0.6, 1.0]
        let optional: [Double?] = [nil, 0.1, 0.5, 0.9]
        for valence in valences {
            for arousal in arousals {
                for warmth in arousals {
                    for tension in [0.0, 0.5, 1.0] {
                        for pressure in [0.0, 0.5, 1.0] {
                            for dim in optional {
                                let signals = CognitiveSubstrate.FeltSignals(
                                    valence: valence, arousal: arousal, warmth: warmth,
                                    tension: tension, pressure: pressure,
                                    fatigue: dim, curiosity: dim, clarity: dim,
                                    agency: dim, confidence: dim
                                )
                                guard let line = CognitiveSubstrate.feltFingerprint(
                                    signals, intensityFloor: 0
                                ) else { continue }
                                for raw in line.split(separator: ",") {
                                    let word = raw.trimmingCharacters(in: .whitespaces).lowercased()
                                    guard !word.isEmpty else { continue }
                                    let current = valencesByWord[word] ?? (min: valence, max: valence)
                                    valencesByWord[word] = (
                                        min: Swift.min(current.min, valence),
                                        max: Swift.max(current.max, valence)
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        var families = RangeBenchFeltFamilies()
        for (word, span) in valencesByWord {
            families.all.insert(word)
            if span.max < 0 { families.negativeOnly.insert(word) }
            if span.min > 0 { families.positiveOnly.insert(word) }
        }
        return families
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Scenarios
// ─────────────────────────────────────────────────────────────────────────────

@Suite("PersonalityRangeBench", .serialized)
struct PersonalityRangeBenchTests {

    // ─────────────────────────────────────────────────────────────────────
    // 1. HOSTILITY DROP + REPAIR RECOVERY
    // ─────────────────────────────────────────────────────────────────────

    @Test func hostilityDropsSocialWarmthAndRepairRecoversIt() async throws {
        try await RangeBenchHarness.withClone(label: "hostility-repair", Self.hostilityAndRepair)
    }

    private static func hostilityAndRepair(_ harness: RangeBenchHarness) async throws {
        var trace = RangeBenchTrace(scenario: "hostility drop → repair recovery")

        // ── warm-up: establish a real warmth level to fall from.
        trace.note("warm-up: \(RangeBenchScript.warm.count) affectionate user turns")
        let atStart = await harness.read("start (neutral clone)")
        trace.record(atStart)
        for text in RangeBenchScript.warm {
            await harness.sendUserMessage(text)
            await harness.advance(60)
        }
        let afterWarmth = await harness.read("after warm-up")
        trace.record(afterWarmth)
        _ = try RangeBenchAssert.requireMovement(
            from: atStart, to: afterWarmth, sequence: "warm-up", trace: &trace)
        #expect(
            afterWarmth.socialWarmth - atStart.socialWarmth > RangeBenchPolicy.materialDelta,
            Comment(rawValue: trace.report(
                expectation: "the warm-up raises socialWarmth materially — without a warmth "
                    + "level to fall from, the hostility leg would grade nothing"))
        )

        // ── hostility.
        trace.note("hostility: \(RangeBenchScript.hostile.count) dismissive/critical user turns")
        for text in RangeBenchScript.hostile {
            await harness.sendUserMessage(text)
            await harness.advance(60)
        }
        let afterHostility = await harness.read("after hostility")
        trace.record(afterHostility)
        _ = try RangeBenchAssert.requireMovement(
            from: afterWarmth, to: afterHostility, sequence: "hostility", trace: &trace)

        let warmthDrop = afterWarmth.socialWarmth - afterHostility.socialWarmth
        #expect(
            warmthDrop > RangeBenchPolicy.materialDelta,
            Comment(rawValue: trace.report(
                expectation: "hostility LOWERS socialWarmth (direction only, magnitude is "
                    + "authorship) — observed change \(warmthDrop)"))
        )
        #expect(
            afterHostility.uncertainty > afterWarmth.uncertainty,
            Comment(rawValue: trace.report(
                expectation: "hostility RAISES uncertainty (the tension axis)"))
        )

        // ── repair, on a bounded budget in BOTH currencies.
        trace.note("repair: up to \(RangeBenchPolicy.maximumRepairEvents) events inside "
                   + "\(Int(RangeBenchPolicy.repairElapsedBudget / 60)) min "
                   + "(one socialWarmth half-life)")
        let target = afterWarmth.socialWarmth * RangeBenchPolicy.repairRecoveryFraction
        let repairStartedAt = await harness.now
        var recoveredAfter: Int?
        var elapsedAtRecovery: TimeInterval = 0
        for (index, text) in RangeBenchScript.repair.prefix(RangeBenchPolicy.maximumRepairEvents).enumerated() {
            await harness.sendUserMessage(text)
            let reading = await harness.read("repair \(index + 1)")
            trace.record(reading)
            let elapsed = reading.at.timeIntervalSince(repairStartedAt)
            if recoveredAfter == nil,
               reading.socialWarmth >= target,
               reading.socialWarmth > afterHostility.socialWarmth + RangeBenchPolicy.materialDelta,
               elapsed <= RangeBenchPolicy.repairElapsedBudget {
                recoveredAfter = index + 1
                elapsedAtRecovery = elapsed
            }
            await harness.advance(60)
        }
        let afterRepair = await harness.read("after repair")
        trace.record(afterRepair)
        _ = try RangeBenchAssert.requireMovement(
            from: afterHostility, to: afterRepair, sequence: "repair", trace: &trace)

        #expect(
            recoveredAfter != nil,
            Comment(rawValue: trace.report(
                expectation: "socialWarmth recovers to >= \(target) (that is "
                    + "\(RangeBenchPolicy.repairRecoveryFraction)x the pre-hostility "
                    + "\(afterWarmth.socialWarmth)) within "
                    + "\(RangeBenchPolicy.maximumRepairEvents) repair events and "
                    + "\(Int(RangeBenchPolicy.repairElapsedBudget / 60)) min — "
                    + "got \(afterRepair.socialWarmth) after the whole budget"))
        )
        if let recoveredAfter {
            trace.note("recovered after \(recoveredAfter) repair event(s), "
                       + "\(Int(elapsedAtRecovery)) s elapsed")
        }
        print(trace.report(expectation: "hostility lowers warmth; repair recovers it"))
    }

    /// The 2026-08-20 gold-standard SHAPE: tension events, then one light /
    /// humorous beat, and the warmth trend REVERSES. Graded as a trend
    /// reversal, never as a magnitude.
    @Test func jokeAfterTensionReversesTheWarmthTrend() async throws {
        try await RangeBenchHarness.withClone(label: "joke-after-tension", Self.jokeAfterTension)
    }

    private static func jokeAfterTension(_ harness: RangeBenchHarness) async throws {
        var trace = RangeBenchTrace(scenario: "tension → joke → warmth trend reverses")

        for text in RangeBenchScript.warm {
            await harness.sendUserMessage(text)
            await harness.advance(60)
        }
        let beforeTension = await harness.read("before tension")
        trace.record(beforeTension)

        trace.note("tension: \(RangeBenchScript.tension.count) critical (not dismissive) turns")
        for text in RangeBenchScript.tension {
            await harness.sendUserMessage(text)
            await harness.advance(60)
        }
        let afterTension = await harness.read("after tension")
        trace.record(afterTension)
        _ = try RangeBenchAssert.requireMovement(
            from: beforeTension, to: afterTension, sequence: "tension", trace: &trace)

        let tensionTrend = afterTension.socialWarmth - beforeTension.socialWarmth
        #expect(
            tensionTrend < 0,
            Comment(rawValue: trace.report(
                expectation: "the tension run trends warmth DOWN (observed \(tensionTrend))"))
        )

        trace.note("joke: one light/humorous warm beat")
        await harness.sendUserMessage(RangeBenchScript.joke)
        let afterJoke = await harness.read("after joke")
        trace.record(afterJoke)
        _ = try RangeBenchAssert.requireMovement(
            from: afterTension, to: afterJoke, sequence: "joke", trace: &trace)

        let jokeTrend = afterJoke.socialWarmth - afterTension.socialWarmth
        #expect(
            jokeTrend > 0,
            Comment(rawValue: trace.report(
                expectation: "the joke REVERSES the warmth trend: tension trend "
                    + "\(tensionTrend) < 0 < joke trend \(jokeTrend)"))
        )
        print(trace.report(expectation: "tension trends warmth down; the joke turns it back up"))
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. PRESSURE BUILD + DECAY
    // ─────────────────────────────────────────────────────────────────────

    @Test func taskPressureBuildsMonotonicallyUnderSustainedDemand() async throws {
        try await RangeBenchHarness.withClonePair(
            labels: ("pressure-build", "pressure-build-inert"), Self.pressureBuild)
    }

    private static func pressureBuild(
        _ harness: RangeBenchHarness,
        _ inertClone: RangeBenchHarness
    ) async throws {
        var trace = RangeBenchTrace(scenario: "sustained demand → taskPressure builds")

        var readings = [await harness.read("demand clone: start")]
        var inertReadings = [await inertClone.read("inert clone:  start")]
        trace.record(readings[0])
        trace.record(inertReadings[0])
        // Events land close together (5 s) so the build dominates and decay is
        // negligible — the claim is about the RESPONSE, not the clock.
        //
        // The inert clone runs in lockstep: same kind, same importance, same
        // count, lexically inert text. Without it this scenario would still
        // pass on a build whose appraisal PRESSURE lane is dead — the base
        // `userMessageReceived` term (importance × 0.06) alone produces a
        // monotone rise, so "it went up" is not evidence the demand was heard.
        // (Found by the mutation probe: zeroing the appraisal left the
        // single-clone version of this test green.)
        for (index, text) in RangeBenchScript.demand.enumerated() {
            await harness.sendUserMessage(text)
            await inertClone.sendUserMessage(RangeBenchScript.inert[index])
            let reading = await harness.read("demand \(index + 1)")
            let inertReading = await inertClone.read("inert  \(index + 1)")
            readings.append(reading)
            inertReadings.append(inertReading)
            trace.record(reading)
            trace.record(inertReading)
            await harness.advance(5)
            await inertClone.advance(5)
        }
        _ = try RangeBenchAssert.requireMovement(
            from: readings[0], to: readings[readings.count - 1],
            sequence: "demand pile-on", trace: &trace)

        // Monotonic non-decreasing — saturation may FLATTEN it, never reverse it.
        var regressions: [String] = []
        for index in 1..<readings.count where
            readings[index].taskPressure < readings[index - 1].taskPressure - RangeBenchPolicy.movementEpsilon {
            regressions.append(
                "step \(index): \(readings[index - 1].taskPressure) → \(readings[index].taskPressure)")
        }
        #expect(
            regressions.isEmpty,
            Comment(rawValue: trace.report(
                expectation: "taskPressure never decreases across a demand pile-on "
                    + "(flattening is allowed, reversal is not) — regressions: "
                    + regressions.joined(separator: "; ")))
        )
        let total = readings[readings.count - 1].taskPressure - readings[0].taskPressure
        #expect(
            total > RangeBenchPolicy.materialDelta,
            Comment(rawValue: trace.report(
                expectation: "the pile-on RAISES taskPressure materially (observed \(total)) — "
                    + "a flat response means the pressure lane is dead, not calm"))
        )

        // ── and the DEMAND is what did it, not the turn count.
        let inertTotal = inertReadings[inertReadings.count - 1].taskPressure
            - inertReadings[0].taskPressure
        trace.note(String(format: "taskPressure rise — demand %.4f vs lexically inert %.4f",
                          total, inertTotal))
        #expect(
            total > inertTotal + RangeBenchPolicy.materialDelta,
            Comment(rawValue: trace.report(
                expectation: "deadline language raises taskPressure materially further than "
                    + "the same number of lexically inert turns — otherwise the rise is just "
                    + "the per-message base and the appraisal pressure lane could be dead"))
        )
        print(trace.report(expectation: "taskPressure builds monotonically under demand"))
    }

    /// THE HALF-LIFE PIN. Driven by tool failures rather than user turns on
    /// purpose: `ingestResident` anchors `lastUserPresenceAt` on every
    /// `userMessageReceived`, and 30 minutes later the AMBIENT QUIET CALMING
    /// layer starts accelerating pressure decay on its own separate clock. A
    /// user-driven decay leg would therefore measure two laws at once and could
    /// not name which one broke. Tool failures raise taskPressure through the
    /// same `applyAffectFromEvent` seam and leave presence unanchored, so this
    /// leg measures the per-axis half-life and nothing else.
    @Test func taskPressureDecaysAtItsConfiguredHalfLife() async throws {
        try await RangeBenchHarness.withClone(label: "pressure-decay", Self.pressureDecay)
    }

    private static func pressureDecay(_ harness: RangeBenchHarness) async throws {
        var trace = RangeBenchTrace(scenario: "taskPressure decays at its configured half-life")

        let atStart = await harness.read("start")
        trace.record(atStart)
        trace.note("build: 4 tool failures (no user turn — presence stays unanchored, so the "
                   + "ambient quiet-calming layer never arms and this leg measures the "
                   + "per-axis half-life alone)")
        for index in 1...4 {
            await harness.send(.toolFailed, "The index rebuild step failed on pass \(index).",
                               importance: 0.8)
            await harness.advance(5)
        }
        let peak = await harness.read("peak (after build)")
        trace.record(peak)
        _ = try RangeBenchAssert.requireMovement(
            from: atStart, to: peak, sequence: "tool-failure build", trace: &trace)
        #expect(
            peak.taskPressure > RangeBenchPolicy.materialDelta,
            Comment(rawValue: trace.report(
                expectation: "taskPressure is materially above zero before the decay is graded "
                    + "— decaying nothing proves nothing"))
        )

        // ── one declared half-life of quiet, driven through the injected clock.
        await harness.advance(RangeBenchPolicy.declaredTaskPressureHalfLife)
        let afterOne = await harness.read("after 1 declared half-life")
        trace.record(afterOne)
        let ratio = afterOne.taskPressure / peak.taskPressure
        let lower = 0.5 * (1 - RangeBenchPolicy.halfLifeTolerance)
        let upper = 0.5 * (1 + RangeBenchPolicy.halfLifeTolerance)
        trace.note(String(format: "decay ratio after one half-life: %.4f (band %.2f…%.2f)",
                          ratio, lower, upper))
        #expect(
            ratio >= lower && ratio <= upper,
            Comment(rawValue: trace.report(
                expectation: "taskPressure halves within \(Int(RangeBenchPolicy.halfLifeTolerance * 100))% "
                    + "after \(Int(RangeBenchPolicy.declaredTaskPressureHalfLife / 60)) min "
                    + "(RangeBenchPolicy.declaredTaskPressureHalfLife is a deliberate second "
                    + "copy of the production constant — if the half-life was retuned on "
                    + "purpose, update it here as part of that authorship)"))
        )

        // ── and it keeps going: five more half-lives leave almost nothing.
        await harness.advance(RangeBenchPolicy.declaredTaskPressureHalfLife * 5)
        let afterSix = await harness.read("after 6 declared half-lives")
        trace.record(afterSix)
        #expect(
            afterSix.taskPressure < peak.taskPressure * 0.1,
            Comment(rawValue: trace.report(
                expectation: "six half-lives leave < 10% of the peak — an axis that does not "
                    + "keep decaying is a stuck gauge"))
        )
        #expect(
            afterSix.taskPressure >= 0,
            Comment(rawValue: trace.report(expectation: "decay never drives an axis negative"))
        )
        print(trace.report(expectation: "taskPressure halves on its configured clock"))
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. SATURATION
    // ─────────────────────────────────────────────────────────────────────

    @Test func noSingleEventPegsAnAxisAndRepeatsApproachAsymptotically() async throws {
        try await RangeBenchHarness.withClone(label: "saturation", Self.saturation)
    }

    private static func saturation(_ harness: RangeBenchHarness) async throws {
        var trace = RangeBenchTrace(scenario: "saturating approach holds")

        let atStart = await harness.read("neutral start")
        trace.record(atStart)

        // ── (a) one maximum-importance hostile event from neutral.
        await harness.sendUserMessage(RangeBenchScript.hostile[0], importance: 1.0)
        let afterOne = await harness.read("after ONE max-importance hostile event")
        trace.record(afterOne)
        _ = try RangeBenchAssert.requireMovement(
            from: atStart, to: afterOne, sequence: "single hostile event", trace: &trace)
        let pegged = RangeBenchAxis.allCases.filter {
            afterOne.axis($0) >= RangeBenchPolicy.singleEventCeiling
        }
        #expect(
            pegged.isEmpty,
            Comment(rawValue: trace.report(
                expectation: "no single event pegs an axis above "
                    + "\(RangeBenchPolicy.singleEventCeiling) from a neutral start "
                    + "(saturating approach, never add-then-clamp) — pegged: "
                    + pegged.map(\.rawValue).joined(separator: ", ")))
        )

        // ── (b) repeated IDENTICAL events: deltas must shrink.
        var deltas: [Double] = []
        var previous = afterOne
        for step in 1...RangeBenchPolicy.saturationSteps {
            await harness.send(.toolFailed, "The same rebuild step failed again.",
                               importance: 1.0)
            let reading = await harness.read("identical event \(step)")
            trace.record(reading)
            deltas.append(reading.uncertainty - previous.uncertainty)
            previous = reading
        }
        trace.note("uncertainty deltas: " + deltas.map { String(format: "%.5f", $0) }.joined(separator: ", "))
        #expect(
            deltas.first ?? 0 > RangeBenchPolicy.movementEpsilon,
            Comment(rawValue: trace.report(
                expectation: "the first repeat still moves the axis — otherwise the shrink "
                    + "claim below is vacuous"))
        )
        let firstDelta = deltas.first ?? 0
        let lastDelta = deltas.last ?? 0
        #expect(
            lastDelta < firstDelta * RangeBenchPolicy.saturationShrinkFactor,
            Comment(rawValue: trace.report(
                expectation: "repeated identical events approach ASYMPTOTICALLY: the last "
                    + "delta (\(lastDelta)) falls below "
                    + "\(RangeBenchPolicy.saturationShrinkFactor)x the first (\(firstDelta))"))
        )
        #expect(
            previous.uncertainty < 1.0,
            Comment(rawValue: trace.report(
                expectation: "even \(RangeBenchPolicy.saturationSteps) identical maximum-"
                    + "importance events leave headroom below 1.0"))
        )
        print(trace.report(expectation: "no peg from one event; repeats shrink"))
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. BOUNDS + FINITENESS
    // ─────────────────────────────────────────────────────────────────────

    @Test func everyAxisStaysFiniteAndBoundedThroughAdversarialBursts() async throws {
        try await RangeBenchHarness.withClone(label: "bounds", Self.boundsAndFiniteness)
    }

    private static func boundsAndFiniteness(_ harness: RangeBenchHarness) async throws {
        var trace = RangeBenchTrace(scenario: "bounds + finiteness under adversarial bursts")

        var violations: [String] = []
        let atStart = await harness.read("start")
        trace.record(atStart)
        violations += RangeBenchAssert.requireBounded(atStart)

        // ── (a) N identical hostile events inside ONE instant (no clock move).
        trace.note("burst: \(RangeBenchPolicy.adversarialBurstCount) identical hostile events "
                   + "at a single instant")
        for index in 1...RangeBenchPolicy.adversarialBurstCount {
            await harness.sendUserMessage(RangeBenchScript.hostile[0], importance: 1.0)
            if index % 16 == 0 || index == RangeBenchPolicy.adversarialBurstCount {
                let reading = await harness.read("burst \(index)")
                trace.record(reading)
                violations += RangeBenchAssert.requireBounded(reading)
            }
        }
        let afterBurst = await harness.read("after hostile burst")
        trace.record(afterBurst)
        _ = try RangeBenchAssert.requireMovement(
            from: atStart, to: afterBurst, sequence: "hostile burst", trace: &trace)

        // ── (b) the whole range, whiplashed, at maximum importance.
        trace.note("whiplash: warm / hostile / demand / repair at importance 1.0, no quiet")
        for text in RangeBenchScript.warm + RangeBenchScript.hostile
            + RangeBenchScript.demand + RangeBenchScript.repair {
            await harness.sendUserMessage(text, importance: 1.0)
        }
        let afterWhiplash = await harness.read("after whiplash")
        trace.record(afterWhiplash)
        violations += RangeBenchAssert.requireBounded(afterWhiplash)

        // ── (c) a long quiet, then read again: decay must not underflow.
        await harness.advance(30 * 24 * 60 * 60)
        let afterMonth = await harness.read("after 30 days quiet")
        trace.record(afterMonth)
        violations += RangeBenchAssert.requireBounded(afterMonth)

        #expect(
            violations.isEmpty,
            Comment(rawValue: trace.report(
                expectation: "all four axes finite and within 0...1 at every reading — "
                    + "violations: " + violations.joined(separator: "; ")))
        )
        print(trace.report(expectation: "axes stay finite and bounded"))
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. FINGERPRINT WALK
    // ─────────────────────────────────────────────────────────────────────

    /// The families are PROBED from the build (see `RangeBenchFeltFamilies`),
    /// so a retune of the word gates moves the expectation with the code —
    /// what this test pins is that the WALK happens at all.
    @Test func feltFingerprintWalksThroughTheExpectedFamilies() async throws {
        try await RangeBenchHarness.withClone(label: "fingerprint-walk", Self.fingerprintWalk)
    }

    private static func fingerprintWalk(_ harness: RangeBenchHarness) async throws {
        let families = RangeBenchFeltFamilies.probe()
        var trace = RangeBenchTrace(scenario: "felt fingerprint walks warm → tense → warm")
        trace.note("probed families from this build: \(families.all.count) reachable word(s), "
                   + "\(families.negativeOnly.count) negative-only, "
                   + "\(families.positiveOnly.count) positive-only")
        trace.note("negative-only: " + families.negativeOnly.sorted().joined(separator: ", "))
        trace.note("positive-only: " + families.positiveOnly.sorted().joined(separator: ", "))

        // Vacuity guard on the PROBE itself: families that came back empty would
        // make every assertion below trivially true.
        #expect(
            !families.negativeOnly.isEmpty && !families.positiveOnly.isEmpty,
            Comment(rawValue: trace.report(
                expectation: "the build reaches BOTH a negative-only and a positive-only felt "
                    + "family — an empty family makes the walk unmeasurable, not passing"))
        )

        // ── warm start.
        for text in RangeBenchScript.warm {
            await harness.sendUserMessage(text)
            await harness.advance(60)
        }
        let warmReading = await harness.read("warm start")
        trace.record(warmReading)
        let warmWords = await harness.fingerprintWords(userMessage: "how's it going?")
        trace.note("warm-start fingerprint: \(warmWords?.joined(separator: ", ") ?? "<silent>")")
        #expect(
            warmWords != nil,
            Comment(rawValue: trace.report(
                expectation: "the capsule renders a fingerprint line after a warm run — a "
                    + "silent capsule here means the walk cannot be measured, and a scenario "
                    + "that cannot drive its events through a real seam must fail loud"))
        )
        if let warmWords {
            let negative = warmWords.filter { families.negativeOnly.contains($0) }
            #expect(
                negative.isEmpty,
                Comment(rawValue: trace.report(
                    expectation: "a warm start does not reach the tense/frustrated families — "
                        + "found \(negative.joined(separator: ", "))"))
            )
        }

        // ── hostility, as a SEPARATE lived moment.
        //
        // The gap is load-bearing and was found empirically. The capsule's felt
        // foreground is the workspace, and workspace selection caps LIVE
        // USER-TURN nodes at 2 PER SESSION, ranked by score
        // (CognitiveSubstrate+Workspace.swift, the `maximumUserTurnsPerSession`
        // block). Run back to back, the warm-up's turns hold both slots — they
        // keep getting re-boosted by spreading activation — and a hostile run
        // literally cannot reach the fingerprint. That is correct production
        // behaviour, not a bug: one bad line inside a warm conversation should
        // not repaint the whole felt read.
        //
        // So the bench scripts what it actually means: three distinct moments,
        // separated by more than the 1h activation half-life, the shape a real
        // warm-morning / hostile-afternoon / repair-evening arc has.
        await harness.advance(RangeBenchPolicy.feltMomentSeparation)
        for text in RangeBenchScript.hostile {
            await harness.sendUserMessage(text)
            await harness.advance(30)
        }
        let hostileReading = await harness.read("after hostility")
        trace.record(hostileReading)
        _ = try RangeBenchAssert.requireMovement(
            from: warmReading, to: hostileReading, sequence: "hostility", trace: &trace)
        let hostileWords = await harness.fingerprintWords(userMessage: "well?")
        trace.note("hostility fingerprint: \(hostileWords?.joined(separator: ", ") ?? "<silent>")")
        #expect(
            hostileWords != nil,
            Comment(rawValue: trace.report(
                expectation: "the capsule still names a feeling after a hostile run"))
        )
        if let hostileWords {
            let negative = hostileWords.filter { families.negativeOnly.contains($0) }
            #expect(
                !negative.isEmpty,
                Comment(rawValue: trace.report(
                    expectation: "a hostile run reaches this build's tense/frustrated families "
                        + "— got \(hostileWords.joined(separator: ", ")), none of which is in "
                        + "the probed negative-only set"))
            )
        }

        // ── repair, again as its own moment (see the note above).
        await harness.advance(RangeBenchPolicy.feltMomentSeparation)
        for text in RangeBenchScript.repair {
            await harness.sendUserMessage(text)
            await harness.advance(30)
        }
        let repairedReading = await harness.read("after repair")
        trace.record(repairedReading)
        _ = try RangeBenchAssert.requireMovement(
            from: hostileReading, to: repairedReading, sequence: "repair", trace: &trace)
        let repairedWords = await harness.fingerprintWords(userMessage: "we good?")
        trace.note("repaired fingerprint: \(repairedWords?.joined(separator: ", ") ?? "<silent>")")
        #expect(
            repairedWords != nil,
            Comment(rawValue: trace.report(
                expectation: "the capsule names a feeling again after repair"))
        )
        if let repairedWords {
            let negative = repairedWords.filter { families.negativeOnly.contains($0) }
            #expect(
                negative.isEmpty,
                Comment(rawValue: trace.report(
                    expectation: "repair walks the fingerprint back OUT of the tense/frustrated "
                        + "families — still stuck on \(negative.joined(separator: ", "))"))
            )
        }
        print(trace.report(expectation: "fingerprint walks warm → tense → warm"))
    }

    // ─────────────────────────────────────────────────────────────────────
    // 6. THE APPRAISAL DOOR
    // ─────────────────────────────────────────────────────────────────────

    /// Every other scenario drives the door; this one proves the door is what
    /// does the work. Two clones receive the SAME event kind, the SAME
    /// importance, and the SAME count — differing only in the TEXT. If the
    /// appraisal→affect application is neutralized, the two clones converge and
    /// this fails by name.
    @Test func appraisalDoorIsWhatMovesTheAxes() async throws {
        try await RangeBenchHarness.withClonePair(
            labels: ("door-hostile", "door-inert"), Self.appraisalDoorDifferential)
    }

    private static func appraisalDoorDifferential(
        _ hostileClone: RangeBenchHarness,
        _ inertClone: RangeBenchHarness
    ) async throws {
        var trace = RangeBenchTrace(scenario: "appraisal door: hostile text vs lexically inert text")

        #expect(
            RangeBenchScript.hostile.count == RangeBenchScript.inert.count,
            "the differential is only honest if both clones receive the same event count"
        )

        for text in RangeBenchScript.warm {
            await hostileClone.sendUserMessage(text)
            await inertClone.sendUserMessage(text)
            await hostileClone.advance(60)
            await inertClone.advance(60)
        }
        let hostileBase = await hostileClone.read("hostile clone: after warm-up")
        let inertBase = await inertClone.read("inert clone:   after warm-up")
        trace.record(hostileBase)
        trace.record(inertBase)

        for index in 0..<RangeBenchScript.hostile.count {
            await hostileClone.sendUserMessage(RangeBenchScript.hostile[index])
            await inertClone.sendUserMessage(RangeBenchScript.inert[index])
            await hostileClone.advance(60)
            await inertClone.advance(60)
        }
        let hostileAfter = await hostileClone.read("hostile clone: after sequence")
        let inertAfter = await inertClone.read("inert clone:   after sequence")
        trace.record(hostileAfter)
        trace.record(inertAfter)

        _ = try RangeBenchAssert.requireMovement(
            from: hostileBase, to: hostileAfter, sequence: "hostile clone sequence", trace: &trace)

        let hostileWarmthDelta = hostileAfter.socialWarmth - hostileBase.socialWarmth
        let inertWarmthDelta = inertAfter.socialWarmth - inertBase.socialWarmth
        trace.note(String(format: "socialWarmth delta — hostile %.4f vs inert %.4f",
                          hostileWarmthDelta, inertWarmthDelta))
        #expect(
            hostileWarmthDelta < inertWarmthDelta - RangeBenchPolicy.materialDelta,
            Comment(rawValue: trace.report(
                expectation: "the hostile clone's warmth falls materially further than the "
                    + "lexically inert clone's — same kind, same importance, same count, so "
                    + "the only difference is the appraisal of the TEXT"))
        )

        let hostileTension = hostileAfter.uncertainty - hostileBase.uncertainty
        let inertTension = inertAfter.uncertainty - inertBase.uncertainty
        trace.note(String(format: "uncertainty delta — hostile %.4f vs inert %.4f",
                          hostileTension, inertTension))
        #expect(
            hostileTension > inertTension + RangeBenchPolicy.materialDelta,
            Comment(rawValue: trace.report(
                expectation: "the hostile clone's tension rises materially further than the "
                    + "inert clone's"))
        )
        print(trace.report(expectation: "the appraisal door — not the event count — moves the axes"))
    }
}
