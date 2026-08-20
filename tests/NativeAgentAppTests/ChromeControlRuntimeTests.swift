import Darwin
import Foundation
import NativeAgentChromeRelayCore
import PersistenceCore
import Testing
@testable import NativeAgentApp

private final class ChromeGateFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func read() -> Bool { lock.withLock { value } }
    func set(_ next: Bool) { lock.withLock { value = next } }
}

@Suite("App-owned Chrome control")
struct ChromeControlRuntimeTests {
    @Test("Switch off refuses extension traffic")
    func disabledRefusesTraffic() async throws {
        let gate = ChromeGateFixture(false)
        let runtime = ChromeControlRuntime(
            socketPath: "/tmp/nativeagent-chrome-disabled-\(UUID().uuidString).sock",
            manageNativeHostRegistration: false,
            authority: { gate.read() }
        )
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        await runtime.installAcceptedDescriptorForTesting(descriptors[0])
        defer { Darwin.close(descriptors[1]) }

        for effect in ChromeControlEffect.allCases where effect.requiresEffectTimeAuthorization {
            await #expect(throws: ChromeControlRuntimeError.disabled) {
                _ = try await runtime.perform(effect, payload: [:])
            }
        }
    }

    @Test("Switch flip mid-lease sends cleanup release and blocks the next effect")
    func switchFlipTerminatesLease() async throws {
        let gate = ChromeGateFixture(true)
        let runtime = ChromeControlRuntime(
            socketPath: "/tmp/nativeagent-chrome-flip-\(UUID().uuidString).sock",
            manageNativeHostRegistration: false,
            authority: { gate.read() }
        )
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        await runtime.installAcceptedDescriptorForTesting(descriptors[0])
        let peer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        let framer = NativeMessagingFramer()

        let fixture = Task.detached { () throws -> [[String: JSONValue]] in
            guard let acquireData = try framer.readMessage(from: peer),
                  case .object(let acquire) = try JSONValue.parse(acquireData),
                  case .string(let requestID)? = acquire["id"] else {
                throw ChromeControlRuntimeError.invalidResponse
            }
            let response = JSONValue.object([
                "version": .int(1), "type": .string("response"), "id": .string(requestID),
                "action": .string("lease.acquire"), "ok": .bool(true),
                "result": .object([
                    "leaseId": .string("lease-fixture"), "tabId": .int(42), "windowId": .int(7),
                    "ownership": .string("created"), "state": .string("active"), "userSequence": .int(0),
                ]),
            ])
            try framer.writeMessage(response.serializedData(pretty: false), to: peer)
            guard let releaseData = try framer.readMessage(from: peer),
                  case .object(let release) = try JSONValue.parse(releaseData) else {
                throw ChromeControlRuntimeError.invalidResponse
            }
            return [acquire, release]
        }

        let acquire = try await runtime.perform(.acquire, payload: ["mode": .string("create")])
        guard case .object(let acquireObject) = acquire else {
            Issue.record("acquire response was not an object")
            return
        }
        #expect(acquireObject["ok"] == .bool(true))
        gate.set(false)
        await #expect(throws: ChromeControlRuntimeError.disabled) {
            _ = try await runtime.perform(.snapshot, payload: ["leaseId": .string("lease-fixture")])
        }
        let messages = try await fixture.value
        #expect(messages[0]["action"] == .string("lease.acquire"))
        #expect(messages[1]["action"] == .string("lease.release"))
        guard case .object(let cleanup)? = messages[1]["payload"] else {
            Issue.record("cleanup payload was not an object")
            return
        }
        #expect(cleanup["leaseId"] == .string("lease-fixture"))
        #expect(cleanup["closeCreatedTab"] == .bool(false))
    }

    @Test("Native-host manifest pins the exact extension origin")
    func registrationIsExact() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChromeHostRegistration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let relay = home.appendingPathComponent("NativeAgentChromeRelay")
        #expect(FileManager.default.createFile(atPath: relay.path, contents: Data("relay".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: relay.path)
        try ChromeNativeHostRegistration.install(home: home, relayURL: relay)

        let manifestURL = home
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/com.nativeagent.chrome.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        #expect(object?["path"] as? String == relay.path)
        #expect(object?["allowed_origins"] as? [String] == [
            "chrome-extension://egdbijiogeeggnmjheomgnnkhmlepfcn/"
        ])
        let mode = try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }
}
