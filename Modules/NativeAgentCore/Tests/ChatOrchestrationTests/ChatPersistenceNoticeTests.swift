import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import DreamREMCycle
import ApprovalInbox
import MacIntegration
import CognitiveSubstrate

private let makeTempRoot: @Sendable (String) throws -> URL = makeChatOrchestrationTempRoot

// MARK: - M1 / M2 (honesty sweep, 2026-07-09): transcript writes fail loud
//
// The partial-reply rescue write and the tool-receipt write were both `try?`.
// The rescue write EXISTS to stop silent loss of a truncated reply — swallowing
// its own failure defeated the entire point — and a dropped tool receipt left
// the reloaded transcript showing a reply with no evidence of the tool that
// produced it. Both now log and raise a turn notice on the existing channel.

/// Forces the transcript append to fail by making the target message file a
/// DIRECTORY: bytes cannot be appended to it, and the lock sidecar cannot be
/// created under it either.
private func wedgeTranscriptPath(root: URL, sessionId: String) throws {
    let messages = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
    try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: messages.appendingPathComponent("\(sessionId).jsonl"),
        withIntermediateDirectories: true
    )
}

private actor NoticeCapture {
    private var notices: [(kind: String, text: String)] = []
    func record(_ kind: String, _ text: String) { notices.append((kind, text)) }
    func kinds() -> [String] { notices.map(\.kind) }
    func texts() -> [String] { notices.map(\.text) }
}

@Test
func persistPartial_writeFailure_raisesTurnNotice() async throws {
    let root = try makeTempRoot("partial-write-fail")
    let sessionId = "s-partial-fail"
    try wedgeTranscriptPath(root: root, sessionId: sessionId)
    let capture = NoticeCapture()

    await makeClientForNoticeTests(root: root).persistPartialIfNeeded(
        sessionId: sessionId,
        runId: "run-1",
        text: "half a reply the user already watched render",
        cancelled: false,
        onNotice: { kind, text in await capture.record(kind, text) }
    )

    let kinds = await capture.kinds()
    #expect(kinds == ["transcript_write_failed"], "a lost partial reply must not be silent")
    let texts = await capture.texts()
    #expect(texts.first?.contains("partial reply") == true)
}

@Test
func persistPartial_success_raisesNoNotice() async throws {
    let root = try makeTempRoot("partial-write-ok")
    let capture = NoticeCapture()

    await makeClientForNoticeTests(root: root).persistPartialIfNeeded(
        sessionId: "s-partial-ok",
        runId: "run-1",
        text: "a partial reply",
        cancelled: true,
        onNotice: { kind, text in await capture.record(kind, text) }
    )

    let kinds = await capture.kinds()
    #expect(kinds.isEmpty, "a successful write must stay quiet")
    let path = root
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
        .appendingPathComponent("s-partial-ok.jsonl")
    #expect(FileManager.default.fileExists(atPath: path.path))
}

@Test
func appendToolMessage_writeFailure_isThrowableNotSwallowed() async throws {
    let root = try makeTempRoot("tool-receipt-fail")
    let sessionId = "s-tool-fail"
    try wedgeTranscriptPath(root: root, sessionId: sessionId)

    // M2 is about the CALLER no longer swallowing this with `try?`; pin that the
    // failure is observable at the throw site in the first place.
    await #expect(throws: (any Error).self) {
        try await makeClientForNoticeTests(root: root).appendToolMessage(
            sessionId: sessionId,
            runId: "run-1",
            toolName: "read_file",
            inputJSON: "{}",
            resultSummary: "null",
            ok: true
        )
    }
}
