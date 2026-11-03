import Foundation
// Blueprint: | `MobileWorkActivity.swift` | Bounded mobile experience projection, activity DTOs and revisioned experience snapshot |

extension Experience {
    /// The face is bounded only at delivery; its identity and evidence stay exact.
    public var mobile: Self {
        var copy = self
        if let face {
            copy.face = .init(words: MobileDeskProjectionBounds.clipped(face.words, to: 2_000), artifacts: face.artifacts)
        }
        return copy
    }
}

public struct MobileWorkActivity: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        case queued, preparing, working, tool, replying, retrying, waiting, blocked
        case completed, stopped, failed, interrupted, unknown

        public var isTerminal: Bool {
            [.completed, .stopped, .failed, .interrupted].contains(self)
        }
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public var title: String
        public var state: State
        public var status: String
        public var updatedAt: Date

        public init(title: String, state: State, status: String, updatedAt: Date) {
            self.title = title; self.state = state; self.status = status; self.updatedAt = updatedAt
        }
    }

    public var id: String
    public var sessionID: String?
    public var startedAt: Date
    public var content: ContentState

    public init(id: String, sessionID: String?, startedAt: Date, content: ContentState) {
        self.id = id; self.sessionID = sessionID; self.startedAt = startedAt; self.content = content
    }

    public var staleDate: Date { content.updatedAt.addingTimeInterval(5 * 60) }
}

public struct MobileWorkActivitySnapshot: Codable, Sendable {
    public var experienceRevision: Int? = 1
    public var experiences: [Experience]? = nil
    public var unavailable: String? = nil
    public var activities: [MobileWorkActivity]
    public var pairingFingerprint: String
    public var pushConfigured: Bool
    public var pushConfigurationError: String?

    public init(activities: [MobileWorkActivity], pairingFingerprint: String, pushConfigured: Bool, pushConfigurationError: String? = nil) {
        self.pairingFingerprint = pairingFingerprint
        self.activities = activities; self.pushConfigured = pushConfigured; self.pushConfigurationError = pushConfigurationError
    }
}
