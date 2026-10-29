import Foundation
import NativeAgentShared
import PersistenceCore
import BackgroundLoops
// Blueprint: | `SlackSocketModeLoop+Evidence.swift` | `SlackSocketModeLoop`: bounded receipts and errors, envelope evidence, diagnostic state patches, timestamps and secret redaction |

extension SlackSocketModeLoop {
    func recordReceipt(kind: String, inbound: SlackInboundMessage, reply: String) async {
        var row: [String: JSONValue] = [
            "id": .string(UUID().uuidString),
            "at": .string(Self.nowString()),
            "kind": .string(kind),
            "eventId": .string(inbound.eventId),
            "teamId": .string(inbound.teamId),
            "channelId": .string(inbound.channelId),
            "userId": .string(inbound.userId),
            "ts": .string(inbound.ts),
            "textPreview": .string(Self.preview(inbound.text)),
            "replyPreview": .string(Self.preview(reply)),
        ]
        if let threadTs = inbound.threadTs { row["threadTs"] = .string(threadTs) }
        var statePatch: [String: JSONValue] = [
            "lastReplyAt": .string(Self.nowString()),
            "lastReplyEventId": .string(inbound.eventId),
            "lastReplyChannelId": .string(inbound.channelId),
            "lastError": .null,
            "lastErrorAt": .null,
        ]
        do {
            try await appendJSONLCapped(
                .object(row),
                to: slackDir.appendingPathComponent("receipts.jsonl"),
                maxLines: feedRetention.maxLines,
                logLabel: "SlackSocketModeLoop.receipts",
                maxBytes: feedRetention.maxBytes,
                trimToBytes: feedRetention.trimToBytes
            )
            statePatch["lastReceiptFeedWriteError"] = .null
        } catch {
            statePatch["lastReceiptFeedWriteError"] = .string(Self.preview(String(describing: error), limit: 512))
        }
        await writeState(statePatch)
    }

    func recordEnvelope(envelope: [String: JSONValue], envelopeId: String?) async {
        var patch: [String: JSONValue] = [
            "lastEnvelopeAt": .string(Self.nowString()),
            "lastEnvelopeType": .string(envelope["type"]?.stringValue ?? "unknown"),
        ]
        if let envelopeId, !envelopeId.isEmpty {
            patch["lastEnvelopeId"] = .string(envelopeId)
        }
        if let payload = envelope["payload"]?.objectValue {
            if let payloadType = payload["type"]?.stringValue {
                patch["lastPayloadType"] = .string(payloadType)
            }
            if let event = payload["event"]?.objectValue {
                if let eventType = event["type"]?.stringValue {
                    patch["lastSlackEventType"] = .string(eventType)
                }
                if let channel = event["channel"]?.stringValue {
                    patch["lastEnvelopeChannelId"] = .string(channel)
                }
                if let channelType = event["channel_type"]?.stringValue {
                    patch["lastEnvelopeChannelType"] = .string(channelType)
                }
            }
        }
        await writeState(patch)
    }

    func recordIgnoredEnvelope(_ detail: (
        reason: String, envelopeType: String, eventType: String?, channelType: String?, channel: String?
    )) async {
        var statePatch: [String: JSONValue] = [
            "lastIgnoredAt": .string(Self.nowString()),
            "lastIgnoredReason": .string(detail.reason),
            "lastIgnoredEnvelopeType": .string(detail.envelopeType),
        ]
        if let value = detail.eventType { statePatch["lastIgnoredEventType"] = .string(value) }
        if let value = detail.channelType { statePatch["lastIgnoredChannelType"] = .string(value) }
        if let value = detail.channel { statePatch["lastIgnoredChannelId"] = .string(value) }
        await writeState(statePatch)
    }

    func recordError(context: String, error: Error, inbound: SlackInboundMessage? = nil) async {
        let safeError = Self.preview(String(describing: error), limit: 1_024)
        var row: [String: JSONValue] = [
            "id": .string(UUID().uuidString),
            "at": .string(Self.nowString()),
            "context": .string(context),
            "errorClass": .string(Self.errorClass(for: error)),
            "error": .string(safeError),
        ]
        if let inbound {
            row["eventId"] = .string(inbound.eventId)
            row["channelId"] = .string(inbound.channelId)
            row["userId"] = .string(inbound.userId)
            if config.ingressPolicy.denial(
                channelId: inbound.channelId, userId: inbound.userId,
                eventType: inbound.eventType, channelType: inbound.channelType,
                rawText: inbound.text
            ) == nil {
                row["textPreview"] = .string(Self.preview(inbound.text))
            }
        }
        var statePatch: [String: JSONValue] = [
            "lastError": .string("\(context): \(safeError)"),
            "lastErrorAt": .string(Self.nowString()),
        ]
        do {
            try await appendJSONLCapped(
                .object(row),
                to: slackDir.appendingPathComponent("errors.jsonl"),
                maxLines: feedRetention.maxLines,
                logLabel: "SlackSocketModeLoop.errors",
                maxBytes: feedRetention.maxBytes,
                trimToBytes: feedRetention.trimToBytes
            )
            statePatch["lastErrorFeedWriteError"] = .null
        } catch {
            statePatch["lastErrorFeedWriteError"] = .string(Self.preview(String(describing: error), limit: 512))
        }
        await writeState(statePatch)
    }

    @discardableResult
    func writeState(_ patch: [String: JSONValue]) async -> SlackRuntimeStateWriteOutcome {
        await SlackRuntimeStateStore.apply(
            patch,
            dataRoot: dataRoot
        )
    }

    private var slackDir: URL {
        dataRoot.appendingPathComponent("slack", isDirectory: true)
    }

    private static func preview(_ text: String, limit: Int = 240) -> String {
        let trimmed = redact(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "..."
    }

    static func nowString(_ date: Date = Date()) -> String {
        NativeTimestampFormat.fractionalZulu(date)
    }

    private static let authenticatedURL = try! NSRegularExpression(
        pattern: #"(?i)\b(?:wss?|https?)://[^\s\"<>?#]+[?#][^\s\"<>]*"#
    )

    static func redact(_ raw: String) -> String {
        // Socket errors embed authenticated URLs (sometimes more than once).
        // Retain the endpoint for diagnosis, never its query or fragment.
        return TurnSecretRedactor.redactText(
            TurnSecretRedactor.redactText(raw), patterns: [("AUTHENTICATED_URL", authenticatedURL)]
        ) { _, value in
            String(value.prefix { $0 != "?" && $0 != "#" }) + "?[REDACTED]"
        }
    }

    /// Stable diagnostic classes make the bounded feed rankable without
    /// retaining transport payloads or redacted error prose as an identifier.
    private static func errorClass(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if error is SlackSocketModeError { return "slack_api" }
        if let urlError = error as? URLError {
            return "url_error_\(urlError.errorCode)"
        }
        return "runtime_error"
    }
}
