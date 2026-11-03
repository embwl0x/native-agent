import Foundation
import CoreFoundation
import NativeAgentShared
import Experiences
import NativeAgentCore
import PersistenceCore
import TurnTrace
import Transcripts
import ProviderRouting
// Blueprint: | `ChatCompactionPolicy.swift` | Compaction policy, outcome and honest transcript errors |
public struct ChatSessionAutocompactionConfig: Sendable, Equatable {
    /// Settings › Context window › Custom size (N tokens).
    public static let defaultsKey = "nativeagent.contextWindowTokens"
    /// Settings › Context window mode: "model" or "custom".
    public static let contextWindowModeKey = "nativeagent.contextWindowMode"
    public static let agingEnabledKey = "nativeagent.compactionAgingEnabled"
    public static let defaultThresholdTokens = 200_000
    public static let compactionPercentKey = "nativeagent.contextWindowCompactionPercent"
    public static let defaultCompactionPercent = 85
    public static let compactionPercentRange = 30...95
    public let compactionPercent: Int
    public var compactionTriggerFraction: Double { Double(compactionPercent) / 100 }
    /// Configured input target, before reserving the request's actual output.
    public var rawHistoryTargetFraction: Double { compactionTriggerFraction * (55.0 / 85.0) }
    public func triggerTokens(in window: Int, outputTokens: Int) -> Int {
        min(Int(Double(window) * compactionTriggerFraction), max(0, window - outputTokens))
    }
    public func targetTokens(in window: Int, outputTokens: Int) -> Int {
        min(Int(Double(window) * rawHistoryTargetFraction), max(0, window - outputTokens))
    }
    /// The model's detected window, optionally limited by the person's cap.
    public enum ContextWindowMode: String, Sendable {
        case modelDefault = "model"
        case custom
    }
    public var thresholdTokens: Int
    public var contextWindowMode: ContextWindowMode
    public var configurationFailure: String?
    /// The continuous lane. When true, the append that crosses the aging
    /// boundary schedules a background distillation of the session's older
    /// turns. Off → the pre-turn threshold is the only lane, exactly as before.
    public var agingEnabled: Bool
    public init(
        thresholdTokens: Int = Self.defaultThresholdTokens,
        agingEnabled: Bool = true,
        contextWindowMode: ContextWindowMode = .custom,
        configurationFailure: String? = nil,
        compactionPercent: Int = Self.defaultCompactionPercent
    ) {
        self.thresholdTokens = max(1, thresholdTokens)
        self.contextWindowMode = contextWindowMode
        self.agingEnabled = agingEnabled
        self.compactionPercent = compactionPercent
        self.configurationFailure = configurationFailure ?? (Self.compactionPercentRange.contains(compactionPercent)
            ? nil : "Compact at must be a whole percentage from 30–95% in Settings > Context window.")
    }
    /// Reads the app preference at the production boundary.  The defaults
    /// instance is injectable solely so callers can exercise the same reader
    /// against an isolated persistent domain; production still uses `.standard`.
    public static func productionDefault(
        defaults: UserDefaults = .standard
    ) -> ChatSessionAutocompactionConfig {
        let rawSize = defaults.object(forKey: defaultsKey)
        let stored = defaults.integer(forKey: defaultsKey)
        let rawMode = defaults.object(forKey: contextWindowModeKey)
        let selectedMode = defaults.string(forKey: contextWindowModeKey).flatMap(ContextWindowMode.init(rawValue:))
        let rawPercent = defaults.object(forKey: compactionPercentKey)
        let percent = rawPercent == nil ? defaultCompactionPercent : defaults.integer(forKey: compactionPercentKey)
        let failure: String?
        if let rawSize, !(rawSize is NSNumber) || stored <= 0
            || (rawSize as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() || $0.doubleValue != Double(stored) }) == true {
            failure = "The saved custom context window is invalid. Choose a positive size in Settings > Context window."
        } else if rawMode != nil, selectedMode == nil {
            failure = "The saved context window mode is invalid. Choose Model default or Custom in Settings > Context window."
        } else if let rawPercent, !(rawPercent is NSNumber) || !compactionPercentRange.contains(percent)
            || (rawPercent as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() || $0.doubleValue != Double(percent) }) == true {
            failure = "The saved Compact at percentage is invalid. Choose a whole percentage from 30–95% in Settings > Context window."
        } else { failure = nil }
        // Absent key → aging on by default; explicit false → off (the pre-turn
        // threshold then behaves exactly as it did before the aging lane).
        let aging = defaults.object(forKey: agingEnabledKey) == nil
            ? true
            : defaults.bool(forKey: agingEnabledKey)
        let mode = selectedMode ?? .modelDefault
        return ChatSessionAutocompactionConfig(
            thresholdTokens: stored > 0 ? stored : defaultThresholdTokens,
            agingEnabled: aging,
            contextWindowMode: mode,
            configurationFailure: failure,
            compactionPercent: percent
        )
    }
    /// The selected model's own window, capped by Custom; nil when unknown.
    public func effectiveWindowTokens(nativeWindowTokens: Int?) -> Int? {
        guard configurationFailure == nil else { return nil }
        guard let native = nativeWindowTokens, native > 0 else { return nil }
        return contextWindowMode == .custom ? min(thresholdTokens, native) : native
    }
    public func effectiveWindowTokens(
        forModel model: String,
        providerID: String? = nil,
        dataRoot: URL? = nil
    ) -> Int? {
        effectiveWindowTokens(nativeWindowTokens: ProviderRouting.verifiedContextLength(
            forModel: model,
            providerID: providerID,
            dataRoot: dataRoot
        ))
    }
    public func contextWindowReadout(forModel model: String, providerID: String?, dataRoot: URL) async throws -> [String: JSONValue] {
        let native = ProviderRouting.verifiedContextLength(forModel: model, providerID: providerID, dataRoot: dataRoot)
        let effective = effectiveWindowTokens(nativeWindowTokens: native)
        let output = try await SessionContextMeasurement.outputAllowance(model: model, providerID: providerID, dataRoot: dataRoot)
        let custom = contextWindowMode == .custom ? thresholdTokens : nil
        return [
            "configuration_failure": configurationFailure.map(JSONValue.string) ?? .null,
            "model": .string(model),
            "effective_tokens": effective.map { .int(Int64($0)) } ?? .null,
            "native_window_tokens": native.map { .int(Int64($0)) } ?? .null,
            "custom_cap_tokens": custom.map { .int(Int64($0)) } ?? .null,
            "native_window_source": .string("ProviderRouting verified model catalog for the selected provider/model"),
            "effective_window_owner": .string("Settings > Context window (ChatSessionAutocompactionConfig)"),
            "request_output_allowance_tokens": .int(Int64(output)),
            "compaction_percent": .int(Int64(compactionPercent)),
            "compaction_trigger_tokens": effective.map { .int(Int64(triggerTokens(in: $0, outputTokens: output))) } ?? .null,
            "compaction_target_tokens": effective.map { .int(Int64(targetTokens(in: $0, outputTokens: output))) } ?? .null,
            "compaction_trigger_fraction": effective.map { .double(Double(triggerTokens(in: $0, outputTokens: output)) / Double($0)) } ?? .null,
            "target_fraction": effective.map { .double(Double(targetTokens(in: $0, outputTokens: output)) / Double($0)) } ?? .null,
            "meaning": .string("Settings > Context window > Compact at governs every model: default 85%, accepted range 30–95%. effective_tokens is the detected window limited by Custom. Trigger is min(configured percent × window, window − request output allowance); target is min(configured percent × window × 55/85, window − request output allowance). The adapter owns that allowance, including any remaining turn cap; zero means no output-cap field is sent. Aging uses the same trigger. Usage is the actual request builder's final character count calibrated by the last matching provider request's characters/input tokens, with no stored-row subtraction; without a matching receipt it is a rendered-history estimate. Automatic aging waits for built-request evidence."),
            "summary": .string(configurationFailure ?? "Context window for \(model): effective \(effective.map(String.init) ?? "unknown") tokens; native \(native.map(String.init) ?? "unknown") tokens; Custom cap \(custom.map(String.init) ?? "none"). Compact at \(compactionPercent)% configured, output allowance \(output) tokens, effective trigger \(effective.map { String(triggerTokens(in: $0, outputTokens: output)) } ?? "unknown") tokens, target \(effective.map { String(targetTokens(in: $0, outputTokens: output)) } ?? "unknown") tokens."),
        ]
    }
    /// Compaction needs the admitted model's actual effective window.
    public func effectiveThresholdTokens(
        forModel model: String,
        providerID: String? = nil,
        dataRoot: URL? = nil
    ) async throws -> Int {
        if let configurationFailure { throw ProviderRoutingError.configurationFailed(configurationFailure) }
        guard let tokens = effectiveWindowTokens(forModel: model, providerID: providerID, dataRoot: dataRoot) else {
            throw ProviderRoutingError.configurationFailed("The selected model's context window is unavailable. Refresh its catalog in Providers before compacting this conversation.")
        }
        let output = try await SessionContextMeasurement.outputAllowance(model: model, providerID: providerID, dataRoot: dataRoot ?? PersistenceCore.defaultDataRoot())
        return triggerTokens(in: tokens, outputTokens: output)
    }
}
public struct ChatSessionCompactionOutcome: Sendable, Equatable {
    public let sessionId: String
    public let compacted: Bool
    public let reason: String
    public let trigger: String
    public let thresholdTokens: Int
    public let estimatedTokensBefore: Int
    public let transcriptCharsBefore: Int
    public let messagesBefore: Int
    public let messagesAfter: Int
    public let messagesReplaced: Int
    public let summaryChars: Int
    public let sourceBytesBefore: Int64
    public let sourceBytesAfter: Int64
    /// Pending recollection for the caller to distill from its verified backup.
    public let summaryRowId: String?
    /// Filesystem path of the verified pre-compaction backup, present
    /// under the same condition as `summaryRowId`.
    public let backupPath: String?
    /// Selected source for the pending recollection, excluding retained rows.
    public let recollectionSource: [JSONValue]
    /// The transcript's bytes as this pass left them, when it read them under
    /// the lock: the turn's history selects from these instead of reading the
    /// file a second time. nil when the pass never read the transcript.
    public internal(set) var transcript: Data?
    /// WHICH lane consolidated this session, derived from the trigger so the
    /// receipt never has to be guessed at from a timestamp. `aging` is the
    /// continuous background lane; `backstop` is the pre-turn threshold that
    /// should now be rare; `manual` is an explicit user request.
    /// (NORTHSTAR clause 2 — a receipt records what actually ran.)
    public var lane: String { Self.lane(forTrigger: trigger) }
    public static func lane(forTrigger trigger: String) -> String {
        if trigger.hasPrefix("aging") { return "aging" }
        if trigger.hasPrefix("manual") { return "manual" }
        return "backstop"
    }
    public init(
        sessionId: String,
        compacted: Bool,
        reason: String,
        trigger: String,
        thresholdTokens: Int,
        estimatedTokensBefore: Int,
        transcriptCharsBefore: Int,
        messagesBefore: Int,
        messagesAfter: Int,
        messagesReplaced: Int,
        summaryChars: Int,
        sourceBytesBefore: Int64,
        sourceBytesAfter: Int64,
        summaryRowId: String? = nil,
        backupPath: String? = nil,
        recollectionSource: [JSONValue] = []
    ) {
        self.sessionId = sessionId
        self.compacted = compacted
        self.reason = reason
        self.trigger = trigger
        self.thresholdTokens = thresholdTokens
        self.estimatedTokensBefore = estimatedTokensBefore
        self.transcriptCharsBefore = transcriptCharsBefore
        self.messagesBefore = messagesBefore
        self.messagesAfter = messagesAfter
        self.messagesReplaced = messagesReplaced
        self.summaryChars = summaryChars
        self.sourceBytesBefore = sourceBytesBefore
        self.sourceBytesAfter = sourceBytesAfter
        self.summaryRowId = summaryRowId
        self.backupPath = backupPath
        self.recollectionSource = recollectionSource
    }
    public func carrying(_ transcript: Data) -> Self {
        var copy = self
        copy.transcript = transcript
        return copy
    }
    public func followed(by next: Self) -> Self {
        var result = Self(sessionId: sessionId, compacted: compacted || next.compacted,
            reason: reason, trigger: trigger, thresholdTokens: thresholdTokens,
            estimatedTokensBefore: estimatedTokensBefore, transcriptCharsBefore: transcriptCharsBefore,
            messagesBefore: messagesBefore, messagesAfter: next.messagesAfter,
            messagesReplaced: messagesReplaced + next.messagesReplaced, summaryChars: summaryChars + next.summaryChars,
            sourceBytesBefore: sourceBytesBefore, sourceBytesAfter: next.sourceBytesAfter,
            summaryRowId: next.summaryRowId, backupPath: next.backupPath, recollectionSource: next.recollectionSource)
        result.transcript = next.transcript
        return result
    }
    public func finished(with readout: Self) -> Self {
        var result = Self(sessionId: sessionId, compacted: compacted,
            reason: reason, trigger: trigger, thresholdTokens: thresholdTokens,
            estimatedTokensBefore: estimatedTokensBefore, transcriptCharsBefore: transcriptCharsBefore,
            messagesBefore: messagesBefore, messagesAfter: readout.messagesAfter,
            messagesReplaced: messagesReplaced, summaryChars: summaryChars,
            sourceBytesBefore: sourceBytesBefore, sourceBytesAfter: readout.sourceBytesAfter)
        result.transcript = readout.transcript
        return result
    }
}
struct ChatSessionCompactionTranscriptError: LocalizedError, Sendable {
    let errorDescription: String?
}
