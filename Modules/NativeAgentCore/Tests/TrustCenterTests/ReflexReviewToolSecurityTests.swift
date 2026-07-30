import Foundation
import Testing
@testable import TrustCenter
import PersistenceCore

@Test func SecurityCenter_reflexReview_isSignedAppDataWrite() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReflexReviewToolSecurity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    let envelope = await center.evaluateTool(
        tool: "reflex_review",
        input: [
            "candidate_id": .string("tool:tool-grep"),
            "decision": .string("approve"),
        ],
        origin: SecurityOriginContext(surface: "codex")
    )

    #expect(envelope.signedToolKnown)
    #expect(envelope.risk == "low")
    #expect(envelope.capabilities.contains("organism_state_write"))
    #expect(envelope.capabilities.contains("app_data_write"))
    #expect(!envelope.capabilities.contains("filesystem_write"))
    #expect(!envelope.capabilities.contains("process_spawn"))
    #expect(!envelope.capabilities.contains("external_send"))
    #expect(envelope.allowed)
}
