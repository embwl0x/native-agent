import Foundation
import NativeAgentShared
import Experiences
import NativeAgentCore
import PersistenceCore
import TurnTrace
import Transcripts
import ProviderRouting
// Blueprint: | `ChatCompactionPolicy.swift` | Compaction policy, outcome and honest transcript errors |
public struct ChatSessionAutocompactionConfig: Sendable, Equatable {
    /// Settings › Context window › Custom size (N tokens). The key keeps its
    /// old name so a size saved as the compaction threshold carries over.
    public static let defaultsKey = "nativeagent.compactionThresholdTokens"
    /// Settings › Context window mode: "model" or "custom".
    public static let contextWindowModeKey = "nativeagent.contextWindowMode"
    public static let agingEnabledKey = "nativeagent.compactionAgingEnabled"
    public static let defaultThresholdTokens = 200_000
    public static let maximumContextWindowFraction = 0.60
    /// Fraction of the threshold at which older turns start aging into
    /// recollection in the background.
    /// Leave recent history whole until near the end. At 100% the synchronous
    /// backstop can replace the source even while aging distills; that aging
    /// result then fails its prefix check and is discarded.
    public static let defaultAgingFraction = 0.85
    /// Keep recent raw history in proportion to the window, not a row count.
    public static let rawHistoryTargetFraction = 0.55
    /// Model's default window: 60% of the model's own window. Custom size:
    /// `thresholdTokens`, never past 60% of the model's window.
    public enum ContextWindowMode: String, Sendable {
        case modelDefault = "model"
        case custom
    }
    public var thresholdTokens: Int
    public var contextWindowMode: ContextWindowMode
    /// The continuous lane. When true, the append that crosses the aging
    /// boundary schedules a background distillation of the session's older
    /// turns. Off → the pre-turn threshold is the only lane, exactly as before.
    public var agingEnabled: Bool
    public init(
        thresholdTokens: Int = Self.defaultThresholdTokens,
        agingEnabled: Bool = true,
        contextWindowMode: ContextWindowMode = .custom
    ) {
        self.thresholdTokens = max(1, thresholdTokens)
        self.contextWindowMode = contextWindowMode
        self.agingEnabled = agingEnabled
    }
    /// Reads the app preference at the production boundary.  The defaults
    /// instance is injectable solely so callers can exercise the same reader
    /// against an isolated persistent domain; production still uses `.standard`.
    public static func productionDefault(
        defaults: UserDefaults = .standard
    ) -> ChatSessionAutocompactionConfig {
        let stored = defaults.integer(forKey: defaultsKey)
        // Absent key → aging on by default; explicit false → off (the pre-turn
        // threshold then behaves exactly as it did before the aging lane).
        let aging = defaults.object(forKey: agingEnabledKey) == nil
            ? true
            : defaults.bool(forKey: agingEnabledKey)
        // A saved size selects custom mode; otherwise use the model default.
        let mode = defaults.string(forKey: contextWindowModeKey)
            .flatMap(ContextWindowMode.init(rawValue:))
            ?? (stored > 0 ? .custom : .modelDefault)
        return ChatSessionAutocompactionConfig(
            thresholdTokens: stored > 0 ? stored : defaultThresholdTokens,
            agingEnabled: aging,
            contextWindowMode: mode
        )
    }
    /// All context sizing uses 60% of the model window, capped by custom size; nil when unknown.
    public func effectiveWindowTokens(nativeWindowTokens: Int?) -> Int? {
        guard let native = nativeWindowTokens, native > 0 else { return nil }
        let safe = max(1, Int(Double(native) * Self.maximumContextWindowFraction))
        return contextWindowMode == .custom ? min(thresholdTokens, safe) : safe
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
    public func contextWindowReadout(forModel model: String, providerID: String?, dataRoot: URL) -> [String: JSONValue] {
        let native = ProviderRouting.verifiedContextLength(forModel: model, providerID: providerID, dataRoot: dataRoot)
        let effective = effectiveWindowTokens(nativeWindowTokens: native)
        let custom = contextWindowMode == .custom ? thresholdTokens : nil
        return [
            "model": .string(model),
            "effective_tokens": effective.map { .int(Int64($0)) } ?? .null,
            "native_window_tokens": native.map { .int(Int64($0)) } ?? .null,
            "custom_cap_tokens": custom.map { .int(Int64($0)) } ?? .null,
            "native_window_source": .string("ProviderRouting verified model catalog for the selected provider/model"),
            "effective_window_owner": .string("Settings > Context window (ChatSessionAutocompactionConfig)"),
            "maximum_native_fraction": .double(Self.maximumContextWindowFraction),
            "meaning": .string("effective_tokens is NativeAgent's history budget, not the model's full capacity or a measure of tokens used. The 60% ceiling leaves room for persona, tool schemas, Fluid Context, tool output and the reply; a selected Custom cap can lower it."),
            "summary": .string("Context window for \(model): effective \(effective.map(String.init) ?? "unknown") tokens; native \(native.map(String.init) ?? "unknown") tokens; Custom cap \(custom.map(String.init) ?? "none"). Effective context is 60% of the model's native window, capped by Custom when selected."),
        ]
    }
    /// Where she compacts: her effective window. An unknown model falls back
    /// to the saved size, the only number there is.
    public func effectiveThresholdTokens(
        forModel model: String,
        providerID: String? = nil,
        dataRoot: URL? = nil
    ) -> Int {
        effectiveWindowTokens(forModel: model, providerID: providerID, dataRoot: dataRoot)
            ?? thresholdTokens
    }
    /// The boundary at which a session's OLDER turns start aging into
    /// recollection, in the background. Always below the pre-turn threshold —
    /// that one is the backstop.
    public func effectiveAgingThresholdTokens(
        forModel model: String,
        providerID: String? = nil,
        dataRoot: URL? = nil
    ) -> Int {
        let ceiling = effectiveThresholdTokens(
            forModel: model,
            providerID: providerID,
            dataRoot: dataRoot
        )
        return max(1, min(ceiling, Int(Double(ceiling) * Self.defaultAgingFraction)))
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
}
struct ChatSessionCompactionTranscriptError: LocalizedError, Sendable {
    let errorDescription: String?
}
