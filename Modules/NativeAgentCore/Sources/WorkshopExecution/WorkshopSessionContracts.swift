import Foundation
import Desk

public enum WorkshopSessionStatus: String, Sendable, Equatable {
    case completed   // ran and produced output
    case blocked     // ran but hit the deadline / needs User — finite, not a wedge
    case refused     // authorization/reservation failed — no LLM was called
}

/// What the pump hands a session: the item and the pump's reservation proof.
public struct WorkshopSessionRequest: Sendable, Equatable {
    public let handle: String
    public let reservationId: String
    /// "workshop:<handle>:<reservationId>" — the sole authorization token.
    public let triggerSource: String
    public let title: String
    /// The bounded work prompt (item title/why/doneLooksLike) — no persona bytes.
    public let promptSeed: String

    // Internal on purpose: only the Core-owned pump can mint a workshop run.
    // Chat tools and other modules can observe reservation ids, but cannot
    // construct an executable request from that data.
    init(handle: String, reservationId: String, title: String, promptSeed: String) {
        self.handle = handle
        self.reservationId = reservationId
        self.triggerSource = WorkshopSessionRequest.makeTriggerSource(handle: handle, reservationId: reservationId)
        self.title = title
        self.promptSeed = promptSeed
    }

    public static func makeTriggerSource(handle: String, reservationId: String) -> String {
        "workshop:\(handle):\(reservationId)"
    }
}

/// A session's honest outcome, keyed by (handle, reservationId) for the M8
/// receipt log. Compact — never the O(all executions) scoreboard.
public struct WorkshopSessionReceipt: Sendable, Equatable {
    public let handle: String
    public let reservationId: String
    public let status: WorkshopSessionStatus
    public let summary: String
    public let model: String?
    public let artifactPaths: [String]
    public let generatedAt: Date
    public let disposition: DeskWorkDisposition

    public init(
        handle: String, reservationId: String, status: WorkshopSessionStatus,
        summary: String, model: String?, artifactPaths: [String], generatedAt: Date,
        disposition: DeskWorkDisposition = .progress
    ) {
        self.handle = handle
        self.reservationId = reservationId
        self.status = status
        self.summary = summary
        self.model = model
        self.artifactPaths = artifactPaths
        self.generatedAt = generatedAt
        self.disposition = disposition
    }
}

public protocol WorkshopSessionRunning: Sendable {
    func run(_ request: WorkshopSessionRequest) async -> WorkshopSessionReceipt
}
