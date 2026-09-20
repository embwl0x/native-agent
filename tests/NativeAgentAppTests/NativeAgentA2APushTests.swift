import Foundation
import Testing
import PersistenceCore
import ChatOrchestration
@testable import NativeAgentApp

struct NativeAgentA2APushTests {
    @Test func webhookAddressPolicyRejectsMetadataAndPrivateNetworks() async throws {
        for address in ["169.254.169.254", "169.254.170.2", "100.100.100.200", "168.63.129.16", "198.18.0.1", "10.0.0.1", "172.16.1.1", "192.168.0.1", "0.0.0.0", "224.0.0.1", "::", "fe80::1", "fc00::1", "::ffff:169.254.169.254", "64:ff9b::a9fe:a9fe", "2002:a9fe:a9fe::1"] {
            #expect(!AgentContactPushConfig.allowed(address, allowHTTP: false))
        }
        #expect(AgentContactPushConfig.allowed("127.0.0.1", allowHTTP: true))
        #expect(AgentContactPushConfig.allowed("::1", allowHTTP: true))
        #expect(AgentContactPushConfig.allowed("8.8.8.8", allowHTTP: false))
        #expect(AgentContactPushConfig.allowed("192.5.6.30", allowHTTP: false))
        #expect(AgentContactPushConfig.allowed("198.41.0.4", allowHTTP: false))
        #expect(!AgentContactPushConfig.allowed("8.8.8.8", allowHTTP: true))
        for url in ["http://8.8.8.8/hook", "https://169.254.169.254/latest", "file:///tmp/hook", "https://user:password@127.0.0.1/hook", "http://127.0.0.1/hook#fragment"] {
            await #expect(throws: (any Error).self) { try await AgentContactPushConfig.destination(url) }
        }
    }

    @Test func pushConfigurationIsOwnedPaginatedAndDeletedIdempotently() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("a2a-push-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let tasks = AgentContactTasks(dataRoot: root) { _, _ in .init(state: .completed, parts: []) }
        let send = NativeAgentA2AWire.Send(rpcID: "push", context: "context", request: "request", text: "hello", clientMessageID: UUID().uuidString)
        let task = try await tasks.send(send, principal: .anonymous, digest: "push-proof")
        _ = try await tasks.settled(task.id, owner: AgentBridgePrincipal.anonymous.id)
        func parameters(_ id: String) -> JSONValue {
            .object(["id": .string(id), "taskId": .string(task.id), "url": .string("http://127.0.0.1:9/hook"),
                     "authentication": .object(["scheme": .string("Bearer"), "credentials": .string("test-only")])])
        }
        let owner = AgentBridgePrincipal.anonymous.id
        for id in ["a", "b"] { _ = try await tasks.push(operation: "CreateTaskPushNotificationConfig", owner: owner, parameters: parameters(id)) }
        let first = try await tasks.push(operation: "ListTaskPushNotificationConfigs", owner: owner,
            parameters: .object(["taskId": .string(task.id), "pageSize": .int(1)]))
        guard case .object(let page) = first, case .array(let configs)? = page["configs"] else { Issue.record("Missing config page"); return }
        #expect(configs.count == 1)
        #expect(page["nextPageToken"] == .string("a"))
        await #expect(throws: (any Error).self) {
            try await tasks.push(operation: "GetTaskPushNotificationConfig", owner: "another-peer", parameters: parameters("a"))
        }
        for _ in 0..<2 { _ = try await tasks.push(operation: "DeleteTaskPushNotificationConfig", owner: owner, parameters: parameters("a")) }
        await #expect(throws: (any Error).self) {
            try await tasks.push(operation: "GetTaskPushNotificationConfig", owner: owner, parameters: parameters("a"))
        }
    }
}
