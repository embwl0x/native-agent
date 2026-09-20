import Darwin
import Foundation
import NativeAgentChromeRelayCore
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("Chrome call reconnection")
struct ChromeReconnectTests {
    @Test("Disconnected snapshot and navigate recover through a fresh relay hello", arguments: [ChromeControlEffect.snapshot, .navigate])
    func reconnectInsideCall(effect: ChromeControlEffect) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cr-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s").path
        let runtime = ChromeControlRuntime(socketPath: path, manageNativeHostRegistration: false,
                                           reconnectTimeout: .seconds(3), authority: { true })
        var payload: [String: JSONValue] = ["leaseId": .string("lease-live")]
        if effect == .navigate { payload["url"] = .string("https://example.com/") }
        let requestPayload = payload
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        await runtime.installAcceptedDescriptorForTesting(descriptors[0])
        let oldPeer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        let framer = NativeMessagingFramer()
        // Snapshot loses a dispatched read; navigate starts on a channel already
        // closed by an invalid read response, so no mutation can be duplicated.
        let drop = Task.detached {
            let data = try #require(try framer.readMessage(from: oldPeer))
            if effect == .navigate {
                guard case .object(let request) = try JSONValue.parse(data) else { throw ChromeControlRuntimeError.invalidResponse }
                try framer.writeMessage(JSONValue.object([
                    "version": .int(1), "type": .string("response"), "id": request["id"]!,
                    "action": .string("wrong"), "ok": .bool(true), "result": .object([:]),
                ]).serializedData(pretty: false), to: oldPeer)
            }
            try oldPeer.close()
        }
        if effect == .navigate {
            await #expect(throws: ChromeControlRuntimeError.invalidResponse) {
                _ = try await runtime.perform(.snapshot, payload: payload)
            }
        }
        let relay = Task.detached {
            // Simulate Chrome launching the replacement host once its app
            // destination is ready, using the real socket and token handshake.
            for _ in 0..<200 where !FileManager.default.fileExists(atPath: path) {
                try await Task.sleep(for: .milliseconds(5))
            }
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            #expect(fd >= 0)
            let peer = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? peer.close() }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = path.utf8CString
            withUnsafeMutableBytes(of: &address.sun_path) { target in
                for (index, byte) in bytes.enumerated() { target[index] = UInt8(bitPattern: byte) }
            }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            #expect(connected == 0)
            let token = try String(contentsOfFile: ChromeControlHandshake.tokenPath(forSocketPath: path), encoding: .utf8)
            try framer.writeMessage(JSONValue.object([
                "version": .int(1), "type": .string("hello"), "token": .string(token),
            ]).serializedData(pretty: false), to: peer)
            _ = try #require(try framer.readMessage(from: peer)) // hello_ack
            let data = try #require(try framer.readMessage(from: peer))
            guard case .object(let request) = try JSONValue.parse(data) else { throw ChromeControlRuntimeError.invalidResponse }
            #expect(request["action"] == .string(effect.rawValue))
            #expect(request["payload"] == .object(requestPayload))
            try framer.writeMessage(JSONValue.object([
                "version": .int(1), "type": .string("response"), "id": request["id"]!,
                "action": .string(effect.rawValue), "ok": .bool(true),
                "result": .object(["reconnected": .bool(true)]),
            ]).serializedData(pretty: false), to: peer)
        }
        let result = try await runtime.perform(effect, payload: payload)
        guard case .object(let object) = result else { throw ChromeControlRuntimeError.invalidResponse }
        #expect(object["result"] == .object(["reconnected": .bool(true)]))
        try await drop.value
        try await relay.value
        await runtime.stop()
    }

    @Test("Missing replacement connection has a bounded deadline")
    func reconnectDeadline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cr-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = ChromeControlRuntime(socketPath: directory.appendingPathComponent("s").path,
            manageNativeHostRegistration: false, reconnectTimeout: .milliseconds(20), authority: { true })
        await #expect(throws: ChromeControlRuntimeError.disconnected) {
            _ = try await runtime.perform(.snapshot, payload: ["leaseId": .string("lease-live")])
        }
        await runtime.stop()
    }
}
