import Foundation
// Blueprint: | `MobileHelpers.swift` | Helper row/edit revisions, shared agent summaries and read-only other-room exchange rows/chronological placement for Mac and phone |

/// HerScreen's reading copy of a concluded exchange, never a chat message.
public struct OtherRoomExchange: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public var contactID: String
    public let contact: String
    public let agent: String
    public let at: Date
    public let message: String
    public let reply: String

    public init(id: String, sessionID: String, contactID: String, contact: String, agent: String,
                at: Date, message: String, reply: String) {
        self.id = id; self.sessionID = sessionID; self.contactID = contactID
        self.contact = contact; self.agent = agent; self.at = at
        self.message = message; self.reply = reply
    }

    public var title: String { contact + " ⇄ " + agent + " — " + Self.firstLine(message) }
    public var subtitle: String { Self.firstLine(reply) }
    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    /// Before the next transcript row by time; "" is the tail after the last.
    public static func anchored(_ events: [Self], to rows: [(id: String, at: Date)]) -> [String: [Self]] {
        guard let first = rows.first else { return [:] }
        return Dictionary(grouping: events.filter { $0.at >= first.at }.sorted { ($0.at, $0.id) < ($1.at, $1.id) }) { event in
            rows.first { $0.at > event.at }?.id ?? ""
        }
    }
}

/// Reading copies and explicit edits only. The Mac's helper and contact stores own all state.
public struct MobileHelpersSnapshot: Codable, Sendable {
    public var experienceRevision: Int? = 1
    public var helpers: [MobileHelperRow] = []
    public var agents: [MobileAgentRow] = []
    public var truncated = false
    public init() {}
}

public struct MobileHelperRow: Codable, Identifiable, Sendable {
    public var revision: Double? = nil
    public var resultID: String? = nil
    public var resultPreview: String? = nil
    public var id: UUID
    public var name: String
    public var status: String
    public var paused: Bool
    public var canPause: Bool
    public init(id: UUID, name: String, status: String, paused: Bool, canPause: Bool) {
        self.id = id; self.name = name; self.status = status
        self.paused = paused; self.canPause = canPause
    }
}

public struct MobileHelperEdit: Codable, Sendable {
    public var id: UUID?
    public var revision: Double?
    public var name = ""
    public var brief = ""
    public var provider = ""
    public var model = ""
    public var modelPinned: Bool? = false
    public var think = ""
    public var fast = false
    public var timing = "manual"
    public var hours = ""
    public var cron = ""
    /// Unused (schedules follow the Mac's clock). It stays on the wire because an
    /// older Mac or iPhone fails to decode an edit without it; "" is their own
    /// default, which an older Mac reads as "follow this Mac".
    public var timeZone: String? = ""
    public var eventSource = "slack"
    public var eventFilter = ""
    public var eventKeyword = ""
    public var tokens = ""
    public var seconds = ""
    public var daily = ""
    public var tell = false
    public var condition = ""
    public init() {}
}

public struct MobileAgentRow: Codable, Identifiable, Sendable, Equatable {
    public var summary: Self {
        var row = self
        row.experienceIDs = experiences?.map(\.id) ?? experienceIDs
        row.experiences = nil
        return row
    }
    public var experiences: [Experience]? = nil
    public var experienceIDs: [String]? = nil
    public var id: String
    public var name: String
    public var via: String
    public var lastExchange: String
    public var status: String
    public var sendRestriction: String?
    public init(id: String, name: String, via: String, lastExchange: String, status: String, sendRestriction: String? = nil) {
        self.id = id; self.name = name; self.via = via
        self.lastExchange = lastExchange; self.status = status
        self.sendRestriction = sendRestriction
    }
}

public struct MobileAgentThread: Codable, Sendable {
    public var experienceRevision: Int? = 1
    public var agent: MobileAgentRow
    public var lines: [MobileAgentLine]
    public var truncated: Bool
    public init(agent: MobileAgentRow, lines: [MobileAgentLine], truncated: Bool) {
        self.agent = agent; self.lines = lines; self.truncated = truncated
    }
}

public struct MobileAgentLine: Codable, Identifiable, Sendable {
    public var id: String
    public var speaker: String
    public var text: String
    public var at: Double
    public init(id: String, speaker: String, text: String, at: Double) {
        self.id = id; self.speaker = speaker; self.text = text; self.at = at
    }
}
