import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Prompt prefix health (Runtime)
//
// The v2Prefix shape (a08a8814 and the commits around it) makes the identity
// block a strict prefix of the stable block so ONE breakpoint covers both and
// every turn after the first reads the transcript out of the provider's cache.
// That property is invisible from the UI: a regression does not throw, it just
// quietly stops reading cache and starts paying full price on every turn. It
// drifted silently once already, which is why this row exists.
//
// Everything below is READ-ONLY over `data/turn_traces/*.jsonl`, bounded by
// `TurnTraceWindowReader` (tailed day files, at most 7 of them), and runs ONLY
// when Doctor runs. Nothing here is on a timer, a chat hook, or the cognition
// runtime.
//
// The measurement window starts at THIS BUILD's launch (DoctorWindowFloor).
// Grading a rolling history window meant grading pre-fix turns — arithmetically
// true and operationally a lie about the build that is actually running.
//
// NORTHSTAR clause 2 is the spec for what it may say:
//   * A day file that exists but will not read is a FAIL, not a zero.
//   * A window with no v2 turns reads UNMEASURED, never "0 problems".
//   * The window it used is NAMED in the row, every time.
//   * The uncached per-turn block is named out loud, so nobody reads the hit
//     rate as "the cache is broken" when it is working exactly as designed.

public struct PromptPrefixHealthCheck: DoctorCheck {
    public let id: String = "prompt_prefix_health"
    public let title: String = "Prompt Prefix Cache"
    /// Doctor's eyes only. This row grades a measurement window, and an
    /// unattended sweep that turns a window verdict into a 3am push is how
    /// 2026-09-02 happened. See `DoctorCheck.heartbeatEligible`.
    public let heartbeatEligible: Bool = false

    private let root: URL
    private let now: @Sendable () -> Date
    /// Injectable so a test never reads (or needs) the real user default.
    private let killSwitchRaw: @Sendable () -> String?
    /// The build whose behavior this row is allowed to grade.
    private let identity: NativeAgentBuildIdentity
    private let cache: DoctorScanCache

    /// Hard ceiling on day FILES opened. The measurement window's floor is
    /// this build's launch (see DoctorWindowFloor); this only bounds the read.
    private let maximumDayFiles = 7
    /// How many offending turnIds to name before summarizing.
    private let maximumNamedTurns = 5
    /// A non-first turn creating more than this many cache tokens did not
    /// reuse the prefix — it rebuilt it.
    private let creationBreakTokens = 3_000
    /// Tolerance: one violation per session per day is noise (a model swap, a
    /// provider-side eviction, a clock skew). More than that is drift.
    private let toleratedPerSessionDay = 1
    /// Below this, an Anthropic lane is not really reusing its prefix.
    private let minimumAnthropicHitPercent = 50.0
    /// The hit rate is a RATE, so it needs enough turns to mean anything. The
    /// window opens at this build's launch, so right after a relaunch there
    /// may be two turns; the percentage is still shown, just not graded.
    /// (The (a)/(b)/(c) violations are deterministic per-turn evidence, not
    /// rates, so a single one still counts against the tolerance.)
    private let minimumHitRateTurns = 10

    public init(
        root: URL = defaultDataRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        killSwitchRaw: (@Sendable () -> String?)? = nil,
        identity: NativeAgentBuildIdentity = .current,
        cacheTTL: TimeInterval = 60
    ) {
        self.root = root
        self.now = now
        self.identity = identity
        self.killSwitchRaw = killSwitchRaw ?? {
            UserDefaults.standard.string(forKey: ConversationPrefixShape.defaultsKey)
        }
        self.cache = DoctorScanCache(ttl: cacheTTL)
    }

    // MARK: - Turn model

    /// The FIRST llm.call of one turn — the only call whose cache read says
    /// anything about cross-turn prefix reuse. Later calls in the same turn
    /// (tool loops) reuse within the turn and would flatter the number.
    private struct TurnObservation {
        var sessionId: String
        var turnId: String
        var at: Date
        var cacheRead: Int?
        var cacheCreation: Int?
        var windowSlid: Bool
        var fingerprint: String?
        /// One digest per cacheable-prefix message; empty on rows written
        /// before the receipt existed, which fall back to the fingerprint rule.
        var prefixDigests: [String] = []
        var volatileChars: Int?
        var toolFingerprint: String?
    }

    private static func stringArray(_ value: JSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap { item -> String? in
            if case .string(let s) = item { return s }
            return nil
        }
    }

    private struct ProviderTokens {
        var read = 0
        var created = 0
        var uncached = 0

        var total: Int { read + created + uncached }
        var hitPercent: Double? {
            total > 0 ? Double(read) / Double(total) * 100 : nil
        }
    }

    public func run() async -> CheckResult {
        let moment = now()
        if let memo = await cache.fresh(now: moment) { return memo }
        let result = measure()
        await cache.store(result, at: moment)
        return result
    }

    // MARK: - Measurement

    private func measure() -> CheckResult {
        var v2FirstCalls: [String: TurnObservation] = [:]   // turnId → first call
        var toolFingerprints: [String: String] = [:]        // turnId → tool schema sha
        var providerTokens: [String: ProviderTokens] = [:]  // provider → v2 token sums
        var v2CallCount = 0
        var v1CallCount = 0
        var unshapedCallCount = 0

        let moment = now()
        let window = DoctorWindowFloor.resolve(root: root, now: moment, identity: identity)
        let summary = TurnTraceWindowReader.scan(
            root: root,
            now: moment,
            days: window.dayFilesToRead(now: moment, maximum: maximumDayFiles),
            floor: window.floor,
            kinds: ["llm.call", "context.snapshot"]
        ) { row in
            switch row.kind {
            case "context.snapshot":
                if let sha = row.payload["toolSchemaFingerprintSHA256"]?.stringValue,
                   !row.turnId.isEmpty {
                    toolFingerprints[row.turnId] = sha
                }
            case "llm.call":
                let shape = row.payload["shapeVersion"]?.stringValue
                switch shape {
                case ConversationPrefixShape.v2Prefix.rawValue:
                    v2CallCount += 1
                case ConversationPrefixShape.v1Legacy.rawValue:
                    v1CallCount += 1
                    return
                default:
                    // Pre-shapeVersion rows and non-Anthropic lanes that never
                    // carry the field. Counted, not judged.
                    unshapedCallCount += 1
                    return
                }

                let provider = row.payload["provider"]?.stringValue ?? "unknown"
                var tokens = providerTokens[provider] ?? ProviderTokens()
                tokens.read += row.payload["cacheReadInputTokens"]?.intValue ?? 0
                tokens.created += row.payload["cacheCreationInputTokens"]?.intValue ?? 0
                tokens.uncached += row.payload["inputTokens"]?.intValue ?? 0
                providerTokens[provider] = tokens

                guard !row.turnId.isEmpty else { return }
                let observation = TurnObservation(
                    sessionId: row.sessionId ?? "unknown",
                    turnId: row.turnId,
                    at: row.ts,
                    cacheRead: row.payload["cacheReadInputTokens"]?.intValue,
                    cacheCreation: row.payload["cacheCreationInputTokens"]?.intValue,
                    windowSlid: row.payload["windowSlid"]?.boolValue ?? false,
                    fingerprint: row.payload["prefixFingerprintSHA256"]?.stringValue,
                    prefixDigests: Self.stringArray(row.payload["prefixMessageDigests"]),
                    volatileChars: row.payload["volatileBlockChars"]?.intValue,
                    toolFingerprint: nil
                )
                if let existing = v2FirstCalls[row.turnId], existing.at <= observation.at { return }
                v2FirstCalls[row.turnId] = observation
            default:
                return
            }
        }

        // Rule 3: an input we could not read is never a clean number.
        if !summary.unreadableDays.isEmpty {
            return CheckResult(
                id: id, title: title, status: "fail",
                detail: "\(summary.unreadableDays.count) turn-trace day file(s) exist but could"
                    + " not be read (\(summary.unreadableDays.joined(separator: ", ")))."
                    + " Prefix-cache health is UNMEASURED \(window.describedAs) — this row"
                    + " is not reporting zero problems, it is reporting that it could not"
                    + " look.",
                repair: "Check permissions and encoding on data/turn_traces/<day>.jsonl."
            )
        }

        let shapeLine = shapeMixLine(
            v2: v2CallCount, v1: v1CallCount, unshaped: unshapedCallCount
        )

        if summary.isEmptyFeed {
            return CheckResult(
                id: id, title: title, status: "warn",
                detail: "UNMEASURED \(window.describedAs) — no turn-trace day files under"
                    + " data/turn_traces. Prefix-cache health has not been observed."
                    + " \(shapeLine)",
                repair: nil
            )
        }
        guard !v2FirstCalls.isEmpty else {
            return CheckResult(
                id: id, title: title, status: "warn",
                detail: "UNMEASURED \(window.describedAs) — \(summary.daysPresent.count)"
                    + " trace day(s) read and \(summary.matchedRows) row(s) in window, but not"
                    + " one llm.call carried shapeVersion=v2Prefix. Nothing about prefix reuse"
                    + " can be measured. \(shapeLine)",
                repair: v1CallCount > 0
                    ? "The v2 prefix shape appears to be rolled back. Clear the"
                        + " \(ConversationPrefixShape.defaultsKey) user default to return to"
                        + " the production default."
                    : nil
            )
        }

        // Attach the tool-array fingerprint each turn actually shipped.
        for (turnId, sha) in toolFingerprints where v2FirstCalls[turnId] != nil {
            v2FirstCalls[turnId]?.toolFingerprint = sha
        }

        // Sessions, each in turn order.
        var sessions: [String: [TurnObservation]] = [:]
        for observation in v2FirstCalls.values {
            sessions[observation.sessionId, default: []].append(observation)
        }
        for key in sessions.keys {
            sessions[key]?.sort { $0.at < $1.at }
        }

        var coldTurns: [String] = []
        var driftTurns: [String] = []
        var driftExplainedByTools = 0
        var creationBreaks: [(turnId: String, tokens: Int)] = []
        var unjudgedFirstCalls = 0
        var exemptSlid = 0
        var exemptToolChange = 0
        // (sessionId, calendar day) → violations, for the tolerance.
        var violationsPerSessionDay: [String: Int] = [:]
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone.current
        dayFormatter.dateFormat = "yyyy-MM-dd"

        var volatileSamples: [Int] = []

        for (sessionId, turns) in sessions {
            for (index, turn) in turns.enumerated() {
                if let chars = turn.volatileChars { volatileSamples.append(chars) }
                // The first turn of a session HAS no prefix to reuse.
                guard index > 0 else { continue }
                let previous = turns[index - 1]
                let toolsChanged: Bool = {
                    guard let now = turn.toolFingerprint, let before = previous.toolFingerprint
                    else { return false }
                    return now != before
                }()
                let bucket = "\(sessionId)|\(dayFormatter.string(from: turn.at))"
                var violated = false

                // (a) cross-turn cache read.
                if turn.windowSlid {
                    exemptSlid += 1
                } else if toolsChanged {
                    exemptToolChange += 1
                } else if let read = turn.cacheRead {
                    if read == 0 {
                        coldTurns.append(turn.turnId)
                        violated = true
                    }
                } else {
                    // No cacheReadInputTokens field at all: unjudged, NOT zero.
                    unjudgedFirstCalls += 1
                }

                // (b) prefix stability. The invariant is that this turn's
                // cacheable prefix EXTENDS the previous turn's: the previous
                // digest list is a prefix of this one. A whole-prefix hash
                // moves every turn by construction (the last exchange is
                // appended), so it is only consulted for rows written before
                // the digest receipt existed.
                let prefixMoved: Bool = {
                    if !turn.prefixDigests.isEmpty, !previous.prefixDigests.isEmpty {
                        return !turn.prefixDigests.starts(with: previous.prefixDigests)
                    }
                    guard let current = turn.fingerprint, let before = previous.fingerprint
                    else { return false }
                    return current != before
                }()
                if prefixMoved, !turn.windowSlid {
                    if toolsChanged {
                        // A structured lane that legitimately reshaped its tool
                        // array reshapes the prefix with it. Counted and named,
                        // never folded into the failure.
                        driftExplainedByTools += 1
                    } else {
                        driftTurns.append(turn.turnId)
                        violated = true
                    }
                }

                // (c) a non-first turn rebuilding the prefix.
                if let created = turn.cacheCreation, created > creationBreakTokens {
                    creationBreaks.append((turn.turnId, created))
                    violated = true
                }

                if violated { violationsPerSessionDay[bucket, default: 0] += 1 }
            }
        }

        let excess = violationsPerSessionDay.values.reduce(0) {
            $0 + max(0, $1 - toleratedPerSessionDay)
        }

        // (e) per-provider hit rate over the v2 rows only — mixing the v1 era
        // into this ratio would describe neither shape honestly.
        var providerLines: [String] = []
        var anthropicBelowFloor: [String] = []
        for (provider, tokens) in providerTokens.sorted(by: { $0.key < $1.key }) {
            guard let hit = tokens.hitPercent else {
                providerLines.append("\(provider)=no tokens reported")
                continue
            }
            providerLines.append(String(format: "%@=%.0f%%", provider, hit))
            if provider.lowercased().contains("anthropic"), hit < minimumAnthropicHitPercent {
                anthropicBelowFloor.append(String(format: "%@ (%.0f%%)", provider, hit))
            }
        }

        var parts: [String] = []
        parts.append(
            "\(window.describedAs): \(v2FirstCalls.count) v2Prefix turn(s) across"
                + " \(sessions.count) session(s) over \(summary.daysPresent.count) trace day(s)"
        )
        parts.append(
            coldTurns.isEmpty
                ? "0 cold non-first turns"
                : "\(coldTurns.count) non-first turn(s) read 0 cache tokens"
                    + " (\(nameTurns(coldTurns)))"
        )
        parts.append(
            driftTurns.isEmpty
                ? "prefix fingerprint stable across consecutive turns"
                : "\(driftTurns.count) unexplained prefix fingerprint change(s)"
                    + " (\(nameTurns(driftTurns)))"
        )
        if !creationBreaks.isEmpty {
            let named = creationBreaks
                .sorted { $0.tokens > $1.tokens }
                .prefix(maximumNamedTurns)
                .map { "\($0.turnId)=\($0.tokens)" }
                .joined(separator: ", ")
            let overflow = creationBreaks.count - min(maximumNamedTurns, creationBreaks.count)
            parts.append(
                "\(creationBreaks.count) non-first turn(s) created >\(creationBreakTokens)"
                    + " cache tokens (\(named)\(overflow > 0 ? ", +\(overflow) more" : ""))"
            )
        } else {
            parts.append("no non-first turn rebuilt the prefix")
        }
        parts.append(volatileLine(volatileSamples))
        parts.append(shapeLine)
        if !providerLines.isEmpty {
            parts.append(
                "cache hit% by provider over v2 rows: " + providerLines.joined(separator: ", ")
                    + " (the per-turn volatile block is uncached BY DESIGN, so 100% is not"
                    + " the target)"
                    + (v2FirstCalls.count < minimumHitRateTurns
                        ? " — below the \(minimumHitRateTurns)-turn floor, so the rate is"
                            + " MEASURED but NOT judged"
                        : "")
            )
        }
        if exemptSlid > 0 || exemptToolChange > 0 || driftExplainedByTools > 0 {
            parts.append(
                "exempt: \(exemptSlid) windowSlid, \(exemptToolChange) tool-array change,"
                    + " \(driftExplainedByTools) fingerprint change explained by a tool-array change"
            )
        }
        if unjudgedFirstCalls > 0 {
            parts.append(
                "\(unjudgedFirstCalls) non-first turn(s) reported no cacheReadInputTokens at all"
                    + " and were UNJUDGED rather than counted as zero"
            )
        }
        if !summary.truncatedDays.isEmpty {
            parts.append(
                "\(summary.truncatedDays.count) day file(s) were tailed to the read budget"
                    + " (\(summary.truncatedDays.joined(separator: ", "))), so earlier turns"
                    + " that day were not scanned"
            )
        }
        if summary.malformedLines > 0 {
            parts.append("\(summary.malformedLines) trace line(s) did not parse")
        }

        var status = "ok"
        var repair: String? = nil
        if excess > 0 {
            status = "fail"
            parts.append(
                "\(excess) violation(s) above the tolerance of \(toleratedPerSessionDay)"
                    + " per session per day"
            )
            repair = "The v2 prefix is not being reused. Check that the identity block is still"
                + " a strict prefix of the stable block and that only one cache breakpoint sits"
                + " at the end of the stable mass (ConversationPrefixShape.v2Prefix)."
        } else if !anthropicBelowFloor.isEmpty, v2FirstCalls.count >= minimumHitRateTurns {
            status = "warn"
            parts.append(
                "Anthropic lane(s) below the \(Int(minimumAnthropicHitPercent))% floor:"
                    + " \(anthropicBelowFloor.joined(separator: ", "))"
            )
            repair = "Low read share on an Anthropic lane means the cached prefix is being"
                + " rebuilt more often than it is read. Compare volatileBlockChars against the"
                + " stable mass for the affected sessions."
        } else if !summary.truncatedDays.isEmpty || unjudgedFirstCalls > 0 {
            // Not a defect, but not a clean bill of health either: part of the
            // window went unread.
            status = "warn"
        }

        return CheckResult(
            id: id, title: title, status: status,
            detail: parts.joined(separator: "; ") + ".",
            repair: repair
        )
    }

    // MARK: - Helpers

    private func nameTurns(_ turns: [String]) -> String {
        let named = turns.prefix(maximumNamedTurns).joined(separator: ", ")
        let overflow = turns.count - min(maximumNamedTurns, turns.count)
        return named + (overflow > 0 ? ", +\(overflow) more" : "")
    }

    /// (d) The kill switch, said out loud, so a silent rollback is visible in
    /// the row instead of only in a user default nobody inspects.
    private func shapeMixLine(v2: Int, v1: Int, unshaped: Int) -> String {
        let raw = killSwitchRaw()
        let parsed = ConversationPrefixShape.parse(raw)
        let switchState: String
        switch (raw, parsed) {
        case (let raw?, let parsed?) where !raw.isEmpty:
            switchState = "\(ConversationPrefixShape.defaultsKey)=\(parsed.rawValue) (set by hand)"
        case (let raw?, nil) where !raw.isEmpty:
            switchState = "\(ConversationPrefixShape.defaultsKey)=\"\(raw)\" (UNPARSEABLE — the"
                + " runtime ignores it and uses the v2Prefix default)"
        default:
            switchState = "\(ConversationPrefixShape.defaultsKey) unset → v2Prefix default"
        }
        return "shape mix over the window: v2Prefix=\(v2) call(s), v1Legacy=\(v1),"
            + " no shapeVersion field=\(unshaped); \(switchState)"
    }

    /// (c) volatile block size distribution. Percentiles, not a mean — one
    /// enormous turn should not move the number the operator reads.
    private func volatileLine(_ samples: [Int]) -> String {
        guard !samples.isEmpty else {
            return "volatileBlockChars UNMEASURED (no v2 turn reported the field)"
        }
        let sorted = samples.sorted()
        func percentile(_ p: Double) -> Int {
            let index = Int((Double(sorted.count - 1) * p).rounded())
            return sorted[max(0, min(sorted.count - 1, index))]
        }
        return "volatileBlockChars p50=\(percentile(0.5)) p95=\(percentile(0.95))"
            + " over \(sorted.count) sample(s)"
    }
}
