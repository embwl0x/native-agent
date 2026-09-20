import Foundation
import Testing
import PersistenceCore
@testable import ProviderRouting

@Suite("RequestPrefixReceipt")
struct RequestPrefixReceiptTests {
    @Test("each request measures its encoded tools and stable block without the dynamic tail")
    func perRequestBytes() throws {
        let prefix = ConversationPrefixTelemetrySnapshot(
            shapeVersion: "v2Prefix", prefixFingerprintSHA256: "old-turn-value",
            historyMessageCount: 0, historyMessageChars: 0, volatileBlockChars: 0,
            volatileDelivery: "systemClearAt", windowCursorAdvanceCount: 0, windowSlid: false
        )
        func receipt(tools: String, stable: String = "stable", dynamic: String = "now") -> [String: JSONValue] {
            RequestPrefixReceipt.payload(Data("""
            {"system":[{"text":"identity"},{"text":"\(stable)","cache_control":{"type":"ephemeral"}},{"text":"\(dynamic)"}],"tools":\(tools),"messages":[{"role":"user","content":"hello"}]}
            """.utf8), prefix: prefix)
        }
        let tools = #"[{"name":"read","input_schema":{"description":"quotes: \"[]{}\" and slash \\","type":"object"}}]"#
        let first = receipt(tools: tools)
        let loaded = receipt(tools: tools.replacingOccurrences(of: "read", with: "read_more"))
        let changed = receipt(tools: tools, stable: "changed")
        #expect(first["tools.wireSchemaBytes"] == .int(Int64(tools.utf8.count)))
        #expect(first == receipt(tools: tools, dynamic: "later"))
        #expect(first["component.toolsSHA256"] != loaded["component.toolsSHA256"])
        #expect(first["component.stablePrefixSHA256"] == loaded["component.stablePrefixSHA256"])
        #expect(first["component.stablePrefixSHA256"] != changed["component.stablePrefixSHA256"])
        #expect(first["prefixFingerprintSHA256"] != loaded["prefixFingerprintSHA256"])
        #expect(first["prefixFingerprintSHA256"] != changed["prefixFingerprintSHA256"])
        for body in [
            #"{"instructions":"stable","tools":[]}"#,
            #"{"messages":[{"role":"system","content":"stable"}],"tools":[]}"#
        ] {
            let a = RequestPrefixReceipt.payload(Data(body.utf8), prefix: prefix)
            let b = RequestPrefixReceipt.payload(Data(body.replacingOccurrences(of: "stable", with: "changed").utf8), prefix: prefix)
            #expect(a["component.stablePrefixSHA256"] != b["component.stablePrefixSHA256"])
        }
    }
}
