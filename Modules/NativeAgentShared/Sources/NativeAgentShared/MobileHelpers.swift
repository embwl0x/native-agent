import Foundation

/// Reading copies and explicit edits only. The Mac's helper and contact stores own all state.
public struct MobileHelpersSnapshot: Codable, Sendable {
    public var helpers: [MobileHelperRow] = []
    public var agents: [MobileAgentRow] = []
    public var truncated = false
    public init() {}
}

public struct MobileHelperRow: Codable, Identifiable, Sendable {
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
    public var think = ""
    public var fast = false
    public var timing = "manual"
    public var hours = ""
    public var cron = ""
    public var timeZone = ""
    public var eventSource = "github"
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
