import Foundation

// Blueprint: | `ProviderCallEvidence.swift` | Payload-free provider lifecycle and first-output timing evidence |

/// Payload-free evidence emitted by the shared provider router around one real adapter invocation. The call id is minted before the adapter starts and is
/// reused for its terminal phase, so the organism can predict an outcome before observing it instead of inferring provider health after the fact.
public enum LLMCallLifecyclePhase: String, Sendable, Equatable {
    case started
    case succeeded
    case failed
    case cancelled
}

public struct LLMCallLifecycleEvent: Sendable, Equatable, Identifiable {
    public let id: String
    public let phase: LLMCallLifecyclePhase
    public let providerId: String
    public let model: String
    public let surface: String
    public let sessionId: String?
    public let turnId: String?
    /// Exact request-scoped reasoning effort presented to the shared provider router. This is payload-free lifecycle evidence, not a quality claim.
    public let reasoningEffort: String?
    public let streaming: Bool
    public let occurredAt: Date
    /// A terminal call's first text or tool output in milliseconds from its request, as the adapter stamped it on the call's `llm.call` row.
    public let firstOutputMs: Int?
    /// A terminal streamed call's `LLMMessagesStreamKind` raw value; nil when it did not come through `streamMessages`.
    public let streamKind: String?
    /// The stream guard cut this call (`ProviderFailure.noReply`).
    public let noReply: Bool
    public let requestBytes: Int?

    public init(
        id: String,
        phase: LLMCallLifecyclePhase,
        providerId: String,
        model: String,
        surface: String,
        sessionId: String?,
        turnId: String?,
        reasoningEffort: String? = nil,
        streaming: Bool,
        occurredAt: Date = Date(),
        firstOutputMs: Int? = nil,
        streamKind: String? = nil,
        noReply: Bool = false,
        requestBytes: Int? = nil
    ) {
        self.requestBytes = requestBytes
        self.id = String(id.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        self.phase = phase
        self.providerId = String(providerId.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        self.model = String(model.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        self.surface = String(surface.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        self.sessionId = sessionId.map { String($0.prefix(160)) }
        self.turnId = turnId.map { String($0.prefix(120)) }
        self.reasoningEffort = reasoningEffort.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(32))
        }.flatMap { $0.isEmpty ? nil : $0 }
        self.streaming = streaming
        self.occurredAt = occurredAt
        self.firstOutputMs = firstOutputMs
        self.streamKind = streamKind
        self.noReply = noReply
    }

    public func terminal(_ phase: LLMCallLifecyclePhase, at date: Date = Date(), firstOutputMs: Int? = nil,
                         streamKind: String? = nil, noReply: Bool = false, requestBytes: Int? = nil) -> Self? {
        guard phase != .started else { return nil }
        return Self(
            id: id,
            phase: phase,
            providerId: providerId,
            model: model,
            surface: surface,
            sessionId: sessionId,
            turnId: turnId,
            reasoningEffort: reasoningEffort,
            streaming: streaming,
            occurredAt: date,
            firstOutputMs: firstOutputMs,
            streamKind: streamKind,
            noReply: noReply,
            requestBytes: requestBytes
        )
    }
}

public protocol LLMCallLifecycleObserving: Sendable {
    func observeProviderCall(_ event: LLMCallLifecycleEvent) async
}

extension LLMMessage {
    /// Text presented to this request, in characters. Image encoding is not text; its token cost remains part of the provider's reported input.
    public static func inputCharacters(_ messages: [LLMMessage], system: String?, tools: [LLMToolSchema]) -> Int {
        (system?.count ?? 0) + tools.reduce(0) {
            $0 + $1.name.count + $1.description.count + String(decoding: $1.parametersJSON, as: UTF8.self).count
        } + messages.reduce(0) { total, message in
            message.content.reduce(total) { total, block in
                switch block {
                case .text(let text): total + text.count
                case .toolUse(let id, let name, let input): total + id.count + name.count + String(decoding: input, as: UTF8.self).count
                case .toolResult(let id, let content, _): total + id.count + content.count
                case .image: total
                }
            }
        }
    }
    /// What a request asks the provider to read, in bytes as sent: the system prompt, every block (an image as its base64) and the tool schemas.
    public static func inputBytes(_ messages: [LLMMessage], system: String?, tools: [LLMToolSchema] = []) -> Int {
        (system?.utf8.count ?? 0) + tools.reduce(0) { $0 + $1.name.utf8.count + $1.description.utf8.count + $1.parametersJSON.count }
            + messages.reduce(0) { total, message in
                message.content.reduce(total) { total, block in
                    switch block {
                    case .text(let text): total + text.utf8.count
                    case .toolUse(let id, let name, let input): total + id.utf8.count + name.utf8.count + input.count
                    case .toolResult(let id, let content, _): total + id.utf8.count + content.utf8.count
                    case .image(_, let base64, _, _): total + base64.utf8.count
                    }
                }
            }
    }
}
