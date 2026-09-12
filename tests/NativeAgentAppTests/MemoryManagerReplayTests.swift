import Foundation
import Testing
@testable import NativeAgentApp

/// The DEBUG-only entry point for the memory-manager replay, the shape
/// SimplicitySnapshots uses: the suite asserts the file stays out of release
/// builds, and runs the replay only when MEMORY_REPLAY_DIR asks for it.
///
///   MEMORY_REPLAY_DIR=workspace/reviews/memory-replay-2026-09-11 \
///     swift test --filter memoryManagerReplay
@Suite("Memory manager replay")
struct MemoryManagerReplayTests {
    @Test func memoryManagerReplayEntryPointStaysDebugOnly() async throws {
        let source = try String(
            contentsOf: AppSourceScraping.appSourcesRoot()
                .appendingPathComponent("MemoryManagerReplay.swift"),
            encoding: .utf8
        )
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "#if DEBUG")
        #expect(source.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"))
        #expect(lines.filter { $0.hasPrefix("#if") }.count == 1)
        #expect(lines.filter { $0.hasPrefix("#endif") }.count == 1)
        #expect(!lines.contains { $0.hasPrefix("#else") })
        // The replay must never write to memory. Absence of the write verbs is
        // the check that keeps it a read-only bed.
        #expect(!source.contains(".propose("))
        #expect(!source.contains("acceptProposal"))
        #if DEBUG
        if let output = ProcessInfo.processInfo.environment["MEMORY_REPLAY_DIR"] {
            try await MemoryManagerReplay.render(
                to: URL(fileURLWithPath: output, isDirectory: true)
            )
        }
        #endif
    }
}
