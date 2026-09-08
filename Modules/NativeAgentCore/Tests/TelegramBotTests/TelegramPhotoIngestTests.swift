import Testing
import Foundation
@testable import TelegramBot
import NativeAgentCore
import NativeAgentTestSupport
import PersistenceCore

// MARK: - telegram-vision-in (inbound photo ingestion)
//
// Recovers the daemon-era telegram_photo_attachment / max_bytes / downloader
// behaviour (commit 0f50aa30) on the Swift poll path. Hermetic: the Telegram
// getUpdates JSON is a fixture and the image download is a mock.

// Dedicated stub subclass for the photo-ingest suite. A SEPARATE class from
// the file's global MockURLProtocol so this @Suite(.serialized) suite can't
// clobber SwiftNativeTelegramBotPhaseBTests' handler when the two suites run
// in parallel — ConfigurableURLProtocolStub keys handler storage by concrete
// class, so distinct subclasses stay isolated (same hazard CmpMockURLProtocol
// avoids).
private final class PhotoMockURLProtocol: ConfigurableURLProtocolStub {}

private func photoMockSession(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
    PhotoMockURLProtocol.makeSession(handler: handler)
}

private func readTracesJSONL(_ root: URL) -> [JSONValue] {
    let path = root
        .appendingPathComponent("traces", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    guard let data = try? Data(contentsOf: path),
          let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
        try? JSONValue.parse(Data(String(line).utf8))
    }
}

@Suite(.serialized)
struct TelegramPhotoIngestTests {

    // A photo downloader that returns fixed bytes (success), mirroring the real
    // two-stage TelegramMediaDownloader's output shape.
    private struct FakePhotoDownloader: TelegramMediaDownloading {
        let bytes: Data
        let filename: String?
        func download(token: String, attachment: TelegramMediaAttachment, maxBytes: Int) async throws -> TelegramMediaAttachment {
            TelegramMediaAttachment(
                kind: attachment.kind,
                fileId: attachment.fileId,
                mimeType: attachment.mimeType,
                sizeBytes: bytes.count,
                bytes: bytes,
                captureFilename: filename
            )
        }
    }

    private struct FailingPhotoDownloader: TelegramMediaDownloading {
        let error: TelegramMediaDownloadError
        func download(token: String, attachment: TelegramMediaAttachment, maxBytes: Int) async throws -> TelegramMediaAttachment {
            throw error
        }
    }

    // MARK: pure extraction

    @Test func photoAttachment_picks_largest_variant() {
        let msg = TelegramMessage(
            messageId: 1, chatId: 9, date: 1,
            extras: .object(["photo": .array([
                .object(["file_id": .string("small"), "width": .int(90), "height": .int(60)]),
                .object(["file_id": .string("big"), "width": .int(1280), "height": .int(720)]),
                .object(["file_id": .string("mid"), "width": .int(320), "height": .int(240)]),
            ])])
        )
        let att = TelegramPollLoop.photoAttachment(from: msg)
        #expect(att?.kind == "photo")
        #expect(att?.fileId == "big")
    }

    @Test func photoAttachment_accepts_image_document() {
        let msg = TelegramMessage(
            messageId: 1, chatId: 9, date: 1,
            extras: .object(["document": .object([
                "file_id": .string("doc1"), "mime_type": .string("image/png"),
            ])])
        )
        let att = TelegramPollLoop.photoAttachment(from: msg)
        #expect(att?.kind == "document")
        #expect(att?.fileId == "doc1")
        #expect(att?.mimeType == "image/png")
    }

    @Test func photoAttachment_rejects_non_image_document_and_text() {
        let pdf = TelegramMessage(messageId: 1, chatId: 9, date: 1,
            extras: .object(["document": .object(["file_id": .string("x"), "mime_type": .string("application/pdf")])]))
        #expect(TelegramPollLoop.photoAttachment(from: pdf) == nil)
        let textOnly = TelegramMessage(messageId: 1, chatId: 9, text: "hi", date: 1)
        #expect(TelegramPollLoop.photoAttachment(from: textOnly) == nil)
    }

    @Test func caption_extracted_from_extras() {
        let msg = TelegramMessage(messageId: 1, chatId: 9, date: 1,
            extras: .object(["caption": .string("  look at this  ")]))
        #expect(TelegramPollLoop.caption(from: msg) == "look at this")
        let blank = TelegramMessage(messageId: 1, chatId: 9, date: 1,
            extras: .object(["caption": .string("   ")]))
        #expect(TelegramPollLoop.caption(from: blank) == nil)
    }

    @Test func imageMime_resolves_from_suffix_and_fallback() {
        #expect(TelegramPollLoop.imageMime(forFilename: "x.png", fallbackMime: nil) == "image/png")
        #expect(TelegramPollLoop.imageMime(forFilename: "x.jpeg", fallbackMime: nil) == "image/jpeg")
        #expect(TelegramPollLoop.imageMime(forFilename: nil, fallbackMime: "image/webp") == "image/webp")
        // unknown suffix -> jpeg default
        #expect(TelegramPollLoop.imageMime(forFilename: "x.dat", fallbackMime: nil) == "image/jpeg")
    }

    // MARK: full-loop — success: image bytes land on the turn

    @Test func photoOnly_downloads_and_attaches_image_to_turn() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_photo_ok_\(UUID().uuidString)", isDirectory: true)
        let offset = root.appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        let raw = #"""
        {"ok":true,"result":[{"update_id":100,"message":{"message_id":5,"chat":{"id":77},"from":{"id":11},"photo":[{"file_id":"small","width":90,"height":60},{"file_id":"big","width":1280,"height":720}],"date":1}}]}
        """#
        let session = photoMockSession { req in (makeResponse(req.url!, 200), Data(raw.utf8)) }

        actor Capture {
            var sent: [String] = []
            var handlerText: String?
            var attachmentCount = 0
            var firstAttachmentBytes: Data?
            var firstAttachmentMime: String?
            func note(_ t: String) { sent.append(t) }
            func handler(_ text: String, _ atts: [TelegramMediaAttachment]) {
                handlerText = text
                attachmentCount = atts.count
                firstAttachmentBytes = atts.first?.bytes
                firstAttachmentMime = atts.first?.mimeType
            }
            func snap() -> ([String], String?, Int, Data?, String?) {
                (sent, handlerText, attachmentCount, firstAttachmentBytes, firstAttachmentMime)
            }
        }
        let cap = Capture()
        let imageBytes = Data("PNGDATA".utf8)

        let loop = TelegramPollLoop(
            interval: 60, token: tokenStr, allowedChatIds: [77], session: session, dataRoot: root, offsetURL: offset,
            sendMessage: { _, _, text in await cap.note(text) },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            attachmentChatHandler: { _, text, atts, _, _ in
                await cap.handler(text, atts)
                return "I see the image"
            },
            photoDownloader: FakePhotoDownloader(bytes: imageBytes, filename: "big.png"),
            typingRefreshNanoseconds: 0
        )
        await loop.tick()

        let (sent, handlerText, attCount, attBytes, attMime) = await cap.snap()
        // The model got a non-empty synthetic prompt + exactly the image.
        #expect(handlerText?.contains("no caption") == true)
        #expect(attCount == 1)
        #expect(attBytes == imageBytes)
        #expect(attMime == "image/png")
        // The reply was sent to the user.
        #expect(sent.contains("I see the image"))

        let receipts = try readTelegramJSONL(root, "receipts.jsonl")
        #expect(receipts.contains { row in
            if case .object(let o) = row, o["kind"] == .string("photo_reply") { return true }
            return false
        })
    }

    @Test func captionedPhoto_uses_caption_as_prompt() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_photo_caption_\(UUID().uuidString)", isDirectory: true)
        let offset = root.appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        let raw = #"""
        {"ok":true,"result":[{"update_id":101,"message":{"message_id":6,"chat":{"id":77},"from":{"id":11},"photo":[{"file_id":"big","width":800,"height":600}],"caption":"what is this?","date":1}}]}
        """#
        let session = photoMockSession { req in (makeResponse(req.url!, 200), Data(raw.utf8)) }

        actor Capture {
            var handlerText: String?
            var attachmentCount = 0
            func handler(_ text: String, _ atts: [TelegramMediaAttachment]) { handlerText = text; attachmentCount = atts.count }
            func snap() -> (String?, Int) { (handlerText, attachmentCount) }
        }
        let cap = Capture()

        let loop = TelegramPollLoop(
            interval: 60, token: tokenStr, allowedChatIds: [77], session: session, dataRoot: root, offsetURL: offset,
            sendMessage: { _, _, _ in },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            attachmentChatHandler: { _, text, atts, _, _ in await cap.handler(text, atts); return "ok" },
            photoDownloader: FakePhotoDownloader(bytes: Data("IMG".utf8), filename: "p.jpg"),
            typingRefreshNanoseconds: 0
        )
        await loop.tick()

        let (handlerText, attCount) = await cap.snap()
        #expect(handlerText == "what is this?")
        #expect(attCount == 1)
    }

    // MARK: tripwire — oversize

    @Test func oversizePhoto_emits_trace_and_user_reply() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_photo_oversize_\(UUID().uuidString)", isDirectory: true)
        let offset = root.appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        let raw = #"""
        {"ok":true,"result":[{"update_id":102,"message":{"message_id":7,"chat":{"id":77},"from":{"id":11},"photo":[{"file_id":"huge","width":4000,"height":3000}],"date":1}}]}
        """#
        let session = photoMockSession { req in (makeResponse(req.url!, 200), Data(raw.utf8)) }

        actor Capture {
            var sent: [String] = []
            var handlerCalled = false
            func note(_ t: String) { sent.append(t) }
            func markHandler() { handlerCalled = true }
            func snap() -> ([String], Bool) { (sent, handlerCalled) }
        }
        let cap = Capture()

        let loop = TelegramPollLoop(
            interval: 60, token: tokenStr, allowedChatIds: [77], session: session, dataRoot: root, offsetURL: offset,
            sendMessage: { _, _, text in await cap.note(text) },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            attachmentChatHandler: { _, _, _, _, _ in await cap.markHandler(); return "should not run" },
            photoDownloader: FailingPhotoDownloader(error: .oversized(reportedBytes: 20 * 1024 * 1024, capBytes: 10 * 1024 * 1024)),
            typingRefreshNanoseconds: 0
        )
        await loop.tick()

        let (sent, handlerCalled) = await cap.snap()
        // Tripwire: user got a visible "couldn't process that image" reply.
        #expect(sent.contains { $0.contains("couldn't process that image") })
        #expect(sent.contains { $0.contains("too large") })
        // The chat handler must NOT have been called (no blind text reply).
        #expect(handlerCalled == false)

        // Tripwire trace landed in traces/events.jsonl.
        let traces = readTracesJSONL(root)
        let dropped = traces.first { row in
            if case .object(let o) = row, o["kind"] == .string("telegram.attachment_dropped") { return true }
            return false
        }
        #expect(dropped != nil)
        if case .object(let o)? = dropped, case .object(let payload)? = o["payload"] {
            #expect(payload["attachmentKind"] == .string("photo"))
            if case .string(let reason)? = payload["reason"] {
                #expect(reason.contains("too large"))
                #expect(!reason.contains(tokenStr))
            } else { Issue.record("missing reason") }
        } else { Issue.record("malformed dropped trace") }
    }

    // MARK: tripwire — download failure

    @Test func photoDownloadFailure_emits_trace_and_user_reply() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_photo_dlfail_\(UUID().uuidString)", isDirectory: true)
        let offset = root.appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        let raw = #"""
        {"ok":true,"result":[{"update_id":103,"message":{"message_id":8,"chat":{"id":77},"from":{"id":11},"photo":[{"file_id":"f","width":800,"height":600}],"date":1}}]}
        """#
        let session = photoMockSession { req in (makeResponse(req.url!, 200), Data(raw.utf8)) }

        actor Capture {
            var sent: [String] = []
            func note(_ t: String) { sent.append(t) }
            func snap() -> [String] { sent }
        }
        let cap = Capture()

        let loop = TelegramPollLoop(
            interval: 60, token: tokenStr, allowedChatIds: [77], session: session, dataRoot: root, offsetURL: offset,
            sendMessage: { _, _, text in await cap.note(text) },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            attachmentChatHandler: { _, _, _, _, _ in "should not run" },
            photoDownloader: FailingPhotoDownloader(error: .httpError(status: 502)),
            typingRefreshNanoseconds: 0
        )
        await loop.tick()

        let sent = await cap.snap()
        #expect(sent.contains { $0.contains("couldn't process that image") })

        let traces = readTracesJSONL(root)
        #expect(traces.contains { row in
            if case .object(let o) = row, o["kind"] == .string("telegram.attachment_dropped") { return true }
            return false
        })

        // The error was also recorded (token-redacted) in errors.jsonl.
        let errors = try readTelegramJSONL(root, "errors.jsonl")
        #expect(errors.contains { row in
            if case .object(let o) = row, o["context"] == .string("photo_ingest") { return true }
            return false
        })
    }

    // MARK: tripwire — no downloader wired (ingestion disabled)

    @Test func photo_withNoDownloader_emits_trace_and_user_reply() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_photo_nodl_\(UUID().uuidString)", isDirectory: true)
        let offset = root.appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        let raw = #"""
        {"ok":true,"result":[{"update_id":104,"message":{"message_id":9,"chat":{"id":77},"from":{"id":11},"photo":[{"file_id":"f","width":800,"height":600}],"date":1}}]}
        """#
        let session = photoMockSession { req in (makeResponse(req.url!, 200), Data(raw.utf8)) }

        actor Capture {
            var sent: [String] = []
            func note(_ t: String) { sent.append(t) }
            func snap() -> [String] { sent }
        }
        let cap = Capture()

        let loop = TelegramPollLoop(
            interval: 60, token: tokenStr, allowedChatIds: [77], session: session, dataRoot: root, offsetURL: offset,
            sendMessage: { _, _, text in await cap.note(text) },
            sendChatAction: { _, _, _ in },
            sendMessageReturningId: discardTurnCardSend,
            editMessageText: discardTurnCardEdit,
            turnCardMinimumEditIntervalSeconds: 0,
            turnCardHeartbeatNanoseconds: 0,
            attachmentChatHandler: { _, _, _, _, _ in "should not run" },
            photoDownloader: nil,
            typingRefreshNanoseconds: 0
        )
        await loop.tick()

        let sent = await cap.snap()
        #expect(sent.contains { $0.contains("couldn't process that image") })
        let traces = readTracesJSONL(root)
        #expect(traces.contains { row in
            if case .object(let o) = row, o["kind"] == .string("telegram.attachment_dropped") { return true }
            return false
        })
    }

    @Test func attachmentDroppedNotice_redacts_token() {
        // _tgRedactToken matches the real bot<digits>:<secret> token shape.
        let withToken = "failed at https://api.telegram.org/bot7123456789:AAH-secret_Token123/getFile"
        let notice = TelegramPollLoop.attachmentDroppedNotice(reason: withToken)
        #expect(!notice.contains("AAH-secret_Token123"))
        #expect(notice.contains("couldn't process that image"))
    }
}
