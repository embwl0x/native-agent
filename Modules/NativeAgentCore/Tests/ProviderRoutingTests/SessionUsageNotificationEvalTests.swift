import Foundation
import Testing
@testable import ProviderRouting
import NativeAgentCore
import PersistenceCore

// MARK: - Ledger row `llm.telemetry.sessionUsageNotification`
//
// SILENT FAILURE this pins: `.nativeAgentSessionProviderUsageDidChange` is the
// ONLY refresh trigger for the chat context fill bar. It is posted inside the
// receipt writer's SUCCESS branch. If the receipt write throws, or the post is
// dropped, the fill bar shows a stale context percentage indefinitely — stale
// UI, no error, nothing red. Nothing asserted that it fires at all.
//
// Envelope asserted: exactly ONE post per durable receipt, carrying the
// NORMALIZED session id as `object`; and ZERO posts on every branch that
// produces no receipt (non-ok status, nil usage, unbound session, unsafe id).
// Serialized because NotificationCenter is process-global; each test still
// filters by its own UUID-bearing session id so a stray post from elsewhere
// cannot make this pass or fail.

private final class UsageNotificationCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [String] = []
    private var token: (any NSObjectProtocol)?

    init() {
        token = NotificationCenter.default.addObserver(
            forName: .nativeAgentSessionProviderUsageDidChange,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self else { return }
            self.lock.lock()
            self.objects.append((note.object as? String) ?? "<non-string>")
            self.lock.unlock()
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    /// Posts whose object matches `id` — everything else in the process is
    /// another suite's traffic and is ignored on purpose.
    func posts(for id: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return objects.filter { $0 == id }
    }

    func total() -> Int {
        lock.lock(); defer { lock.unlock() }
        return objects.count
    }
}

private func usageEvalRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SessionUsageNotificationEval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private let evalUsage = LLMUsage(
    inputTokens: 12,
    outputTokens: 34,
    cacheReadInputTokens: 56,
    cacheCreationInputTokens: 78
)

@Suite(.serialized)
struct SessionUsageNotificationEvalTests {

    /// Envelope: one durable receipt → exactly one post, and its `object` is
    /// the NORMALIZED session id. Written with a raw id that needs trimming so
    /// a test that echoed the caller's own string could not pass vacuously.
    @Test func durableReceipt_postsExactlyOnce_withTheNormalizedSessionID() async throws {
        let root = try usageEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let normalized = "usage-eval-\(UUID().uuidString)"
        let raw = "  \(normalized)  "
        #expect(NativeAgentChatSessionID.normalizedPathComponent(raw) == normalized)

        let collector = UsageNotificationCollector()
        let recorder = LLMCallTraceRecorder(dataRootOverride: root)
        await LLMCallContext.$surface.withValue("chat") {
            await LLMCallContext.$sessionId.withValue(raw) {
                await TurnTraceContext.$turnId.withValue("turn-\(normalized)") {
                    await recorder.record(
                        provider: "anthropic_oauth_direct",
                        model: "claude-opus-4-8",
                        streaming: true,
                        usage: evalUsage,
                        ttftMs: 40,
                        durationMs: 90
                    )
                }
            }
        }

        // The receipt is durable at the normalized path...
        let receipt = root
            .appendingPathComponent("chat/session_state/\(normalized)/provider_usage.json")
        #expect(FileManager.default.fileExists(atPath: receipt.path))
        // ...and the fill bar's ONLY refresh trigger fired exactly once for it.
        #expect(collector.posts(for: normalized).count == 1)
        #expect(collector.posts(for: raw).isEmpty,
                "the post must carry the normalized id, not the caller's raw string")
    }

    /// Envelope: every branch that produces NO receipt must also produce NO
    /// post — a refresh with nothing new behind it teaches the UI to trust a
    /// signal that does not mean anything.
    @Test func noReceiptBranches_postNothing() async throws {
        let root = try usageEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let collector = UsageNotificationCollector()
        let recorder = LLMCallTraceRecorder(dataRootOverride: root)

        let failedID = "usage-eval-failed-\(UUID().uuidString)"
        let nilUsageID = "usage-eval-nilusage-\(UUID().uuidString)"
        let unsafeID = "../usage-eval-escape-\(UUID().uuidString)"

        // (a) non-ok status
        await LLMCallContext.$surface.withValue("chat") {
            await LLMCallContext.$sessionId.withValue(failedID) {
                await recorder.record(
                    provider: "anthropic_oauth_direct", model: "claude-opus-4-8",
                    streaming: true, usage: evalUsage, ttftMs: nil, durationMs: 5,
                    status: "error"
                )
            }
        }
        // (b) nil usage
        await LLMCallContext.$surface.withValue("chat") {
            await LLMCallContext.$sessionId.withValue(nilUsageID) {
                await recorder.record(
                    provider: "anthropic_oauth_direct", model: "claude-opus-4-8",
                    streaming: true, usage: nil, ttftMs: nil, durationMs: 5
                )
            }
        }
        // (c) session id that is not a safe path component
        await LLMCallContext.$surface.withValue("chat") {
            await LLMCallContext.$sessionId.withValue(unsafeID) {
                await recorder.record(
                    provider: "anthropic_oauth_direct", model: "claude-opus-4-8",
                    streaming: true, usage: evalUsage, ttftMs: nil, durationMs: 5
                )
            }
        }
        // (d) no session bound at all
        let unboundBefore = collector.total()
        await LLMCallContext.$surface.withValue("chat") {
            await recorder.record(
                provider: "anthropic_oauth_direct", model: "claude-opus-4-8",
                streaming: true, usage: evalUsage, ttftMs: nil, durationMs: 5
            )
        }

        #expect(collector.posts(for: failedID).isEmpty, "a failed call must not refresh the fill bar")
        #expect(collector.posts(for: nilUsageID).isEmpty, "a call with no usage numbers has nothing to publish")
        #expect(collector.posts(for: unsafeID).isEmpty)
        #expect(collector.total() == unboundBefore,
                "an unbound session must not post at all")

        // No receipt escaped the session_state directory either.
        let sessionState = root.appendingPathComponent("chat/session_state", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: sessionState.path)) ?? []
        #expect(entries.isEmpty, "no receipt should exist for any of these branches, found \(entries)")

        // But the llm.call trace row itself is still written for the failed
        // call — the notification is gated, the telemetry feed is not.
        let events = root.appendingPathComponent("traces/events.jsonl")
        let text = (try? String(contentsOf: events, encoding: .utf8)) ?? ""
        #expect(text.contains(#""kind":"llm.call""#) || text.contains("llm.call"),
                "llm.call rows must still be appended for non-ok calls")
    }
}
