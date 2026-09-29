import Foundation

public struct SessionContextStatus: Codable, Hashable {
    public var session_id: String
    public var used_tokens: Int
    public var transcript_tokens: Int?
    public var prompt_tokens: Int?
    public var previous_turn_tokens: Int?
    public var turn_delta_tokens: Int?
    public var budget: Int
    public var percent: Double
    public var message_count: Int
    public var compactable: Bool
    public var auto_compact_threshold: Int
    public var model: String
    public var context_loaded: Bool?
    public var context_mode: String?
    public var context_fingerprint: String?
    public var context_prompt_chars: Int?
    public init(session_id: String, used_tokens: Int, transcript_tokens: Int? = nil, prompt_tokens: Int? = nil, previous_turn_tokens: Int? = nil, turn_delta_tokens: Int? = nil, budget: Int, percent: Double, message_count: Int, compactable: Bool, auto_compact_threshold: Int, model: String, context_loaded: Bool? = nil, context_mode: String? = nil, context_fingerprint: String? = nil, context_prompt_chars: Int? = nil) {
        self.session_id = session_id
        self.used_tokens = used_tokens
        self.transcript_tokens = transcript_tokens
        self.prompt_tokens = prompt_tokens
        self.previous_turn_tokens = previous_turn_tokens
        self.turn_delta_tokens = turn_delta_tokens
        self.budget = budget
        self.percent = percent
        self.message_count = message_count
        self.compactable = compactable
        self.auto_compact_threshold = auto_compact_threshold
        self.model = model
        self.context_loaded = context_loaded
        self.context_mode = context_mode
        self.context_fingerprint = context_fingerprint
        self.context_prompt_chars = context_prompt_chars
    }
}
