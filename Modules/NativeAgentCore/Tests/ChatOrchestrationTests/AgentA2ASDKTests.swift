import Foundation
import Testing
import PersistenceCore
@testable import ChatOrchestration

@Suite struct AgentA2ASDKTests {
    private func fixture(_ version: String) throws -> [String: JSONValue] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("tests/a2a_sdk/fixtures/sdk-\(version).json"))
        guard case .object(let result) = try JSONValue.parse(data) else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }

    @Test(arguments: ["1.0", "0.3"])
    func pinnedOfficialSDKWires(version: String) throws {
        let wire = try fixture(version)
        let cardURL = URL(string: "http://127.0.0.1:9999/.well-known/agent-card.json")!
        let selected = try AgentA2AWire.selectInterface(card: #require(wire["card"]), cardURL: cardURL)
        #expect(selected.version == version)
        try SwiftToolDispatcher.peerAuthorizeInterface(selected, cardURL: cardURL, hasCredential: true)
        #expect(throws: (any Error).self) {
            try SwiftToolDispatcher.peerAuthorizeInterface(selected, cardURL: cardURL, hasCredential: false)
        }
        let request = try AgentA2AWire.messageRequest(text: "Hello", messageID: "m1", interface: selected, requestID: "r1")
        // SDK includes optional empty acceptedOutputModes in the legacy shape.
        guard case .object(var expected) = try #require(wire["send"]),
              case .object(var params)? = expected["params"],
              case .object(var config)? = params["configuration"] else { Issue.record("SDK request"); return }
        if config["acceptedOutputModes"] == .array([]) { config.removeValue(forKey: "acceptedOutputModes") }
        params["configuration"] = .object(config); expected["params"] = .object(params)
        #expect(request.body == .object(expected))
        let reply = try AgentA2AWire.normalizeResponse(#require(wire["reply"]), interface: selected, expectedRequestID: "r1")
        #expect(reply.text == "Hello from the SDK" && !reply.completed)
        let task = try AgentA2AWire.normalizeResponse(#require(wire["task"]), interface: selected, expectedRequestID: "r1")
        #expect(task.taskID == "t1" && !task.completed)
        let done = try AgentA2AWire.normalizeResponse(#require(wire["get"]), interface: selected, expectedRequestID: "r1", expectedTaskID: "t1")
        #expect(done.completed)
        guard case .array(let events)? = wire["events"] else { Issue.record("SDK events"); return }
        let interrupted = try AgentA2AStream.normalize(Array(events.prefix(2)), interface: selected, requestID: "r1")
        #expect(interrupted.interrupted && interrupted.result?.completed == false)
        #expect(interrupted.result?.taskID == "t1")
        let needsAnswer = try AgentA2AStream.normalize(events, interface: selected, requestID: "r1")
        #expect(needsAnswer.result?.needsInput == true && needsAnswer.result?.completed == false)
        #expect(!needsAnswer.interrupted)
        let artifact = try AgentA2AStream.normalize([events[0], #require(wire["artifact"])], interface: selected, requestID: "r1")
        #expect(artifact.interrupted && artifact.result?.completed == false)
        #expect(artifact.result?.artifacts.count == 1)
        #expect(throws: (any Error).self) {
            try AgentA2AStream.normalize([events[1]], interface: selected, requestID: "r1")
        }
        #expect(throws: (any Error).self) {
            try AgentA2AStream.normalize(events, interface: selected, requestID: "wrong")
        }
        let complete = try events[0].serializedData(pretty: false)
        var sse = Data(": comment\r\ndata: ".utf8)
        sse.append(complete); sse.append(Data("\r\n\r\ndata: {\"partial\":".utf8))
        #expect(try AgentA2AStream.events(in: sse) == [events[0]])
    }

    private struct Peer: Decodable {
        let url: URL
        let version: String
        let binding: String
        let token: String
        let revoke: String
        let webhook: String
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NATIVEAGENT_A2A_TEST_PEERS"] != nil))
    func officialSDKPeers() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["NATIVEAGENT_A2A_TEST_PEERS"])
        let peers = try JSONDecoder().decode([Peer].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(peers.count == 4)
        for peer in peers {
            let card = try await AgentPeerHTTP.get(peer.url)
            let selected = try await AgentPeerDiscovery.authenticatedInterface(card: #require(card.json), cardURL: peer.url, bearerToken: peer.token)
            #expect(selected.version == peer.version && selected.binding == peer.binding)
            try SwiftToolDispatcher.peerAuthorizeInterface(selected, cardURL: peer.url, hasCredential: true)

            func send(_ text: String, streaming: Bool = false) async throws -> AgentA2AStream.Receipt {
                let request = try AgentA2AWire.messageRequest(text: text, messageID: UUID().uuidString,
                    interface: selected, streaming: streaming)
                let response = try await AgentPeerHTTP.send(request, bearerToken: peer.token, timeout: 8)
                #expect(response.statusCode == 200)
                if streaming {
                    return try AgentA2AStream.normalize(response.events, interface: selected, requestID: request.requestID)
                }
                let result = try AgentA2AWire.normalizeResponse(#require(response.json), interface: selected, expectedRequestID: request.requestID)
                return .init(result: result, interrupted: false)
            }

            func read(_ id: String, cancel: Bool = false) async throws -> AgentA2AWire.Result {
                let request = try cancel ? AgentA2AWire.cancelRequest(taskID: id, interface: selected)
                    : AgentA2AWire.taskRequest(taskID: id, interface: selected)
                let response = try await AgentPeerHTTP.send(request, bearerToken: peer.token, timeout: 8)
                #expect(response.statusCode == 200)
                return try AgentA2AWire.normalizeResponse(#require(response.json), interface: selected,
                    expectedRequestID: request.requestID, expectedTaskID: id)
            }

            let greeting = try await send("hello")
            #expect(greeting.result?.text == "Hello from the SDK")
            #expect(greeting.result?.completed == false)
            let tracked = try await send("tracked")
            var progress = try #require(tracked.result)
            #expect(!progress.completed)
            let id = try #require(progress.taskID)
            for _ in 0..<30 {
                progress = try await read(id)
                if progress.terminal { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(progress.completed && progress.text == "Finished by the SDK")

            if selected.version == "1.0" {
                let subscribed = try await send("subscribe")
                let subscribedID = try #require(subscribed.result?.taskID)
                let request = try AgentA2AWire.operationRequest("SubscribeToTask",
                    parameters: ["id": .string(subscribedID)], interface: selected)
                let response = try await AgentPeerHTTP.send(request, bearerToken: peer.token, timeout: 8)
                let receipt = try AgentA2AStream.normalize(response.events, interface: selected, requestID: request.requestID)
                #expect(receipt.result?.completed == true && !receipt.interrupted)
            }
            let stream = try await send("stream", streaming: true)
            #expect(stream.result?.completed == true && !stream.interrupted)
            let interrupted = try await send("interrupt", streaming: true)
            #expect(interrupted.interrupted && interrupted.result?.completed == false)
            #expect(interrupted.result?.state == "working")
            #expect(interrupted.result?.taskID != nil)
            let input = try await send("input", streaming: true)
            #expect(input.result?.needsInput == true && input.result?.completed == false)
            #expect(input.result?.text == "Please answer before I continue")
            let auth = try await send("auth", streaming: true)
            #expect(auth.result?.needsAuthentication == true && auth.result?.completed == false)
            let pending = try await send("cancel")
            let canceledID = try #require(pending.result?.taskID)
            let canceled = try await read(canceledID, cancel: true)
            #expect(canceled.state == "canceled" && canceled.terminal && !canceled.completed)

            if selected.version == "1.0" {
                func operation(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
                    let request = try AgentA2AWire.operationRequest(method, parameters: params, interface: selected)
                    let response = try await AgentPeerHTTP.send(request, bearerToken: peer.token, timeout: 8)
                    #expect(response.statusCode == 200)
                    return try AgentA2AWire.operationResult(#require(response.json), interface: selected, requestID: request.requestID)
                }
                let extended = try await operation("GetExtendedAgentCard")
                if case .object(let value) = extended { #expect(value["name"] == .string("SDK test peer extended")) }
                let listRequest = try AgentA2AWire.operationRequest("ListTasks", parameters: ["pageSize": .int(1)], interface: selected)
                let listResponse = try await AgentPeerHTTP.send(listRequest, bearerToken: peer.token)
                #expect(listResponse.statusCode == 200)
                let listing = try AgentA2AWire.normalizeTaskList(#require(listResponse.json), interface: selected, requestID: listRequest.requestID)
                if case .object(let value) = listing { #expect(value["tasks"] != nil) }
                let configID = "nativeagent-sdk-proof"
                let config: [String: JSONValue] = ["id": .string(configID), "taskId": .string(canceledID), "url": .string(peer.webhook)]
                let created = try await operation("CreateTaskPushNotificationConfig", config)
                if case .object(let value) = created { #expect(value["id"] == .string(configID)) }
                let identity: [String: JSONValue] = ["taskId": .string(canceledID), "id": .string(configID)]
                let fetched = try await operation("GetTaskPushNotificationConfig", identity)
                #expect(fetched == created)
                _ = try await operation("ListTaskPushNotificationConfigs", ["taskId": .string(canceledID)])
                _ = try await operation("DeleteTaskPushNotificationConfig", identity)
            }

            let badURL = peer.url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("incompatible.json")
            let incompatible = try await AgentPeerHTTP.get(badURL)
            #expect(throws: AgentA2AWire.WireError.self) {
                try AgentA2AWire.selectInterface(card: #require(incompatible.json), cardURL: badURL)
            }
            // This very credential worked above; revoke it without touching Keychain.
            try Data().write(to: URL(fileURLWithPath: peer.revoke))
            let request = try AgentA2AWire.messageRequest(text: "hello", messageID: UUID().uuidString, interface: selected)
            let denied = try await AgentPeerHTTP.send(request, bearerToken: peer.token, timeout: 8)
            #expect(denied.statusCode == 401 && denied.events.isEmpty)
        }
    }
}
