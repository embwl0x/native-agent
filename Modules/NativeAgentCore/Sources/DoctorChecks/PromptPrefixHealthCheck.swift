import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import TurnTrace

// Blueprint: | `PromptPrefixHealthCheck.swift` | `PromptPrefixHealthCheck`: measured prefix/cache health from turn and provider evidence |

// MARK: - Prompt prefix health (Runtime)
// Stable system material precedes a transcript whose cursor moves only at 1.15/0.70 hysteresis; changing context follows. Anthropic breakpoints and OpenAI
// routing use this layout, but provider limits still govern cache hits. Silent cache misses cost full input reads, so measure from bounded traces only during
// explicit Doctor runs. Start at this build's launch: older turns cannot describe the running build. Failed reads fail; no eligible turns stay unmeasured.
// Name the window and uncached block to avoid misleading hit rates.

public struct PromptPrefixHealthCheck: DoctorCheck {
    public let id: String = "prompt_prefix_health"
    public let title: String = "Prompt Prefix Cache"
    /// Measurement-window verdicts stay Doctor-only and never trigger unattended pushes.
    public let heartbeatEligible: Bool = false

    private let root: URL
    private let cache: DoctorScanCache

    private let maximumNamedTurns = 5
    /// Allow one violation per session/day for model swaps, provider eviction or clock skew; repeated violations signal drift.
    private let toleratedPerSessionDay = 1
    private let minimumAnthropicHitPercent = 50.0
    /// Grade rates only with enough turns; show small-sample percentages without a health verdict. Deterministic per-turn violations still count against
    /// tolerance even with a small sample.
    private let minimumHitRateTurns = 10
    // Headroom above the provider's 1,024-token caching minimum.
    private let minimumCacheInputTokens = 2_048
    /// Stable-block cache entries expire after the longest breakpoint TTL of one hour.
    private let cacheTTLSeconds: TimeInterval = 3_600

    public init(
        root: URL = defaultDataRoot(),
        cacheTTL: TimeInterval = 60
    ) {
        self.root = root
        self.cache = DoctorScanCache(ttl: cacheTTL)
    }

    // MARK: - Turn model

    /// Only the first llm.call measures cross-turn reuse; later tool-loop calls would flatter the number.
    private struct TurnObservation {
        var sessionId: String
        var turnId: String
        var at: Date
        var cacheRead: Int?
        var cacheCreation: Int?
        var historyContextWindow: String?
        var fingerprint: String?
        /// One digest per cacheable-prefix message. Missing evidence is ungraded.
        var prefixDigests: [String] = []
        var volatileChars: Int?
        var toolFingerprint: String?
        var stableFingerprint: String?
        var provider: String = "unknown"
        var inputTokens: Int = 0
        var additiveInputCounters: Bool = false
    }

    private static func stringArray(_ value: JSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap { item -> String? in
            if case .string(let s) = item { return s }
            return nil
        }
    }

    private struct ProviderTokens {
        var read: Int?
        var total = 0

        var hitPercent: Double? {
            guard let read, total > 0 else { return nil }
            return Double(read) / Double(total) * 100
        }
    }

    public func run() async -> CheckResult {
        let moment = Date()
        if let memo = await cache.fresh(now: moment) { return memo }
        let result = await measure()
        await cache.store(result, at: moment)
        return result
    }

    // MARK: - Measurement

    private func measure() async -> CheckResult {
        var v2FirstCalls: [String: TurnObservation] = [:]
        var callsByTurn: [String: [TurnObservation]] = [:]
        var toolFingerprints: [String: String] = [:]
        var providerTokens: [String: ProviderTokens] = [:]
        var v2CallCount = 0
        var unshapedCallCount = 0
        var ignoredSurfaces = 0
        var ignoredSmallCalls = 0

        let moment = Date()
        guard let window = DoctorWindowFloor.resolve(root: root, now: moment) else {
            return CheckResult(source: root.appendingPathComponent(NativeAgentBuildIdentity.launchStampFilename).path,
                id: id, title: title, status: "unmeasured",
                detail: """
                    This launch's build stamp is unavailable or invalid. Repair build_launch.json through the app launch owner before measuring \
                    this build.
                    """)
        }
        let summary: TurnTraceScanSummary
        do {
            summary = try await TurnTraceWindowReader.scan(
                root: root,
                now: moment,
                floor: window.floor,
                kinds: ["llm.call", "context.snapshot"]
            ) { row in
                let payload = row.payload.objectValue ?? [:]
                switch row.kind {
                case "context.snapshot":
                    if let sha = payload["toolSchemaFingerprintSHA256"]?.stringValue,
                       !row.turnId.isEmpty {
                        toolFingerprints[row.turnId] = sha
                    }
                case "llm.call":
                    // Payload names the actual call; the envelope may name a hosting helper's chat turn.
                    let surface = payload["surface"]?.stringValue ?? row.surface
                    guard surface == "chat" else {
                        ignoredSurfaces += 1
                        return
                    }
                    let provider = payload["provider"]?.stringValue ?? "unknown"
                    let additive = LLMUsage.persistedAdditiveInputCounters(payload["additiveInputCounters"], provider: provider)
                    let usage = LLMUsage(
                        inputTokens: payload["inputTokens"]?.intValue,
                        cacheReadInputTokens: payload["cacheReadInputTokens"]?.intValue,
                        cacheCreationInputTokens: payload["cacheCreationInputTokens"]?.intValue,
                        additiveInputCounters: additive
                    )
                    if let input = usage.logicalInputTokens(provider: provider),
                       input < minimumCacheInputTokens {
                        ignoredSmallCalls += 1
                        return
                    }
                    let shape = payload["shapeVersion"]?.stringValue
                    switch shape {
                    case "v2Prefix":
                        v2CallCount += 1
                    default:
                        // Automatic caching needs usage counters; it cannot supply Anthropic shape receipts.
                        unshapedCallCount += 1
                        if provider.lowercased().contains("anthropic") { return }
                    }

                    guard !row.turnId.isEmpty else { return }
                    let observation = TurnObservation(
                        sessionId: row.sessionId ?? "unknown",
                        turnId: row.turnId,
                        at: row.ts,
                        cacheRead: payload["cacheReadInputTokens"]?.intValue,
                        cacheCreation: payload["cacheCreationInputTokens"]?.intValue,
                        historyContextWindow: payload["historyContextWindow"]?.stringValue,
                        fingerprint: payload["prefixFingerprintSHA256"]?.stringValue,
                        prefixDigests: Self.stringArray(payload["prefixMessageDigests"]),
                        volatileChars: payload["volatileBlockChars"]?.intValue,
                        toolFingerprint: payload["component.toolsSHA256"]?.stringValue,
                        stableFingerprint: payload["component.stablePrefixSHA256"]?.stringValue,
                        provider: provider,
                        inputTokens: payload["inputTokens"]?.intValue ?? 0,
                        additiveInputCounters: additive
                    )
                    callsByTurn[row.turnId, default: []].append(observation)
                    if let existing = v2FirstCalls[row.turnId], existing.at <= observation.at { return }
                    v2FirstCalls[row.turnId] = observation
                default:
                    return
                }
            }
        } catch {
            return CheckResult(source: TurnTraceWindowReader.source,
                id: id, title: title, status: "fail",
                detail: "The experience record could not be read, so prefix-cache health is unmeasured \(window.describedAs): \(error).",
                harm: "Prefix reuse problems cannot be diagnosed from the saved turns.")
        }

        let coverageDetail = summary.coverageDetail

        let shapeLine = shapeMixLine(
            v2: v2CallCount, unshaped: unshapedCallCount
        ) + "; ignored \(ignoredSurfaces) calls outside chat and \(ignoredSmallCalls) chat calls"
            + " below \(minimumCacheInputTokens) input tokens (too small to judge cache reuse)"

        if summary.isEmptyFeed {
            return CheckResult(source: TurnTraceWindowReader.source,
                id: id, title: title, status: "unmeasured",
                detail: "UNMEASURED \(window.describedAs) — no matching trace details were recorded,"
                    + " so prefix-cache health has not been observed; \(shapeLine)\(coverageDetail).",
                repair: nil
            )
        }
        guard !v2FirstCalls.isEmpty else {
            return CheckResult(source: TurnTraceWindowReader.source,
                id: id, title: title, status: "unmeasured",
                detail: "UNMEASURED \(window.describedAs) — \(summary.eventsRead) event(s) read in window, but not"
                    + " one eligible chat call used the current prompt format, so prefix reuse cannot be measured; \(shapeLine)\(coverageDetail).",
                repair: nil
            )
        }

        for (turnId, sha) in toolFingerprints where v2FirstCalls[turnId]?.toolFingerprint == nil {
            v2FirstCalls[turnId]?.toolFingerprint = sha
        }

        // Compare adjacent requests: an unchanged miss cannot be explained by an earlier tool load.
        var explainedMidTurnMisses = 0
        for calls in callsByTurn.values {
            let ordered = calls.sorted { $0.at < $1.at }
            for (index, call) in ordered.enumerated() {
                let changed: Bool
                if index > 0 {
                    let previous = ordered[index - 1]
                    func differs(_ current: String?, _ before: String?) -> Bool {
                        guard let current, !current.isEmpty, let before, !before.isEmpty else { return false }
                        return current != before
                    }
                    changed = differs(call.toolFingerprint, previous.toolFingerprint)
                        || differs(call.stableFingerprint, previous.stableFingerprint)
                } else {
                    changed = false
                }
                if changed, call.cacheRead == 0 {
                    explainedMidTurnMisses += 1
                    continue
                }
                var tokens = providerTokens[call.provider] ?? ProviderTokens()
                let logical = LLMUsage(inputTokens: call.inputTokens,
                    cacheReadInputTokens: call.cacheRead,
                    cacheCreationInputTokens: call.cacheCreation,
                    additiveInputCounters: call.additiveInputCounters).logicalInputTokens(provider: call.provider) ?? 0
                let total = tokens.total.addingReportingOverflow(logical)
                let read = (tokens.read ?? 0).addingReportingOverflow(call.cacheRead ?? 0)
                guard !total.overflow, !read.overflow else {
                    return CheckResult(source: TurnTraceWindowReader.source, id: id, title: title, status: "fail",
                        detail: """
                            UNMEASURED \(window.describedAs) — provider \(call.provider) token totals exceed the supported integer range at turn \
                            \(call.turnId), session \(call.sessionId), timestamp \(call.at). Inspect the retained llm.call usage receipts.
                            """)
                }
                tokens.total = total.partialValue
                if call.cacheRead != nil { tokens.read = read.partialValue }
                providerTokens[call.provider] = tokens
            }
        }

        var sessions: [String: [TurnObservation]] = [:]
        for observation in v2FirstCalls.values {
            sessions[observation.provider + "|" + observation.sessionId, default: []].append(observation)
        }
        for key in sessions.keys {
            sessions[key]?.sort { $0.at < $1.at }
        }

        var coldTurns: [String] = []
        var driftTurns: [String] = []
        var driftExplainedByTools = 0
        var creationBreaks: [(turnId: String, tokens: Int)] = []
        var unjudgedFirstCalls = 0
        var unmeasuredPrefixPairs = 0
        var exemptSlid = 0
        var exemptToolChange = 0
        // Cache expiry and changed stable blocks exempt rebuilt turns from drift.
        var exemptExpired = 0
        var exemptStableChange = 0
        var violationsPerSessionDay: [String: Int] = [:]

        var volatileSamples: [Int] = []

        for (sessionId, turns) in sessions {
            for (index, turn) in turns.enumerated() {
                if let chars = turn.volatileChars { volatileSamples.append(chars) }
                // The first turn of a session HAS no prefix to reuse.
                guard index > 0 else { continue }
                if turn.cacheRead == nil { unjudgedFirstCalls += 1 }
                // Automatic prefix caching promises neither a hit on each turn nor a creation receipt.
                guard turn.provider.lowercased().contains("anthropic") else { continue }
                let previous = turns[index - 1]
                let recollectionChanged = turn.historyContextWindow != nil
                    && previous.historyContextWindow != nil
                    && turn.historyContextWindow != previous.historyContextWindow
                let toolsChanged: Bool = {
                    guard let now = turn.toolFingerprint, let before = previous.toolFingerprint
                    else { return false }
                    return now != before
                }()
                let bucket = "\(sessionId)|\(TurnTracePersistLane.dayString(from: turn.at))"
                var violated = false
                // This turn can reuse the preceding turn's last request, not its first.
                let previousLast = (callsByTurn[previous.turnId] ?? [previous]).max { $0.at < $1.at } ?? previous
                // Creation alone can be growth; rebuilding requires reading below the previous request's cached share.
                let cachedBefore = (previousLast.cacheRead ?? 0) + (previousLast.cacheCreation ?? 0)
                let rebuilt = turn.cacheRead.map { $0 == 0 || Double($0) * 100 < Double(cachedBefore) * minimumAnthropicHitPercent } ?? false
                // The longest breakpoint TTL is 1h; past it nothing is left to read.
                if rebuilt, turn.at.timeIntervalSince(previousLast.at) > cacheTTLSeconds {
                    exemptExpired += 1
                    continue
                }
                if rebuilt, let now = turn.stableFingerprint, let before = previousLast.stableFingerprint, now != before {
                    exemptStableChange += 1
                    continue
                }

                if recollectionChanged {
                    exemptSlid += 1
                } else if toolsChanged {
                    exemptToolChange += 1
                } else if let read = turn.cacheRead {
                    if read == 0 {
                        coldTurns.append(turn.turnId)
                        violated = true
                    }
                }

                // The current cacheable prefix must extend the previous digest list; missing receipts cannot prove movement.
                let prefixMoved: Bool? = {
                    if !turn.prefixDigests.isEmpty, !previous.prefixDigests.isEmpty {
                        return !turn.prefixDigests.starts(with: previous.prefixDigests)
                    }
                    return nil
                }()
                if prefixMoved == nil { unmeasuredPrefixPairs += 1 }
                if prefixMoved == true, !recollectionChanged {
                    if toolsChanged {
                        // Legitimate tool-array changes reshape the prefix; name them separately instead of counting failure.
                        driftExplainedByTools += 1
                    } else {
                        driftTurns.append(turn.turnId)
                        violated = true
                    }
                }

                if rebuilt, turn.cacheRead != 0, !recollectionChanged, !toolsChanged {
                    creationBreaks.append((turn.turnId, cachedBefore - (turn.cacheRead ?? 0)))
                    violated = true
                }

                if violated { violationsPerSessionDay[bucket, default: 0] += 1 }
            }
        }

        let excess = violationsPerSessionDay.values.reduce(0) {
            $0 + max(0, $1 - toleratedPerSessionDay)
        }

        var providerLines: [String] = []
        var anthropicBelowFloor: [String] = []
        for (provider, tokens) in providerTokens.sorted(by: { $0.key < $1.key }) {
            guard let hit = tokens.hitPercent else {
                providerLines.append("\(provider)=cache usage unreported")
                continue
            }
            providerLines.append(String(format: "%@=%.1f%%", provider, hit))
            let turns = v2FirstCalls.values.filter { $0.provider == provider }.count
            if provider.lowercased().contains("anthropic"), turns >= minimumHitRateTurns, hit < minimumAnthropicHitPercent {
                anthropicBelowFloor.append(String(format: "%@ (%.0f%%)", provider, hit))
            }
        }

        var parts: [String] = []
        parts.append(
            "\(window.describedAs): \(v2FirstCalls.count) eligible chat turn(s) across"
                + " \(sessions.count) session(s) over \(summary.observedDays) day(s) with matching events"
        )
        parts.append(summary.windowCovered)
        parts.append(
            coldTurns.isEmpty
                ? "0 cold non-first Anthropic turns"
                : "\(coldTurns.count) non-first Anthropic turn(s) read 0 cache tokens"
                    + " (\(nameTurns(coldTurns)))"
        )
        parts.append(
            driftTurns.isEmpty
                ? "no unexplained Anthropic prefix changes among measured receipt pairs"
                : "\(driftTurns.count) unexplained prefix receipt change(s)"
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
                "\(creationBreaks.count) non-first turn(s) read under \(Int(minimumAnthropicHitPercent))% of the prefix"
                    + " the previous request cached (not reused: \(named)\(overflow > 0 ? ", +\(overflow) more" : ""))"
            )
        } else {
            parts.append("no non-first Anthropic turn rebuilt the prefix")
        }
        parts.append(volatileLine(volatileSamples))
        parts.append(shapeLine)
        parts.append("\(explainedMidTurnMisses) mid-turn cache misses explained by changed tools or stable instructions (excluded from the cache reuse rate)")
        if !providerLines.isEmpty {
            parts.append(
                "cache hit% by provider over eligible rows: " + providerLines.joined(separator: ", ")
                    + " (OpenAI: cached/input, automatic prefix caching; Anthropic: read/(uncached+read+created), explicit breakpoints; 100% is not the target)"
                    + (v2FirstCalls.count < minimumHitRateTurns
                        ? " — below the \(minimumHitRateTurns)-turn floor, so the rate is"
                            + " MEASURED but NOT judged"
                        : "")
            )
        }
        if exemptSlid > 0 || exemptToolChange > 0 || driftExplainedByTools > 0 || exemptExpired > 0 || exemptStableChange > 0 {
            parts.append(
                "exempt: \(exemptSlid) recollection change, \(exemptToolChange) tool-array change,"
                    + " \(driftExplainedByTools) fingerprint change explained by a tool-array change,"
                    + " \(exemptExpired) after the 1h cache expired, \(exemptStableChange) after a changed stable system block"
            )
        }
        if unjudgedFirstCalls > 0 {
            parts.append(
                "\(unjudgedFirstCalls) non-first turn(s) reported no cacheReadInputTokens at all"
                    + " and were UNJUDGED rather than counted as zero"
            )
        }
        if unmeasuredPrefixPairs > 0 {
            parts.append("\(unmeasuredPrefixPairs) Anthropic turn pair(s) lack prefix digest receipts; prefix stability is unmeasured for those pairs")
        }
        parts.append(contentsOf: summary.coverageParts)

        var status = "ok"
        var humanAction: String? = nil
        if excess > 0 {
            status = "fail"
            parts.append(
                "\(excess) violation(s) above the tolerance of \(toleratedPerSessionDay)"
                    + " per session per day"
            )
            humanAction = """
                Correct NativeAgent's prompt assembly so the identity block remains a strict prefix of the stable block and one cache \
                breakpoint sits at the end of the stable mass (v2Prefix).
                """
        } else if !anthropicBelowFloor.isEmpty {
            status = "warn"
            parts.append(
                "Anthropic lane(s) below the \(Int(minimumAnthropicHitPercent))% floor:"
                    + " \(anthropicBelowFloor.joined(separator: ", "))"
            )
            humanAction = """
                Review NativeAgent's prompt assembly using volatileBlockChars and the stable mass for the affected Anthropic sessions to \
                correct repeated prefix rebuilds.
                """
        } else if !summary.coverageParts.isEmpty || unjudgedFirstCalls > 0 || unmeasuredPrefixPairs > 0 {
            // Incomplete coverage or missing metrics cannot certify health.
            status = "unmeasured"
        }

        return CheckResult(source: TurnTraceWindowReader.source,
            id: id, title: title, status: status,
            detail: parts.joined(separator: "; ") + ".",
            harm: DoctorSafeRepairPolicy.isAdverse(status) ? "Repeated prompt processing uses extra provider time and tokens." : nil,
            human_action: humanAction,
            // A measured miss is the prompt assembly's: the build fixes it.
            owner: DoctorSafeRepairPolicy.isAdverse(status) ? .builder : nil
        )
    }

    // MARK: - Helpers

    private func nameTurns(_ turns: [String]) -> String {
        let named = turns.prefix(maximumNamedTurns).joined(separator: ", ")
        let overflow = turns.count - min(maximumNamedTurns, turns.count)
        return named + (overflow > 0 ? ", +\(overflow) more" : "")
    }

    private func shapeMixLine(v2: Int, unshaped: Int) -> String {
        return "shape mix over the window: v2Prefix=\(v2) call(s),"
            + " no shapeVersion field=\(unshaped)"
    }

    /// Use percentiles so one enormous turn cannot distort the displayed volatile-block size.
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
