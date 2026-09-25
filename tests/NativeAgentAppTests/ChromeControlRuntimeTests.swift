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

    @Test("A response cannot settle a different requested effect")
    func mismatchedResponseActionClosesTheChannel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cr-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = ChromeControlRuntime(
            socketPath: directory.appendingPathComponent("s").path,
            manageNativeHostRegistration: false,
            reconnectTimeout: .milliseconds(20),
            authority: { true }
        )
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        await runtime.installAcceptedDescriptorForTesting(descriptors[0])
        let peer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        let framer = NativeMessagingFramer()

        let fixture = Task.detached {
            guard let requestData = try framer.readMessage(from: peer),
                  case .object(let request) = try JSONValue.parse(requestData),
                  case .string(let requestID)? = request["id"] else {
                throw ChromeControlRuntimeError.invalidResponse
            }
            let response = JSONValue.object([
                "version": .int(1), "type": .string("response"), "id": .string(requestID),
                "action": .string("lease.acquire"), "ok": .bool(true),
                "result": .object(["leaseId": .string("wrong-effect")]),
            ])
            try framer.writeMessage(response.serializedData(pretty: false), to: peer)
        }

        await #expect(throws: ChromeControlRuntimeError.invalidResponse) {
            _ = try await runtime.perform(.snapshot, payload: ["leaseId": .string("lease-fixture")])
        }
        try await fixture.value
        await #expect(throws: ChromeControlRuntimeError.disconnected) {
            _ = try await runtime.perform(.snapshot, payload: ["leaseId": .string("lease-fixture")])
        }
        await runtime.stop()
    }

    @Test("Unconfirmed mutations report unknown outcomes while read deadlines remain read failures")
    func dispatchedMutationTimeoutAndDisconnectStayHonest() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let channel = ChromeControlChannel(descriptor: descriptors[0], requestTimeout: .milliseconds(100))
        await channel.start()
        let peer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        let framer = NativeMessagingFramer()

        await #expect(throws: ChromeControlRuntimeError.outcomeUnknown(
            action: ChromeControlEffect.fill.rawValue,
            reason: ChromeControlRuntimeError.requestTimedOut.localizedDescription
        )) {
            _ = try await channel.request(action: .fill, payload: [:])
        }
        let fill = try #require(try framer.readMessage(from: peer))
        guard case .object(let fillRequest) = try JSONValue.parse(fill) else {
            throw ChromeControlRuntimeError.invalidResponse
        }
        #expect(fillRequest["action"] == .string(ChromeControlEffect.fill.rawValue))

        await #expect(throws: ChromeControlRuntimeError.requestTimedOut) {
            _ = try await channel.request(action: .snapshot, payload: [:])
        }
        _ = try #require(try framer.readMessage(from: peer))

        let disconnect = Task.detached {
            _ = try #require(try framer.readMessage(from: peer))
            try peer.close()
        }
        await #expect(throws: ChromeControlRuntimeError.outcomeUnknown(
            action: ChromeControlEffect.click.rawValue,
            reason: ChromeControlRuntimeError.disconnected.localizedDescription
        )) {
            _ = try await channel.request(action: .click, payload: [:])
        }
        try await disconnect.value
    }

    @Test("Extension refusals preserve their protocol code and explanation")
    func extensionRefusalKeepsTypedEvidence() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let channel = ChromeControlChannel(descriptor: descriptors[0])
        await channel.start()
        let peer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        let framer = NativeMessagingFramer()

        let fixture = Task.detached {
            let data = try #require(try framer.readMessage(from: peer))
            guard case .object(let request) = try JSONValue.parse(data),
                  case .string(let requestID)? = request["id"] else {
                throw ChromeControlRuntimeError.invalidResponse
            }
            let response = JSONValue.object([
                "version": .int(1), "type": .string("response"), "id": .string(requestID),
                "action": .string("page.snapshot.read"), "ok": .bool(false),
                "error": .object([
                    "code": .string("snapshot_stale"),
                    "message": .string("The page changed after capture."),
                ]),
            ])
            try framer.writeMessage(response.serializedData(pretty: false), to: peer)
        }

        await #expect(throws: ChromeControlRuntimeError.extensionRejected(
            code: "snapshot_stale",
            message: "The page changed after capture."
        )) {
            _ = try await channel.request(action: .snapshot, payload: ["leaseId": .string("lease-fixture")])
        }
        try await fixture.value
        await channel.shutdown(releaseLeases: false)
    }

    @Test("Cancelling delayed Chrome typing revokes its lease without closing the tab")
    func cancelledTypingReleasesItsLeaseWithoutClosingTheTab() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let channel = ChromeControlChannel(descriptor: descriptors[0])
        await channel.start()
        let peer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        let framer = NativeMessagingFramer()
        let typing = Task {
            try await channel.request(action: .type, payload: ["leaseId": .string("lease-cancel")])
        }
        _ = try await Task.detached { try #require(try framer.readMessage(from: peer)) }.value
        typing.cancel()
        await #expect(throws: CancellationError.self) { _ = try await typing.value }
        let cleanupData = try #require(try framer.readMessage(from: peer))
        guard case .object(let cleanup) = try JSONValue.parse(cleanupData),
              case .object(let payload)? = cleanup["payload"] else {
            throw ChromeControlRuntimeError.invalidResponse
        }
        #expect(cleanup["action"] == .string("lease.release"))
        #expect(payload["leaseId"] == .string("lease-cancel"))
        #expect(payload["closeCreatedTab"] == .bool(false))
        await channel.shutdown(releaseLeases: false)
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
        #expect(object?["nativeagent_bundle_id"] as? String == InstallPaths.privateBundleIdentifier)
        let original = try Data(contentsOf: manifestURL)
        let otherID = "test.nativeagent.mac"
        try ChromeNativeHostRegistration.install(home: home, relayURL: relay, bundleIdentifier: otherID)
        try ChromeNativeHostRegistration.uninstall(home: home, relayURL: relay, bundleIdentifier: otherID)
        #expect(try Data(contentsOf: manifestURL) == original)
        try ChromeNativeHostRegistration.uninstall(home: home, relayURL: relay)
        try ChromeNativeHostRegistration.install(home: home, relayURL: relay, bundleIdentifier: otherID)
        let other = try Data(contentsOf: manifestURL)
        try ChromeNativeHostRegistration.install(home: home, relayURL: relay)
        #expect(try Data(contentsOf: manifestURL) == other)
        var legacy = try #require(object)
        legacy.removeValue(forKey: "nativeagent_bundle_id")
        legacy["path"] = home.appendingPathComponent("OtherRelay").path
        let legacyBytes = try JSONSerialization.data(withJSONObject: legacy)
        try legacyBytes.write(to: manifestURL)
        try ChromeNativeHostRegistration.install(home: home, relayURL: relay)
        #expect(try Data(contentsOf: manifestURL) == legacyBytes)
        legacy["path"] = relay.path
        try JSONSerialization.data(withJSONObject: legacy).write(to: manifestURL)
        try ChromeNativeHostRegistration.install(home: home, relayURL: relay)
        #expect(try Data(contentsOf: manifestURL) == original)
        try Data("broken".utf8).write(to: manifestURL)
        #expect(throws: (any Error).self) { try ChromeNativeHostRegistration.install(home: home, relayURL: relay) }
        #expect(try Data(contentsOf: manifestURL) == Data("broken".utf8))
    }
}

@Suite("Chrome activity lease continuity")
struct ChromeActivityLeaseTests {
    @Test("Active work renews near expiry; expired or comfortable leases are never auto-renewed",
          arguments: [50, -10, 285])
    func renewOnlyLiveNearExpiry(remainingSeconds: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-activity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = ChromeControlRuntime(
            socketPath: directory.appendingPathComponent("s").path,
            manageNativeHostRegistration: false, authority: { true }
        )
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        await runtime.installAcceptedDescriptorForTesting(descriptors[0])
        let peer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        let fixture = Task.detached { () throws -> [String] in
            let framer = NativeMessagingFramer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let expiry = Date().addingTimeInterval(Double(remainingSeconds))
            var actions: [String] = []
            for _ in 0..<(remainingSeconds == 50 ? 3 : 2) {
                guard let data = try framer.readMessage(from: peer),
                      case .object(let request) = try JSONValue.parse(data),
                      case .string(let id)? = request["id"],
                      case .string(let action)? = request["action"] else {
                    throw ChromeControlRuntimeError.invalidResponse
                }
                actions.append(action)
                if action == "lease.renew" {
                    #expect(request["payload"] == .object([
                        "leaseId": .string("activity-lease"), "expectedUserSequence": .int(7),
                        "leaseDurationMs": .int(300_000),
                    ]))
                }
                let deadline = action == "lease.renew" ? Date().addingTimeInterval(300) : expiry
                let result: JSONValue = action == "page.snapshot.read" ? .object(["text": .string("visible content")]) : .object([
                    "leaseId": .string("activity-lease"), "userSequence": .int(7),
                    "renewedAt": .string(formatter.string(from: deadline.addingTimeInterval(-300))),
                    "expiresAt": .string(formatter.string(from: deadline)),
                ])
                let expired = remainingSeconds < 0 && action == "page.snapshot.read"
                var response: [String: JSONValue] = [
                    "version": .int(1), "type": .string("response"), "id": .string(id),
                    "action": .string(action), "ok": .bool(!expired),
                ]
                if expired {
                    response["error"] = .object(["code": .string("lease_expired"), "message": .string("Expired")])
                } else { response["result"] = result }
                try framer.writeMessage(JSONValue.object(response).serializedData(pretty: false), to: peer)
            }
            return actions
        }
        _ = try await runtime.perform(.acquire, payload: ["mode": .string("create")])
        if remainingSeconds < 0 {
            await #expect(throws: ChromeControlRuntimeError.extensionRejected(code: "lease_expired", message: "Expired")) {
                _ = try await runtime.perform(.snapshot, payload: ["leaseId": .string("activity-lease")])
            }
        } else {
            _ = try await runtime.perform(.snapshot, payload: ["leaseId": .string("activity-lease")])
        }
        let actions = try await fixture.value
        #expect(actions == (remainingSeconds == 50
            ? ["lease.acquire", "lease.renew", "page.snapshot.read"]
            : ["lease.acquire", "page.snapshot.read"]))
        await runtime.stop()
    }
}
