import Foundation
import SwiftUI
// Blueprint: | `TurnFace.swift` | `TurnFace`, `TurnSessionsFace`, `TurnElsewhereLine`: turn values and quiet cross-conversation movement drawing |

/// Keep phase raw values stable for persisted presentation adapters.
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

/// Pair session and turn IDs so late activity from a prior stream cannot enter its replacement.
public struct MacChatTurnIdentity: Sendable, Equatable, Codable {
    public let sessionId: String
    public let turnId: String

    public init(sessionId: String, turnId: String) {
        self.sessionId = sessionId
        self.turnId = turnId
    }
}

/// A turn's approval projected from the canonical inbox, with only proven decisions represented as approved or denied.
public struct MacChatTurnCardApproval: Sendable, Equatable, Codable {
    public let approvalId: String
    /// What the call does, in words.
    public let act: String
    public let reason: String?
    public var inputSummary: String? = nil
    /// Name peer requesters from Trust; the person's own approvals need no requester label.
    public var requester: String? = nil
    public let outcome: ApprovalRequest.Outcome

    public init(approvalId: String, act: String, reason: String?, inputSummary: String? = nil,
                requester: String? = nil, outcome: ApprovalRequest.Outcome) {
        self.approvalId = approvalId
        self.act = act
        self.reason = reason
        self.inputSummary = inputSummary
        self.requester = requester
        self.outcome = outcome
    }

    /// Only a pending request can be decided from here.
    public var isActionable: Bool { outcome == .pending }
}

extension MacChatTurnCardApproval {
    /// Keep unproven outcomes visible after the turn; proven decisions remain available in Approvals.
    public var keepsCardVisible: Bool {
        switch outcome {
        case .pending, .expired, .unresolved: return true
        case .approved, .denied: return false
        }
    }
}

/// Derive every card field from evidence; views keep no mutable turn state.
public struct MacChatTurnCardModel: Sendable, Equatable, Codable {
    /// Keep visual register separate from phase so unknown outcomes cannot acquire success or failure treatment.
    public enum Tone: String, Sendable, Equatable, Codable {
        case working
        /// Observed stalls are not terminal errors.
        case attention
        /// Unknown terminal outcomes are neither success nor failure.
        case unresolved
        /// Terminal failure requires typed evidence.
        case failed
        /// Terminal stop requires typed evidence.
        case canceled
    }

    public let identity: MacChatTurnIdentity
    public let phase: TurnPresentationPhase
    public let title: String
    public let detail: String?
    public let delegateName: String?
    public let tone: Tone
    public let symbolName: String
    public let isTerminal: Bool
    public let showsLiveIndicator: Bool
    /// A Stop request is not proof of settlement.
    public let cancellationPending: Bool
    /// Read approvals from the existing inbox; the card keeps no approval state or authority.
    public let approval: MacChatTurnCardApproval?

    /// The face draws elapsed time from these event timestamps.
    public let clock: Clock

    public let thinkingSince: Date?
    /// When reply text arrives alone, retain the duration spent thinking.
    public let thoughtFor: TimeInterval?

    /// Use the same three timestamps for projection and live readout so their seconds cannot disagree.
    public struct Clock: Equatable, Sendable, Codable {
        public let startedAt: Date
        public let endedAt: Date?
        public let lastMovementAt: Date
        public let isTerminal: Bool

        public init(startedAt: Date, endedAt: Date?, lastMovementAt: Date, isTerminal: Bool) {
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.lastMovementAt = lastMovementAt
            self.isTerminal = isTerminal
        }

        /// Quantize to whole seconds so token-rate movement cannot re-render unchanged text.
        public static func wholeSeconds(_ interval: TimeInterval) -> TimeInterval {
            guard interval.isFinite, interval > 0 else { return 0 }
            return interval.rounded(.down)
        }

        public func elapsed(at instant: Date) -> TimeInterval {
            Self.wholeSeconds((endedAt ?? instant).timeIntervalSince(startedAt))
        }

        public func secondsSinceMovement(at instant: Date) -> TimeInterval? {
            isTerminal ? nil : Self.wholeSeconds(instant.timeIntervalSince(lastMovementAt))
        }
    }

    public init(identity: MacChatTurnIdentity, phase: TurnPresentationPhase, title: String, detail: String?,
                delegateName: String?, tone: Tone, symbolName: String, isTerminal: Bool, showsLiveIndicator: Bool,
                cancellationPending: Bool, approval: MacChatTurnCardApproval?, clock: Clock,
                thinkingSince: Date?, thoughtFor: TimeInterval?) {
        self.identity = identity
        self.phase = phase
        self.title = title
        self.detail = detail
        self.delegateName = delegateName
        self.tone = tone
        self.symbolName = symbolName
        self.isTerminal = isTerminal
        self.showsLiveIndicator = showsLiveIndicator
        self.cancellationPending = cancellationPending
        self.approval = approval
        self.clock = clock
        self.thinkingSince = thinkingSince
        self.thoughtFor = thoughtFor
    }

    /// Settled cards without decisions must be inert; live approvals remain clickable.
    public var hasControls: Bool {
        !isTerminal || approval?.isActionable == true
    }

}

public enum MacChatTurnCardFormat {
    /// Invalid or unrepresentable intervals have no duration reading.
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0,
              let total = Int(exactly: seconds.rounded()) else { return "Duration unavailable" }
        if total < 60 { return "\(total)s" }
        if total < 3_600 {
            let minutes = total / 60
            let rest = total % 60
            return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s"
        }
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    public static func elapsedPhrase(_ seconds: TimeInterval, isTerminal: Bool) -> String {
        isTerminal ? "Ran for \(duration(seconds))" : "\(duration(seconds)) elapsed"
    }

    /// Assemble timing once so visual, spoken and model metadata cannot drift; name quiet only after movement actually pauses.
    public static func metaLine(
        elapsed: TimeInterval,
        secondsSinceMovement: TimeInterval?,
        isTerminal: Bool,
        separator: String
    ) -> String {
        var parts = [elapsedPhrase(elapsed, isTerminal: isTerminal)]
        if let movement = movementPhrase(secondsSinceMovement) {
            parts.append(movement)
        }
        return parts.joined(separator: separator)
    }

    public static func movementPhrase(_ secondsSinceMovement: TimeInterval?) -> String? {
        guard let secondsSinceMovement,
              secondsSinceMovement >= TurnFace.movementNoticeAfter else {
            return nil
        }
        return "no movement for \(duration(secondsSinceMovement))"
    }
}

/// One conversation's finished status. Missing feed input remains unknown; only owner events replace it.
public struct TurnFace: FaceValue {
    public static let movementNoticeAfter: TimeInterval = 20
    public let sessionID: String
    public let turnID: String?
    public let activeTurnID: String?
    public let phase: TurnPresentationPhase?
    public let isInFlight: Bool
    public let card: MacChatTurnCardModel?
    public let hasReservation: Bool
    public let isBusy: Bool
    public let isStreaming: Bool
    public let isReplying: Bool
    public let isThinking: Bool
    public let liveLine: String?
    public let workPill: String?
    public let steps: [Step]
    public let preview: Preview?
    public let approvalStatus: String?

    public var isWorking: Bool { isBusy || isStreaming }
    public var isRunning: Bool { isWorking || isInFlight || phase.map { !$0.isTerminal } == true }

    public init(sessionID: String, turnID: String?, activeTurnID: String?, phase: TurnPresentationPhase?, isInFlight: Bool,
                card: MacChatTurnCardModel?, hasReservation: Bool, isBusy: Bool, isStreaming: Bool, isReplying: Bool, isThinking: Bool,
                liveLine: String?, workPill: String?, steps: [Step], preview: Preview?, approvalStatus: String?) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.activeTurnID = activeTurnID
        self.phase = phase
        self.isInFlight = isInFlight
        self.card = card
        self.hasReservation = hasReservation
        self.isBusy = isBusy
        self.isStreaming = isStreaming
        self.isReplying = isReplying
        self.isThinking = isThinking
        self.liveLine = liveLine
        self.workPill = workPill
        self.steps = steps
        self.preview = preview
        self.approvalStatus = approvalStatus
    }

    public struct Step: Sendable, Equatable, Codable {
        public enum Outcome: String, Sendable, Equatable, Codable { case ok, refused, failed }
        public let text: String
        public let outcome: Outcome?
        public init(text: String, outcome: Outcome?) { self.text = text; self.outcome = outcome }
    }

    /// Masked image bytes cross with the caption; a failed encoding is visible without retaining a previous frame.
    public struct Preview: Sendable, Equatable, Codable {
        public let imageData: Data?
        public let imageError: String?
        public let readText: String?
        public let caption: String
        public let updatedAt: Date
        public var isShowable: Bool { imageData != nil && !caption.isEmpty }

        public init(imageData: Data?, imageError: String? = nil, readText: String?, caption: String, updatedAt: Date) {
            self.imageData = imageData
            self.imageError = imageError
            self.readText = readText
            self.caption = caption
            self.updatedAt = updatedAt
        }
    }
}

/// Membership and payload-free movement for views spanning conversations; room content stays in its own slot.
public struct TurnSessionsFace: FaceValue {
    public let activeTurnIDs: [String: String]
    public let inFlightTurnIDs: Set<String>
    public let streamingSessionIDs: Set<String>
    public var movements: [Movement]? = nil

    public struct Movement: Sendable, Equatable, Codable, Identifiable {
        public let identity: MacChatTurnIdentity
        /// The accepted run Stop matches, distinct from the trace turn id; absent on older publications.
        public let runID: String?
        public let line: String
        public let isMoving: Bool
        public var id: String { identity.turnId }

        public init(identity: MacChatTurnIdentity, runID: String?, line: String, isMoving: Bool) {
            self.identity = identity
            self.runID = runID
            self.line = line
            self.isMoving = isMoving
        }
    }

    public func movements(outside sessionID: String) -> [Movement] {
        movements?.filter { $0.identity.sessionId != sessionID } ?? []
    }
    public init(activeTurnIDs: [String: String],
                inFlightTurnIDs: Set<String>, streamingSessionIDs: Set<String>) {
        self.activeTurnIDs = activeTurnIDs
        self.inFlightTurnIDs = inFlightTurnIDs
        self.streamingSessionIDs = streamingSessionIDs
    }
}

extension Notification.Name {
    public static let turnSessionsFacePublished = Notification.Name("turnSessionsFacePublished")
}

/// One quiet row, with navigation and cancellation reaching the turn's existing owners.
public struct TurnElsewhereLine: View {
    public let movements: [TurnSessionsFace.Movement]
    public let agentName: String
    public let open: (String) -> Void
    public let stop: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(movements: [TurnSessionsFace.Movement], agentName: String,
                open: @escaping (String) -> Void, stop: @escaping (String) -> Void) {
        self.movements = movements
        self.agentName = agentName
        self.open = open
        self.stop = stop
    }

    public var body: some View {
        if let first = movements.first {
            HStack(spacing: 8) {
                Button { open(first.identity.sessionId) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: first.isMoving ? "ellipsis" : "pause")
                            .symbolEffect(.pulse, options: .repeating, isActive: first.isMoving && !reduceMotion)
                        Text(agentName + " · " + first.line).lineLimit(1).truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityHint("Open the conversation where this turn is running")
                if movements.count > 1 {
                    Menu {
                        ForEach(movements) { movement in
                            Button(movement.line) { open(movement.identity.sessionId) }
                        }
                    } label: { Text("+\(movements.count - 1)") }
                    .accessibilityLabel("Other open turns")
                }
                if first.runID != nil {
                    Button { stop(first.identity.sessionId) } label: { Image(systemName: "stop.fill") }
                        .accessibilityLabel("Stop this turn")
                }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("chat.turn-elsewhere")
        }
    }
}
