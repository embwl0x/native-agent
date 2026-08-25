import Foundation
import PersistenceCore
import Testing
@testable import ChatOrchestration

// Coverage-ledger fence `core.chat.persistence`:
//   * chat.tracer.busPreviewRedaction (silent leak)
//
// Unlike the events.jsonl row (contractually keys-only), the BUS event carries
// the tool's serialized input and result through ONE redactor before a 500-char
// cut, and that row persists into data/turn_traces for days. The order is the
// whole guarantee: redact THEN truncate. Truncate-first looks identical on a
// short payload and leaks a live token on a long one, because a token sliced at
// the cut no longer matches the pattern that exists to catch it.
@Suite("eval: tool.dispatch bus preview redaction")
struct EvalBusPreviewRedactionTests {

    private func tempRoot(_ tag: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eval-preview-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Drive the real tracer on a private bus and return the `end` event.
    private func endEvent(
        root: URL,
        tool: String,
        input: [String: JSONValue],
        result: JSONValue
    ) async throws -> TurnTraceEvent {
        let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: root))
        let subscription = await bus.subscribe(capacity: 16)
        let tracer = ChatToolDispatchTracer(
            inner: MockToolDispatchClient(scripted: [tool: result]),
            dataRoot: root
        )

        _ = try await TurnTraceContext.$turnId.withValue("turn-preview") {
            try await TurnTraceContext.$bus.withValue(bus) {
                try await tracer.dispatch(tool: tool, input: input, surface: "chat")
            }
        }

        let drain = Task { () -> TurnTraceEvent? in
            for await event in subscription.stream {
                guard event.kind == "tool.dispatch",
                      case .object(let payload) = event.payload,
                      payload["phase"] == .string("end") else { continue }
                return event
            }
            return nil
        }
        let stopper = Task {
            try? await Task.sleep(for: .milliseconds(3_000))
            await bus.unsubscribe(subscription.id)
        }
        let event = await drain.value
        stopper.cancel()
        await bus.unsubscribe(subscription.id)
        return try #require(event)
    }

    private func previewString(_ event: TurnTraceEvent, _ key: String) -> String? {
        guard case .object(let object) = event.payload,
              case .string(let text)? = object[key] else { return nil }
        return text
    }

    /// THE ORDER TEST. The token is planted so that only a HANDFUL of its body
    /// characters fall inside the 500-char window. A redactor that ran after
    /// the cut cannot recognise that remnant — every pattern it owns requires
    /// 20+ body characters — so truncate-first leaves a live credential prefix
    /// sitting in a 14-day feed, looking exactly like a well-formed row.
    @Test func aSecretStraddlingTheTruncationCutIsRedactedNotSliced() async throws {
        let root = try tempRoot("straddle")
        defer { try? FileManager.default.removeItem(at: root) }

        let secret = "sk-proj-A1B2C3D4E5F6G7H8J9K0L1M2N3P4Q5R6S7T8" // gitleaks:allow — deliberate fake secret; this eval proves redaction
        // `{"note": "` is the 10-byte serialized envelope; the trailing space
        // is load-bearing (every pattern is word-boundary anchored, which is
        // how a credential actually appears in a header, URL or log line).
        let secretStart = 486
        let pad = String(repeating: "x", count: secretStart - 10 - 1) + " "
        let event = try await endEvent(
            root: root,
            tool: "http_request",
            input: ["note": .string(pad + secret)],
            result: .object(["ok": .bool(true)])
        )

        let args = try #require(previewString(event, "args"))
        #expect(args.contains("[REDACTED_"), "the redactor did not run before the cut")
        // Not even the leading fragment a truncate-first order would expose.
        #expect(!args.contains("sk-proj-A1"))
        #expect(!args.contains(secret))
        // ...and it is still BOUNDED. Redaction must not have been bought by
        // dropping the cap.
        #expect(args.count <= 600)
    }

    /// The same order guarantee on the RESULT lane. `ax_act` re-reads what it
    /// wrote, so the result is a second, independent path for the same secret —
    /// and results are the long side of a dispatch, where the cut actually bites.
    @Test func aSecretInALongToolResultIsRedactedBeforeTheCut() async throws {
        let root = try tempRoot("result")
        defer { try? FileManager.default.removeItem(at: root) }

        let bearer = "Bearer eyJhbGciOiJIUzI1NiJ9.aaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbb"
        let pad = String(repeating: "y", count: 486 - 10 - 1) + " "
        let event = try await endEvent(
            root: root,
            tool: "http_request",
            input: ["url": .string("https://example.invalid")],
            result: .object([
                "body": .string(pad + bearer),
                "ok": .bool(true),
            ])
        )

        let result = try #require(previewString(event, "result"))
        #expect(result.contains("[REDACTED_"), "the redactor did not run before the cut")
        #expect(!result.contains("Bearer eyJ"))
        #expect(!result.contains(bearer))
        #expect(result.count <= 600)
    }

    /// The whole serialized event — not just the two preview keys — must be
    /// clean, and the row must still be a usable receipt (named tool, argument
    /// KEYS present) rather than a blanked shell.
    @Test func theWholeBusEventIsCleanAndStillUsable() async throws {
        let root = try tempRoot("whole")
        defer { try? FileManager.default.removeItem(at: root) }

        let githubToken = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let event = try await endEvent(
            root: root,
            tool: "http_request",
            input: ["header": .string("authorization: token \(githubToken)"), "url": .string("https://x.invalid")],
            result: .object(["ok": .bool(true), "echo": .string(githubToken)])
        )

        let serialized = (try? event.payload.serialize(pretty: false)) ?? ""
        #expect(!serialized.isEmpty)
        #expect(!serialized.contains(githubToken))
        #expect(!serialized.contains("ghp_ABCDEFGHIJKLMNOP"))
        guard case .object(let payload) = event.payload else {
            Issue.record("expected object payload"); return
        }
        #expect(payload["name"] == .string("http_request"))
        #expect(payload["argKeys"] == .array([.string("header"), .string("url")]))
        #expect(payload["status"] == .string("ok"))
    }
}
