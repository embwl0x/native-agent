import Foundation
import Testing
import PersistenceCore
@testable import NativeAgentApp

// Board LOW (2026-07-09): the debugSessionIds FIFO ring had no test. M9 bounded
// what used to be an insert-only set; nothing pinned the bound, so a regression
// that dropped the eviction would have shipped silently.

private func makeDebugSessionTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("debug-session-cap-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct DebugSessionIdsCapTests {
    @Test func markSessionDebugCapsTheRingAtItsMaximum() async throws {
        let root = try makeDebugSessionTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(dataRoot: root)

        let cap = NativeCognitionRuntime.maximumDebugSessionIds
        let overflow = 44
        for i in 0..<(cap + overflow) {
            await runtime.markSessionDebug("session-\(i)")
        }

        let ids = await runtime.debugSessionIds
        #expect(ids.count == cap)
        // The oldest markings aged out, the newest survived: FIFO, not random.
        #expect(!ids.contains("session-0"))
        #expect(!ids.contains("session-\(overflow - 1)"))
        #expect(ids.contains("session-\(overflow)"))
        #expect(ids.contains("session-\(cap + overflow - 1)"))
    }

    @Test func markSessionDebugIsIdempotentAndDoesNotEvictOnRemark() async throws {
        let root = try makeDebugSessionTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(dataRoot: root)

        let cap = NativeCognitionRuntime.maximumDebugSessionIds
        for i in 0..<cap { await runtime.markSessionDebug("session-\(i)") }
        // Re-marking an already-debug session must not append a second order
        // entry — that would evict a live session for no reason.
        for _ in 0..<10 { await runtime.markSessionDebug("session-0") }

        let ids = await runtime.debugSessionIds
        #expect(ids.count == cap)
        #expect(ids.contains("session-0"))
    }

    // NOT covered: markSessionDebug also evicts the stale id from
    // pendingDebugReplySessionIds. That set is only ever populated from inside
    // the actor (NativeCognitionRuntime+Events), with no seam to seed it from a
    // test, so pinning that line would mean adding production API for the test's
    // benefit alone. Left uncovered deliberately rather than faked.
}
