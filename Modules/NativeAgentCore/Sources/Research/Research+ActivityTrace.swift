import Privacy
import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `Research+ActivityTrace.swift` | `SwiftNativeResearchClient`: `recordActivity`, `recordTrace`, `pythonCodepointPrefix` |

extension SwiftNativeResearchClient {
    // Receipt append failures propagate even after the run itself persisted.

    /// Activity envelopes redact title, detail and payload; executionId is null.
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

    /// Trace envelopes redact title and payload; status is the nonempty payload status string or `ok`.
    func recordTrace(
        kind: String,
        title: String,
        payload: JSONValue
    ) async throws {
        let redactedPayload = NativeAgentSecretRedactor.redactValue(payload)
        var statusField = "ok"
        if case .object(let obj) = redactedPayload, case .string(let s) = obj["status"] ?? .null, !s.isEmpty {
            statusField = s
        }
        try await TurnTracePersistLane(standalonePath: tracesPath).appendChecked(
            TurnTraceEvent(kind: kind, title: NativeAgentSecretRedactor.redactText(title),
                status: statusField, payload: redactedPayload, createdAt: Self.isoTimestamp(Date())))
    }

    /// Clip to the first n Unicode code points rather than grapheme clusters.
    nonisolated static func pythonCodepointPrefix(_ value: String, _ n: Int) -> String {
        let scalars = value.unicodeScalars
        if scalars.count <= n { return value }
        return String(String.UnicodeScalarView(scalars.prefix(n)))
    }

}
