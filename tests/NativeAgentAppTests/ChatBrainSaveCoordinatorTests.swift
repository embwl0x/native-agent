import Foundation
import Testing
@testable import NativeAgentApp

private struct ChatBrainFixtureFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
private final class ChatBrainWriteHarness {
    typealias Selection = AppModel.ChatBrainSelection
    typealias Receipt = AppModel.ChatBrainWriteReceipt

    private var pending: [(Selection, CheckedContinuation<Receipt, any Error>)] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var calls: [Selection] = []

    func write(_ selection: Selection) async throws -> Receipt {
        calls.append(selection)
        return try await withCheckedThrowingContinuation { continuation in
            pending.append((selection, continuation))
            resumeSatisfiedWaiters()
        }
    }

    func waitForCallCount(_ count: Int) async {
        if calls.count >= count { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    func succeedNext(as selection: Selection? = nil) {
        let next = pending.removeFirst()
        next.1.resume(returning: Receipt(selection: selection ?? next.0, catalog: nil))
    }

    func failNext(_ message: String) {
        let next = pending.removeFirst()
        next.1.resume(throwing: ChatBrainFixtureFailure(message: message))
    }

    private func resumeSatisfiedWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in countWaiters {
            if calls.count >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        countWaiters = remaining
    }
}

@Suite("Chat brain save coordinator", .serialized)
@MainActor
struct ChatBrainSaveCoordinatorTests {
    typealias Selection = AppModel.ChatBrainSelection

    private func model(canonical: Selection) async -> AppModel {
        let model = AppModel()
        // Let the production init refresh finish before installing hermetic
        // persistence seams and fixture state.
        await Task.yield()
        model.chatBrainCanonicalSelection = canonical
        model.chatBrainReadOverride = { canonical }
        model.chatModel = canonical.model
        model.chatReasoningEffort = canonical.reasoningEffort
        model.chatFastMode = canonical.fastMode
        return model
    }

    @Test("overlapping picker edits serialize captured tuples and latest wins")
    func latestCapturedTupleWins() async {
        let original = Selection(model: "model-a", reasoningEffort: "high", fastMode: false)
        let model = await model(canonical: original)
        let harness = ChatBrainWriteHarness()
        model.chatBrainWriteOverride = { selection in
            try await harness.write(selection)
        }

        model.chatModel = "model-b"
        let first = Task { @MainActor in await model.saveChatBrainDefaults() }
        await harness.waitForCallCount(1)

        model.chatReasoningEffort = "ultra"
        model.chatFastMode = true
        let latest = Task { @MainActor in await model.saveChatBrainDefaults() }
        await Task.yield()

        #expect(harness.calls == [
            Selection(model: "model-b", reasoningEffort: "high", fastMode: false),
        ])

        harness.succeedNext()
        await harness.waitForCallCount(2)
        #expect(harness.calls[1] == Selection(
            model: "model-b",
            reasoningEffort: "ultra",
            fastMode: true
        ))
        harness.succeedNext()

        let finalResult = await latest.value
        _ = await first.value
        #expect(finalResult == .saved(Selection(
            model: "model-b",
            reasoningEffort: "ultra",
            fastMode: true
        )))
        #expect(model.chatModel == "model-b")
        #expect(model.chatReasoningEffort == "ultra")
        #expect(model.chatFastMode)
        #expect(model.isSavingChatBrain == false)
    }

    @Test("a failed latest save restores the checked canonical tuple")
    func failedLatestSaveRollsBack() async {
        let canonical = Selection(model: "model-a", reasoningEffort: "medium", fastMode: false)
        let model = await model(canonical: canonical)
        let harness = ChatBrainWriteHarness()
        model.chatBrainWriteOverride = { selection in
            try await harness.write(selection)
        }

        model.chatModel = "model-b"
        model.chatReasoningEffort = "max"
        model.chatFastMode = true
        let save = Task { @MainActor in await model.saveChatBrainDefaults() }
        await harness.waitForCallCount(1)
        harness.failNext("fixture disk full")

        let result = await save.value
        #expect(result == .failed(message: "fixture disk full", rolledBackTo: canonical))
        #expect(model.chatModel == canonical.model)
        #expect(model.chatReasoningEffort == canonical.reasoningEffort)
        #expect(model.chatFastMode == canonical.fastMode)
        #expect(model.statusText.contains("fixture disk full"))
    }

    @Test("an intermediate failure cannot roll the UI behind a newer edit")
    func intermediateFailureDoesNotRollbackLatestEdit() async {
        let canonical = Selection(model: "model-a", reasoningEffort: "high", fastMode: false)
        let model = await model(canonical: canonical)
        let harness = ChatBrainWriteHarness()
        model.chatBrainWriteOverride = { selection in
            try await harness.write(selection)
        }

        model.chatModel = "model-b"
        let first = Task { @MainActor in await model.saveChatBrainDefaults() }
        await harness.waitForCallCount(1)

        model.chatModel = "model-c"
        model.chatReasoningEffort = "xhigh"
        let latest = Task { @MainActor in await model.saveChatBrainDefaults() }
        harness.failNext("first write failed")

        await harness.waitForCallCount(2)
        #expect(model.chatModel == "model-c")
        #expect(model.chatReasoningEffort == "xhigh")
        harness.succeedNext()

        _ = await first.value
        #expect(await latest.value == .saved(Selection(
            model: "model-c",
            reasoningEffort: "xhigh",
            fastMode: false
        )))
        #expect(model.chatModel == "model-c")
    }
}
