import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import TrustCenter

@Suite struct AgentCommunicationContractTests {
    @Test func connectionDefaultsToDiscoveryWithOptionalTransport() throws {
        let schema = try #require(BuiltInToolSchemaFactory(requestedNames: ["agent_connect"])
            .agentCommunicationSchemas().compactMap { $0 }.first)
        let decoded = try JSONSerialization.jsonObject(with: schema.parametersJSON) as! [String: Any]
        #expect(Set(decoded["required"] as! [String]) == Set(["name"]))
        let fields = decoded["properties"] as! [String: [String: Any]]
        #expect((fields["transport"]?["type"] as? [String])?.contains("null") == true)
        #expect((fields["transport"]?["enum"] as? [Any])?.contains(where: { $0 as? String == "auto" }) == true)
    }
    @Test func strictProviderSchemasAdmitNullForInapplicableAdapterFields() throws {
        let schema = try #require(BuiltInToolSchemaFactory(requestedNames: ["agent_read"])
            .agentCommunicationSchemas().compactMap { $0 }.first)
        let decoded = try JSONSerialization.jsonObject(with: schema.parametersJSON) as! [String: Any]
        let fields = decoded["properties"] as! [String: [String: Any]]
        #expect(fields["agent"]?["type"] as? String == "string")
        for name in ["task_id", "conversation_id", "limit", "offset", "message_id"] {
            #expect((fields[name]?["type"] as? [String])?.contains("null") == true)
        }
        #expect(fields["max_chars"] == nil, "Fixed NativeAgent reply pages avoid an inapplicable knob on every local read")
    }
    @Test func discoveryExposesSmallLazyContractWithoutChangingAlwaysOnPrompt() throws {
        let names: Set<String> = ["agent_contacts", "agent_connect", "agent_message", "agent_read"]
        let factory = BuiltInToolSchemaFactory(requestedNames: names)
        let schemas = factory.agentCommunicationSchemas().compactMap { $0 }
        #expect(Set(schemas.map(\.name)) == names)
        #expect(names.isSubset(of: Set(SwiftToolDispatcher.builtInToolNames)))
        #expect(names.isDisjoint(with: SwiftToolDispatcher.alwaysOnCoreNames))
        for schema in schemas {
            let value = try #require(JSONSerialization.jsonObject(with: schema.parametersJSON) as? [String: Any])
            #expect(value["type"] as? String == "object")
        }
        #expect(BuiltInToolSchemaFactory(requestedNames: ["read_file"]).agentCommunicationSchemas().isEmpty)
    }

    @Test func remoteMessageKeepsSendRiskAndCredentialsAreRedactedAtTraceBoundary() throws {
        let root = URL(fileURLWithPath: "/fixture/nativeagent")
        #expect(SwiftNativeSecurityCenter.canonicalToolRisk(tool: "agent_message", input: [:], dataRoot: root) == .high)
        #expect(SwiftNativeSecurityCenter.canonicalToolRisk(tool: "agent_connect", input: [:], dataRoot: root) == .high)
        #expect(SwiftNativeSecurityCenter.canonicalToolRisk(tool: "agent_contacts", input: [:], dataRoot: root) == .low)
        let value = TurnTraceRedactor.redactValue(.object([
            "name": .string("Peer"), "bearer_token": .string("fixture-only-short-secret"),
            "nested": .object(["bearer_token": .string("another-fixture-secret")])
        ]))
        let text = try value.serialize(pretty: false)
        #expect(!text.contains("fixture-only-short-secret"))
        #expect(!text.contains("another-fixture-secret"))
        #expect(text.contains("Peer"))
    }
}
