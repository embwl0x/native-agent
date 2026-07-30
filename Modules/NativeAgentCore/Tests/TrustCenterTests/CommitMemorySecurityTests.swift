import Testing
import Foundation
@testable import TrustCenter
import PersistenceCore

// commit_memory (Agent's memory WRITE path) must profile as a built-in,
// LOW-risk memory write — NOT shell / process_spawn / filesystem_write. The
// tool name contains "commit", which trips no keyword catcher in
// SecurityCenter.profile, so the explicit memory_write branch is what pins the
// shape. Asserted through the public evaluateTool envelope.

@Test func SecurityCenter_commitMemory_isLowRiskMemoryWrite() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CommitMemorySecurity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let center = SwiftNativeSecurityCenter(dataRoot: root)

    let envelope = await center.evaluateTool(
        tool: "commit_memory",
        input: ["text": .string("the user prefers concise replies"), "kind": .string("preference")],
        origin: SecurityOriginContext(surface: "chat")
    )

    // RISK PROFILE (the SecurityCenter wiring this change owns): low risk,
    // memory_write capability, recognized as a built-in/signed tool — NOT
    // shell / process_spawn / filesystem_write. The keyword catcher must not
    // have fired on "commit_memory".
    #expect(envelope.risk == "low")
    #expect(envelope.capabilities.contains("memory_write"))
    #expect(envelope.signedToolKnown)
    #expect(!envelope.capabilities.contains("shell"))
    #expect(!envelope.capabilities.contains("process_spawn"))
    #expect(!envelope.capabilities.contains("filesystem_write"))
    // rollback is only required for filesystem mutators — a memory write
    // must not be flagged for rollback.
    #expect(envelope.rollbackRequired == false)
    // NOTE: envelope.allowed reflects the AUTONOMY policy layer, not risk.
    // With no policy file the default is send_approval, so a hermetic
    // evaluate returns decision:.ask — that's the autonomy default, a
    // separate concern from the low-risk memory_write profile asserted above.
}
