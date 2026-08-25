import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

// Coverage ledger app.chat / api.ChatExportService.exportCurrentChat (UNCOVERED
// → COVERED).
//
// Silent-failure mode being pinned: `/export` is the only write this fence makes
// OUTSIDE the data root, and the composer reports "Chat exported to Downloads"
// on any non-throwing return. A transcript exported with rows missing (or a
// session id that escapes the Downloads directory) reports success just the
// same. The three error cases route to two different toast lanes, so a
// regression that turned one into a silent no-op would also read as success.
//
// Hermetic: the Downloads directory is redirected into a temp dir through the
// injectable `FileManager`, so nothing is written to the real ~/Downloads.

/// FileManager whose `.downloadsDirectory` lookup answers with a temp dir.
/// `nil` roots simulate the `downloadsUnavailable` branch.
private final class RedirectedDownloadsFileManager: FileManager, @unchecked Sendable {
    let redirect: URL?
    init(redirect: URL?) {
        self.redirect = redirect
        super.init()
    }
    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        guard directory == .downloadsDirectory else {
            return super.urls(for: directory, in: domainMask)
        }
        guard let redirect else { return [] }
        return [redirect]
    }
}

private func exportMessage(
    id: String,
    role: String,
    content: String,
    attachments: [PersistedAttachment] = []
) -> ChatMessage {
    var metadata: ChatMessageMetadata?
    if !attachments.isEmpty {
        var m = ChatMessageMetadata()
        m.attachments = attachments
        metadata = m
    }
    return ChatMessage(
        id: id,
        role: role,
        content: content,
        createdAt: "2026-08-23T00:00:00Z",
        metadata: metadata
    )
}

private func exportSession(id: String, title: String) throws -> ChatSession {
    try JSONDecoder().decode(ChatSession.self, from: Data("""
    {"id": "\(id)", "title": "\(title)", "createdAt": "2026-08-23T00:00:00Z"}
    """.utf8))
}

@Suite("Chat export service envelope")
struct ChatExportServiceEnvelopeTests {

    private func temporaryDownloads() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nativeagent-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Every message the transcript holds must survive the round-trip to disk.
    /// A truncated write is the failure the "exported" toast cannot see.
    @Test func exportedFileCarriesEveryVisibleRowAndTheLastRowInFull() throws {
        let downloads = try temporaryDownloads()
        defer { try? FileManager.default.removeItem(at: downloads) }

        let longTail = String(repeating: "tail-marker ", count: 400)
        let messages: [ChatMessage] = [
            exportMessage(id: "u1", role: "user", content: "first question"),
            exportMessage(id: "a1", role: "assistant", content: "first answer"),
            // Hidden in the transcript AND in exports — the memory-aid row.
            exportMessage(id: "s1", role: "system", content: "[tool: read_file] summary"),
            exportMessage(id: "u2", role: "user", content: "second question", attachments: [
                PersistedAttachment(id: "att-1", type: "file", mime: "application/pdf",
                                    name: "spec.pdf", byteSize: 12),
                PersistedAttachment(id: "att-2", type: "image", mime: "image/png",
                                    name: "shot.png", byteSize: 34),
            ]),
            exportMessage(id: "a2", role: "assistant", content: longTail),
        ]

        let url = try ChatExportService.export(
            session: try exportSession(id: "sess-export", title: "Export me"),
            sessionId: "sess-export",
            messages: messages,
            fileManager: RedirectedDownloadsFileManager(redirect: downloads),
            exportedAt: Date(timeIntervalSince1970: 1_756_000_000)
        )

        let written = try String(contentsOf: url, encoding: .utf8)
        // Envelope, not exact bytes: every visible row is present, the hidden
        // row is not, and the last row is present IN FULL (a short write is the
        // silent failure).
        for expected in ["first question", "first answer", "second question"] {
            #expect(written.contains(expected), "export dropped a row: \(expected)")
        }
        #expect(!written.contains("[tool: read_file] summary"),
                "the hidden [tool: memory-aid row leaked into the export")
        #expect(written.contains(longTail), "the final message was truncated in the export")
        #expect(written.contains("spec.pdf") && written.contains("shot.png"),
                "attachment references were dropped from the export")
        // One rendered block per visible role header.
        let userBlocks = written.components(separatedBy: "**User:**").count - 1
        let assistantBlocks = written.components(separatedBy: "**Assistant:**").count - 1
        #expect(userBlocks == 2)
        #expect(assistantBlocks == 2)
        // The bytes on disk are the whole rendering — nothing lost between
        // render and atomic write.
        let rendered = ChatExportService.sessionMarkdown(
            session: try exportSession(id: "sess-export", title: "Export me"),
            sessionId: "sess-export",
            messages: messages,
            exportedAt: Date(timeIntervalSince1970: 1_756_000_000)
        )
        #expect(written.count == rendered.count)
    }

    /// A hostile or path-shaped session id must never place the export outside
    /// the Downloads directory. This is the only write leaving the data root.
    @Test func sessionIdsCannotSteerTheExportOutOfDownloads() throws {
        let downloads = try temporaryDownloads()
        defer { try? FileManager.default.removeItem(at: downloads) }
        let manager = RedirectedDownloadsFileManager(redirect: downloads)

        for hostile in ["../../etc/passwd", "a/b/c", "  ", "sess:with/slash", String(repeating: "z", count: 300)] {
            let url = try ChatExportService.export(
                session: nil,
                sessionId: hostile,
                messages: [exportMessage(id: "a1", role: "assistant", content: "hi")],
                fileManager: manager,
                exportedAt: Date(timeIntervalSince1970: 1_756_000_000)
            )
            #expect(
                url.deletingLastPathComponent().standardizedFileURL.path
                    == downloads.standardizedFileURL.path,
                "export for session id \(hostile) landed outside Downloads at \(url.path)"
            )
            #expect(url.lastPathComponent.hasPrefix("NativeAgent-chat-"))
            #expect(url.pathExtension == "md")
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    /// Each refusal must THROW its own case. A branch that silently returned a
    /// URL (or the wrong error) shows the user a success toast.
    @Test func everyRefusalThrowsItsOwnCaseInsteadOfReportingSuccess() throws {
        let downloads = try temporaryDownloads()
        defer { try? FileManager.default.removeItem(at: downloads) }
        let manager = RedirectedDownloadsFileManager(redirect: downloads)
        let oneMessage = [exportMessage(id: "a1", role: "assistant", content: "hi")]

        #expect(throws: ChatExportError.noActiveSession) {
            try ChatExportService.export(
                session: nil, sessionId: "", messages: oneMessage, fileManager: manager
            )
        }
        #expect(throws: ChatExportError.noMessages) {
            try ChatExportService.export(
                session: nil, sessionId: "sess", messages: [], fileManager: manager
            )
        }
        #expect(throws: ChatExportError.downloadsUnavailable) {
            try ChatExportService.export(
                session: nil,
                sessionId: "sess",
                messages: oneMessage,
                fileManager: RedirectedDownloadsFileManager(redirect: nil)
            )
        }
        // Nothing was written by any refusal.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: downloads.path)
        #expect(leftovers.isEmpty, "a refused export still wrote \(leftovers)")
    }
}
