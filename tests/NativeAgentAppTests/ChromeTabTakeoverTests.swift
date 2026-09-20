import Darwin
import Foundation
import NativeAgentChromeRelayCore
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("Chrome tab takeover")
struct ChromeTabTakeoverTests {
    @Test("tab_activated settles in-flight and subsequent calls calmly", arguments: [ChromeControlEffect.snapshot, .navigate])
    func tabActivated(effect: ChromeControlEffect) async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let channel = ChromeControlChannel(descriptor: descriptors[0])
        await channel.start()
        let peer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        let framer = NativeMessagingFramer()
        let fixture = Task.detached {
            _ = try #require(try framer.readMessage(from: peer))
            try framer.writeMessage(JSONValue.object([
                "version": .int(1), "type": .string("event"), "event": .string("lease.yielded"),
                "payload": .object(["leaseId": .string("lease-live"), "tabId": .int(42),
                    "reason": .string("tab_activated"), "userSequence": .int(1)]),
            ]).serializedData(pretty: false), to: peer)
            // Neither the in-flight call nor the next one may retake the tab.
            #expect(try framer.readMessage(from: peer) == nil)
        }
        var payload: [String: JSONValue] = ["leaseId": .string("lease-live")]
        if effect == .navigate { payload["url"] = .string("https://example.com/") }
        for attempt in 0..<2 {
            let response = try await channel.request(action: effect, payload: payload)
            guard case .object(let envelope) = response,
                  case .object(let result)? = envelope["result"] else { throw ChromeControlRuntimeError.invalidResponse }
            #expect(result["status"] == .string("yielded"))
            #expect(result["reason"] == .string("tab_activated"))
            #expect(result["outcome"] == .string(attempt == 0 && effect == .navigate ? "outcome_unknown" : "not_performed"))
            guard case .string(let message)? = result["message"] else { throw ChromeControlRuntimeError.invalidResponse }
            #expect(message.contains("The person took the tab."))
            #expect(message.contains("acquire a fresh lease for that tab"))
        }
        await channel.shutdown(releaseLeases: false)
        try await fixture.value
    }
}
