import Foundation
import Testing
@testable import ProviderRouting
import NativeAgentCore
import PersistenceCore

@Suite(.serialized) struct ProviderStreamGuardTests {
    @Test func cleanStreamPassesThroughChunksAndCompletion() async throws {
        let upstream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("a")
            continuation.yield("b")
            continuation.finish()
        }
        let stream = ProviderStreamGuard.wrap(
            upstream,
            config: ProviderStreamGuardConfig(idleTimeout: 5, wallTimeout: 10),
            providerLabel: "test-provider"
        )

        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }

        #expect(chunks == ["a", "b"])
    }

    @Test func cleanStructuredStreamPassesThroughEventsAndCompletion() async throws {
        let upstream = AsyncThrowingStream<LLMMessageStreamEvent, Error> { continuation in
            continuation.yield(.textDelta("a"))
            continuation.yield(.toolCall(LLMStreamToolCall(id: "call-1", name: "read_file", inputJSON: Data("{}".utf8))))
            continuation.finish()
        }
        let stream = ProviderStreamGuard.wrap(
            upstream,
            config: ProviderStreamGuardConfig(idleTimeout: 5, wallTimeout: 10),
            providerLabel: "test-provider"
        )

        var events: [LLMMessageStreamEvent] = []
        for try await event in stream {
            events.append(event)
        }

        #expect(events == [
            .textDelta("a"),
            .toolCall(LLMStreamToolCall(id: "call-1", name: "read_file", inputJSON: Data("{}".utf8))),
        ])
    }

    @Test func idleClockWaitsForProducerAdmissionButWallClockDoesNot() async throws {
        let gate = StreamGuardAdmissionGate()
        let upstream = cleanStream(["ready"])
        let stream = ProviderStreamGuard._wrapForTesting(
            upstream,
            config: ProviderStreamGuardConfig(
                idleTimeout: 0.03,
                wallTimeout: 10,
                checkInterval: 0.005
            ),
            providerLabel: "gated-provider",
            beforeProducerAdmission: { await gate.holdProducer() },
            watchdogStarted: { await gate.markWatchdogStarted() }
        )

        let collector = Task { () -> (chunks: [String], error: Error?) in
            var chunks: [String] = []
            let error = await collect(stream: stream, chunks: &chunks)
            return (chunks, error)
        }
        await gate.waitUntilProducerAndWatchdogStarted()
        // Keep the producer unadmitted past the complete idle window while the
        // watchdog is definitely running. This was the loaded false timeout.
        try await Task.sleep(for: .milliseconds(80))
        await gate.releaseProducer()

        let result = await collector.value
        #expect(result.chunks == ["ready"])
        #expect(result.error == nil)
    }

    @Test func wallClockCanExpireBeforeProducerAdmission() async throws {
        let gate = StreamGuardAdmissionGate()
        let stream = ProviderStreamGuard._wrapForTesting(
            cleanStream(["too-late"]),
            config: ProviderStreamGuardConfig(
                idleTimeout: 0.01,
                wallTimeout: 0.05,
                checkInterval: 0.005
            ),
            providerLabel: "gated-provider",
            beforeProducerAdmission: { await gate.holdProducer() },
            watchdogStarted: { await gate.markWatchdogStarted() }
        )

        let collector = Task { () -> (chunks: [String], error: Error?) in
            var chunks: [String] = []
            let error = await collect(stream: stream, chunks: &chunks)
            return (chunks, error)
        }
        await gate.waitUntilProducerAndWatchdogStarted()
        let result = await collector.value
        await gate.releaseProducer()

        #expect(result.chunks.isEmpty)
        let error = try #require(result.error as? LLMError)
        if case .transient(let message) = error {
            #expect(message.contains("wall timeout"))
        } else {
            Issue.record("expected wall timeout, got \(error)")
        }
    }

    @Test func idleTimeoutCancelsUpstreamStream() async throws {
        let termination = TerminationFlag()
        let upstream = hangingStream(initialChunk: "first", termination: termination)
        let stream = ProviderStreamGuard.wrap(
            upstream,
            config: ProviderStreamGuardConfig(idleTimeout: 0.05, wallTimeout: 10),
            providerLabel: "test-provider"
        )

        var chunks: [String] = []
        let thrown = await collect(stream: stream, chunks: &chunks)

        #expect(chunks == ["first"])
        let err = try #require(thrown as? LLMError)
        if case .transient(let message) = err {
            #expect(message.contains("idle timeout"))
            #expect(message.contains("test-provider"))
        } else {
            Issue.record("expected idle transient, got \(err)")
        }
        #expect(await termination.waitUntilSet(), "idle timeout did not cancel upstream stream")
    }

    @Test func wallTimeoutCancelsActiveButOverlongStream() async throws {
        let termination = TerminationFlag()
        let upstream = tickingStream(termination: termination)
        let stream = ProviderStreamGuard.wrap(
            upstream,
            config: ProviderStreamGuardConfig(idleTimeout: 0.25, wallTimeout: 0.08),
            providerLabel: "test-provider"
        )

        var chunks: [String] = []
        let thrown = await collect(stream: stream, chunks: &chunks)

        #expect(chunks.isEmpty == false)
        let err = try #require(thrown as? LLMError)
        if case .transient(let message) = err {
            #expect(message.contains("wall timeout"))
            #expect(message.contains("test-provider"))
        } else {
            Issue.record("expected wall transient, got \(err)")
        }
        #expect(await termination.waitUntilSet(), "wall timeout did not cancel upstream stream")
    }

    @Test func swiftNativeLLMClientAppliesGuardAtSharedRoutingLayer() async throws {
        let termination = TerminationFlag()
        let codex = GuardedAdapter(streamFactory: {
            hangingStream(initialChunk: nil, termination: termination)
        })
        let client = SwiftNativeLLMClient(
            router: GuardRouter(chatModel: "llama-3"),
            codex: codex,
            anthropic: GuardedAdapter(streamFactory: { cleanStream(["anthropic"]) }),
            openAI: GuardedAdapter(streamFactory: { cleanStream(["openai"]) }),
            streamGuardConfig: ProviderStreamGuardConfig(idleTimeout: 0.05, wallTimeout: 10),
            moonshotCatalogDataRoot: hermeticMoonshotCatalogDataRoot()
        )

        var chunks: [String] = []
        let thrown = await collect(
            stream: client.stream(prompt: "p", system: nil, model: "llama-3"),
            chunks: &chunks
        )

        #expect(chunks.isEmpty)
        let err = try #require(thrown as? LLMError)
        if case .transient(let message) = err {
            #expect(message.contains("idle timeout"))
            #expect(message.contains("codex"))
        } else {
            Issue.record("expected routed idle transient, got \(err)")
        }
        #expect(await termination.waitUntilSet(), "routed guard did not cancel adapter stream")
    }

    @Test func swiftNativeLLMClientAppliesGuardToStructuredRoutingLayer() async throws {
        let termination = TerminationFlag()
        let codex = GuardedAdapter(
            streamFactory: { cleanStream(["unused"]) },
            messageStreamFactory: {
                hangingMessageStream(initialEvent: nil, termination: termination)
            }
        )
        let client = SwiftNativeLLMClient(
            router: GuardRouter(chatModel: "llama-3"),
            codex: codex,
            anthropic: GuardedAdapter(streamFactory: { cleanStream(["anthropic"]) }),
            openAI: GuardedAdapter(streamFactory: { cleanStream(["openai"]) }),
            streamGuardConfig: ProviderStreamGuardConfig(idleTimeout: 0.05, wallTimeout: 10),
            moonshotCatalogDataRoot: hermeticMoonshotCatalogDataRoot()
        )

        var events: [LLMMessageStreamEvent] = []
        let thrown = await collectEvents(
            stream: client.streamMessages(
                messages: [.user("p")],
                system: nil,
                model: "llama-3",
                surface: "chat",
                tools: nil
            ),
            events: &events
        )

        #expect(events.isEmpty)
        let err = try #require(thrown as? LLMError)
        if case .transient(let message) = err {
            #expect(message.contains("idle timeout"))
            #expect(message.contains("codex"))
        } else {
            Issue.record("expected structured idle transient, got \(err)")
        }
        #expect(await termination.waitUntilSet(), "structured routed guard did not cancel adapter stream")
    }
}

private final class TerminationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func waitUntilSet(timeout: Duration = .seconds(5)) async -> Bool {
        // The wrapper has already surfaced its exact timeout before this wait.
        // Here we prove downstream cancellation reaches the upstream stream;
        // use a monotonic deadline rather than 100 assumed 10 ms scheduler
        // slices, which can stretch and exhaust under the canonical parallel
        // provider shard even while cancellation is correctly in flight.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if get() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return get()
    }
}

private actor StreamGuardAdmissionGate {
    private var producerWaiting = false
    private var watchdogRunning = false
    private var released = false
    private var producerWaiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []

    func holdProducer() async {
        producerWaiting = true
        notifyObserversIfReady()
        guard !released else { return }
        await withCheckedContinuation { continuation in
            producerWaiters.append(continuation)
        }
    }

    func markWatchdogStarted() {
        watchdogRunning = true
        notifyObserversIfReady()
    }

    func waitUntilProducerAndWatchdogStarted() async {
        guard !producerWaiting || !watchdogRunning else { return }
        await withCheckedContinuation { continuation in
            observers.append(continuation)
        }
    }

    func releaseProducer() {
        released = true
        let waiters = producerWaiters
        producerWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func notifyObserversIfReady() {
        guard producerWaiting, watchdogRunning else { return }
        let ready = observers
        observers.removeAll()
        for observer in ready {
            observer.resume()
        }
    }
}

private func collect(
    stream: AsyncThrowingStream<String, Error>,
    chunks: inout [String]
) async -> Error? {
    do {
        for try await chunk in stream {
            chunks.append(chunk)
        }
        return nil
    } catch {
        return error
    }
}

private func collectEvents(
    stream: AsyncThrowingStream<LLMMessageStreamEvent, Error>,
    events: inout [LLMMessageStreamEvent]
) async -> Error? {
    do {
        for try await event in stream {
            events.append(event)
        }
        return nil
    } catch {
        return error
    }
}

private func cleanStream(_ chunks: [String]) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        for chunk in chunks {
            continuation.yield(chunk)
        }
        continuation.finish()
    }
}

private func hangingStream(
    initialChunk: String?,
    termination: TerminationFlag
) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            if let initialChunk {
                continuation.yield(initialChunk)
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            termination.set()
            task.cancel()
        }
    }
}

private func hangingMessageStream(
    initialEvent: LLMMessageStreamEvent?,
    termination: TerminationFlag
) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            if let initialEvent {
                continuation.yield(initialEvent)
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            termination.set()
            task.cancel()
        }
    }
}

private func tickingStream(termination: TerminationFlag) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            var count = 0
            while !Task.isCancelled {
                continuation.yield("tick-\(count)")
                count += 1
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            termination.set()
            task.cancel()
        }
    }
}

private struct GuardRouter: ProviderRoutingProtocol {
    var chatModel: String
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult {
        ProviderTestResult(rawResponse: .object([:]))
    }
    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        ["chat": SurfacePreference(surface: "chat", model: chatModel, reasoningEffort: "high")]
    }
}

private final class GuardedAdapter: LLMAdapter, @unchecked Sendable {
    let providerId = "guarded"
    private let streamFactory: @Sendable () -> AsyncThrowingStream<String, Error>
    private let messageStreamFactory: @Sendable () -> AsyncThrowingStream<LLMMessageStreamEvent, Error>

    init(
        streamFactory: @escaping @Sendable () -> AsyncThrowingStream<String, Error>,
        messageStreamFactory: @escaping @Sendable () -> AsyncThrowingStream<LLMMessageStreamEvent, Error> = {
            AsyncThrowingStream { $0.finish() }
        }
    ) {
        self.streamFactory = streamFactory
        self.messageStreamFactory = messageStreamFactory
    }

    func complete(prompt: String, system: String?, model: String) async throws -> String {
        ""
    }

    func stream(prompt: String, system: String?, model: String) -> AsyncThrowingStream<String, Error> {
        streamFactory()
    }

    func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        messageStreamFactory()
    }
}
