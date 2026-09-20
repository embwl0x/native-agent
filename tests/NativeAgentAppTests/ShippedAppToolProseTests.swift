import Foundation
import Testing
@testable import NativeAgentApp

@Suite struct ShippedAppToolProseTests {
    @Test func appDescriptionsHaveNoPersonalNames() throws {
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
        for schema in AppChatToolDispatcher.appToolSchemas() {
            check(schema.description, tool: schema.name)
            walk(try JSONSerialization.jsonObject(with: schema.parametersJSON), tool: schema.name)
        }
    }
}
