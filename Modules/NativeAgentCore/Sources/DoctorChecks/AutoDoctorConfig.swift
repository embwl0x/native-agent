import Foundation

public struct AutoDoctorConfig: Codable, Hashable {
    public var enabled: Bool?
    public var runOnStartup: Bool?
    public var intervalSeconds: Int?
    public var usesModelCalls: Bool?
    public var checkLLM: Bool?
    public init(enabled: Bool? = nil, runOnStartup: Bool? = nil, intervalSeconds: Int? = nil, usesModelCalls: Bool? = nil, checkLLM: Bool? = nil) {
        self.enabled = enabled
        self.runOnStartup = runOnStartup
        self.intervalSeconds = intervalSeconds
        self.usesModelCalls = usesModelCalls
        self.checkLLM = checkLLM
    }
}
