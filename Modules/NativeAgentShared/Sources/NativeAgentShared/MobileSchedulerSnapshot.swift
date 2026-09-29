import Foundation

/// A value-only projection. Job payloads and execution authority stay on Mac.
public struct MobileSchedulerSnapshot: Codable, Equatable, Sendable {
    public var capturedAt: Double
    public var jobs: [MobileSchedulerJob]

    public init(capturedAt: Double, jobs: [MobileSchedulerJob]) {
        self.capturedAt = capturedAt
        self.jobs = jobs
    }
}

public struct MobileSchedulerJob: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var enabled: Bool
    public var schedule: String
    public var nextRunAt: String?
    public var lastRunAt: String?
    public var lastRunStatus: String?
    public var cancelledAt: String?

    public init(id: String, name: String, kind: String, enabled: Bool, schedule: String,
                nextRunAt: String?, lastRunAt: String?, lastRunStatus: String?, cancelledAt: String?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.enabled = enabled
        self.schedule = schedule
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.lastRunStatus = lastRunStatus
        self.cancelledAt = cancelledAt
    }
}
