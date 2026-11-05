import Privacy
import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `Research+ActivityTrace.swift` | `SwiftNativeResearchClient`: `recordActivity`, `recordTrace`, `pythonCodepointPrefix` |

extension SwiftNativeResearchClient {
    // Receipt append failures propagate even after the run itself persisted.

    /// Redact activity fields before publishing them; execution identity is not part of the activity envelope.
    func recordActivity(
        kind: String,
        title: String,
        detail: String,
        status: String,
        payload: JSONValue
    ) async throws {
        let event = SwiftNativePersistenceCore.activityEvent(
            id: UUID().uuidString.lowercased(),
            kind: kind,
            title: NativeAgentSecretRedactor.redactText(title),
            detail: NativeAgentSecretRedactor.redactText(detail),
            status: status,
            executionId: nil,
            payload: NativeAgentSecretRedactor.redactValue(payload),
            createdAt: Self.isoTimestamp(Date())
        )
        try await SwiftNativePersistenceCore.appendActivityEvent(
            event,
            to: activityPath,
            logLabel: "Research"
        )
    }

    func recordTrace(
        kind: String,
        title: String,
        payload: JSONValue,
        turn: Turn
    ) async throws {
        let redactedPayload = NativeAgentSecretRedactor.redactValue(payload)
        var statusField = "ok"
        if case .object(let obj) = redactedPayload, case .string(let s) = obj["status"] ?? .null, !s.isEmpty {
            statusField = s
        }
        try await TurnTracePersistLane(dataRootOverride: receiptsDir.deletingLastPathComponent()).appendChecked(
            TurnTraceEvent(kind: kind, title: NativeAgentSecretRedactor.redactText(title),
                status: statusField, payload: redactedPayload, createdAt: Self.isoTimestamp(Date()), turn: turn))
    }

    /// Clip by Unicode code points to preserve the caller's counting contract rather than grapheme count.
    nonisolated static func pythonCodepointPrefix(_ value: String, _ n: Int) -> String {
        let scalars = value.unicodeScalars
        if scalars.count <= n { return value }
        return String(String.UnicodeScalarView(scalars.prefix(n)))
    }

}
