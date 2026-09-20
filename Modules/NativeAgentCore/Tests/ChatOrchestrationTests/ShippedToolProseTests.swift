import Foundation
import Testing
@testable import ChatOrchestration

@Suite struct ShippedToolProseTests {
    @Test func durableExamplesStandAloneWithinMainlineBudgets() throws {
        let schemas = BuiltInToolSchemaFactory(requestedNames: nil).schemas(
            includeFullMacFileTools: true, includeFullMacSystemTools: true, includeFullMacAppTools: true,
            includeFullMacAccessibilityReadTools: true, includeFullMacAccessibilityInjectionTools: true,
            includeActivityQueryTool: true)
        let memory = try #require(schemas.first { $0.name == "commit_memory" })
        #expect(memory.description.count <= 1230)
        #expect(memory.description.contains("Sam wants pixels"))
        #expect(memory.description.contains("Sam drinks coffee black"))
        #expect(!memory.description.contains("the person"))
        func field(_ tool: String, _ key: String) throws -> String {
            let schema = try #require(schemas.first { $0.name == tool })
            let json = try #require(JSONSerialization.jsonObject(with: schema.parametersJSON) as? [String: Any])
            let properties = try #require(json["properties"] as? [String: [String: Any]])
            return try #require(properties[key]?["description"] as? String)
        }
        let text = try field("commit_memory", "text")
        #expect(text.count <= 292)
        #expect(text.contains("Sam wants pixels"))
        let provenance = try field("commit_memory", "provenance_by")
        #expect(provenance.count <= 59)
        #expect(provenance.contains("\"Sam\""))
        let assignee = try field("desk_add_item", "assignee")
        #expect(assignee.count <= 72)
        #expect(assignee.contains("the coding agent"))
    }

    @Test func builtInAndConnectorDescriptionsHaveNoPersonalNames() throws {
        let schemas = BuiltInToolSchemaFactory(requestedNames: nil).schemas(
            includeFullMacFileTools: true, includeFullMacSystemTools: true, includeFullMacAppTools: true,
            includeFullMacAccessibilityReadTools: true, includeFullMacAccessibilityInjectionTools: true,
            includeActivityQueryTool: true)
        let names = try NSRegularExpression(pattern: #"(?i)\b(user|agent|nova|claude)\b"#)
        func check(_ text: String, tool: String) {
            #expect(names.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil,
                "Personal name in \(tool): \(text)")
        }
        func walk(_ value: Any, tool: String) {
            if let object = value as? [String: Any] {
                for (key, child) in object {
                    if ["description", "title"].contains(key), let text = child as? String { check(text, tool: tool) }
                    else { walk(child, tool: tool) }
                }
            } else if let array = value as? [Any] { array.forEach { walk($0, tool: tool) } }
        }
        for schema in schemas {
            check(schema.description, tool: schema.name)
            walk(try JSONSerialization.jsonObject(with: schema.parametersJSON), tool: schema.name)
        }
        #expect(schemas.contains { $0.name == "desk_nag_control" && $0.description.contains("the person's switch") })
    }
}
