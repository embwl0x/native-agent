import Foundation
import ChatTurnRuntime
import PersistenceCore
import NativeAgentShared
import BackgroundLoops
// Blueprint: | `SlackSocketModeLoop+Media.swift` | `SlackSocketModeLoop`: inbound file parsing, bounded image hydration, attachment notices and uploadable image selection |

extension SlackSocketModeLoop {
    enum AttachmentFailure: Error {
        case unsupported, oversized, empty, limit
        case permanent(Int), transient(String)

        var notice: String {
            switch self {
            case .unsupported:
                return "attachment_unsupported: Expected an HTTPS JPEG, PNG, GIF or WebP image. Send a supported image or paste its text."
            case .oversized:
                return "attachment_oversized: Image exceeds the remaining byte limit (10 MB each, 20 MB total). Send a smaller image."
            case .empty:
                return "attachment_empty: Slack returned no bytes. Upload a nonempty image."
            case .limit:
                return "attachment_limit: At most four images and 20 MB total can be read. Send the remaining images in another message."
            case .permanent(let status):
                return "attachment_rejected: Slack download returned HTTP \(status). Check file access in Slack before sending it again."
            case .transient(let detail):
                return "attachment_download_failed: \(detail). Check the Slack connection before sending it again."
            }
        }
    }

    struct AttachmentHydration {
        let inbound: SlackInboundMessage
        let failures: [(index: Int, cause: AttachmentFailure)]
        var hasTransientFailure: Bool { failures.contains { if case .transient = $0.cause { return true }; return false } }
        var notice: String? {
            failures.isEmpty ? nil : failures.map { "Attachment \($0.index + 1): \($0.cause.notice)" }.joined(separator: "\n")
        }
    }

    func attachmentAwareReply(_ hydration: AttachmentHydration, original: SlackInboundMessage, sessionId: String) async throws -> SlackSocketModeReply {
        let inbound = hydration.inbound
        if inbound.text.isEmpty && inbound.attachments.isEmpty {
            return SlackSocketModeReply(text: hydration.notice ?? "No readable message was received.")
        }
        var reply = try await generateReply(inbound, sessionId: sessionId, sink: noticeSink(for: original))
        if let notice = hydration.notice { reply.text = notice + "\n\n" + reply.text }
        return reply
    }

    func hydratingAttachments(_ inbound: SlackInboundMessage) async -> AttachmentHydration {
        var attachments = inbound.attachments
        var failures: [(index: Int, cause: AttachmentFailure)] = []
        var remainingBytes = 20 * 1_024 * 1_024
        for (index, file) in inbound.files.enumerated() {
            guard index < 4, remainingBytes > 0 else { failures.append((index, .limit)); continue }
            do {
                let attachment = try await downloadInboundFile(
                    file,
                    maximumBytes: min(10 * 1_024 * 1_024, remainingBytes)
                )
                remainingBytes -= attachment.byteSize
                attachments.append(attachment)
            } catch {
                failures.append((index, (error as? AttachmentFailure) ?? .transient(Self.redact(error.localizedDescription))))
                await writeState([
                    "lastInboundAttachmentErrorAt": .string(Self.nowString()),
                    "lastInboundAttachmentError": .string(String(describing: error)),
                ])
            }
        }
        let text = !failures.isEmpty && (!inbound.text.isEmpty || !attachments.isEmpty)
            ? inbound.text + "\n\n[Slack attachment notice: " + failures.map { "Attachment \($0.index + 1): \($0.cause.notice)" }.joined(separator: "\n") + "]"
            : inbound.text
        let hydrated = SlackInboundMessage(
            eventId: inbound.eventId,
            teamId: inbound.teamId,
            channelId: inbound.channelId,
            userId: inbound.userId,
            eventType: inbound.eventType,
            text: text,
            ts: inbound.ts,
            threadTs: inbound.threadTs,
            channelType: inbound.channelType,
            isDirectMessage: inbound.isDirectMessage,
            files: inbound.files,
            attachments: attachments,
            opensReplyThread: inbound.opensReplyThread
        )
        return AttachmentHydration(inbound: hydrated, failures: failures)
    }

    private func downloadInboundFile(
        _ file: SlackInboundFile,
        maximumBytes: Int
    ) async throws -> ChatTurnRuntime.MultimodalAttachment {
        let mime = file.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let supportedMIMEs: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp"]
        guard supportedMIMEs.contains(mime),
              let url = URL(string: file.downloadURL), url.scheme?.lowercased() == "https" else {
            throw AttachmentFailure.unsupported
        }
        if let declared = file.byteSize, declared < 0 || declared > maximumBytes {
            throw AttachmentFailure.oversized
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(config.botToken)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AttachmentFailure.transient("Slack returned a non-HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            if (400..<500).contains(http.statusCode), ![408, 425, 429].contains(http.statusCode) {
                throw AttachmentFailure.permanent(http.statusCode)
            }
            throw AttachmentFailure.transient("Slack download returned HTTP \(http.statusCode)")
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            throw AttachmentFailure.oversized
        }
        var data = Data()
        data.reserveCapacity(min(file.byteSize ?? 0, maximumBytes))
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw AttachmentFailure.oversized
            }
            data.append(byte)
        }
        guard !data.isEmpty else { throw AttachmentFailure.empty }
        return ChatTurnRuntime.MultimodalAttachment(
            type: "image",
            base64: data.base64EncodedString(),
            mime: mime,
            name: file.name,
            byteSize: data.count
        )
    }

    static func inboundFiles(_ value: JSONValue?) -> [SlackInboundFile] {
        guard case .array(let rows)? = value else { return [] }
        return rows.compactMap { value in
            guard case .object(let file) = value,
                  let url = file["url_private_download"]?.stringValue ?? file["url_private"]?.stringValue,
                  let mime = file["mimetype"]?.stringValue else { return nil }
            let bytes: Int? = {
                switch file["size"] {
                case .int(let value)?: return Int(value)
                case .double(let value)?: return Int(exactly: value.rounded(.towardZero))
                default: return nil
                }
            }()
            return SlackInboundFile(
                downloadURL: url,
                mimeType: mime,
                name: file["name"]?.stringValue,
                byteSize: bytes
            )
        }
    }

    static func uploadableImageAttachments(
        _ attachments: [ChatTurnRuntime.MultimodalAttachment]
    ) -> [ChatTurnRuntime.MultimodalAttachment] {
        attachments.filter { attachment in
            attachment.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "image"
        }
    }
}
