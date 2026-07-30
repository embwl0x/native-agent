import Foundation

struct MacAssistantStatusResponse: Decodable, Hashable {
    var status: String
    var summary: String?
    var access: [MacAssistantAccessItem]
    var watchTemplates: [MacAssistantWatchTemplate]
    var blockedAccessCount: Int?
    var templateAttentionCount: Int?
    var schedulerActions: [String]?
    var createsJobs: Bool?
    var createdAt: String?
}

struct MacAssistantAccessItem: Identifiable, Decodable, Hashable {
    var id: String
    var title: String
    var status: String
    var detail: String?
    var setupRoute: String?
    var requiredFor: [String]?
    var actionIds: [String]?
    var toolNames: [String]?
    var nextStep: String?
}

struct MacAssistantWatchTemplate: Identifiable, Decodable, Hashable {
    var id: String
    var title: String
    var status: String
    var summary: String?
    var scheduleLabel: String?
    var sources: [String]?
    var requiredAccess: [String]?
    var actionIds: [String]?
}
