// Blueprint: | `RunRecord.swift` | RunRecord: shared Codable run-history fields |

import Foundation

public struct RunRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var kind: String
    public var status: String
    public var model: String?
    public var requestedModel: String?
    public var reasoningEffort: String?
    public var codexSandbox: String?
    public var fileAccessMode: String?
    public var prompt: String?
    public var output: String?
    public var error: String?
    public var createdAt: String
    public var durationSeconds: Double?
}
