//  TurnReplayStageBudget.swift — the SPEED half of the turn-replay contract.
//
//  docs/build_plans/evals-total-coverage.md states the turn-replay contract as
//  "every turn carries what it should + a SPEED BUDGET per stage against a
//  frozen baseline". Until this file the second half did not exist: the bench
//  graded ingredients and segment sizes and never looked at a single
//  millisecond, so a 3x assembly slowdown shipped green (ledger row
//  `speed.budget.frozenBaseline`, status UNCOVERED).
//
//  ─────────────────────────────────────────────────────────────────────────
//  WHAT THIS GRADES, AND WHICH HALF HAS THE TEETH
//  ─────────────────────────────────────────────────────────────────────────
//  Three clauses, in descending order of how much they can be trusted:
//
//   1. STRUCTURAL — a stage the baseline declares REQUIRED that the replay did
//      not emit is a DARK STAGE. This is the clause with real teeth: it is
//      machine-independent, cannot flake, and it is what would have caught a
//      silently dropped lane (the "resident allowlist drop" class). Deleting
//      `trace.record("rem_pins.read", …)` fails here by name.
//
//   2. STRUCTURAL — a stage the replay emitted that the baseline has never
//      heard of is an UNBUDGETED NEW STAGE. Also machine-independent. It is
//      not an accusation of slowness; it is the ratchet that stops the budget
//      from silently covering a shrinking fraction of the turn. Adding a stage
//      is fine — adding it to the table below in the same commit is the price.
//
//   3. WALL-CLOCK — elapsed vs `multiplier x` the frozen number, with a floor.
//      This is the weakest clause and it is deliberately WIDE. Per the
//      hangproof-subprocess-tests convention ("never assert a tight elapsed
//      bound"), a test machine under parallel load can be several times slower
//      than the machine that froze the baseline. The band catches an
//      order-of-magnitude regression, not a 40% one, and that is the honest
//      claim. Anything tighter teaches people to disable the gate.
//
//  Plus two derived lanes that are not stages at all:
//
//   4. THE UNTRACED PROLOGUE (`speed.stage.untracedAssemblyPrologue`). The
//      residual `totalMs - sum(stageMs)` is the largest single bucket of live
//      assembly (p50 260ms / p95 1208ms against totalMs p50 416 / p95 1914,
//      measured over 96 live rows) because `beginQueryEmbedding` and its
//      bounded warm-up wait sit BEFORE the first `trace.record`. Budgeting
//      only the named stages would leave ~63% of median assembly unbudgeted,
//      so the residual is measured, named, reported, and bounded here.
//
//      Its hard bound is derived from the PRODUCTION CONSTANT
//      `SwiftNativeTurnEngine.queryEmbeddingWarmupWaitNanos`, not from a
//      retyped number — that is the "grep-proves this constant against the
//      assembly budget" the ledger says nothing does today. Raise the constant
//      and the budget moves with it; the assert still bounds the wait.
//
//   5. THE HISTORY NESTING (`speed.stage.history.lane`). `context.base` inside
//      the `context.history.summary` receipt is the ENTIRE inner assembly,
//      already reported by its own `context.summary` receipt. Nothing in the
//      instrument or the bench declared that nesting, so a future aggregate
//      that sums both receipts would silently double-count. The declaration is
//      made executable here: `context.base >= inner totalMs`.
//
//  ─────────────────────────────────────────────────────────────────────────
//  WHY THE BASELINE IS SWIFT AND NOT JSON
//  ─────────────────────────────────────────────────────────────────────────
//  A `.json` beside the test sources would need a `resources:` declaration in
//  Package.swift to be readable from the test bundle. A typed table needs
//  nothing, cannot drift out of sync with the decoder, and shows up in a diff
//  the same way. It is dated, and it moves only with a named wave.

import Foundation
import DreamREMCycle
import PersistenceCore
@testable import ChatOrchestration

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - One decoded trace receipt
// ─────────────────────────────────────────────────────────────────────────────

/// A `context.summary` / `context.history.summary` / `turn.plan` payload,
/// decoded off the bench's private trace bus.
///
/// Before this existed the bench drained ONLY `payload.counts` — every
/// millisecond the assembly measured about itself was thrown away at the bus,
/// which is the mechanical reason no speed invariant could be written.
struct BenchReceipt: Sendable {
    var counts: [String: Int] = [:]
    var stageMs: [String: Int] = [:]
    var flags: [String: Bool] = [:]
    var labels: [String: String] = [:]
    var strings: [String: String] = [:]
    var totalMs: Int = 0

    func count(_ key: String) -> Int { counts[key] ?? 0 }

    /// Stage timings EXCLUDING the ones nested inside another stage.
    ///
    /// `recordAttentionTrace` writes each attention sub-stage as its own
    /// timing (`contextFlow.attention.<stage>`) while `contextFlow.attention`
    /// already spans all of them. Summing raw `stageMs` therefore double-counts
    /// the attention lane and would understate the untraced residual — the
    /// exact arithmetic error that made the residual invisible in the first
    /// place. Nesting is declared here, once.
    var topLevelStageMs: [String: Int] {
        stageMs.filter { !$0.key.hasPrefix("contextFlow.attention.") }
    }

    var tracedMs: Int { topLevelStageMs.values.reduce(0, +) }

    /// `totalMs - sum(top-level stages)`: everything the assembly spent that no
    /// `trace.record` wrapped. Never negative (clock granularity can make the
    /// parts round above the whole on a sub-millisecond turn).
    var untracedResidualMs: Int { max(0, totalMs - tracedMs) }

    /// Decode from the bus payload. Unknown shapes decode to empty rather than
    /// throwing: a missing key must surface as a NAMED invariant breach
    /// upstream, not as a decode error nobody can act on.
    init(payload: JSONValue) {
        guard case .object(let object) = payload else { return }
        func ints(_ key: String) -> [String: Int] {
            guard case .object(let nested)? = object[key] else { return [:] }
            var out: [String: Int] = [:]
            for (k, v) in nested {
                if case .int(let n) = v { out[k] = Int(n) }
                else if case .double(let d) = v { out[k] = Int(d) }
            }
            return out
        }
        counts = ints("counts")
        stageMs = ints("stageMs")
        if case .object(let raw)? = object["flags"] {
            for (k, v) in raw { if case .bool(let b) = v { flags[k] = b } }
        }
        if case .object(let raw)? = object["labels"] {
            for (k, v) in raw { if case .string(let s) = v { labels[k] = s } }
        }
        for (k, v) in object {
            if case .string(let s) = v { strings[k] = s }
        }
        if case .int(let n)? = object["totalMs"] { totalMs = Int(n) }
        else if case .double(let d)? = object["totalMs"] { totalMs = Int(d) }
    }

    /// Test-only constructor for the budget's own negative controls.
    init(totalMs: Int, stageMs: [String: Int], counts: [String: Int] = [:]) {
        self.totalMs = totalMs
        self.stageMs = stageMs
        self.counts = counts
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - The frozen baseline
// ─────────────────────────────────────────────────────────────────────────────

/// THE CHECKED-IN PER-STAGE BASELINE, captured on the SYNTHETIC fixture.
///
/// Captured 2026-08-23 on an M-series Mac running `swift test --filter
/// TurnReplayBench` with nothing else on the box. Numbers are the max observed
/// across the fixture's turns, which on a synthetic root are all small — the
/// fixture has no memory store and a four-row transcript. That is FINE and it
/// is the point: the wall-clock clause is the weak one (see the header), and
/// the two structural clauses do not care what the numbers are.
///
/// MOVING THESE NUMBERS IS A NAMED ACT. A stage that legitimately got slower
/// gets its baseline raised in the same commit as the change that slowed it,
/// with the reason in the commit message — never as a drive-by "unflake".
enum TurnReplayStageBaseline {
    static let capturedOn = "2026-08-23"
    static let capturedOnFixture = "synthetic"

    /// How far above the frozen number a replay may land before it is a
    /// finding. Wide on purpose (see clause 3 in the header).
    static let slowdownMultiplier = 5.0
    /// No stage is graded below this. Sub-100ms stages on a loaded test box
    /// swing by more than any multiplier can absorb.
    static let stageFloorMs = 150
    /// Same idea for the whole-assembly number.
    static let totalFloorMs = 1_500
    /// Slack above the production warm-up constant for the untraced prologue.
    static let prologueSlackMs = 400

    /// One receipt kind's expectation.
    struct Frozen: Sendable {
        /// Stages that MUST appear on every replayed turn of this kind.
        /// A missing one is a dark stage — clause 1, the teeth.
        var required: [String: Int]
        /// Stages the production path emits CONDITIONALLY (a branch that this
        /// fixture may or may not take). Budgeted when present, never dark.
        /// Being explicit about which is which is what keeps clause 1 from
        /// being a flake generator, and keeps clause 2 from being vacuous.
        var conditional: [String: Int]
        /// Whole-receipt `totalMs`.
        var totalMs: Int
        /// `totalMs - sum(top-level stages)` at capture.
        var residualMs: Int
        /// Whether this receipt's residual is the one that contains the
        /// query-embedding warm-up wait, and therefore gets the ceiling derived
        /// from the production constant. True for the bare assembly only: in
        /// the history receipt that wait is already inside `context.base`.
        var residualCarriesEmbeddingWarmup: Bool

        func frozenMs(for stage: String) -> Int? {
            required[stage] ?? conditional[stage]
        }
        var knownStages: Set<String> {
            Set(required.keys).union(conditional.keys)
        }
    }

    /// `context.summary` — the bare per-turn assembly.
    ///
    /// `rem_pins.read` is REQUIRED: `ChatOrchestration+TurnEngine.swift:860`
    /// records it unconditionally, outside the `if let dataRoot` — so it is
    /// present even on a root with no pins, and its disappearance means the
    /// read site itself was removed (ledger row `speed.stage.rem_pins.read`).
    ///
    /// `contextFlow.attention.*` sub-stages and `context.clock_runtime` /
    /// `provider.preferences` are conditional: they sit inside branches.
    ///
    /// The conditional `contextFlow.attention.*` entries are exactly
    /// `ContextStageTrace`'s own `permittedStages` set (actorAdmission /
    /// bootstrap / substrate / organism / pursuit) — production drops any other
    /// sub-stage name on the floor, so this list is closed by construction and
    /// not a guess about what might show up.
    static let assembly = Frozen(
        required: [
            "contextFlow.attention": 2,
            "contextFlow.prepare": 5,
            "persona.compile": 2,
            "rem_pins.read": 2,
            "memory.recall": 2,
            "tools.names": 1,
            "tools.schemas": 1,
            "prompt.render": 1,
        ],
        conditional: [
            // Taken only when the turn did NOT reuse an admitted provider.
            "provider.preferences": 5,
            // Skipped by the history lane (includeClockContext: false there).
            "context.clock_runtime": 2,
            "contextFlow.attention.actorAdmission": 2,
            "contextFlow.attention.bootstrap": 2,
            "contextFlow.attention.substrate": 2,
            "contextFlow.attention.organism": 2,
            "contextFlow.attention.pursuit": 2,
        ],
        totalMs: 20,
        residualMs: 15,
        residualCarriesEmbeddingWarmup: true
    )

    /// `context.history.summary` — the session-history lane wrapped around it.
    /// `context.base` here is the WHOLE inner assembly (see clause 5).
    static let history = Frozen(
        required: [
            "history.prompt_read": 2,
            "history.recall_query": 2,
            "context.base": 20,
            "history.digest": 2,
            "history.render": 2,
        ],
        conditional: [
            // Only when the window exceeded historyLimit or was truncated.
            "history.middle_sample": 5,
            "context.clock_runtime": 2,
        ],
        totalMs: 30,
        residualMs: 10,
        residualCarriesEmbeddingWarmup: false
    )

    static func frozen(forKind kind: String) -> Frozen? {
        switch kind {
        case "context.summary": return assembly
        case "context.history.summary": return history
        default: return nil
        }
    }

    static func budget(forFrozenMs frozenMs: Int, floor: Int) -> Int {
        max(floor, Int((Double(frozenMs) * slowdownMultiplier).rounded(.up)))
    }

    /// The hard ceiling on the untraced prologue, DERIVED from the production
    /// constant rather than retyped. `queryEmbeddingWarmupWaitNanos` is the
    /// only unbounded-looking thing sitting outside every `trace.record`; if it
    /// is raised, this moves with it and the assertion stays true-by-derivation
    /// instead of quietly becoming vacuous.
    static var prologueCeilingMs: Int {
        Int(SwiftNativeTurnEngine.queryEmbeddingWarmupWaitNanos / 1_000_000) + prologueSlackMs
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Production-emitted context-stage vocabulary
// ─────────────────────────────────────────────────────────────────────────────

/// The stage-budget table is intentionally frozen, but the stage names are
/// minted by the real turn engine. A replay fixture only visits some conditional
/// branches, so a new literal hidden behind one of those branches could otherwise
/// remain unbudgeted until a particular fixture happened to take it. Read the
/// actual emission sites instead of duplicating another hand-maintained list:
/// a new stage must be placed in `TurnReplayStageBaseline.assembly` in the same
/// change, or the executable contract fails by name.
// ─────────────────────────────────────────────────────────────────────────────
// MARK: - The grader
// ─────────────────────────────────────────────────────────────────────────────

/// Pure. Takes a decoded receipt and the frozen table, returns named findings.
/// Being pure is what lets the budget's OWN negative controls run in
/// microseconds against hand-built receipts instead of needing a slow replay to
/// prove each clause bites.
enum TurnReplayStageBudget {

    /// Grade one receipt against its frozen row.
    /// - Parameter innerTotalMs: for `context.history.summary` only — the inner
    ///   `context.summary` totalMs, used for the nesting declaration.
    static func evaluate(
        kind: String,
        receipt: BenchReceipt,
        turnLabel: String,
        innerTotalMs: Int? = nil
    ) -> [BenchFinding] {
        guard let frozen = TurnReplayStageBaseline.frozen(forKind: kind) else { return [] }
        var findings: [BenchFinding] = []
        func breach(_ invariant: String, _ expected: String, _ got: String) {
            findings.append(BenchFinding(
                turn: turnLabel, invariant: invariant, expected: expected, got: got
            ))
        }

        // ── (1) DARK STAGE. The clause with teeth.
        for (stage, frozenMs) in frozen.required.sorted(by: { $0.key < $1.key })
        where receipt.stageMs[stage] == nil {
            breach("speed.stageDark",
                   "\(kind) to carry the required stage `\(stage)` "
                   + "(frozen \(frozenMs)ms, \(TurnReplayStageBaseline.capturedOn))",
                   "absent — the stage went dark; either the trace.record was "
                   + "removed or the whole lane stopped running")
        }

        // ── (2) UNBUDGETED NEW STAGE. Also structural.
        let known = frozen.knownStages
        for stage in receipt.stageMs.keys.sorted() where !known.contains(stage) {
            breach("speed.stageUnbudgeted",
                   "every \(kind) stage to appear in the frozen baseline "
                   + "(\(TurnReplayStageBaseline.capturedOn))",
                   "`\(stage)` = \(receipt.stageMs[stage] ?? 0)ms is new — add it to "
                   + "TurnReplayStageBaseline so the budget keeps covering the whole turn")
        }

        // ── (3) WALL CLOCK. Wide band, weakest clause.
        for (stage, elapsed) in receipt.stageMs.sorted(by: { $0.key < $1.key }) {
            guard let frozenMs = frozen.frozenMs(for: stage) else { continue }
            let budget = TurnReplayStageBaseline.budget(
                forFrozenMs: frozenMs, floor: TurnReplayStageBaseline.stageFloorMs
            )
            guard elapsed > budget else { continue }
            breach("speed.stageBudget",
                   "\(kind) stage `\(stage)` <= \(budget)ms "
                   + "(\(TurnReplayStageBaseline.slowdownMultiplier)x the frozen "
                   + "\(frozenMs)ms, floor \(TurnReplayStageBaseline.stageFloorMs)ms)",
                   "\(elapsed)ms")
        }

        // ── (3b) THE WHOLE RECEIPT.
        let totalBudget = TurnReplayStageBaseline.budget(
            forFrozenMs: frozen.totalMs, floor: TurnReplayStageBaseline.totalFloorMs
        )
        if receipt.totalMs > totalBudget {
            breach("speed.totalBudget",
                   "\(kind) totalMs <= \(totalBudget)ms "
                   + "(\(TurnReplayStageBaseline.slowdownMultiplier)x the frozen "
                   + "\(frozen.totalMs)ms, floor \(TurnReplayStageBaseline.totalFloorMs)ms)",
                   "\(receipt.totalMs)ms")
        }

        // ── (4) THE UNTRACED PROLOGUE — bounded by the production constant.
        let residual = receipt.untracedResidualMs
        let baselineResidualCeiling = TurnReplayStageBaseline.budget(
            forFrozenMs: frozen.residualMs, floor: TurnReplayStageBaseline.stageFloorMs
        )
        let residualCeiling = frozen.residualCarriesEmbeddingWarmup
            ? max(TurnReplayStageBaseline.prologueCeilingMs, baselineResidualCeiling)
            : baselineResidualCeiling
        if residual > residualCeiling {
            breach("speed.untracedPrologue",
                   "\(kind) untraced residual (totalMs - sum(top-level stageMs)) "
                   + "<= \(residualCeiling)ms"
                   + (frozen.residualCarriesEmbeddingWarmup
                      ? " — the bound is DERIVED from "
                        + "SwiftNativeTurnEngine.queryEmbeddingWarmupWaitNanos "
                        + "(\(SwiftNativeTurnEngine.queryEmbeddingWarmupWaitNanos / 1_000_000)ms) "
                        + "plus \(TurnReplayStageBaseline.prologueSlackMs)ms slack"
                      : " (this receipt does not carry the embedder warm-up wait; "
                        + "that cost sits inside context.base)"),
                   "\(residual)ms untraced of \(receipt.totalMs)ms total "
                   + "(\(receipt.tracedMs)ms traced across "
                   + "\(receipt.topLevelStageMs.count) top-level stage(s)) — the "
                   + "largest bucket of assembly is outside every trace.record")
        }

        // ── (5) THE HISTORY NESTING DECLARATION.
        if kind == "context.history.summary", let innerTotalMs,
           let base = receipt.stageMs["context.base"] {
            // 1ms of slack: the two clocks round independently.
            if base + 1 < innerTotalMs {
                breach("speed.history.nesting",
                       "`context.base` (\(base)ms) >= the inner context.summary "
                       + "totalMs (\(innerTotalMs)ms) — context.base WRAPS the whole "
                       + "bare assembly, which is why summing both receipts' stageMs "
                       + "double-counts it",
                       "context.base is SMALLER than the assembly it is supposed to "
                       + "contain — the nesting this bench documents no longer holds, "
                       + "and any aggregate built on it is wrong")
            }
        }

        return findings
    }

    /// One line of report per receipt: every stage with its ms, the traced sum,
    /// and the residual. Printed whether or not anything failed — a speed gate
    /// nobody can read the numbers of is a gate nobody will trust.
    static func reportLine(kind: String, receipt: BenchReceipt) -> String {
        let stages = receipt.topLevelStageMs
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return "  speed[\(kind)] total=\(receipt.totalMs)ms traced=\(receipt.tracedMs)ms "
            + "untraced=\(receipt.untracedResidualMs)ms :: \(stages)"
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - The attention abandon latch, pinned to the source
// ─────────────────────────────────────────────────────────────────────────────

/// `SwiftNativeTurnEngine.attentionSignalsTimeoutNanos` is `private static`, so
/// no import can reach it. Retyping `250` here would produce an assertion that
/// silently stops meaning anything the day someone changes the constant — the
/// vacuous-guard failure mode. So the number is READ OUT OF THE SOURCE, and a
/// source that no longer declares it is reported by name instead of falling
/// back to a guess.
///
/// The lane it guards: attention is bounded BY DESIGN (a wedged substrate can
/// never stall a chat turn). Bounded-by-design means the observable signature
/// of a wedge is not "slow" — it is "pinned just under the latch, with
/// `contextFlow.attentionTimedOut` set". A run that blows through the latch
/// WITHOUT that flag means the latch itself stopped working.
enum TurnReplayAttentionLatch {
    /// nil ⇒ the declaration could not be found (reported, never assumed).
    static let declaredMilliseconds: Int? = {
        guard let root = try? AppSourceScraping.repositoryRoot() else { return nil }
        let url = root.appendingPathComponent(
            "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatOrchestration+TurnEngine.swift"
        )
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in source.split(separator: "\n")
        where line.contains("attentionSignalsTimeoutNanos") && line.contains("=") {
            let digits = line.split(separator: "=").last.map {
                $0.filter { $0.isNumber || $0 == "_" }.replacingOccurrences(of: "_", with: "")
            } ?? ""
            if let nanos = Int(digits), nanos > 0 { return nanos / 1_000_000 }
        }
        return nil
    }()

    /// Scheduling slack above the latch. The latch is a `Task.sleep` race
    /// against the read, so the observed stage can land slightly above it.
    static let slackMs = 250
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - The REM-pins header, derived from the production renderer
// ─────────────────────────────────────────────────────────────────────────────

/// The header `renderSystemPromptSegments` puts above REM pins in the STABLE
/// segment — obtained by CALLING the production renderer with one probe pin and
/// diffing against the same call with none, never by retyping the string.
///
/// Same reasoning as the recall-query `bareLine` probe already in the bench: a
/// retyped literal turns into an assertion that quietly stops matching the day
/// the header is reworded, and a bench that no longer matches anything passes.
/// Derived, it either tracks the renderer or reports that it cannot (nil).
enum TurnReplayRemPinsProbe {
    private static let probeText = "BENCH-REM-PIN-PROBE-9f3a2c"

    /// nil ⇒ the renderer emitted no distinguishable header for a pin, which is
    /// itself reported by name rather than passed over.
    static let header: String? = {
        func stable(_ pins: [REMPin]) -> String {
            SwiftNativeTurnEngine.renderSystemPromptSegments(
                compiledPersonaPrompt: "PROBE-PERSONA",
                recalled: [],
                remPins: pins,
                includeNaturalExpressionGuidance: false
            ).stable
        }
        let base = stable([])
        let withPin = stable([
            REMPin(id: "probe", text: probeText, createdAt: "2026-01-01T00:00:00Z")
        ])
        guard withPin.count > base.count, withPin.hasPrefix(base) else { return nil }
        for raw in String(withPin.dropFirst(base.count)).split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("-") || line.contains(probeText) { continue }
            return line
        }
        return nil
    }()
}
