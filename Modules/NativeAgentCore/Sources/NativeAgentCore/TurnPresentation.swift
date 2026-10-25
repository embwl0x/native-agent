import Foundation
import NativeAgentShared

// Blueprint: | `TurnPresentation.swift` | `TurnPresentationReducer`: sanitized bounded turn lifecycle/activity projection; no tool arguments, payloads or hidden reasoning |

/// Surface-neutral lifecycle phases for presenting one accepted agent turn.
/// Raw values remain stable for existing persisted presentation adapters.
public enum TurnPresentationPhase: String, CaseIterable, Sendable, Codable, Equatable {
    case acknowledged
    case working
    case tool
    case delegation
    case retrying
    case waiting
    case blocked
    case stalled
    case completed
    case failed
    case canceled
    case outcomeUnknown = "outcome_unknown"

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .canceled, .outcomeUnknown:
            return true
        default:
            return false
        }
    }
}

/// Explicit lifecycle evidence supplied by a surface or turn orchestrator.
/// Associated strings are redacted, normalized, and bounded before entering
/// ``TurnPresentationState``.
public enum TurnPresentationLifecycleEvent: Sendable, Equatable {
    case acknowledged
    case working(action: String?)
    case tool(name: String, action: String?)
    case delegation(delegate: String, action: String?)
    case retrying(action: String?)
    case waiting(action: String?)
    case blocked(reason: String?)
    case stalled(reason: String?)
    case completed(summary: String?)
    case failed(reason: String?)
    case canceled(reason: String?)
    case outcomeUnknown(reason: String?)
}

/// One sanitized, bounded movement entry. It intentionally contains no tool
/// arguments, provider payload, model output, hidden reasoning, or transport
/// identity.
public struct TurnPresentationActivity: Sendable, Equatable {
    /// How a tool step ended, read from its own result. Nil for a step that
    /// is not a settled tool result.
    public enum Outcome: Sendable, Equatable {
        case ok
        case refused
        case failed
    }

    public let phase: TurnPresentationPhase
    public let detail: String?
    public let delegateName: String?
    public let outcome: Outcome?
    public let occurredAt: Date

    init(
        phase: TurnPresentationPhase,
        detail: String?,
        delegateName: String?,
        outcome: Outcome?,
        occurredAt: Date
    ) {
        self.phase = phase
        self.detail = detail
        self.delegateName = delegateName
        self.outcome = outcome
        self.occurredAt = occurredAt
    }
}

/// Compact value-only state for presenting one accepted turn. The state owns
/// no timer and performs no IO; callers supply event and observation instants.
public struct TurnPresentationState: Sendable, Equatable {
    public internal(set) var phase: TurnPresentationPhase
    public internal(set) var startedAt: Date
    public internal(set) var lastMovementAt: Date
    public internal(set) var endedAt: Date?
    public internal(set) var currentAction: String?
    public internal(set) var delegateName: String?
    public internal(set) var activities: [TurnPresentationActivity]

    // Accumulated model text never enters presentation state. Its length is
    // enough to coalesce duplicate streaming snapshots while observing real
    // movement.
    public internal(set) var streamedTextLength: Int
    public internal(set) var firstReplyAt: Date? = nil

    public var isTerminal: Bool { phase.isTerminal }

    public init(startedAt: Date) {
        phase = .acknowledged
        self.startedAt = startedAt
        lastMovementAt = startedAt
        endedAt = nil
        currentAction = nil
        delegateName = nil
        activities = []
        streamedTextLength = 0
    }
}

/// The single authoritative pure lifecycle reducer shared by presentation
/// surfaces. Surface adapters translate their transport/progress vocabulary
/// into these lifecycle events and may supply one additional token redactor.
public enum TurnPresentationReducer {
    public typealias AdditionalRedactor = @Sendable (String) -> String

    // Keep a bounded receipt's explanation and next step together.
    public static let textLimit = 1_000
    public static let detailHistoryLimit = 12
    public static let defaultStalledAfter: TimeInterval = 90

    public static func initialState(at instant: Date) -> TurnPresentationState {
        TurnPresentationState(startedAt: instant)
    }

    public static func reduce(
        _ state: TurnPresentationState,
        lifecycle event: TurnPresentationLifecycleEvent,
        at instant: Date,
        additionalRedactor: AdditionalRedactor? = nil
    ) -> TurnPresentationState {
        guard !state.isTerminal else { return state }

        let phase: TurnPresentationPhase
        var action: String? = nil
        var delegate: String? = nil
        var resetStreamLength = false
        switch event {
        case .acknowledged:
            guard state.phase == .acknowledged else { return state }
            phase = .acknowledged
        case .working(let detail):
            phase = .working
            action = detail
        case .tool(let name, let detail):
            phase = .tool
            action = detail ?? ToolActivityPresentation.progress(name)
        case .delegation(let name, let detail):
            phase = .delegation
            action = detail
            delegate = name
        case .retrying(let detail):
            phase = .retrying
            action = detail
            resetStreamLength = true
        case .waiting(let detail):
            phase = .waiting
            action = detail
        case .blocked(let reason):
            phase = .blocked
            action = reason
        case .stalled(let reason):
            phase = .stalled
            action = reason
        case .completed(let summary):
            phase = .completed
            action = summary
        case .failed(let reason):
            phase = .failed
            action = reason
        case .canceled(let reason):
            phase = .canceled
            action = reason
        case .outcomeUnknown(let reason):
            phase = .outcomeUnknown
            action = reason
        }
        return transition(
            state,
            phase: phase,
            action: action,
            delegate: delegate,
            at: instant,
            resetStreamLength: resetStreamLength,
            additionalRedactor: additionalRedactor
        )
    }

    /// Records growing assistant output by length only. The text itself never
    /// crosses the presentation boundary.
    public static func recordStreamProgress(
        _ state: TurnPresentationState,
        accumulatedUTF16Length: Int,
        at instant: Date
    ) -> TurnPresentationState {
        guard !state.isTerminal else { return state }
        let length = max(0, accumulatedUTF16Length)
        guard length != state.streamedTextLength else { return state }
        return transition(
            state,
            phase: .working,
            at: instant,
            streamedTextLength: length
        )
    }

    /// Records surface-normalized activity that carries an optional delegate.
    /// This is the narrow adapter seam for progress vocabularies whose detail
    /// does not originate as an explicit lifecycle event.
    public static func recordActivity(
        _ state: TurnPresentationState,
        phase: TurnPresentationPhase,
        detail: String?,
        delegateName: String?,
        outcome: TurnPresentationActivity.Outcome? = nil,
        at instant: Date,
        resetStreamLength: Bool = false,
        additionalRedactor: AdditionalRedactor? = nil
    ) -> TurnPresentationState {
        guard !state.isTerminal else { return state }
        return transition(
            state,
            phase: phase,
            action: detail,
            delegate: delegateName,
            outcome: outcome,
            at: instant,
            resetStreamLength: resetStreamLength,
            additionalRedactor: additionalRedactor
        )
    }

    public static func sanitized(
        _ raw: String?,
        additionalRedactor: AdditionalRedactor? = nil
    ) -> String? {
        guard let raw else { return nil }
        var redacted = TurnSecretRedactor.redactText(raw)
        if let additionalRedactor {
            redacted = additionalRedactor(redacted)
        }
        let singleLine = redacted
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !singleLine.isEmpty else { return nil }
        guard singleLine.count > textLimit else { return singleLine }
        return String(singleLine.prefix(textLimit - 1)) + "…"
    }

    /// Derives a stalled presentation without mutating authoritative lifecycle
    /// state. Waiting, blocked, explicit-stall, and terminal states do not age
    /// into a different meaning.
    public static func effectivePhase(
        _ state: TurnPresentationState,
        secondsSinceMovement: TimeInterval,
        stalledAfter: TimeInterval = defaultStalledAfter
    ) -> TurnPresentationPhase {
        guard stalledAfter > 0,
              secondsSinceMovement >= stalledAfter,
              canBecomeStalled(state.phase) else {
            return state.phase
        }
        return .stalled
    }

    private static func transition(
        _ state: TurnPresentationState,
        phase: TurnPresentationPhase,
        action: String? = nil,
        delegate: String? = nil,
        outcome: TurnPresentationActivity.Outcome? = nil,
        at instant: Date,
        streamedTextLength: Int? = nil,
        resetStreamLength: Bool = false,
        additionalRedactor: AdditionalRedactor? = nil
    ) -> TurnPresentationState {
        let safeAction = sanitized(action, additionalRedactor: additionalRedactor)
        let safeDelegate = sanitized(delegate, additionalRedactor: additionalRedactor)
        let nextTextLength: Int
        if resetStreamLength {
            nextTextLength = 0
        } else if let streamedTextLength {
            nextTextLength = max(0, streamedTextLength)
        } else {
            nextTextLength = state.streamedTextLength
        }

        guard phase != state.phase
                || safeAction != state.currentAction
                || safeDelegate != state.delegateName
                || nextTextLength != state.streamedTextLength else {
            return state
        }

        var next = state
        let movementAt = max(instant, state.lastMovementAt)
        next.phase = phase
        next.lastMovementAt = movementAt
        next.endedAt = phase.isTerminal ? movementAt : nil
        next.currentAction = safeAction
        next.delegateName = safeDelegate
        next.streamedTextLength = nextTextLength
        if nextTextLength > 0, next.firstReplyAt == nil { next.firstReplyAt = movementAt }
        next.activities.append(TurnPresentationActivity(
            phase: phase,
            detail: safeAction,
            delegateName: safeDelegate,
            outcome: outcome,
            occurredAt: movementAt
        ))
        if next.activities.count > detailHistoryLimit {
            next.activities.removeFirst(next.activities.count - detailHistoryLimit)
        }
        return next
    }

    private static func canBecomeStalled(_ phase: TurnPresentationPhase) -> Bool {
        switch phase {
        case .acknowledged, .working, .tool, .delegation, .retrying:
            return true
        case .waiting, .blocked, .stalled, .completed, .failed, .canceled, .outcomeUnknown:
            return false
        }
    }
}
