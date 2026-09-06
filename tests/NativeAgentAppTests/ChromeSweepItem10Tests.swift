import Darwin
import Foundation
import NativeAgentChromeRelayCore
import PersistenceCore
import Testing
@testable import NativeAgentApp

// Fable 5.1 sweep item 10 — Chrome threw away its richest outcome data.
//
//   (a) the yield `reason` was parsed and dropped, so "the user touched the
//       page and I yielded" reached her as a timeout or a bare lease_not_found;
//   (b) the extension's per-action receipt came back as raw JSON and was never
//       admitted as a motor consequence the way MacControl and Browser are;
//   (c) `lease.renew` existed in the extension and had no Swift case, so every
//       Chrome task carried a hard 60-second ceiling.

@Suite("Chrome sweep item 10")
struct ChromeSweepItem10Tests {

    // MARK: - (a) the yield reason, in words

    @Test("Every lease-end reason is said out loud")
    func leaseEndReasonSpeaks() {
        #expect(ChromeLeaseEndReason.words(event: "lease.yielded", reason: "user_click")
            .contains("user touched the page"))
        #expect(ChromeLeaseEndReason.words(event: "lease.yielded", reason: "user_keydown")
            .contains("user touched the page"))
        #expect(ChromeLeaseEndReason.words(event: "lease.yielded", reason: "tab_activated")
            .contains("came to the foreground"))
        #expect(ChromeLeaseEndReason.words(event: "lease.released", reason: "host_released")
            .contains("already been released"))
        // An unrecognised reason is QUOTED, never swallowed: some reason beats
        // no reason, which is what the old code produced for all of them.
        #expect(ChromeLeaseEndReason.words(event: "lease.yielded", reason: "quantum_weirdness")
            .contains("quantum_weirdness"))
        #expect(!ChromeLeaseEndReason.words(event: "lease.yielded", reason: "").isEmpty)
    }

    @Test("A call against a yielded lease answers with the yield reason, not lease_not_found")
    func yieldReasonReachesTheNextCall() async throws {
        let runtime = ChromeControlRuntime(
            socketPath: "/tmp/nativeagent-chrome-yield-\(UUID().uuidString).sock",
            manageNativeHostRegistration: false,
            authority: { true }
        )
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        await runtime.installAcceptedDescriptorForTesting(descriptors[0])
        let peer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        let framer = NativeMessagingFramer()

        // The event is written BEFORE the probe request is answered, and the
        // channel reads its socket in order — so by the time the probe's
        // response lands, the yield has already been applied. No sleeping.
        let fixture = Task.detached { () throws -> Int in
            let event = JSONValue.object([
                "version": .int(1),
                "type": .string("event"),
                "event": .string("lease.yielded"),
                "occurredAt": .string("2026-09-01T00:00:00Z"),
                "payload": .object([
                    "leaseId": .string("lease-yielded"),
                    "tabId": .int(42),
                    "reason": .string("user_click"),
                    "userSequence": .int(1),
                ]),
            ])
            try framer.writeMessage(event.serializedData(pretty: false), to: peer)
            guard let probeData = try framer.readMessage(from: peer),
                  case .object(let probe) = try JSONValue.parse(probeData),
                  case .string(let probeID)? = probe["id"] else {
                throw ChromeControlRuntimeError.invalidResponse
            }
            let response = JSONValue.object([
                "version": .int(1), "type": .string("response"), "id": .string(probeID),
                "action": .string("page.snapshot.read"), "ok": .bool(true),
                "result": .object(["nodes": .array([])]),
            ])
            try framer.writeMessage(response.serializedData(pretty: false), to: peer)
            // Anything further would mean the yielded lease was still dispatched.
            return try framer.readMessage(from: peer) == nil ? 1 : 2
        }

        _ = try await runtime.perform(.snapshot, payload: ["leaseId": .string("probe-lease")])
        do {
            _ = try await runtime.perform(.snapshot, payload: ["leaseId": .string("lease-yielded")])
            Issue.record("a yielded lease must not be dispatched")
        } catch let error as ChromeControlRuntimeError {
            guard case .leaseEnded(let leaseID, let event, let reason) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(leaseID == "lease-yielded")
            #expect(event == "lease.yielded")
            #expect(reason == "user_click")
            let words = error.localizedDescription
            #expect(words.contains("user touched the page"), "\(words)")
            #expect(words.contains("Acquire a fresh lease"), "\(words)")
        }
        await runtime.stop()
        _ = try? await fixture.value
    }

    @Test("A yield fails the call already in flight with the reason, not a timeout")
    func yieldReasonReachesTheInFlightCall() async throws {
        let runtime = ChromeControlRuntime(
            socketPath: "/tmp/nativeagent-chrome-inflight-\(UUID().uuidString).sock",
            manageNativeHostRegistration: false,
            authority: { true }
        )
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        await runtime.installAcceptedDescriptorForTesting(descriptors[0])
        let peer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        let framer = NativeMessagingFramer()

        // Read the click, then yield the tab instead of answering it — the
        // live shape of "she clicked, User grabbed the mouse".
        let fixture = Task.detached { () throws -> [String: JSONValue] in
            guard let data = try framer.readMessage(from: peer),
                  case .object(let request) = try JSONValue.parse(data) else {
                throw ChromeControlRuntimeError.invalidResponse
            }
            let event = JSONValue.object([
                "version": .int(1),
                "type": .string("event"),
                "event": .string("lease.yielded"),
                "occurredAt": .string("2026-09-01T00:00:00Z"),
                "payload": .object([
                    "leaseId": .string("lease-live"),
                    "tabId": .int(42),
                    "reason": .string("user_pointerdown"),
                    "userSequence": .int(1),
                ]),
            ])
            try framer.writeMessage(event.serializedData(pretty: false), to: peer)
            return request
        }

        do {
            _ = try await runtime.perform(.click, payload: [
                "leaseId": .string("lease-live"),
                "expectedUserSequence": .int(0),
                "snapshotId": .string("snap-1"),
                "nodeId": .string("node-1"),
            ])
            Issue.record("the click must not resolve successfully")
        } catch let error as ChromeControlRuntimeError {
            // A click already dispatched stays outcome-unknown — the yield does
            // not un-click it — but the CAUSE is now named instead of a bare
            // deadline.
            guard case .outcomeUnknown(let action, let reason) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(action == "page.element.click")
            #expect(reason.contains("user touched the page"), "\(reason)")
        }
        let request = try await fixture.value
        #expect(request["action"] == .string("page.element.click"))
        await runtime.stop()
    }

    // MARK: - (b) the receipt as a motor consequence

    @Test("The Chrome receipt becomes a motor read model in the shared vocabulary")
    func receiptBecomesAMotorReadModel() {
        let succeeded = JSONValue.object([
            "outcome": .string("succeeded"),
            "receipt": .object([
                "id": .string("chrome-action-1"),
                "action": .string("click"),
                "leaseId": .string("lease-1"),
                "outcome": .string("succeeded"),
                "verification": .string("page_acknowledged"),
                "retry": .string("fresh_snapshot_required"),
                "completedAt": .string("2026-09-01T12:00:00.000Z"),
            ]),
        ])
        let model = AppChatToolDispatcher.chromeReceiptMotorActionReadModel(succeeded)
        #expect(model?.domain == "chrome_control")
        #expect(model?.actionIdentity == CausalTransitionEvidence.opaqueIdentity("chrome-action-1"),
                "the identity has to be the 64-char digest the event factory accepts")
        #expect(model?.actionIdentity.count == 64)
        #expect(model?.phase == .succeeded)
        #expect(model?.domainState == "succeeded")
        // 2026-09-06: was `.satisfied`. 9c97af4b (r2 finding 12) separated
        // acknowledgement from verification: `page_acknowledged` is the page
        // saying it RECEIVED the act, and a click on a control that ignored it
        // acknowledges just as loudly. Evidence is still owed, so the receipt
        // maps to `.pending` (AppChatToolDispatcher.swift:1893). The phase
        // above stays `.succeeded` — the act completed; what is unproven is
        // that it did anything.
        #expect(model?.verification == .pending)
        #expect(model?.updatedAt == "2026-09-01T12:00:00.000Z")
        #expect(model?.expectedNextEvidence?.contains("fresh Chrome snapshot") == true)
        // And it survives all the way to a cognitive event, which is the only
        // thing that makes it a motor consequence rather than more JSON.
        #expect(model.flatMap { NativeCognitiveEventFactory.motorActionState($0) } != nil)
    }

    @Test("An unknown Chrome outcome stays unknown and forbids an automatic retry")
    func unknownReceiptStaysUnknown() {
        let unknown = JSONValue.object([
            "receipt": .object([
                "id": .string("chrome-action-2"),
                "outcome": .string("outcome_unknown"),
                "verification": .string("outcome_unknown"),
                "retry": .string("never_automatic"),
            ]),
        ])
        let model = AppChatToolDispatcher.chromeReceiptMotorActionReadModel(unknown)
        // `.waitingExternal`, never `.unknown`: the cognitive event factory
        // drops `.unknown` outright, which is how these receipts stayed
        // invisible in the first place.
        #expect(model?.phase == .waitingExternal,
                "an unknown outcome is evidence owed, not success and not silence")
        #expect(model?.domainState == "outcome_unknown")
        #expect(model?.verification == .unknown)
        #expect(model?.expectedNextEvidence?.contains("never be retried automatically") == true)

        // A partial type keeps its own word: the phase vocabulary has no
        // "partially completed" and collapsing it either way loses the point.
        let partial = JSONValue.object([
            "receipt": .object([
                "id": .string("chrome-action-3"),
                "outcome": .string("partially_completed"),
                "verification": .string("not_verified"),
                "retry": .string("fresh_snapshot_then_remaining_text_only"),
            ]),
        ])
        let partialModel = AppChatToolDispatcher.chromeReceiptMotorActionReadModel(partial)
        #expect(partialModel?.domainState == "partially_completed")
        #expect(partialModel?.phase == .waitingExternal)
        #expect(partialModel?.verification == .unverified)
        #expect(partialModel?.expectedNextEvidence?.contains("characters that did not land") == true)

        let refused = JSONValue.object([
            "receipt": .object([
                "id": .string("chrome-action-4"),
                "outcome": .string("refused"),
                "verification": .string("not_verified"),
                "retry": .string("fresh_snapshot_required"),
            ]),
        ])
        #expect(AppChatToolDispatcher.chromeReceiptMotorActionReadModel(refused)?.phase == .blocked,
                "MacControl calls a refusal blocked; Chrome says it the same way")

        // The whole point of the mapping: every one of these reaches cognition
        // as a real event instead of being dropped on the floor.
        for value in [unknown, partial, refused] {
            let model = AppChatToolDispatcher.chromeReceiptMotorActionReadModel(value)
            #expect(model.flatMap { NativeCognitiveEventFactory.motorActionState($0) } != nil,
                    "a Chrome receipt that produces no cognitive event is the original defect")
        }
    }

    @Test("A Chrome result with no receipt invents no consequence")
    func noReceiptNoModel() {
        #expect(AppChatToolDispatcher.chromeReceiptMotorActionReadModel(
            .object(["leaseId": .string("lease-1")])
        ) == nil)
        #expect(AppChatToolDispatcher.chromeReceiptMotorActionReadModel(.string("nope")) == nil)
        // A receipt with no id is not an identity to observe against.
        #expect(AppChatToolDispatcher.chromeReceiptMotorActionReadModel(
            .object(["receipt": .object(["outcome": .string("succeeded")])])
        ) == nil)
    }

    // MARK: - (c) lease.renew, end to end

    @Test("lease.renew is a real effect with the extension's own action name")
    func renewIsAnEffect() {
        #expect(ChromeControlEffect.renew.rawValue == "lease.renew",
                "the wire name has to match the extension's ACTIONS list exactly")
        #expect(ChromeControlEffect.allCases.contains(.renew))
        #expect(ChromeControlEffect.renew.requiresEffectTimeAuthorization)
        #expect(ChromeControlEffect.renew.mayChangeExternalState,
                "an unconfirmed renew moved the lease's expiry or did not — never a free retry")
    }

    @Test("browser.chrome_renew is exposed like the other Chrome tools")
    func renewToolIsExposed() {
        #expect(AppChatToolDispatcher.catalogRegisteredToolNames.contains("browser.chrome_renew"))
        #expect(AppChatToolDispatcher.catalogBucket(forRegisteredToolNamed: "browser.chrome_renew")
            == .browser)
    }

    @Test("A renew is dispatched to Chrome with the lease, the sequence and the duration")
    func renewReachesChrome() async throws {
        let runtime = ChromeControlRuntime(
            socketPath: "/tmp/nativeagent-chrome-renew-\(UUID().uuidString).sock",
            manageNativeHostRegistration: false,
            authority: { true }
        )
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        await runtime.installAcceptedDescriptorForTesting(descriptors[0])
        let peer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        let framer = NativeMessagingFramer()

        let fixture = Task.detached { () throws -> [String: JSONValue] in
            guard let data = try framer.readMessage(from: peer),
                  case .object(let request) = try JSONValue.parse(data),
                  case .string(let requestID)? = request["id"] else {
                throw ChromeControlRuntimeError.invalidResponse
            }
            let response = JSONValue.object([
                "version": .int(1), "type": .string("response"), "id": .string(requestID),
                "action": .string("lease.renew"), "ok": .bool(true),
                "result": .object([
                    "leaseId": .string("lease-renew"),
                    "state": .string("active"),
                    "expiresAt": .string("2026-09-01T12:05:00.000Z"),
                ]),
            ])
            try framer.writeMessage(response.serializedData(pretty: false), to: peer)
            return request
        }

        let renewed = try await runtime.perform(.renew, payload: [
            "leaseId": .string("lease-renew"),
            "expectedUserSequence": .int(0),
            "leaseDurationMs": .int(300_000),
        ])
        guard case .object(let envelope) = renewed,
              case .object(let result)? = envelope["result"] else {
            Issue.record("renew returned no result object")
            return
        }
        #expect(result["expiresAt"] == .string("2026-09-01T12:05:00.000Z"))
        let request = try await fixture.value
        #expect(request["action"] == .string("lease.renew"))
        guard case .object(let payload)? = request["payload"] else {
            Issue.record("no payload")
            return
        }
        #expect(payload["leaseId"] == .string("lease-renew"))
        #expect(payload["expectedUserSequence"] == .int(0))
        #expect(payload["leaseDurationMs"] == .int(300_000),
                "the extension bounds this at 30000–300000; the ceiling has to be reachable")
        await runtime.stop()
    }
}
