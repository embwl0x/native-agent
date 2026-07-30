import Testing
import Foundation
@testable import BackgroundLoops
import NativeAgentCore
import ProviderRouting

/// LLM stub: fixed response, thread-safe call counter (satisfies @Sendable).
private final class StubLLM: LLMClient, @unchecked Sendable {
    let response: String
    let error: Error?
    private let lock = NSLock()
    private var _calls = 0
    init(response: String, error: Error? = nil) {
        self.response = response
        self.error = error
    }
    var calls: Int { lock.withLock { _calls } }
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        lock.withLock { _calls += 1 }
        if let error { throw error }
        return response
    }
}

/// Thread-safe collector for the injected surfaceNotice closure.
private final class NoticeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [HeartbeatNotice] = []
    func add(_ notice: HeartbeatNotice) { lock.lock(); _items.append(notice); lock.unlock() }
    var items: [HeartbeatNotice] { lock.lock(); defer { lock.unlock() }; return _items }
}

private func makeLoop(
    checklist: String?,
    response: String,
    assessment: HeartbeatAssessment = HeartbeatAssessment(
        signals: "Doctor: 1 failing.",
        deterministicOK: false,
        conditionId: "doctor-failing",
        fallbackAlert: "Doctor has failing checks."
    ),
    error: Error? = nil,
    collector: NoticeCollector
) -> (HeartbeatLoop, StubLLM) {
    let llm = StubLLM(response: response, error: error)
    return (HeartbeatLoop(
        llm: llm,
        router: SwiftNativeProviderRouting(),
        loadChecklist: { checklist },
        gatherAssessment: { assessment },
        surfaceNotice: { collector.add($0) }
    ), llm)
}

@Test func heartbeat_loopId_and_surface() {
    let loop = HeartbeatLoop(
        llm: StubLLM(response: ""),
        loadChecklist: { nil },
        gatherAssessment: { .clean(signals: "") },
        surfaceNotice: { _ in })
    #expect(loop.loopId == "heartbeat")
    #expect(HeartbeatLoop.surface == "heartbeat")
    #expect(HeartbeatLoop.okToken == "HEARTBEAT_OK")
    #expect(HeartbeatLoop.defaultInterval == 12 * 60 * 60)
    #expect(loop.interval == HeartbeatLoop.defaultInterval)
}

@Test func heartbeat_deterministic_OK_skips_llm_and_notice() async {
    let collector = NoticeCollector()
    let llm = StubLLM(response: "this should not be called")
    let loop = HeartbeatLoop(
        llm: llm,
        loadChecklist: { "- doctor green" },
        gatherAssessment: { .clean(signals: "Doctor: 0 failing, 0 warning, 9 total.") },
        surfaceNotice: { collector.add($0) })
    #expect(await loop.tickOutcome() == .completed(result: "deterministic heartbeat healthy"))
    #expect(llm.calls == 0)
    #expect(collector.items.isEmpty)   // silent OK → nothing surfaced
}

@Test func heartbeat_non_OK_is_surfaced() async {
    let collector = NoticeCollector()
    let (loop, llm) = makeLoop(
        checklist: "- doctor green",
        response: "Doctor has 2 failing checks: storage, chat_sessions.",
        collector: collector)
    #expect(await loop.tickOutcome() == .completed(result: "heartbeat notice surfaced"))
    #expect(llm.calls == 1)
    #expect(collector.items.count == 1)
    #expect(collector.items.first?.body.contains("2 failing") == true)
    #expect(collector.items.first?.conditionId == "doctor-failing")
}

@Test func heartbeat_notice_staging_failure_returns_failed() async {
    // FIX 3 (A4.5): a failed inbox write must NOT be reported as
    // ".completed(heartbeat notice surfaced)". Returning .failed trips the
    // manager's failure-receipt net so the dropped card is recorded, not lost.
    struct StageError: Error {}
    let loop = HeartbeatLoop(
        llm: StubLLM(response: "Doctor has 2 failing checks: storage, chat."),
        router: SwiftNativeProviderRouting(),
        loadChecklist: { "- doctor green" },
        gatherAssessment: {
            HeartbeatAssessment(
                signals: "Doctor: 1 failing.",
                deterministicOK: false,
                conditionId: "doctor-failing",
                fallbackAlert: "Doctor has failing checks."
            )
        },
        surfaceNotice: { _ in throw StageError() }
    )
    let outcome = await loop.tickOutcome()
    guard case .failed(let error) = outcome else {
        Issue.record("expected .failed when the notice staging write fails, got \(outcome)")
        return
    }
    #expect(error.contains("heartbeat notice staging"))
}

@Test func heartbeat_model_OK_on_deterministic_anomaly_uses_fallback() async {
    let collector = NoticeCollector()
    let (loop, _) = makeLoop(
        checklist: "- doctor green",
        response: "  HEARTBEAT_OK\n",
        collector: collector)
    await loop.tick()
    #expect(collector.items.count == 1)
    #expect(collector.items.first?.body == "Doctor has failing checks.")
}

@Test func heartbeat_token_with_nonwhitespace_addition_surfaces_model_body() async {
    // The contract is exact-match after a whitespace-ONLY trim. ANY
    // non-whitespace addition must surface — these are the dangerous
    // near-misses where a model smuggles a caveat into an "OK".
    for reply in ["HEARTBEAT_OK.", "HEARTBEAT_OK but note: disk at 91%",
                  "heartbeat_ok", "OK HEARTBEAT_OK", "\"HEARTBEAT_OK\""] {
        let collector = NoticeCollector()
        let (loop, _) = makeLoop(checklist: "- doctor green", response: reply, collector: collector)
        await loop.tick()
        #expect(collector.items.count == 1, "must surface, not suppress: \(reply)")
        #expect(collector.items.first?.body == reply)
    }
}

@Test func heartbeat_near_miss_token_is_surfaced_not_suppressed() async {
    let collector = NoticeCollector()
    // A paraphrase must NOT fall into silence — exact match only.
    let (loop, _) = makeLoop(checklist: "- doctor green", response: "heartbeat ok, all good", collector: collector)
    await loop.tick()
    #expect(collector.items.count == 1)
}

@Test func heartbeat_empty_reply_uses_fallback() async {
    let collector = NoticeCollector()
    let (loop, _) = makeLoop(checklist: "- doctor green", response: "   ", collector: collector)
    await loop.tick()
    #expect(collector.items.count == 1)
    #expect(collector.items.first?.body == "Doctor has failing checks.")
}

@Test func heartbeat_llm_error_uses_fallback() async {
    struct Boom: Error {}
    let collector = NoticeCollector()
    let (loop, _) = makeLoop(
        checklist: "- doctor green",
        response: "",
        error: Boom(),
        collector: collector)
    await loop.tick()
    #expect(collector.items.count == 1)
    #expect(collector.items.first?.body == "Doctor has failing checks.")
}

@Test func heartbeat_missing_checklist_is_honest_noop() async {
    let collector = NoticeCollector()
    let llm = StubLLM(response: "HEARTBEAT_OK")
    let loop = HeartbeatLoop(
        llm: llm,
        loadChecklist: { nil },            // no HEARTBEAT.md
        gatherAssessment: { .clean(signals: "Doctor: ok") },
        surfaceNotice: { collector.add($0) })
    #expect(await loop.tickOutcome() == .skipped(reason: "HEARTBEAT.md missing or empty"))
    #expect(llm.calls == 0)                // never asked the LLM
    #expect(collector.items.isEmpty)       // and never surfaced a (fabricated) all-clear
}

@Test func heartbeat_empty_checklist_is_honest_noop() async {
    let collector = NoticeCollector()
    let llm = StubLLM(response: "HEARTBEAT_OK")
    let loop = HeartbeatLoop(
        llm: llm,
        loadChecklist: { "   \n  " },      // present but blank
        gatherAssessment: { .clean(signals: "Doctor: ok") },
        surfaceNotice: { collector.add($0) })
    await loop.tick()
    #expect(llm.calls == 0)
    #expect(collector.items.isEmpty)
}
