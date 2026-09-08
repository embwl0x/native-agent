import Foundation

public struct ProviderModelInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var context_length: Int
    public var supports_streaming: Bool
    public var supports_vision: Bool
    public var supports_tools: Bool
    public var supports_json_mode: Bool
    public var cost_per_1k_in: Double?
    public var cost_per_1k_out: Double?
    public var default_reasoning_effort: String? = nil
    public var supported_reasoning_efforts: [String]? = nil
    public var supports_fast: Bool? = nil

    public init(
        id: String,
        name: String,
        context_length: Int,
        supports_streaming: Bool,
        supports_vision: Bool,
        supports_tools: Bool,
        supports_json_mode: Bool,
        cost_per_1k_in: Double? = nil,
        cost_per_1k_out: Double? = nil,
        default_reasoning_effort: String? = nil,
        supported_reasoning_efforts: [String]? = nil,
        supports_fast: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.context_length = context_length
        self.supports_streaming = supports_streaming
        self.supports_vision = supports_vision
        self.supports_tools = supports_tools
        self.supports_json_mode = supports_json_mode
        self.cost_per_1k_in = cost_per_1k_in
        self.cost_per_1k_out = cost_per_1k_out
        self.default_reasoning_effort = default_reasoning_effort
        self.supported_reasoning_efforts = supported_reasoning_efforts
        self.supports_fast = supports_fast
    }
}

public struct ProviderTestResult: Codable, Hashable, Sendable {
    public var provider_id: String
    public var status: String
    public var tested: Bool
    public var response: String?
    public var model_used: String?
    public var detail: String?
    public var error: String?

    public init(
        provider_id: String,
        status: String,
        tested: Bool,
        response: String? = nil,
        model_used: String? = nil,
        detail: String? = nil,
        error: String? = nil
    ) {
        self.provider_id = provider_id
        self.status = status
        self.tested = tested
        self.response = response
        self.model_used = model_used
        self.detail = detail
        self.error = error
    }
}
