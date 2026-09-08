import Foundation
import Testing
@testable import NativeAgentApp

@Suite("NextGenCoding")
struct NextGenCodingTests {
    @Test(arguments: ["1e100", "\"1e100\"", "\"nan\"", "\"inf\""])
    func invalidPrimaryCountTriesAlias(_ primary: String) throws {
        let json = "{\"receiptCount\":\(primary),\"receipt_count\":7}"
        let summary = try JSONDecoder().decode(NextGenSummary.self, from: Data(json.utf8))
        #expect(summary.receiptCount == 7)
    }

    @Test func checkedProjectionsPreserveTruncationAndDisplayFallback() {
        #expect(NextGenJSONValue.number(1e100).intValue == nil)
        #expect(NextGenJSONValue.number(1e100).displayString == String(1e100))
        #expect(NextGenJSONValue.number(.infinity).intValue == nil)
        #expect(NextGenJSONValue.number(.nan).intValue == nil)
        #expect(NextGenJSONValue.string("-2.9").intValue == -2)
        #expect(NextGenJSONValue.string("phase-7").intValue == 7)
        #expect(NextGenJSONValue.number(2).displayString == "2")
    }
}
