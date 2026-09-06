//  TurnReplayBenchTests.swift — the TURN-REPLAY BENCH.
//
//  Item 2 of docs/build_plans/agent-improvement-instrument.md: the
//  "did we change who she is" regression gate.
//
//  ─────────────────────────────────────────────────────────────────────────
//  WHAT IT ACTUALLY RUNS (the seam, and why it is this one)
//  ─────────────────────────────────────────────────────────────────────────
//  The bench REPLAYS recorded real user messages through the candidate build's
//  own per-turn context assembly, against a hermetic snapshot of the store
//  those turns ran on. It then awaits and re-parses the candidate's canonical
//  persisted turn-trace rows, rather than treating in-memory delivery as proof.
//
//  The production path for one live turn is:
//
//    makeChatOrchestrationClient(tools:dataRoot:cognitiveContextProvider:
//                                contextFlow:memoryAtomTranslator:)
//      → SwiftNativeChatOrchestrationClient
//          .engine.buildTurnContext(...)          ← persona + memory + REM
//              → NativeContextFlowRuntime         ← Fluid Context packet
//                  → ContextFlowCoordinator.prepareTurn
//              → NativeCognitionRuntime.attentionSignals  ← attention lanes
//          .contextByAppendingCognitiveCapsule(...)  ← [CognitiveSubstrate]
//              ← NativeCognitionRuntime.prepareTurnProjection
//                                                    ← [OrganismBehavior]
//
//  When a session is live, production streaming wraps that in the
//  SESSION-HISTORY path (ChatOrchestration+Streaming.swift →
//  ChatOrchestration+SessionHistory.swift):
//
//    engine.buildTurnContextWithHistory(sessionId:historyReader:…)
//      → SessionHistoryReader.promptMessagesWithStats   ← chat/messages/<sid>.jsonl
//      → SessionHistoryPromptRenderer.recallQuery        ← recall-query EXPANSION
//      → engine.buildTurnContext(recallQueryOverride:, recentTurns: prior.suffix(4))
//      → SessionHistoryPromptRenderer.renderDetailed     ← history block, appended
//                                                           to the DYNAMIC segment
//      → emits its own `context.history.summary` receipt
//
//  Since 2026-08-21 (v2 fixtures) the bench replays THAT path whenever a
//  captured turn carries a bounded transcript window — the prior rows the
//  source turn actually saw, copied verbatim by `agent_bench_capture.swift`
//  into `root/chat/transcripts/<turnId>.jsonl` and staged into the
//  production-keyed `root/chat/messages/<sessionId>.jsonl` for the duration of
//  that turn's replay. Both receipts (inner `context.summary`, outer
//  `context.history.summary`) are captured on the private bus and graded. A
//  v1 fixture (no transcript) still replays bare `buildTurnContext`.
//
//  NAMED LIMIT of the history lane: the window is BOUNDED (head anchors +
//  ≤80-line/≤192KB tail), so the reader's relevance-sampled MIDDLE lane —
//  which production runs when prior.count > historyLimit or the file was not
//  fully read — still runs on windows above 40 rows, but samples the WINDOW,
//  not the full source transcript. A regression confined to middle-snippet
//  selection over a long transcript is therefore not graded here; it is named,
//  not silently covered.
//
//  Every arrow above is exercised here with the REAL type, on a fixture data
//  root. Three seams are deliberately NOT real:
//
//    * the LLM. `makeChatOrchestrationClient` on a non-default data root
//      installs `AlternateRootUnavailableChatLLMClient`, which throws on any
//      complete()/stream(). The bench never calls it — assembling the context
//      IS the measured artifact. No network, no tokens.
//    * the tool dispatcher (`BenchNoToolsDispatcher`) — tool inventory is not
//      an identity signal and the real one touches process-global state.
//    * the cognition master ON/OFF toggle, which lives in the app's
//      UserDefaults suite and is not shared with a `swift test` process. The
//      bench forces the enabled branch of the real resolver (see
//      `benchCognitiveConfiguration`). It grades what she IS when the
//      subsystem is on, not whether the user turned it on.
//
//  One seam is real but HERMETICALLY ROOTED: the prior-session anchor
//  (`SessionDigestProvider`) reads `<dataRoot>/chat/sessions.json`. The bench
//  passes a provider rooted INSIDE the fixture, so a replay never reads the
//  live session index; an absent one fails open to no anchor, as in
//  production.
//
//  ─────────────────────────────────────────────────────────────────────────
//  WHAT IT GRADES: ENVELOPE INVARIANTS, NOT BYTE EQUALITY
//  ─────────────────────────────────────────────────────────────────────────
//  Substrate state legitimately drifts between the recorded turn and the
//  replay — affect decays, the workspace turns over, memory grows. Byte
//  equality would be a flake generator that teaches people to disable the
//  gate. So each invariant asks "is this lane still ALIVE and in shape",
//  citing the recorded turn's own numbers as the floor.
//
//  ─────────────────────────────────────────────────────────────────────────
//  TWO FIXTURE MODES
//  ─────────────────────────────────────────────────────────────────────────
//    * SYNTHETIC (always on, no env var): a tiny hand-built root created in a
//      temp dir by `SyntheticBenchFixture` — generic persona docs, a seeded
//      cognitive substrate, no personal data. `swift test` therefore always
//      exercises the bench end-to-end.
//    * REAL: `NATIVEAGENT_BENCH_FIXTURE=<dir>` points at a fixture produced by
//      `script/agent_bench_capture.swift`. Absent env var → that test is
//      skipped, never silently passed.
//
//  A bench run with ZERO turns is a FAILURE in both modes (vacuity guard).
//

import Foundation
import Testing
import CognitiveSubstrate
import Context
import MemoryV2
import NativeAgentCore
import PersistenceCore
@testable import ChatOrchestration
@testable import NativeAgentApp

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Substrate-owned REM-pin read grading
// ─────────────────────────────────────────────────────────────────────────────

/// Ledger row `speed.rem_pins.read` (core.substrate.organism).
///
/// `TurnReplayStageBudget` continues to grade the whole turn-contract stage
/// vocabulary.  This small, separate grade is deliberately substrate-owned:
/// every replay must publish the REM index read, and the run-wide p95 keeps a
/// synchronous persisted-index read from becoming an unbounded hidden cost.
enum TurnReplaySubstrateREMPinsGrade {
    static let p95BudgetMs = 15

    static func p95(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = max(0, (sorted.count * 95 + 99) / 100 - 1) // ceil(0.95n) - 1
        return sorted[index]
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Fixture model
// ─────────────────────────────────────────────────────────────────────────────

/// Per-turn expectations captured from the SOURCE build's live turn traces.
/// Every field is what the recorded turn actually produced — the bench uses
/// them as floors and bands, never as byte targets.
struct BenchTurnExpectation: Sendable {
    var turnId: String
    var sessionId: String
    var surface: String
    var userMessage: String
    var counts: [String: Int]
    var flags: [String: Bool]
    var capsuleBytes: Int?
    var containsCognitiveSubstrate: Bool?
    var containsOrganismBehavior: Bool?
    /// When the SOURCE turn ran. Used for the staleness gate below — NOT as
    /// the replay clock (see `BenchFixture.capturedAt`).
    var ts: Date?
    /// The bounded transcript window the source turn saw (v2 fixtures).
    /// Present ⇒ this turn replays through `buildTurnContextWithHistory`.
    var transcript: BenchTranscriptWindow?
    /// The exact REM pin texts the fixture AUTHORED for this turn, when it
    /// authored them.
    ///
    /// SYNTHETIC ONLY. The bench wrote those pins itself, so asserting the text
    /// reached the STABLE segment is a genuine end-to-end proof, not a byte
    /// equality flake. A REAL fixture leaves this empty and only the header and
    /// the count are graded — a live pin's text is REM-authored and drifts, and
    /// the ledger row says explicitly: never byte-equality on pin text.
    var remPinTexts: [String] = []

    func count(_ key: String) -> Int { counts[key] ?? 0 }
}

/// One captured turn's prior-conversation window: a verbatim copy of the rows
/// of `chat/messages/<sessionId>.jsonl` that preceded the source user row,
/// bounded the way `SessionHistoryReader` bounds its own read (head anchors +
/// ≤80-line/≤192KB tail). Staged into the production-keyed path per turn.
struct BenchTranscriptWindow: Sendable {
    /// Absolute URL of the window file inside the fixture.
    var fileURL: URL
    /// Raw line count as captured (reported, not graded).
    var lines: Int
    /// Whether the capture bounded the window below the full prefix.
    var truncated: Bool
}

struct BenchFixture: Sendable {
    var label: String
    var dataRoot: URL
    var turns: [BenchTurnExpectation]
    /// WHEN THE STORES WERE SNAPSHOT — and therefore the instant the replay
    /// clock is pinned to.
    ///
    /// This took one wrong turn to get right and the reasoning is worth
    /// keeping. The substrate's hot set decays against `now` (1h activation
    /// half-life), so replaying at wall-clock `now` — hours or days after the
    /// capture — reads a mind that has aged in a freezer and reports every
    /// attention lane dead. The obvious correction, pinning to the SOURCE
    /// TURN's timestamp, is worse: the fixture's stores hold state as of
    /// CAPTURE, not as of the turn, so it winds the clock back behind the
    /// substrate's own `updatedAt` and every affect axis reads exactly 0.
    ///
    /// Capture time is the only instant at which the fixture is internally
    /// coherent. The recorded turn's numbers stay what they are — a floor from
    /// earlier — and the gap between the two is handled explicitly by the
    /// staleness gate in `evaluate`, never by pretending it isn't there.
    var capturedAt: Date = Date()
    /// NEGATIVE-CONTROL SWITCH for the plan-hint lane. When true the runner
    /// skips `contextByAppendingTurnPlanHint`, reproducing exactly the failure
    /// live telemetry cannot see: a plan that was computed, traced, and whose
    /// hint never reached the prompt. Nothing but the bench's own negative
    /// control sets it — a real or synthetic fixture leaves it false.
    var suppressTurnPlanHint: Bool = false
    /// BENCH-ONLY fault injection for the persisted trace reader. This never
    /// changes the engine or its bus: after the canonical JSONL row has been
    /// read, it removes the one stage from that decoded row so the named
    /// substrate admission check can prove it rejects a missing sample.
    var removePersistedRemPinsStageForNegativeControl: Bool = false
    /// Optional substrate seeding, run against the SAME runtime instance the
    /// bench replays through. Real fixtures leave it nil (their substrate came
    /// off disk); the synthetic fixture uses it because a separate seeding
    /// instance would not have flushed its nodes to the fixture store.
    var seed: (@Sendable (NativeCognitionRuntime) async -> Void)?

    /// Decode a fixture directory produced by `script/agent_bench_capture.swift`.
    static func load(directory: URL, label: String) throws -> BenchFixture {
        let expectationsURL = directory.appendingPathComponent("expectations.json")
        let data = try Data(contentsOf: expectationsURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BenchError.malformedFixture("expectations.json is not a JSON object")
        }
        // v1: bare-path fixtures. v2 (2026-08-21): per-turn `transcript`
        // windows + `history.*` counts → the session-history lane.
        guard let schema = object["schema"] as? String,
              schema == "turn-replay-bench.expectations.v1"
                || schema == "turn-replay-bench.expectations.v2" else {
            throw BenchError.malformedFixture(
                "unsupported expectations schema: \(object["schema"] as? String ?? "<missing>")"
            )
        }
        let relativeRoot = (object["fixtureDataRoot"] as? String) ?? "root"
        let root = directory.appendingPathComponent(relativeRoot, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw BenchError.malformedFixture("fixture data root missing at \(root.path)")
        }
        let rawTurns = (object["turns"] as? [[String: Any]]) ?? []
        let turns: [BenchTurnExpectation] = try rawTurns.compactMap { raw in
            guard let turnId = raw["turnId"] as? String,
                  let message = raw["userMessage"] as? String,
                  !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            var counts: [String: Int] = [:]
            for (k, v) in (raw["counts"] as? [String: Any]) ?? [:] {
                if let n = v as? Int { counts[k] = n } else if let d = v as? Double { counts[k] = Int(d) }
            }
            var flags: [String: Bool] = [:]
            for (k, v) in (raw["flags"] as? [String: Any]) ?? [:] {
                if let b = v as? Bool { flags[k] = b }
            }
            let capsule = raw["capsule"] as? [String: Any]
            // A declared transcript whose file is missing is a MALFORMED
            // fixture, not a bare-path turn: silently downgrading would let a
            // broken capture grade the history lane as "not applicable".
            var transcript: BenchTranscriptWindow?
            if let rawTranscript = raw["transcript"] as? [String: Any] {
                guard let relative = rawTranscript["relativePath"] as? String,
                      !relative.isEmpty else {
                    throw BenchError.malformedFixture(
                        "turn \(turnId): transcript entry has no relativePath"
                    )
                }
                let url = root.appendingPathComponent(relative)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw BenchError.malformedFixture(
                        "turn \(turnId): transcript window missing at \(url.path)"
                    )
                }
                transcript = BenchTranscriptWindow(
                    fileURL: url,
                    lines: (rawTranscript["lines"] as? Int) ?? 0,
                    truncated: (rawTranscript["truncated"] as? Bool) ?? false
                )
            }
            return BenchTurnExpectation(
                turnId: turnId,
                sessionId: (raw["sessionId"] as? String) ?? "",
                surface: (raw["surface"] as? String) ?? "chat",
                userMessage: message,
                counts: counts,
                flags: flags,
                capsuleBytes: capsule?["bytes"] as? Int,
                containsCognitiveSubstrate: capsule?["containsCognitiveSubstrate"] as? Bool,
                containsOrganismBehavior: capsule?["containsOrganismBehavior"] as? Bool,
                ts: (raw["ts"] as? String).flatMap(Self.parseTimestamp),
                transcript: transcript
            )
        }
        return BenchFixture(
            label: label,
            dataRoot: root,
            turns: turns.sorted { ($0.ts ?? .distantPast) < ($1.ts ?? .distantPast) },
            capturedAt: (object["capturedAt"] as? String).flatMap(Self.parseTimestamp) ?? Date()
        )
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let d = formatter.date(from: raw) { return d }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }
}

enum BenchError: Error, CustomStringConvertible {
    case malformedFixture(String)
    case assemblyUnavailable(String)

    var description: String {
        switch self {
        case .malformedFixture(let s): return "malformed fixture: \(s)"
        case .assemblyUnavailable(let s): return "context assembly unavailable: \(s)"
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Findings
// ─────────────────────────────────────────────────────────────────────────────

/// One named invariant breach. Every failure names the turn, the invariant,
/// and expected-vs-got — a bench that says only "failed" cannot be acted on.
struct BenchFinding: Sendable, CustomStringConvertible {
    var turn: String
    var invariant: String
    var expected: String
    var got: String

    var description: String {
        "[\(turn)] \(invariant): expected \(expected), got \(got)"
    }
}

struct BenchResult: Sendable {
    var fixture: String
    var turnsReplayed: Int = 0
    var findings: [BenchFinding] = []
    var lines: [String] = []

    var passed: Bool { findings.isEmpty && turnsReplayed > 0 }

    var report: String {
        var out = ["turn-replay bench — fixture \(fixture): \(turnsReplayed) turn(s) replayed"]
        out.append(contentsOf: lines.map { "  " + $0 })
        if findings.isEmpty {
            out.append(turnsReplayed > 0
                       ? "  VERDICT: PASS — every envelope invariant held"
                       : "  VERDICT: FAIL — zero turns replayed (vacuity guard)")
        } else {
            out.append("  VERDICT: FAIL — \(findings.count) invariant breach(es)")
            out.append(contentsOf: findings.map { "  ✗ " + $0.description })
        }
        return out.joined(separator: "\n")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Bench-only stubs (the two seams that are deliberately not real)
// ─────────────────────────────────────────────────────────────────────────────

/// No tools. Tool inventory is not an identity signal, and the production
/// dispatcher reaches process-global state that a hermetic replay must not
/// touch. `context.summary`'s tool counts are therefore expected to be 0 in a
/// replay and are NOT graded.
private struct BenchNoToolsDispatcher: ToolDispatchClient {
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        throw BenchError.assemblyUnavailable("the bench never dispatches tools")
    }
    func listAvailableTools() async throws -> [String] { [] }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] { [] }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - The runner
// ─────────────────────────────────────────────────────────────────────────────

/// Bands and floors, named once so a failure report can cite them and a future
/// reader can argue with the number instead of guessing it.
enum BenchPolicy {
    /// Segment sizes drift with the substrate; they must stay in the same
    /// order of magnitude as the recorded turn. Widened from the 0.5x–2x
    /// starting point only where live evidence forced it (see docs/INSTRUMENT.md).
    static let stableSegmentBand: ClosedRange<Double> = 0.5...2.0
    static let dynamicSegmentBand: ClosedRange<Double> = 0.25...4.0
    /// How long a replayed turn may take to publish its `context.summary`
    /// trace on the bench's private bus. Bounded so a lost emission FAILS
    /// instead of hanging the suite (hangproof convention).
    static let traceDeadline: TimeInterval = 20
    /// The felt-fingerprint vocabulary the build can still reach. A lobotomy
    /// that empties the word families drops this to near zero.
    static let minimumFeltVocabulary = 12
    /// How far a fixture's CAPTURE may sit after a recorded turn before that
    /// turn's WORKING-SET expectations (memory activation / working atoms) stop
    /// transferring.
    ///
    /// Those two lanes are read off the substrate's hot set, which decays on a
    /// 1h activation half-life. A store snapshot taken ten hours after the turn
    /// no longer contains the hot nodes that produced those numbers — through
    /// no fault of the build. Past this horizon the lanes are reported
    /// UNMEASURABLE by name, with the gap, and never as a healthy zero.
    static let workingSetTransferHorizon: TimeInterval = 2 * 60 * 60
    static let workingSetLanes: Set<String> = [
        "contextFlow.attentionActivation",
        "contextFlow.attentionWorkingAtoms",
    ]
    /// The production history window. `ChatOrchestration+Streaming` passes
    /// the engine default (40); the capture bounds its transcript window to
    /// the reader's matching tail (max(64, 40*2) = 80 lines).
    static let historyLimit = 40
}

/// The substrate clock the bench pins per turn. `NativeCognitionRuntime` takes
/// `now` as a `@Sendable () -> Date`, so this box is the only way to move the
/// whole subconscious to the instant a recorded turn actually ran.
final class BenchClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

actor TurnReplayBench {
    private let fixture: BenchFixture

    init(fixture: BenchFixture) { self.fixture = fixture }

    /// The cognition config the bench runs under: the REAL production resolver,
    /// with the master enable branch forced on (see the file header).
    static func benchCognitiveConfiguration() -> CognitiveConfiguration {
        var configuration = NativeCognitionRuntime.loadConfiguration()
        guard !configuration.enabled else { return configuration }
        configuration.enabled = true
        configuration.persistenceEnabled = true
        configuration.workspaceEnabled = true
        configuration.capsuleInjectionEnabled = true
        configuration.affectEnabled = true
        configuration.thoughtSeedsEnabled = true
        configuration.replayEnabled = true
        configuration.observatoryEnabled = true
        // Background microcycles and reflective (LLM) calls stay OFF: the bench
        // must never start a loop or reach a provider.
        configuration.backgroundMicrocyclesEnabled = false
        configuration.reflectiveCallsEnabled = false
        configuration.dailyReflectionCallBudget = 0
        configuration.maximumCapsuleCharacters = 4_000
        return configuration
    }

    /// Sweep the build's felt-fingerprint mapping over a coarse signal grid and
    /// collect every word it can still emit. This is the vocabulary probe: it
    /// asks the CANDIDATE BUILD what feelings it is capable of naming, rather
    /// than comparing against a hardcoded list that would rot.
    static func reachableFeltVocabulary() -> Set<String> {
        var words: Set<String> = []
        let axis: [Double] = [0, 0.25, 0.5, 0.75, 1.0]
        let valences: [Double] = [-1.0, -0.5, -0.15, 0, 0.15, 0.5, 1.0]
        let optional: [Double?] = [nil, 0.1, 0.5, 0.9]
        for valence in valences {
            for arousal in axis {
                for warmth in axis {
                    for tension in [0.0, 0.5, 1.0] {
                        for pressure in [0.0, 0.5, 1.0] {
                            for dim in optional {
                                let signals = CognitiveSubstrate.FeltSignals(
                                    valence: valence,
                                    arousal: arousal,
                                    warmth: warmth,
                                    tension: tension,
                                    pressure: pressure,
                                    fatigue: dim,
                                    curiosity: dim,
                                    clarity: dim,
                                    agency: dim,
                                    confidence: dim
                                )
                                guard let line = CognitiveSubstrate.feltFingerprint(
                                    signals, intensityFloor: 0
                                ) else { continue }
                                for word in line.split(separator: ",") {
                                    let w = word.trimmingCharacters(in: .whitespaces).lowercased()
                                    if !w.isEmpty { words.insert(w) }
                                }
                            }
                        }
                    }
                }
            }
        }
        return words
    }

    func run() async -> BenchResult {
        var result = BenchResult(fixture: fixture.label)

        // ── Build-level invariant: the felt vocabulary is still reachable.
        let vocabulary = Self.reachableFeltVocabulary()
        result.lines.append("felt vocabulary reachable: \(vocabulary.count) word(s)")
        if vocabulary.count < BenchPolicy.minimumFeltVocabulary {
            result.findings.append(BenchFinding(
                turn: "<build>",
                invariant: "felt.vocabulary",
                expected: ">= \(BenchPolicy.minimumFeltVocabulary) reachable fingerprint words",
                got: "\(vocabulary.count) (\(vocabulary.sorted().joined(separator: ", ")))"
            ))
        }

        let root = fixture.dataRoot.standardizedFileURL
        let sessionStateDir: URL? = fixture.turns.contains { $0.transcript != nil }
            ? root.appendingPathComponent("chat", isDirectory: true)
                .appendingPathComponent("session_state", isDirectory: true)
            : nil
        let sessionStateExistedBefore = sessionStateDir.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? true

        // ── The pinned substrate clock (see BenchFixture.capturedAt).
        let clock = BenchClock(fixture.capturedAt)

        // ── The real cognition runtime over the fixture substrate.
        let cognition = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: Self.benchCognitiveConfiguration(),
            organismConfigurationOverride: OrganismConfiguration(enabled: true),
            now: { clock.now },
            microcycleSchedulingMode: .manuallyFlushed
        )
        if let seed = fixture.seed { await seed(cognition) }

        // ── The real Fluid Context runtime over the fixture stores.
        let contextFlow = NativeContextFlowRuntime(
            dataRoot: root,
            configurationOverride: NativeContextFlowConfiguration(mode: .active, budget: .default)
        )
        await contextFlow.start()
        guard let health = await contextFlow.health() else {
            result.findings.append(BenchFinding(
                turn: "<fixture>",
                invariant: "contextFlow.started",
                expected: "ContextFlowCoordinator started in .active mode on the fixture root",
                got: "coordinator nil — the fixture's stores could not open"
            ))
            return result
        }
        // Structured cleanup (gpt-5.5 review): stop is awaited before every
        // return below — a fire-and-forget Task in a defer lets the test exit
        // with watchers still live, bleeding flakiness into other tests.
        result.lines.append(
            "context flow: generation=\(health.activeArenaGenerationID.map(String.init) ?? "-")"
            + " sources=\(health.registeredSourceCount)"
        )

        // ── The real chat client wiring (persona / memory / REM / trace bus).
        // The engine's own clock is pinned too (gpt-5.5 review): the attention
        // request inside buildTurnContext reads the ENGINE clock, not the
        // clockNowOverride — unpinned it drifts with wall time and the hot
        // set's 1h half-life makes real fixtures decay-flaky in CI.
        let pinnedNow = clock.now
        let client = makeChatOrchestrationClient(
            tools: BenchNoToolsDispatcher(),
            dataRoot: root,
            cognitiveContextProvider: cognition,
            contextFlow: contextFlow,
            memoryAtomTranslator: { NativeContextFlowRuntime.memoryRecordAtomID(forRecordID: $0) },
            clock: { pinnedNow }
        )
        let engine = await client.engine

        var sawAffectSignal = false
        var expectedAnyCapsule = false
        // Did ANY replayed turn produce a plan hint? Without this, a fixture
        // whose every turn happens to take the "minimal chat, no hint" branch
        // would make `turnPlan.hintInjected` silently vacuous.
        var sawPlanHint = false
        // Kept independently of the generic speed-stage grade below: this is
        // the substrate's persisted REM-index read, not a replacement for the
        // turn-contract speed vocabulary.
        var remPinsReadSamples: [(turn: String, milliseconds: Int)] = []

        for expectation in fixture.turns {
            let turnLabel = String(expectation.turnId.prefix(8)) + "/" + expectation.surface
            if (expectation.capsuleBytes ?? 0) > 0 { expectedAnyCapsule = true }

            // WARM THE RESIDENT ATTENTION PROJECTION at the pinned instant.
            //
            // `attentionSignals` is a pure read of the LAST PUBLISHED
            // projection — in the live app that projection is continuously
            // refreshed by preceding turns and events, never cold. Without this
            // warm-up the bench reports every attention lane dead on turn 1 and
            // alive on turn 2, which measures the bench's own startup, not the
            // build. (Observed, first real-fixture run.)
            let turnInstant = clock.now
            _ = await cognition.prepareTurnProjection(CognitiveCapsuleRequest(
                surface: expectation.surface,
                userMessage: expectation.userMessage,
                sessionId: expectation.sessionId.isEmpty ? nil : expectation.sessionId,
                mode: .inspectOnly
            ))

            // Replay through the build's own assembly. Its real receipt(s)
            // are emitted through this private bus and then awaited from the
            // canonical persisted JSONL lane below; the bus is deliberately
            // NOT the benchmark's source of timing truth.
            let bus = makeChatTurnTraceBus(dataRoot: root)
            let turnId = TurnTraceContext.mintTurnId()
            let sessionId = expectation.sessionId.isEmpty
                ? "bench-\(UUID().uuidString)"
                : expectation.sessionId

            // ── THE SESSION-HISTORY LANE (v2 fixtures).
            //
            // Stage the turn's transcript window at the production-keyed path
            // the reader opens, replay through buildTurnContextWithHistory, and
            // un-stage afterwards (structured cleanup — the fixture root must
            // not accumulate one turn's window into the next turn's replay).
            // The staging is per turn because two captured turns from one
            // session saw two different windows.
            var staged: URL?
            if let transcript = expectation.transcript {
                guard let safeId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
                    result.findings.append(BenchFinding(
                        turn: turnLabel,
                        invariant: "history.sessionId",
                        expected: "a session id the production reader accepts as a path component",
                        got: "\"\(sessionId)\" — the history lane cannot be staged"
                    ))
                    continue
                }
                let messagesDir = root
                    .appendingPathComponent("chat", isDirectory: true)
                    .appendingPathComponent("messages", isDirectory: true)
                let target = messagesDir.appendingPathComponent("\(safeId).jsonl")
                do {
                    try FileManager.default.createDirectory(
                        at: messagesDir, withIntermediateDirectories: true
                    )
                    if FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.removeItem(at: target)
                    }
                    try FileManager.default.copyItem(at: transcript.fileURL, to: target)
                    staged = target
                } catch {
                    result.findings.append(BenchFinding(
                        turn: turnLabel,
                        invariant: "history.staged",
                        expected: "transcript window staged at \(target.path)",
                        got: "copy failed: \(String(reflecting: error))"
                    ))
                    continue
                }
            }
            defer {
                if let staged { try? FileManager.default.removeItem(at: staged) }
            }
            let historyLane = staged != nil

            let assembled: TurnContext
            do {
                assembled = try await TurnTraceContext.$bus.withValue(bus) {
                    try await TurnTraceContext.$turnId.withValue(turnId) {
                        if historyLane {
                            // The PRODUCTION history path, rooted at the
                            // fixture: reader + digest both read the fixture
                            // root and nothing outside it.
                            return try await engine.buildTurnContextWithHistory(
                                surface: expectation.surface,
                                userMessage: expectation.userMessage,
                                sessionId: sessionId,
                                historyLimit: BenchPolicy.historyLimit,
                                historyReader: SessionHistoryReader(dataRoot: root),
                                personaOverride: String?.none,
                                excludeHistoryRunId: String?.none,
                                sessionDigest: Self.hermeticDigestProvider(root: root),
                                imageBlocks: [],
                                queryUserMessage: String?.none,
                                clockNowOverride: turnInstant
                            )
                        }
                        return try await engine.buildTurnContext(
                            surface: expectation.surface,
                            userMessage: expectation.userMessage,
                            personaOverride: String?.none,
                            imageBlocks: [],
                            recallQueryOverride: String?.none,
                            includeClockContext: true,
                            sessionID: sessionId,
                            recentTurns: [],
                            clockNowOverride: turnInstant
                        )
                    }
                }
            } catch {
                result.findings.append(BenchFinding(
                    turn: turnLabel,
                    invariant: "assembly.completed",
                    expected: historyLane
                        ? "buildTurnContextWithHistory returns a TurnContext"
                        : "buildTurnContext returns a TurnContext",
                    got: "threw \(String(reflecting: error))"
                ))
                continue
            }

            // ── THE TURN PLAN AND ITS HINT (ledger row `telemetry.turn.plan`).
            //
            // Live there are 184 `turn.plan` rows beside 184 `context.summary`
            // rows and NOTHING records whether the plan's hint actually reached
            // the prompt: a plan that yields an empty hint and a hint that was
            // computed and dropped look identical from the trace. The bench
            // closes that by running the production ORDER — plan →
            // contextByAppendingTurnPlanHint → capsule
            // (ChatOrchestrationClient+StructuredChat.swift:251-277) — and then
            // grading the hint against the assembled prompt downstream.
            //
            // The planner is the REAL one and it is hermetic: TurnPlanner →
            // SwiftNativeRouterPlanClient is keyword routing with no LLM and no
            // network, and its trust center is rooted at the fixture.
            let turnPlan = try? await TurnPlanner(
                dataRoot: root, clock: { pinnedNow }
            ).plan(
                message: expectation.userMessage,
                surface: expectation.surface,
                sessionId: sessionId,
                fileAccess: "read_only",
                approvalAvailable: true
            )
            if let turnPlan {
                await TurnPlanTraceRecorder.append(
                    turnPlan,
                    runId: "bench-\(turnId)",
                    surface: expectation.surface,
                    dataRoot: root,
                    turnId: turnId,
                    turnTraceBus: bus
                )
            }
            if turnPlan?.contextHint != nil { sawPlanHint = true }
            let planned = fixture.suppressTurnPlanHint
                ? assembled
                : SwiftNativeTurnEngine.contextByAppendingTurnPlanHint(
                    assembled, turnPlan: turnPlan
                )

            var receiptKinds: Set<String> = ["context.summary"]
            if historyLane { receiptKinds.insert("context.history.summary") }
            if turnPlan != nil { receiptKinds.insert("turn.plan") }
            var receipts = await Self.awaitPersistedReceipts(
                dataRoot: root, turnId: turnId, kinds: receiptKinds
            )
            // Mutation proof for the named substrate row. The mutation is
            // applied only AFTER reading the persisted canonical row, so it
            // cannot accidentally turn the grade back into a bus sample.
            if fixture.removePersistedRemPinsStageForNegativeControl,
               var mutated = receipts["context.summary"] {
                mutated.stageMs.removeValue(forKey: "rem_pins.read")
                receipts["context.summary"] = mutated
            }
            guard let summary = receipts["context.summary"] else {
                result.findings.append(BenchFinding(
                    turn: turnLabel,
                    invariant: "assembly.traced",
                    expected: "one persisted context.summary receipt within \(Int(BenchPolicy.traceDeadline))s",
                    got: "no turn_traces JSONL row — the assembly ran unmeasured"
                ))
                continue
            }
            let historySummary = receipts["context.history.summary"]
            if historyLane && historySummary == nil {
                result.findings.append(BenchFinding(
                    turn: turnLabel,
                    invariant: "history.traced",
                    expected: "one persisted context.history.summary receipt within \(Int(BenchPolicy.traceDeadline))s",
                    got: "no turn_traces JSONL row — the history path ran unmeasured"
                ))
            }

            if let elapsed = summary.stageMs["rem_pins.read"] {
                remPinsReadSamples.append((turn: turnLabel, milliseconds: elapsed))
            } else {
                // The generic `speed.stageDark` contract below also fires.
                // Keep this distinct named row so the organism substrate
                // evidence remains attributable when the shared stage list is
                // revised for an unrelated turn-contract change.
                result.findings.append(BenchFinding(
                    turn: turnLabel,
                    invariant: "speed.rem_pins.read",
                    expected: "a persisted rem_pins.read timing stage on every replayed turn",
                    got: "absent from turn_traces JSONL — the REM-index read is unmeasured"
                ))
            }

            // ── The capsule, through the PRODUCTION injection seam.
            let request = await client.cognitiveTurnProjectionRequest(
                surface: expectation.surface,
                userMessage: expectation.userMessage,
                sessionId: sessionId
            )
            let projection = await cognition.prepareTurnProjection(request)
            let (projected, _) = await client.contextByAppendingCognitiveCapsule(
                to: planned,
                surface: expectation.surface,
                userMessage: expectation.userMessage,
                runId: "bench-\(turnId)",
                sessionId: sessionId,
                fileAccess: "read_only",
                projection: projection
            )
            // NOTE: the projection is deliberately NOT committed. Committing
            // would consume the Body-line / fingerprint suppress windows and
            // mutate the fixture substrate between turns.

            result.turnsReplayed += 1
            let evaluated = Self.evaluate(
                expectation: expectation,
                turnLabel: turnLabel,
                summary: summary,
                historySummary: historyLane ? historySummary : nil,
                planReceipt: receipts["turn.plan"],
                turnPlan: turnPlan,
                projected: projected,
                capsule: projection.capsule,
                posture: projection.posture,
                vocabulary: vocabulary,
                staleBy: fixture.capturedAt.timeIntervalSince(expectation.ts ?? fixture.capturedAt)
            )
            result.findings.append(contentsOf: evaluated.findings)
            result.lines.append(evaluated.line)
        }

        // ── Affect: axes read from the live substrate at the end of the run.
        let affect = await cognition.substrate.affectSnapshot()
        let axes: [(String, Double)] = [
            ("arousal", affect.arousal), ("uncertainty", affect.uncertainty),
            ("taskPressure", affect.taskPressure), ("socialWarmth", affect.socialWarmth),
        ]
        for (name, value) in axes {
            if !value.isFinite || value < 0 || value > 1 {
                result.findings.append(BenchFinding(
                    turn: "<substrate>",
                    invariant: "affect.axes",
                    expected: "\(name) finite and within 0...1",
                    got: String(describing: value)
                ))
            }
            if value > 0 { sawAffectSignal = true }
        }
        result.lines.append(
            "affect: " + axes.map { "\($0.0)=\(String(format: "%.3f", $0.1))" }.joined(separator: " ")
        )
        // The 0...1 half above is a CONTRACT check (CognitiveAffectState's init
        // clamps, so it only fires if that type changes). This is the half with
        // teeth: a fixture whose source turns carried a real capsule came from a
        // substrate that was feeling something. All four axes flat at zero after
        // a replay means the affect feed is dead, not calm.
        if expectedAnyCapsule && !sawAffectSignal {
            result.findings.append(BenchFinding(
                turn: "<substrate>",
                invariant: "affect.liveness",
                expected: "at least one affect axis > 0 (source turns carried a live capsule)",
                got: "all four axes exactly 0"
            ))
        }

        // ── VACUITY GUARD for the plan-hint lane: at least one replayed turn
        //    must have produced a hint, or `turnPlan.hintInjected` graded
        //    nothing all run and the lane is unproven rather than healthy.
        if result.turnsReplayed > 0 && !sawPlanHint {
            result.findings.append(BenchFinding(
                turn: "<fixture>",
                invariant: "turnPlan.hintVacuity",
                expected: ">= 1 replayed turn whose TurnPlan produced a context hint, so the "
                    + "hint-reaches-the-prompt invariant actually graded something",
                got: "0 of \(result.turnsReplayed) turn(s) — either every turn took the "
                    + "minimal-chat branch or contextHint stopped being produced at all"
            ))
        }

        // `rem_pins.read` is synchronous file I/O before the provider call.
        // Grade its run-wide p95 separately from the broad generic stage
        // envelope so a slow persistent index cannot hide behind a healthy
        // total turn.  The sample-count check is the every-turn half; p95 only
        // has meaning after that admission succeeds.
        if result.turnsReplayed > 0 {
            if remPinsReadSamples.count != result.turnsReplayed {
                result.findings.append(BenchFinding(
                    turn: "<substrate>",
                    invariant: "speed.rem_pins.read",
                    expected: "one persisted rem_pins.read sample for each of \(result.turnsReplayed) replayed turn(s)",
                    got: "\(remPinsReadSamples.count) sample(s)"
                ))
            }
            if let p95 = TurnReplaySubstrateREMPinsGrade.p95(
                remPinsReadSamples.map(\.milliseconds)
            ) {
                result.lines.append(
                    "substrate rem_pins.read (turn_traces): n=\(remPinsReadSamples.count) p95=\(p95)ms "
                    + "budget<=\(TurnReplaySubstrateREMPinsGrade.p95BudgetMs)ms"
                )
                if p95 > TurnReplaySubstrateREMPinsGrade.p95BudgetMs {
                    result.findings.append(BenchFinding(
                        turn: "<substrate>",
                        invariant: "speed.rem_pins.read",
                        expected: "persisted p95 rem_pins.read <= \(TurnReplaySubstrateREMPinsGrade.p95BudgetMs)ms",
                        got: "\(p95)ms across \(remPinsReadSamples.count) replayed turn(s)"
                    ))
                }
            }
        }

        // ── VACUITY GUARD. A run that replayed nothing proves nothing.
        if result.turnsReplayed == 0 {
            result.findings.append(BenchFinding(
                turn: "<fixture>",
                invariant: "bench.nonvacuous",
                expected: ">= 1 replayed turn",
                got: "0 — a bench that replays nothing can never fail"
            ))
        }
        await contextFlow.stop()
        // Replay dirt the history lane leaves INSIDE the fixture root: the
        // since-last-session digest persists per-session bytes under
        // chat/session_state/<sessionId>/digest.txt (gpt-5.5 review). Swept
        // only when the bench created it, so a real fixture that shipped one
        // keeps it.
        if let sessionStateDir, !sessionStateExistedBefore {
            try? FileManager.default.removeItem(at: sessionStateDir)
        }
        return result
    }

    /// The prior-session anchor provider, rooted INSIDE the fixture. Its only
    /// source is `<root>/chat/sessions.json`, so a replay can never reach the
    /// live index; an absent or unqualifying index fails open to no anchor,
    /// exactly as in production.
    static func hermeticDigestProvider(root: URL) -> SessionDigestProvider {
        SessionDigestProvider(dataRoot: root)
    }

    /// Bounded persistence drain for this turn's canonical JSONL receipt(s).
    /// The trace writer is intentionally fire-and-forget, so the replay bench
    /// polls `TurnTraceRecentReader` until every expected row for this turn is
    /// durable or the deadline expires. This makes an absent persisted row a
    /// named failure instead of treating an in-memory bus delivery as proof.
    ///
    /// The reader is the production `turn_traces/<yyyy-MM-dd>.jsonl` reader,
    /// rooted at the fixture's exact data root. Decoding the whole payload
    /// retains `stageMs` and `totalMs` from the durable record for speed grades.
    private static func awaitPersistedReceipts(
        dataRoot: URL,
        turnId: String,
        kinds: Set<String>
    ) async -> [String: BenchReceipt] {
        let reader = TurnTraceRecentReader(dataRootOverride: dataRoot)
        let deadline = Date().addingTimeInterval(BenchPolicy.traceDeadline)
        var latest: [String: BenchReceipt] = [:]
        repeat {
            if let snapshot = try? await reader.read() {
                var receipts: [String: BenchReceipt] = [:]
                for event in snapshot.events where event.turnId == turnId && kinds.contains(event.kind) {
                    // A turn produces at most one receipt of each expected kind;
                    // retain the first durable record if an instrument regresses
                    // to duplicate emission, matching the prior bus contract.
                    if receipts[event.kind] == nil {
                        receipts[event.kind] = BenchReceipt(payload: event.payload)
                    }
                }
                latest = receipts
                if receipts.count == kinds.count { return receipts }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
        return latest
    }

    // ── The invariants themselves.
    private static func evaluate(
        expectation: BenchTurnExpectation,
        turnLabel: String,
        summary: BenchReceipt,
        /// The outer `context.history.summary` receipt — nil on the bare lane
        /// (v1 fixture or a turn with no transcript), and nil on the history
        /// lane when the receipt never arrived (already a `history.traced`
        /// finding upstream; the history invariants then stay silent rather
        /// than double-reporting against an empty dictionary).
        historySummary: BenchReceipt?,
        /// The `turn.plan` receipt, when this turn produced a plan.
        planReceipt: BenchReceipt?,
        /// The plan itself — the bench needs the hint text to prove it landed.
        turnPlan: TurnPlan?,
        projected: TurnContext?,
        capsule: CognitiveCapsule?,
        posture: OrganismBehaviorPosture?,
        vocabulary: Set<String>,
        staleBy: TimeInterval
    ) -> (findings: [BenchFinding], line: String) {
        var findings: [BenchFinding] = []
        func breach(_ invariant: String, _ expected: String, _ got: String) {
            findings.append(BenchFinding(
                turn: turnLabel, invariant: invariant, expected: expected, got: got
            ))
        }
        let systemPrompt = projected?.systemPrompt ?? ""

        // (1) CAPSULE — present, and composed from the live substrate.
        let sourceExpectedCapsule = (expectation.containsCognitiveSubstrate ?? false)
            || (expectation.capsuleBytes ?? 0) > 0
        if sourceExpectedCapsule {
            if !systemPrompt.contains("[CognitiveSubstrate]") {
                breach("capsule.injected",
                       "a [CognitiveSubstrate] block in the assembled system prompt "
                       + "(source turn carried \(expectation.capsuleBytes ?? 0) capsule bytes)",
                       "no [CognitiveSubstrate] block — her inner state never reached the turn")
            }
            if let capsule {
                if capsule.stableKernel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    breach("capsule.kernel", "a non-empty capsule stable kernel", "empty")
                }
                let felt = capsule.dynamicContext.trimmingCharacters(in: .whitespacesAndNewlines)
                if felt.isEmpty {
                    breach("capsule.feltLines",
                           "a non-empty capsule dynamic context (her felt lines)",
                           "empty — the capsule rendered nothing to feel")
                }
                if capsule.provenanceNodeIds.isEmpty {
                    breach("capsule.provenance",
                           ">= 1 provenance node id (proof the capsule was composed "
                           + "from live substrate nodes, not a constant)",
                           "0 provenance nodes")
                }
                // The fingerprint line, when the cadence let it speak, must use
                // this build's own reachable vocabulary.
                if let fingerprint = feltFingerprintLine(in: capsule.dynamicContext) {
                    let words = fingerprint.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                        .filter { !$0.isEmpty }
                    let unknown = words.filter { !vocabulary.contains($0) }
                    if words.isEmpty {
                        breach("capsule.fingerprint", "felt words on the fingerprint line", "none")
                    } else if !unknown.isEmpty {
                        breach("capsule.fingerprint",
                               "every felt word drawn from the build's fingerprint families",
                               "unknown word(s): \(unknown.joined(separator: ", "))")
                    }
                }
            } else {
                breach("capsule.composed",
                       "a CognitiveCapsule from the live substrate",
                       "nil — prepareTurnProjection returned no capsule")
            }
        }

        // (1b) ORGANISM POSTURE.
        if expectation.containsOrganismBehavior == true {
            if posture == nil {
                breach("organism.posture",
                       "an OrganismBehaviorPosture (source turn carried one)",
                       "nil")
            } else if !systemPrompt.contains("[OrganismBehavior]") {
                breach("organism.injected",
                       "an [OrganismBehavior] block in the assembled system prompt",
                       "absent")
            }
        }

        // (2) ATTENTION LANES — nonzero where the source turn was nonzero.
        var unmeasurable: [String] = []
        for lane in [
            "contextFlow.attentionTerms",
            "contextFlow.attentionToolGroups",
            "contextFlow.attentionActivation",
            "contextFlow.attentionWorkingAtoms",
        ] {
            let source = expectation.count(lane)
            guard source > 0 else { continue }
            if BenchPolicy.workingSetLanes.contains(lane), staleBy > BenchPolicy.workingSetTransferHorizon {
                unmeasurable.append(
                    "\(lane) (source \(source); fixture captured "
                    + "\(Int(staleBy / 3600))h after the turn — the hot set's 1h "
                    + "half-life has expired, so this lane is UNMEASURABLE here, not zero)"
                )
                continue
            }
            let replay = summary.count(lane)
            if replay <= 0 {
                breach(lane,
                       "> 0 (source turn had \(source))",
                       "0 — this attention lane no longer reaches context selection")
            }
        }

        // (3) MEMORY RECORDS — selected where the source had them.
        let sourceMemory = expectation.count("contextFlow.memoryRecords")
        if sourceMemory >= 1 {
            let replayMemory = summary.count("contextFlow.memoryRecords")
            if replayMemory < 1 {
                breach("memory.records",
                       ">= 1 memory record in the packet (source turn had \(sourceMemory))",
                       "0 — the memory lane selected nothing")
            }
        }

        // (5) SCHEMA / SEGMENTS — both present, sizes inside a stated band.
        let stable = summary.count("system.stableChars")
        let dynamic = summary.count("system.dynamicChars")
        if stable <= 0 {
            breach("segments.stable", "a non-empty STABLE system segment (persona + pins)", "0 chars")
        }
        // 2026-09-06: graded on the receipt that OWNS the final rendering, not
        // always on `summary`. On the history lane the base builder is called
        // with `includeClockContext: false`
        // (ChatOrchestration+SessionHistory.swift, the buildTurnContext call in
        // buildTurnContextWithHistory) precisely so the history assembler does
        // the one eventual prompt rendering — so the base receipt's dynamic
        // segment is deliberately UNFINISHED there, and on a root with no
        // ContextFlow packet and no memory store it is legitimately 0. The
        // segment that actually reaches the model on such a turn is the one
        // measured by `context.history.summary`, and grading `summary` here
        // asserted a segment production never intended to be complete.
        //
        // This is not a softening: on a history turn (7a) below still requires
        // outerDynamic − innerDynamic >= the rendered history block, so a block
        // that is computed and never appended still fails by name.
        let finalDynamic = historySummary?.count("system.dynamicChars") ?? dynamic
        if finalDynamic <= 0 {
            breach("segments.dynamic",
                   "a non-empty DYNAMIC system segment (packet + recall"
                   + (historySummary == nil ? ")" : " + history)"),
                   "0 chars")
        }
        func band(_ name: String, _ source: Int, _ replay: Int, _ range: ClosedRange<Double>) {
            guard source > 0, replay > 0 else { return }
            let ratio = Double(replay) / Double(source)
            guard !range.contains(ratio) else { return }
            breach(name,
                   "within \(range.lowerBound)x–\(range.upperBound)x of the source turn's "
                   + "\(source) chars",
                   "\(replay) chars (\(String(format: "%.2f", ratio))x)")
        }
        band("segments.stableBand", expectation.count("system.stableChars"), stable,
             BenchPolicy.stableSegmentBand)
        band("segments.dynamicBand", expectation.count("system.dynamicChars"), dynamic,
             BenchPolicy.dynamicSegmentBand)

        // (6) PERSONA DOCS.
        let sourceDocs = expectation.count("persona.docCount")
        let replayDocs = summary.count("persona.docCount")
        if sourceDocs > 0 && replayDocs < sourceDocs {
            breach("persona.docCount",
                   ">= \(sourceDocs) persona docs loaded",
                   "\(replayDocs)")
        }

        // (7) THE SESSION-HISTORY LANE — only when this turn replayed through
        // buildTurnContextWithHistory with its transcript window staged.
        var historyLine = ""
        if let historySummary {
            let sourcePrior = expectation.count("history.priorCount")
            let sourceRecallQuery = expectation.count("history.recallQueryChars")
            let replayPrior = historySummary.count("history.priorCount")
            let replayBlock = historySummary.count("historyBlockChars")
            let replayRecallQuery = historySummary.count("history.recallQueryChars")
            let innerDynamic = summary.count("system.dynamicChars")
            let outerDynamic = historySummary.count("system.dynamicChars")

            // (7a) HISTORY INJECTED where the source had it. Three claims, one
            // invariant: the reader still returns prior rows off the staged
            // window, the renderer still produces a block, and the block
            // actually LANDED in the dynamic segment (outer − inner ≥ block —
            // a count that is computed but never appended would pass the
            // first two and fail here).
            if sourcePrior > 0 {
                if replayPrior <= 0 {
                    breach("history.injected",
                           "> 0 prior rows read from the staged transcript window "
                           + "(source turn saw \(sourcePrior))",
                           "0 — the session-history reader returned nothing; "
                           + "her continuity never reached the turn")
                } else if replayBlock <= 0 {
                    breach("history.injected",
                           "a non-empty rendered history block "
                           + "(source turn had \(expectation.count("historyBlockChars")) chars)",
                           "0 chars — \(replayPrior) prior row(s) read but nothing rendered")
                } else if outerDynamic - innerDynamic < replayBlock {
                    breach("history.injected",
                           "the history block appended to the DYNAMIC segment "
                           + "(outer − inner dynamic ≥ \(replayBlock) block chars)",
                           "outer \(outerDynamic) − inner \(innerDynamic) = "
                           + "\(outerDynamic - innerDynamic) — rendered but not injected")
                }
            }

            // (7b) RECALL-QUERY EXPANSION where the source had it. The query
            // is not observable except through its length: the bare line is
            // "Current user: <message capped at 520>"; every prior
            // user/assistant row adds a further line. So where prior rows
            // were read, the expanded query must be LONGER than the bare
            // current-user line. Cutting the expansion (query := message)
            // fails this by name.
            if sourceRecallQuery > 0 {
                // The bare line is whatever the PRODUCTION renderer emits for
                // this message with NO prior rows — computed by calling it
                // (same normalize / redact / cap), not approximated. An
                // approximation from the raw message length false-fails on
                // heavy whitespace or secret redaction (gpt-5.5 review) and
                // false-passed a >520-char message until its "..." cap suffix
                // was counted (mutation drill) — both gone by construction.
                let bareLine = SessionHistoryPromptRenderer.recallQuery(
                    userMessage: expectation.userMessage, messages: []
                ).count
                if replayRecallQuery <= 0 {
                    breach("history.recallQuery",
                           "a non-empty expanded recall query "
                           + "(source turn produced \(sourceRecallQuery) chars)",
                           "0 chars — recall ran on nothing")
                } else if replayPrior > 0 && replayRecallQuery <= bareLine {
                    breach("history.recallQuery",
                           "> \(bareLine) chars — the bare current-user line plus at least "
                           + "one prior-turn line (source produced \(sourceRecallQuery); "
                           + "\(replayPrior) prior row(s) were read)",
                           "\(replayRecallQuery) chars — the recall query was not expanded "
                           + "with the prior conversation")
                }
            }

            historyLine = " history(prior/recallQ/block)=\(replayPrior)/\(replayRecallQuery)/\(replayBlock)"
                + " window=\(expectation.transcript?.lines ?? 0)l"
                + ((expectation.transcript?.truncated ?? false) ? "(bounded)" : "")
        }

        // ─────────────────────────────────────────────────────────────────
        // (8) REM PINS — the STABLE-segment override lane.
        //     Ledger row `turn.ingredient.remPins`, silent-failure class
        //     SILENT ZERO: `remPinsDataRoot` goes nil or the file moves, the
        //     pins vanish out of the stable prompt, and `remPins.count` reads
        //     0 forever with nothing failing. Three separate claims, because
        //     each can break without the others:
        //       (a) the READ found pins            → counts.remPins.count
        //       (b) the RENDER emitted the header  → header in STABLE
        //       (c) the pin actually REACHED the assembled prompt, in the
        //           CACHEABLE half — a pin rendered into the dynamic segment
        //           would satisfy (a) and (b) and still be wrong.
        // ─────────────────────────────────────────────────────────────────
        let stableSegment = projected?.systemSegments?.stable ?? ""
        let dynamicSegment = projected?.systemSegments?.dynamic ?? ""
        let replayPins = summary.count("remPins.count")
        if expectation.count("remPins.count") > 0 {
            if replayPins < 1 {
                breach("remPins.count",
                       ">= 1 REM pin read into the turn "
                       + "(source turn carried \(expectation.count("remPins.count")))",
                       "0 — REMPinsReader returned nothing; the pins lane is silently dead "
                       + "(nil remPinsDataRoot, or rem_pins.json moved)")
            } else if let header = TurnReplayRemPinsProbe.header {
                if !stableSegment.contains(header) {
                    breach("remPins.injectedStable",
                           "the `\(header)` header inside the STABLE system segment "
                           + "(\(replayPins) pin(s) were read)",
                           dynamicSegment.contains(header)
                               ? "the header is in the DYNAMIC segment — pins are REM-approved "
                                 + "overrides and belong in the cacheable stable prefix"
                               : "absent from both segments — the pins were read and never rendered")
                }
            } else {
                breach("remPins.injectedStable",
                       "the production renderer to emit a distinguishable pins header so this "
                       + "invariant can be graded (probed by calling "
                       + "renderSystemPromptSegments with and without a pin)",
                       "no header delta — the pin block cannot be located in the prompt, so "
                       + "this invariant would pass vacuously")
            }
            // (c) synthetic only: the bench authored these pins, so the text is
            // a legitimate end-to-end target. Real fixtures never set this.
            for text in expectation.remPinTexts where !stableSegment.contains(text) {
                breach("remPins.textReachedStable",
                       "the authored pin text in the STABLE segment: \"\(text.prefix(48))…\"",
                       "absent — the pin was counted but its content never reached the prompt")
            }
        }

        // ─────────────────────────────────────────────────────────────────
        // (9) THE TURN PLAN AND ITS HINT.
        //     Ledger row `telemetry.turn.plan`, silent-failure class PLAN/HINT
        //     DIVERGENCE: the row records goalType and nothing records whether
        //     the hint reached the prompt, so "the plan produced no hint" and
        //     "the hint was computed and dropped" are indistinguishable live.
        //     They are distinguished here.
        // ─────────────────────────────────────────────────────────────────
        var planLine = " plan=none"
        if turnPlan == nil {
            if !expectation.userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                breach("turnPlan.produced",
                       "a TurnPlan for a non-empty user message (the planner is "
                       + "deterministic keyword routing — it has no reason to fail)",
                       "nil — the per-turn plan lane is dead")
            }
        } else if let turnPlan {
            if let planReceipt {
                let goal = planReceipt.strings["goalType"] ?? ""
                let mode = planReceipt.strings["contextMode"] ?? ""
                let risk = planReceipt.strings["risk"] ?? ""
                if goal.isEmpty || mode.isEmpty || risk.isEmpty {
                    breach("turnPlan.traced",
                           "a turn.plan receipt carrying non-empty goalType/contextMode/risk",
                           "goalType=\"\(goal)\" contextMode=\"\(mode)\" risk=\"\(risk)\"")
                }
            } else {
                breach("turnPlan.traced",
                       "one turn.plan receipt on the bus for this turn",
                       "no receipt — the plan ran unmeasured")
            }
            if let hint = turnPlan.contextHint {
                if !dynamicSegment.contains(hint) && !(projected?.systemPrompt ?? "").contains(hint) {
                    breach("turnPlan.hintInjected",
                           "the plan's context hint in the assembled prompt "
                           + "(goal=\(turnPlan.goalType) context=\(turnPlan.contextMode)) — "
                           + "the plan is only worth tracing if its hint reaches the model",
                           "absent — the hint was computed and dropped, which live telemetry "
                           + "cannot tell apart from a plan that produced no hint")
                }
                planLine = " plan=\(turnPlan.goalType)/\(turnPlan.contextMode)(hint=\(hint.count)c)"
            } else {
                // Legitimate (a minimal chat turn injects nothing) but it is
                // reported by name so a fixture where NO turn ever produces a
                // hint cannot silently make the invariant above vacuous — the
                // run-level `turnPlan.hintVacuity` guard picks that up.
                planLine = " plan=\(turnPlan.goalType)/\(turnPlan.contextMode)(hint=none)"
            }
        }

        // ─────────────────────────────────────────────────────────────────
        // (10) THE SPEED BUDGET. Ledger rows `speed.budget.frozenBaseline`,
        //      `speed.stage.totalMs`, `speed.stage.contextFlow.prepare`,
        //      `speed.stage.rem_pins.read`, `speed.stage.history.lane`,
        //      `speed.stage.untracedAssemblyPrologue`. See
        //      TurnReplayStageBudget.swift for which clause has the teeth.
        // ─────────────────────────────────────────────────────────────────
        var speedLines: [String] = []
        findings.append(contentsOf: TurnReplayStageBudget.evaluate(
            kind: "context.summary", receipt: summary, turnLabel: turnLabel
        ))
        speedLines.append(TurnReplayStageBudget.reportLine(
            kind: "context.summary", receipt: summary
        ))
        if let historySummary {
            findings.append(contentsOf: TurnReplayStageBudget.evaluate(
                kind: "context.history.summary",
                receipt: historySummary,
                turnLabel: turnLabel,
                innerTotalMs: summary.totalMs
            ))
            speedLines.append(TurnReplayStageBudget.reportLine(
                kind: "context.history.summary", receipt: historySummary
            ))
        }

        // (10b) THE ATTENTION ABANDON LATCH (`speed.stage.contextFlow.attention`).
        //       Bounded BY DESIGN, so the failure signature is not "slow" — it
        //       is "over the latch with the timeout flag unset", i.e. the latch
        //       stopped bounding anything.
        let attentionMs = summary.stageMs["contextFlow.attention"] ?? 0
        if let latchMs = TurnReplayAttentionLatch.declaredMilliseconds {
            let ceiling = latchMs + TurnReplayAttentionLatch.slackMs
            if attentionMs > ceiling && summary.flags["contextFlow.attentionTimedOut"] != true {
                breach("speed.attentionLatch",
                       "contextFlow.attention <= \(ceiling)ms (the source-declared "
                       + "\(latchMs)ms abandon latch + \(TurnReplayAttentionLatch.slackMs)ms "
                       + "scheduling slack), or contextFlow.attentionTimedOut set",
                       "\(attentionMs)ms with the timeout flag unset — the read ran past its "
                       + "own latch, so a wedged substrate CAN now stall a chat turn")
            }
        } else {
            breach("speed.attentionLatch",
                   "attentionSignalsTimeoutNanos still declared in "
                   + "ChatOrchestration+TurnEngine.swift so the latch can be graded",
                   "the declaration could not be read — this invariant would otherwise "
                   + "pass vacuously against a constant that no longer exists")
        }

        let line = "turn \(turnLabel): attn(terms/atoms/act/groups)="
            + "\(summary.count("contextFlow.attentionTerms"))/"
            + "\(summary.count("contextFlow.attentionWorkingAtoms"))/"
            + "\(summary.count("contextFlow.attentionActivation"))/"
            + "\(summary.count("contextFlow.attentionToolGroups"))"
            + " mem=\(summary.count("contextFlow.memoryRecords"))"
            + " docs=\(replayDocs)"
            + " stable/dynamic=\(stable)/\(dynamic)"
            + " capsule=\(capsule?.combined.utf8.count ?? 0)b"
            + " posture=\(posture == nil ? "-" : "yes")"
            + " pins=\(replayPins)"
            + planLine
            + historyLine
        var lines = [line]
        if !unmeasurable.isEmpty {
            lines.append("    unmeasurable: " + unmeasurable.joined(separator: "; "))
        }
        lines.append(contentsOf: speedLines)
        return (findings, lines.joined(separator: "\n"))
    }

    /// The fingerprint line is the capsule's leading bare line — the tail lines
    /// are all `- Label: …`. Returns nil when the cadence suppressed it, which
    /// is legitimate behaviour, not a failure.
    private static func feltFingerprintLine(in dynamicContext: String) -> String? {
        for raw in dynamicContext.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("-") { continue }
            if line.hasSuffix(":") { continue }
            return line
        }
        return nil
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - The synthetic fixture (checked in, no personal data)
// ─────────────────────────────────────────────────────────────────────────────

/// A tiny hand-built fixture so `swift test` always exercises the bench
/// end-to-end. Everything in it is invented here — generic persona docs, an
/// invented user name, invented turn text — so it can live in the repository.
///
/// It is built rather than checked in as data files on purpose: a directory of
/// binary sqlite blobs in the tree would rot silently against schema changes,
/// while this builds its substrate through the REAL ingest API every run.
enum SyntheticBenchFixture {
    static func make() async throws -> (fixture: BenchFixture, cleanup: @Sendable () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurnReplayBenchSynthetic-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        let dataRoot = root.appendingPathComponent("root", isDirectory: true)
        // One instant and one formatter for everything this fixture writes:
        // pins, transcript rows and turn timestamps must agree or the bench
        // grades a root that is not internally coherent.
        let fixtureInstant = Date()
        let stampFormatter = ISO8601DateFormatter()
        stampFormatter.formatOptions = [.withInternetDateTime]
        for sub in ["persona", "memory", "cognition", "context", "turn_traces", "chat/transcripts"] {
            try fm.createDirectory(
                at: dataRoot.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let persona = dataRoot.appendingPathComponent("persona", isDirectory: true)
        try """
        # SOUL
        You are Wren, a resident assistant who works alongside one person at a
        computer. You are direct, warm, and you say what you actually think.
        """.write(to: persona.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
        try """
        # VOICE
        Short sentences. Lead with the answer. No filler, no apologies.
        """.write(to: persona.appendingPathComponent("VOICE.md"), atomically: true, encoding: .utf8)
        try """
        # USER
        Sam works on a small research project and prefers concise updates.
        """.write(to: persona.appendingPathComponent("USER.md"), atomically: true, encoding: .utf8)
        try #"{"userName":"Sam"}"#.write(
            to: dataRoot.appendingPathComponent("memory/profile.json"),
            atomically: true, encoding: .utf8
        )

        // ── REM PINS (ledger row `turn.ingredient.remPins`).
        //
        // Written in the exact on-disk shape `REMPinsReader.read` decodes —
        // target → [REMPin] — so the pins reach the turn through the PRODUCTION
        // reader, the production dedup pass, and the production renderer.
        // Before this the synthetic root had no rem_pins.json at all, which is
        // why the whole lane graded as an honest zero and a nil
        // `remPinsDataRoot` could never have been caught here.
        //
        // Two pins under one target: `REMPinsReader.latest(idx, latestN: 3)`
        // sorts by createdAt descending, so a sort that broke would still be
        // exercised, and both survive the 3-pin cap.
        let remPinTexts = [
            "Sam wants the notes index rebuilt before any dedupe pass.",
            "Weekly review drafts stay short unless Sam asks for the full one.",
        ]
        let remPinsPayload: [String: Any] = [
            "persona/USER.md": [
                [
                    "id": "synthetic-pin-0",
                    "text": remPinTexts[0],
                    "createdAt": stampFormatter.string(from: fixtureInstant.addingTimeInterval(-3_600)),
                ],
                [
                    "id": "synthetic-pin-1",
                    "text": remPinTexts[1],
                    "createdAt": stampFormatter.string(from: fixtureInstant.addingTimeInterval(-1_800)),
                ],
            ],
        ]
        try JSONSerialization
            .data(withJSONObject: remPinsPayload, options: [.sortedKeys])
            .write(to: dataRoot.appendingPathComponent("rem_pins.json"), options: .atomic)

        // Seed the substrate through the REAL ingest path so the capsule has
        // something honest to compose from. This runs against the runner's OWN
        // runtime instance (via `BenchFixture.seed`) — a separate seeding
        // instance writes into its own in-memory field and the graded runtime
        // would replay an empty mind.
        let turnInstant = fixtureInstant
        let seed: @Sendable (NativeCognitionRuntime) async -> Void = { runtime in
            let seeds: [(CognitiveEventKind, String, String, String, Double)] = [
                (.userMessageReceived, "notes-index", "Notes index",
                 "Sam asked how the notes index rebuild is coming along.", 0.7),
                (.userCorrection, "notes-index-order", "Notes index order",
                 "Sam corrected the plan: rebuild the index before deduping.", 0.9),
                (.userMessageReceived, "weekly-review", "Weekly review",
                 "Sam wants the weekly review draft finished before Friday.", 0.8),
                (.assistantTurnCompleted, "weekly-review", "Weekly review",
                 "Walked Sam through what is still open on the weekly review.", 0.6),
            ]
            for (offset, item) in seeds.enumerated() {
                await runtime.observe(CognitiveEvent(
                    id: "synthetic-seed-\(offset)",
                    kind: item.0,
                    subject: CognitiveSubjectReference(
                        type: "topic", id: item.1, label: item.2
                    ),
                    sourceClass: .observed,
                    occurredAt: turnInstant.addingTimeInterval(Double(offset - seeds.count) * 60),
                    summary: item.3,
                    importance: item.4,
                    metadata: [
                        "role": .string(item.0 == .assistantTurnCompleted ? "assistant" : "user"),
                        "sessionId": .string("SYNTHETIC-SESSION-0001"),
                    ]
                ))
            }
        }

        // The SESSION-HISTORY lane: turn 2 carries a small transcript window —
        // the rows a second turn of this invented session would have seen —
        // in the exact on-disk shape the production reader decodes (role /
        // content / createdAt / runId). Turn 1 stays bare (a session's FIRST
        // turn has no history), so every `swift test` exercises BOTH lanes.
        let stamp = stampFormatter
        let windowRows: [(String, String, Int)] = [
            ("user", "Where did we land on the notes index rebuild?", -240),
            ("assistant",
             "We agreed to rebuild the index before deduping. The rebuild is "
             + "scripted; I still need to run it against the full notes set and "
             + "check the duplicate report afterwards.", -230),
            ("user", "Okay. And the weekly review — what is still open there?", -120),
            ("assistant",
             "Two sections: the metrics table and the open-risks list. I can "
             + "draft both once the index rebuild finishes. Do you want the short "
             + "version or the full one?", -110),
        ]
        var window = ""
        for (offset, row) in windowRows.enumerated() {
            let object: [String: Any] = [
                "id": "synthetic-row-\(offset)",
                "role": row.0,
                "content": row.1,
                "createdAt": stamp.string(from: turnInstant.addingTimeInterval(Double(row.2))),
                "runId": "synthetic-run-\(offset / 2)",
                "sessionId": "SYNTHETIC-SESSION-0001",
                "source": "bench",
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            window += String(decoding: data, as: UTF8.self) + "\n"
        }
        let transcriptURL = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("synthetic-0002.jsonl")
        try window.write(to: transcriptURL, atomically: true, encoding: .utf8)

        // Hand-declared expectations. Attention/memory lanes are declared 0 —
        // a synthetic root has no memory store and no recorded attention
        // history — so those invariants stay honestly silent here; the REAL
        // fixture is what exercises them. Everything the synthetic root CAN
        // prove (assembly runs, capsule composes from live nodes, posture
        // renders, segments render, persona loads, vocabulary reachable,
        // history injected + recall query expanded off the staged window,
        // non-vacuous) is declared and graded.
        let turns = [
            BenchTurnExpectation(
                turnId: "synthetic-0001",
                sessionId: "SYNTHETIC-SESSION-0001",
                surface: "chat",
                userMessage: "Where did we land on the notes index rebuild?",
                counts: [
                    "persona.docCount": 3,
                    // The seeded substrate reliably yields attention terms
                    // (13 observed). Declared as 1 so the ">0 where source >0"
                    // invariant bites on a cut attention feed WITHOUT pinning a
                    // brittle exact count. Verified 2026-08-21: cutting
                    // NativeCognitionRuntime.attentionSignals fails this lane.
                    "contextFlow.attentionTerms": 1,
                    // REM pins. Declared as a floor (1), same reasoning as the
                    // lanes above: the fixture writes 2 and the reader caps at
                    // 3, so ">= 1 where the source had pins" bites on a dead
                    // pins lane without pinning an exact count.
                    "remPins.count": 1,
                ],
                flags: [:],
                capsuleBytes: 1,
                containsCognitiveSubstrate: true,
                containsOrganismBehavior: true,
                ts: turnInstant,
                remPinTexts: remPinTexts
            ),
            BenchTurnExpectation(
                turnId: "synthetic-0002",
                sessionId: "SYNTHETIC-SESSION-0001",
                surface: "chat",
                userMessage: "Draft the weekly review for Sam, short version.",
                counts: [
                    "persona.docCount": 3,
                    // The seeded substrate reliably yields attention terms
                    // (13 observed). Declared as 1 so the ">0 where source >0"
                    // invariant bites on a cut attention feed WITHOUT pinning a
                    // brittle exact count. Verified 2026-08-21: cutting
                    // NativeCognitionRuntime.attentionSignals fails this lane.
                    "contextFlow.attentionTerms": 1,
                    // The history lane. Declared as floors (1), same
                    // reasoning: "alive where the source was", never an exact
                    // count. Verified 2026-08-21 by mutation: forcing the
                    // history block nil fails `history.injected`; replacing
                    // the expanded recall query with the bare message fails
                    // `history.recallQuery`.
                    "history.priorCount": 1,
                    "history.recallQueryChars": 1,
                    "historyBlockChars": 1,
                    "remPins.count": 1,
                ],
                flags: [:],
                capsuleBytes: 1,
                containsCognitiveSubstrate: true,
                containsOrganismBehavior: true,
                ts: turnInstant.addingTimeInterval(30),
                transcript: BenchTranscriptWindow(
                    fileURL: transcriptURL, lines: windowRows.count, truncated: false
                ),
                remPinTexts: remPinTexts
            ),
        ]
        let fixture = BenchFixture(
            label: "synthetic", dataRoot: dataRoot, turns: turns, seed: seed
        )
        return (fixture, { try? FileManager.default.removeItem(at: root) })
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Tests
// ─────────────────────────────────────────────────────────────────────────────

@Suite("TurnReplayBench", .serialized)
struct TurnReplayBenchTests {

    /// The build-level probe: can this build still NAME feelings? A lobotomy of
    /// the fingerprint families shows up here before any fixture is involved.
    @Test func feltFingerprintVocabularyIsStillReachable() {
        let vocabulary = TurnReplayBench.reachableFeltVocabulary()
        #expect(
            vocabulary.count >= BenchPolicy.minimumFeltVocabulary,
            Comment(rawValue: "reachable felt vocabulary collapsed to \(vocabulary.count) word(s): "
                + vocabulary.sorted().joined(separator: ", "))
        )
    }

    /// ALWAYS RUNS. No personal data, no env var, no network.
    @Test func syntheticFixtureReplaysAndHoldsEveryEnvelopeInvariant() async throws {
        let (fixture, cleanup) = try await SyntheticBenchFixture.make()
        defer { cleanup() }
        let result = await TurnReplayBench(fixture: fixture).run()
        print(result.report)
        #expect(result.turnsReplayed == fixture.turns.count,
                Comment(rawValue: "vacuity guard: replayed \(result.turnsReplayed) of \(fixture.turns.count) turns"))
        #expect(result.passed, Comment(rawValue: "\n" + result.report))
        // WIRING PROOF for the speed half: the grader's clauses are mutation-
        // proved in `stageBudgetBitesOnEveryClause`, but that proves the pure
        // function, not that the bench feeds it. These two lines can only
        // appear if a real replayed receipt of each kind was graded — and the
        // per-stage numbers are printed for a human to argue with.
        #expect(result.report.contains("speed[context.summary]"),
                Comment(rawValue: "the bare-assembly speed lane never ran:\n" + result.report))
        #expect(result.report.contains("speed[context.history.summary]"),
                Comment(rawValue: "the history-lane speed budget never ran:\n" + result.report))
        #expect(result.report.contains("substrate rem_pins.read (turn_traces): n=\(fixture.turns.count) p95="),
                Comment(rawValue: "the substrate REM-pin p95 grade never ran:\n" + result.report))
    }

    /// A bench that cannot fail is theater. This pins the failure path itself:
    /// a fixture whose expectations claim a lane the replay cannot possibly
    /// satisfy MUST produce a named finding.
    @Test func benchReportsANamedFindingWhenAnInvariantCannotHold() async throws {
        let (base, cleanup) = try await SyntheticBenchFixture.make()
        defer { cleanup() }
        var poisoned = base
        poisoned.label = "synthetic-negative-control"
        // The history lane's negative control: an EMPTY transcript window
        // (a session file with no rows) under an expectation that claims the
        // source saw prior turns. The reader returns nothing, so
        // `history.injected` must fire by name.
        let emptyWindow = base.dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("negative-empty-window.jsonl")
        try "".write(to: emptyWindow, atomically: true, encoding: .utf8)
        poisoned.turns = poisoned.turns.enumerated().map { index, turn in
            var t = turn
            // The synthetic root has no attention projection history, so this
            // lane can never come back nonzero — the invariant must fire.
            t.counts["contextFlow.attentionWorkingAtoms"] = 8
            if index == 0 {
                t.counts["history.priorCount"] = 5
                t.counts["history.recallQueryChars"] = 900
                t.counts["historyBlockChars"] = 2_000
                t.transcript = BenchTranscriptWindow(fileURL: emptyWindow, lines: 0, truncated: false)
            }
            return t
        }
        let result = await TurnReplayBench(fixture: poisoned).run()
        #expect(!result.passed, Comment(rawValue: "negative control passed — the gate does not bite:\n" + result.report))
        #expect(
            result.findings.contains { $0.invariant == "contextFlow.attentionWorkingAtoms" },
            Comment(rawValue: "expected a named attention finding, got:\n" + result.report)
        )
        #expect(
            result.findings.contains { $0.invariant == "history.injected" && $0.turn.hasPrefix("syntheti") },
            Comment(rawValue: "expected a named history.injected finding on the empty-window turn, got:\n" + result.report)
        )
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: The every-turn INGREDIENT lanes added 2026-08-23
    //       (ledger rows turn.ingredient.remPins, telemetry.turn.plan)
    // ─────────────────────────────────────────────────────────────────────

    /// NEGATIVE CONTROL for the REM-pins lane. Ledger row
    /// `turn.ingredient.remPins`, silent-failure class SILENT ZERO: the pins
    /// file moves or `remPinsDataRoot` goes nil, the pins stop reaching the
    /// stable prompt, and `remPins.count` reads 0 forever with nothing failing.
    ///
    /// This deletes `rem_pins.json` out from under a fixture that declares it
    /// had pins — the exact shape of "the file moved" — and requires the bench
    /// to name it. A green run here would mean the assert above proves nothing.
    @Test func benchReportsANamedFindingWhenTheRemPinsFileDisappears() async throws {
        let (fixture, cleanup) = try await SyntheticBenchFixture.make()
        defer { cleanup() }
        let pins = fixture.dataRoot.appendingPathComponent("rem_pins.json")
        #expect(FileManager.default.fileExists(atPath: pins.path),
                "the synthetic fixture must SHIP pins for its removal to prove anything")
        try FileManager.default.removeItem(at: pins)
        var poisoned = fixture
        poisoned.label = "synthetic-no-rem-pins"
        let result = await TurnReplayBench(fixture: poisoned).run()
        #expect(!result.passed,
                Comment(rawValue: "the pins lane went dark and the bench passed:\n" + result.report))
        #expect(result.findings.contains { $0.invariant == "remPins.count" },
                Comment(rawValue: "expected a named remPins.count finding, got:\n" + result.report))
    }

    /// Mutation proof for the durable-telemetry half of
    /// `speed.rem_pins.read`: the engine may still read and inject pins, but
    /// if the persisted `context.summary` row loses the timing stage, the
    /// substrate grade must fail by its own ledger ID rather than passing on a
    /// live bus receipt.
    @Test func benchNamesRemPinsSpeedRowWhenPersistedStageIsMissing() async throws {
        let (base, cleanup) = try await SyntheticBenchFixture.make()
        defer { cleanup() }
        var poisoned = base
        poisoned.label = "synthetic-missing-persisted-rem-pins-stage"
        poisoned.removePersistedRemPinsStageForNegativeControl = true
        let result = await TurnReplayBench(fixture: poisoned).run()
        #expect(!result.passed,
                Comment(rawValue: "the persisted REM stage was removed and the bench passed:\n" + result.report))
        #expect(result.findings.contains { $0.invariant == "speed.rem_pins.read" },
                Comment(rawValue: "expected named speed.rem_pins.read finding, got:\n" + result.report))
    }

    /// NEGATIVE CONTROL for the plan-hint lane. Ledger row
    /// `telemetry.turn.plan`, silent-failure class PLAN/HINT DIVERGENCE: live
    /// there are 184 `turn.plan` rows and nothing that records whether the hint
    /// reached the prompt, so "no hint produced" and "hint computed and
    /// dropped" are indistinguishable. Here the hint IS produced and IS
    /// dropped; the bench must say so by name.
    @Test func benchReportsANamedFindingWhenThePlanHintNeverReachesThePrompt() async throws {
        let (fixture, cleanup) = try await SyntheticBenchFixture.make()
        defer { cleanup() }
        var poisoned = fixture
        poisoned.label = "synthetic-dropped-plan-hint"
        poisoned.suppressTurnPlanHint = true
        let result = await TurnReplayBench(fixture: poisoned).run()
        #expect(!result.passed,
                Comment(rawValue: "the plan hint was dropped and the bench passed:\n" + result.report))
        #expect(result.findings.contains { $0.invariant == "turnPlan.hintInjected" },
                Comment(rawValue: "expected a named turnPlan.hintInjected finding, got:\n"
                        + result.report))
    }

    /// The pins-header probe must actually resolve. If the renderer stops
    /// emitting a distinguishable header the `remPins.injectedStable` invariant
    /// degrades to a named finding rather than a silent pass — this pins that
    /// the probe is working TODAY, so a green bench means the check ran.
    @Test func remPinsHeaderProbeResolvesFromTheProductionRenderer() {
        let header = TurnReplayRemPinsProbe.header
        #expect(header != nil, "the REM-pins header could not be derived from the renderer")
        #expect(header?.isEmpty == false)
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: The SPEED half of the turn-replay contract
    //       (ledger rows speed.budget.frozenBaseline, speed.stage.totalMs,
    //        speed.stage.contextFlow.prepare, speed.stage.rem_pins.read,
    //        speed.stage.contextFlow.attention, speed.stage.history.lane,
    //        speed.stage.untracedAssemblyPrologue)
    // ─────────────────────────────────────────────────────────────────────

    /// The abandon-latch constant must be readable out of the engine source.
    /// Unreadable ⇒ `speed.attentionLatch` grades nothing, so this failing is
    /// the difference between a bounded lane and a lane nobody is checking.
    @Test func attentionAbandonLatchIsReadableFromTheEngineSource() {
        let latch = TurnReplayAttentionLatch.declaredMilliseconds
        #expect(latch != nil,
                "attentionSignalsTimeoutNanos could not be read from ChatOrchestration+TurnEngine.swift")
        #expect((latch ?? 0) > 0)
    }

    /// The prologue ceiling must be DERIVED from the production constant, not
    /// retyped. If someone changes `queryEmbeddingWarmupWaitNanos` the budget
    /// moves with it — this proves the derivation, so the bound can never go
    /// stale against the constant it is supposed to bound.
    @Test func untracedPrologueCeilingIsDerivedFromTheWarmupConstant() {
        let constantMs = Int(SwiftNativeTurnEngine.queryEmbeddingWarmupWaitNanos / 1_000_000)
        #expect(constantMs > 0)
        #expect(TurnReplayStageBaseline.prologueCeilingMs
                == constantMs + TurnReplayStageBaseline.prologueSlackMs)
    }

    /// `chat.engine.contextStageBudget`: every typed stage the production
    /// context or history wrapper can emit has a frozen entry before replay
    /// grades it. Runtime replay proves receipt wiring; this registry contract
    /// covers conditional branches a fixture need not happen to visit.
    @Test func everyProductionContextStageHasAFrozenBudgetEntry() {
        let emittedAssembly = Set(ContextStageName.allCases.map(\.rawValue))
        let budgetedAssembly = TurnReplayStageBaseline.assembly.knownStages
        #expect(
            emittedAssembly == budgetedAssembly,
            Comment(rawValue: "production assembly-stage vocabulary and frozen budget diverged; "
                + "unbudgeted=\(emittedAssembly.subtracting(budgetedAssembly).sorted()) "
                + "stale=\(budgetedAssembly.subtracting(emittedAssembly).sorted())")
        )

        let emittedHistory = Set(ContextHistoryStageName.allCases.map(\.rawValue))
        let budgetedHistory = TurnReplayStageBaseline.history.knownStages
        #expect(
            emittedHistory == budgetedHistory,
            Comment(rawValue: "production history-stage vocabulary and frozen budget diverged; "
                + "unbudgeted=\(emittedHistory.subtracting(budgetedHistory).sorted()) "
                + "stale=\(budgetedHistory.subtracting(emittedHistory).sorted())")
        )
    }

    /// MUTATION PROOFS for every clause of the speed budget, against
    /// hand-built receipts. The grader is pure, so each clause is proved to
    /// bite in microseconds instead of needing a slow replay per clause — and
    /// a clause that cannot be made to fire here is theater.
    @Test func stageBudgetBitesOnEveryClause() {
        let frozen = TurnReplayStageBaseline.assembly
        // A receipt that satisfies everything: every required stage present,
        // nothing unknown, small numbers.
        var healthyStages: [String: Int] = [:]
        for stage in frozen.required.keys { healthyStages[stage] = 1 }
        let healthy = BenchReceipt(totalMs: 20, stageMs: healthyStages)
        #expect(TurnReplayStageBudget.evaluate(
            kind: "context.summary", receipt: healthy, turnLabel: "t"
        ).isEmpty, "the healthy control must produce no findings")

        func invariants(_ receipt: BenchReceipt, _ kind: String = "context.summary",
                        inner: Int? = nil) -> Set<String> {
            Set(TurnReplayStageBudget.evaluate(
                kind: kind, receipt: receipt, turnLabel: "t", innerTotalMs: inner
            ).map(\.invariant))
        }

        // (1) DARK STAGE — the clause with teeth. Drop `rem_pins.read`, which
        //     production records unconditionally.
        var dark = healthyStages
        dark["rem_pins.read"] = nil
        #expect(invariants(BenchReceipt(totalMs: 20, stageMs: dark)).contains("speed.stageDark"))

        // (2) UNBUDGETED NEW STAGE.
        var extra = healthyStages
        extra["contextFlow.brandNewLane"] = 3
        #expect(invariants(BenchReceipt(totalMs: 20, stageMs: extra))
                .contains("speed.stageUnbudgeted"))

        // (3) A SINGLE STAGE OVER BUDGET.
        var slow = healthyStages
        slow["contextFlow.prepare"] = TurnReplayStageBaseline.budget(
            forFrozenMs: frozen.required["contextFlow.prepare"] ?? 0,
            floor: TurnReplayStageBaseline.stageFloorMs
        ) + 1
        #expect(invariants(BenchReceipt(totalMs: 20, stageMs: slow))
                .contains("speed.stageBudget"))

        // (3b) THE WHOLE RECEIPT OVER BUDGET.
        let totalBudget = TurnReplayStageBaseline.budget(
            forFrozenMs: frozen.totalMs, floor: TurnReplayStageBaseline.totalFloorMs
        )
        var bulk = healthyStages
        bulk["contextFlow.prepare"] = totalBudget + 1
        let fat = BenchReceipt(totalMs: totalBudget + 1, stageMs: bulk)
        #expect(invariants(fat).contains("speed.totalBudget"))

        // (4) THE UNTRACED PROLOGUE. Nothing is over ITS stage budget — the
        //     cost is entirely in the gap between totalMs and the traced sum,
        //     which is exactly how a warm-up-wait regression hides today.
        let prologue = BenchReceipt(
            totalMs: TurnReplayStageBaseline.prologueCeilingMs + 50, stageMs: healthyStages
        )
        let prologueFindings = invariants(prologue)
        #expect(prologueFindings.contains("speed.untracedPrologue"))

        // (5) THE HISTORY NESTING. `context.base` must contain the whole inner
        //     assembly; smaller means the nesting this bench documents (and any
        //     aggregate built on it) is wrong.
        var historyStages: [String: Int] = [:]
        for stage in TurnReplayStageBaseline.history.required.keys { historyStages[stage] = 1 }
        let broken = BenchReceipt(totalMs: 30, stageMs: historyStages)
        #expect(invariants(broken, "context.history.summary", inner: 500)
                .contains("speed.history.nesting"))
        #expect(!invariants(broken, "context.history.summary", inner: 1)
                .contains("speed.history.nesting"),
                "the nesting clause must not fire when context.base does contain the assembly")
    }

    /// The REAL-fixture lane. Skipped (never silently passed) without the env
    /// var, because the fixture holds real personal data and lives outside the
    /// repository.
    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["NATIVEAGENT_BENCH_FIXTURE"]?
            .trimmingCharacters(in: .whitespaces).isEmpty == false
            || ProcessInfo.processInfo.environment["NATIVEAGENT_RELEASE_GATE"] == "1",
        "NATIVEAGENT_BENCH_FIXTURE unset — real-fixture replay skipped; synthetic replay remains enabled"
    ))
    func realFixtureReplayHoldsEveryEnvelopeInvariant() async throws {
        guard let path = ProcessInfo.processInfo.environment["NATIVEAGENT_BENCH_FIXTURE"],
              !path.trimmingCharacters(in: .whitespaces).isEmpty else {
            // Ordinary `swift test`: an explicit SKIP, not a "known issue" —
            // "passed with 1 known issue" normalizes in release output until
            // nobody reads it (gpt-5.5 review). In RELEASE-GATE mode the
            // missing fixture is a hard failure: a release close-out that
            // forgot to capture a fixture must not look green.
            if ProcessInfo.processInfo.environment["NATIVEAGENT_RELEASE_GATE"] == "1" {
                Issue.record("RELEASE GATE: NATIVEAGENT_BENCH_FIXTURE is required — capture one with script/agent_bench_capture.swift before shipping")
                return
            }
            return
        }
        let directory = URL(fileURLWithPath: path).standardizedFileURL
        let fixture = try BenchFixture.load(directory: directory, label: directory.lastPathComponent)
        #expect(!fixture.turns.isEmpty, Comment(rawValue: "vacuity guard: fixture \(path) declares zero turns"))
        let result = await TurnReplayBench(fixture: fixture).run()
        print(result.report)
        #expect(result.passed, Comment(rawValue: "\n" + result.report))
    }
}
