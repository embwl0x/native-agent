import Foundation
import Testing
import PersistenceCore
@testable import ChatOrchestration

@Test func toolArgumentCoercionPreservesMeaning() throws {
    let schema = try JSONValue.parse(Data(#"""
    {"properties":{
      "count":{"type":"integer"}, "ratio":{"type":["number","null"]},
      "enabled":{"type":["boolean","null"]}, "text":{"type":"string"},
      "mode":{"type":"string","enum":["read_only","write"]},
      "rows":{"type":"array","items":{"type":"object","properties":{"enabled":{"type":"boolean"}}}},
      "ids":{"type":"array","items":{"type":"string"}},
      "required":{"type":"string"}, "optional":{"type":"string"},
      "union":{"type":["string","number"]}
    },"required":["required"]}
    """#.utf8))
    let input: [String: JSONValue] = [
        "count": .string(" 42 "), "ratio": .string(" 1.25 "), "enabled": .string(" FALSE "),
        "text": .string(""), "mode": .string(" Read  Only "),
        "rows": .array([.object(["enabled": .string("true")])]),
        "ids": .array([.int(9007199254740993), .double(12)]),
        "required": .null, "optional": .null, "extra": .null, "union": .string("12")
    ]
    let result = ToolArguments.normalized(input, schema: schema)
    #expect(result == [
        "count": .int(42), "ratio": .double(1.25), "enabled": .bool(false),
        "text": .string(""), "mode": .string("read_only"),
        "rows": .array([.object(["enabled": .bool(true)])]),
        "ids": .array([.string("9007199254740993"), .string("12")]),
        "required": .null, "extra": .null, "union": .string("12")
    ])
    #expect(ToolArguments.normalized(result, schema: schema) == result)
    for input: [String: JSONValue] in [
        ["count": .double(1.5), "ratio": .string("NaN"), "enabled": .string("maybe")],
        ["count": .string("9223372036854775808"), "text": .bool(false), "mode": .string("unknown")]
    ] {
        #expect(ToolArguments.normalized(input, schema: schema) == input)
    }
}
