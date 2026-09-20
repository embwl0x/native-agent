import Foundation
import Testing
@testable import MemoryV2

@Suite("Embedding load sharing")
struct EmbeddingLoadSharingTests {
    @Test func concurrentColdRequestsLoadOneModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = DispatchSemaphore(value: 0)
        let attempted = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let calls = Calls()
        let provider = ManagedEmbeddingProvider(
            dataRoot: root,
            loader: { _ in
                calls.increment()
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
                return MockEmbeddingProvider(dimensions: 3)
            },
            availabilityProbe: { true }
        )
        let first = Task.detached { try await provider.embed(["first"]) }
        #expect(await wait(entered, seconds: 5) == .success)
        let second = Task.detached {
            attempted.signal()
            return try await provider.embed(["second"])
        }
        #expect(await wait(attempted, seconds: 5) == .success)
        // A second loader must not enter while the first model is loading.
        let duplicateLoad = await wait(entered, seconds: 0.2)
        release.signal()
        release.signal()
        #expect(duplicateLoad == .timedOut)
        #expect(try await first.value.first?.count == 3)
        #expect(try await second.value.first?.count == 3)
        #expect(calls.count == 1)
        #expect(provider.snapshot().loadCount == 1)
    }

    private func wait(_ semaphore: DispatchSemaphore, seconds: Double) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + seconds))
            }
        }
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
}
