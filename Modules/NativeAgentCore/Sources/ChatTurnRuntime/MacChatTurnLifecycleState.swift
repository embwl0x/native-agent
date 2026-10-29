import Foundation
import NativeAgentCore
import Privacy
import ChatToolParsing
@_exported import ChatToolRuntime
@_exported import ChatSessionWork
import NativeAgentShared
import Dispatcher
import PersistenceCore
import MemoryV2
import ProviderRouting
import MacIntegration
import Context
import MacControl
@_exported import AgentWorkspace
import ToolRegistry
import Desk
import TrustCenter
import TurnTrace
import CryptoKit
import ApprovalInbox
import AuthoredCapabilities
import Experiences
import PersonaEngine
import SwarmRuns
import StandingBots
@_exported import ChatTurnContracts
import Transcripts
import Senses
import os
import CognitiveSubstrate
@_exported import AgentConversations
import Darwin
import UniformTypeIdentifiers
import Synchronization
import DreamREMCycle
import Observation
import Speech
import AVFoundation
import AppKit
import CoreGraphics
// Blueprint: | `MacChatTurnLifecycleState.swift` | Lifecycle state, input, terminal evidence and reducer; `MacChatPersistedTurnLifecycle` validates the payload-free durable projection |

/// Closed, payload-free terminal evidence; retains no provider, tool or transport bodies.
public enum MacChatTurnTerminalEvidence: String, Codable, Sendable, Equatable {
    case finalResponsePersisted = "final_response_persisted"
    case explicitTypedFailure = "explicit_typed_failure"
    case cancellationAcknowledged = "cancellation_acknowledged"
    case interruptedOutcomeUnknown = "interrupted_outcome_unknown"
}

/// One accepted turn's shared-kernel state; requesting cancellation does not prove it stopped.
public struct MacChatTurnLifecycleState: Sendable, Equatable {
    public let identity: MacChatTurnIdentity
    public let presentation: TurnPresentationState
    public let cancellationRequestedAt: Date?
    public let terminalEvidence: MacChatTurnTerminalEvidence?
    /// Ephemeral display hint only; never written to the lifecycle receipt.
    public let replyTextSettled: Bool

    public init(identity: MacChatTurnIdentity, startedAt: Date) {
        self.identity = identity
        presentation = TurnPresentationReducer.initialState(at: startedAt)
        cancellationRequestedAt = nil
        terminalEvidence = nil
        replyTextSettled = false
    }

    public init(
        identity: MacChatTurnIdentity,
        presentation: TurnPresentationState,
        cancellationRequestedAt: Date?,
        terminalEvidence: MacChatTurnTerminalEvidence?,
        replyTextSettled: Bool = false
    ) {
        self.identity = identity
        self.presentation = presentation
        self.cancellationRequestedAt = cancellationRequestedAt
        self.terminalEvidence = terminalEvidence
        self.replyTextSettled = replyTextSettled
    }

    public func effectivePhase(
        at instant: Date,
        stalledAfter: TimeInterval = TurnPresentationReducer.defaultStalledAfter
    ) -> TurnPresentationPhase {
        TurnPresentationReducer.effectivePhase(
            presentation,
            secondsSinceMovement: max(0, instant.timeIntervalSince(presentation.lastMovementAt)),
            stalledAfter: stalledAfter
        )
    }
}

public struct MacChatTurnLifecycleInput: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case working(action: String?)
        case activity(MacChatTurnActivity)
        case streamProgress(accumulatedUTF16Length: Int)
        case replyTextSettled(Bool)
        case retrying(action: String?)
        case waiting(action: String?)
        case blocked(reason: String?)
        case cancellationRequested
        case completed
        case failed(reason: String?)
        case cancellationConfirmed
        case outcomeUnknown(reason: String?)
    }

    public let identity: MacChatTurnIdentity
    public let kind: Kind
    public let occurredAt: Date

    public init(identity: MacChatTurnIdentity, kind: Kind, occurredAt: Date) {
        self.identity = identity
        self.kind = kind
        self.occurredAt = occurredAt
    }
}

public enum MacChatTurnLifecycleReducer {
    public static func reduce(
        _ state: MacChatTurnLifecycleState,
        input: MacChatTurnLifecycleInput
    ) -> MacChatTurnLifecycleState {
        guard input.identity == state.identity, !state.presentation.isTerminal else {
            return state
        }

        let nextPresentation: TurnPresentationState
        var nextCancellationRequestedAt = state.cancellationRequestedAt
        var nextTerminalEvidence: MacChatTurnTerminalEvidence?
        var nextReplyTextSettled = false

        switch input.kind {
        case .replyTextSettled(let settled):
            nextPresentation = settled ? state.presentation : TurnPresentationReducer.recordActivity(
                state.presentation, phase: .working, detail: nil, delegateName: nil,
                at: input.occurredAt, resetStreamLength: true,
                additionalRedactor: additionalRedactor
            )
            nextReplyTextSettled = settled
        case .working(let action):
            nextPresentation = lifecycle(
                state.presentation,
                .working(action: action),
                at: input.occurredAt
            )
        case .activity(let activity):
            // Activity proves movement; only closed terminal evidence may end a turn.
            guard activity.identity == state.identity,
                  !activity.phase.isTerminal else { return state }
            nextPresentation = TurnPresentationReducer.recordActivity(
                state.presentation,
                phase: activity.phase,
                detail: activity.actionSummary,
                delegateName: activity.delegateDisplayName,
                outcome: activity.outcome,
                at: activity.occurredAt,
                resetStreamLength: activity.phase == .retrying,
                additionalRedactor: additionalRedactor
            )
        case .streamProgress(let accumulatedUTF16Length):
            nextReplyTextSettled = state.replyTextSettled
            nextPresentation = TurnPresentationReducer.recordStreamProgress(
                state.presentation,
                accumulatedUTF16Length: accumulatedUTF16Length,
                at: input.occurredAt
            )
        case .retrying(let action):
            nextPresentation = lifecycle(
                state.presentation,
                .retrying(action: action),
                at: input.occurredAt
            )
        case .waiting(let action):
            nextPresentation = lifecycle(
                state.presentation,
                .waiting(action: action),
                at: input.occurredAt
            )
        case .blocked(let reason):
            nextPresentation = lifecycle(
                state.presentation,
                .blocked(reason: reason),
                at: input.occurredAt
            )
        case .cancellationRequested:
            nextPresentation = state.presentation
            let requestedAt = max(input.occurredAt, state.presentation.startedAt)
            nextCancellationRequestedAt = state.cancellationRequestedAt.map {
                min($0, requestedAt)
            } ?? requestedAt
        case .completed:
            nextPresentation = lifecycle(
                state.presentation,
                .completed(summary: nil),
                at: max(input.occurredAt, state.cancellationRequestedAt ?? input.occurredAt)
            )
            nextTerminalEvidence = .finalResponsePersisted
        case .failed(let reason):
            nextPresentation = lifecycle(
                state.presentation,
                .failed(reason: reason),
                at: max(input.occurredAt, state.cancellationRequestedAt ?? input.occurredAt)
            )
            nextTerminalEvidence = .explicitTypedFailure
        case .cancellationConfirmed:
            nextPresentation = lifecycle(
                state.presentation,
                .canceled(reason: nil),
                at: max(input.occurredAt, state.cancellationRequestedAt ?? input.occurredAt)
            )
            nextTerminalEvidence = .cancellationAcknowledged
        case .outcomeUnknown(let reason):
            nextPresentation = lifecycle(
                state.presentation,
                .outcomeUnknown(reason: reason),
                at: max(input.occurredAt, state.cancellationRequestedAt ?? input.occurredAt)
            )
            nextTerminalEvidence = .interruptedOutcomeUnknown
        }

        guard nextPresentation != state.presentation
                || nextCancellationRequestedAt != state.cancellationRequestedAt
                || nextTerminalEvidence != state.terminalEvidence
                || nextReplyTextSettled != state.replyTextSettled else {
            return state
        }
        return MacChatTurnLifecycleState(
            identity: state.identity,
            presentation: nextPresentation,
            cancellationRequestedAt: nextCancellationRequestedAt,
            terminalEvidence: nextTerminalEvidence,
            replyTextSettled: nextReplyTextSettled
        )
    }

    private static func lifecycle(
        _ state: TurnPresentationState,
        _ event: TurnPresentationLifecycleEvent,
        at instant: Date
    ) -> TurnPresentationState {
        TurnPresentationReducer.reduce(
            state,
            lifecycle: event,
            at: instant,
            additionalRedactor: additionalRedactor
        )
    }

    private static let additionalRedactor: TurnPresentationReducer.AdditionalRedactor = {
        NativeAppSecretRedactor.redactText($0)
    }
}

/// Durable state without prompts, replies, raw tool/provider material or accumulated stream text.
public struct MacChatPersistedTurnLifecycle: Codable, Sendable, Equatable {
    public let sessionId: String
    public let turnId: String
    public let phase: TurnPresentationPhase
    public let startedAt: Date
    public let lastMovementAt: Date
    public let endedAt: Date?
    public let currentAction: String?
    public let delegateName: String?
    public let cancellationRequestedAt: Date?
    public let terminalEvidence: MacChatTurnTerminalEvidence?

    public init?(state: MacChatTurnLifecycleState) {
        let presentation = state.presentation
        sessionId = state.identity.sessionId
        turnId = state.identity.turnId
        phase = presentation.phase
        startedAt = presentation.startedAt
        lastMovementAt = presentation.lastMovementAt
        endedAt = presentation.endedAt
        currentAction = Self.safeText(presentation.currentAction)
        delegateName = Self.safeText(presentation.delegateName)
        cancellationRequestedAt = state.cancellationRequestedAt
        terminalEvidence = state.terminalEvidence
        guard isValidRecord else { return nil }
    }

    public var identity: MacChatTurnIdentity {
        MacChatTurnIdentity(sessionId: sessionId, turnId: turnId)
    }

    public var updatedAt: Date {
        endedAt ?? cancellationRequestedAt ?? lastMovementAt
    }

    public var isTerminal: Bool { phase.isTerminal }

    public func restoredState() -> MacChatTurnLifecycleState? {
        guard isValidRecord else { return nil }

        var presentation = TurnPresentationReducer.initialState(at: startedAt)
        if phase != .acknowledged {
            presentation = TurnPresentationReducer.recordActivity(
                presentation,
                phase: phase,
                detail: Self.safeText(currentAction),
                delegateName: Self.safeText(delegateName),
                at: lastMovementAt,
                resetStreamLength: phase == .retrying,
                additionalRedactor: { NativeAppSecretRedactor.redactText($0) }
            )
        }
        return MacChatTurnLifecycleState(
            identity: identity,
            presentation: presentation,
            cancellationRequestedAt: cancellationRequestedAt,
            terminalEvidence: terminalEvidence
        )
    }

    private var isValidRecord: Bool {
        guard NativeAgentChatSessionID.normalizedPathComponent(sessionId) == sessionId,
              Self.safeIdentity(turnId, limit: 128) == turnId,
              Self.safeText(currentAction) == currentAction,
              Self.safeText(delegateName) == delegateName,
              startedAt.timeIntervalSince1970.isFinite,
              lastMovementAt.timeIntervalSince1970.isFinite,
              lastMovementAt >= startedAt,
              endedAt.map({ $0.timeIntervalSince1970.isFinite && $0 == lastMovementAt }) ?? true,
              cancellationRequestedAt.map({
                  $0.timeIntervalSince1970.isFinite && $0 >= startedAt
              }) ?? true,
              cancellationRequestedAt.map({ requestedAt in
                  endedAt.map { requestedAt <= $0 } ?? true
              }) ?? true,
              phase.isTerminal == (endedAt != nil) else { return false }
        switch (phase, terminalEvidence) {
        case (.completed, .finalResponsePersisted),
             (.failed, .explicitTypedFailure),
             (.canceled, .cancellationAcknowledged),
             (.outcomeUnknown, .interruptedOutcomeUnknown):
            return true
        case (.acknowledged, nil), (.working, nil), (.tool, nil),
             (.delegation, nil), (.retrying, nil), (.waiting, nil),
             (.blocked, nil), (.stalled, nil):
            return true
        default:
            return false
        }
    }

    private static func safeIdentity(_ raw: String, limit: Int) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.unicodeScalars.count <= limit,
              value.utf8.count <= limit * 4,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return value
    }

    private static func safeText(_ raw: String?) -> String? {
        guard let sanitized = TurnPresentationReducer.sanitized(
            raw,
            additionalRedactor: { NativeAppSecretRedactor.redactText($0) }
        ) else { return nil }
        let scalars = sanitized.unicodeScalars
        guard scalars.count > TurnPresentationReducer.textLimit else { return sanitized }
        return String(scalars.prefix(TurnPresentationReducer.textLimit - 1)) + "…"
    }
}
