import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import ChatOrchestration

@Suite("Agent workspace owner-schema forms")
struct AgentWorkspaceFormTests {
    private func form(_ parameters: String, bound: [String: JSONValue] = [:]) throws -> AgentWorkspaceForm {
        try AgentWorkspaceForm(schema: LLMToolSchema(name: "fixture_owner", description: "Fixture capability",
            parametersJSON: Data(parameters.utf8)), title: "Fixture", bound: bound)
    }

    private func fields(_ entries: [(String, String)]) -> JSONValue {
        .array(entries.map { .object(["field": .string($0.0), "value": .string($0.1)]) })
    }

    @Test func convertsTypedValuesWithoutLosingTheirStructure() throws {
        let value = try form(#"{"type":"object","properties":{"count":{"type":"integer"},"enabled":{"type":"boolean"},"rows":{"type":"array","items":{"type":"string"}},"options":{"type":"object"},"ratio":{"type":"number"}},"required":["count","enabled","rows","options"]}"#)
        let args = try value.arguments(fields: fields([
            ("count", "3"), ("enabled", "false"), ("rows", #"["a","b"]"#),
            ("options", #"{"nested":{"ready":true},"nothing":null}"#), ("ratio", "1.5"),
        ]), text: nil)
        #expect(args["count"] == .int(3))
        #expect(args["enabled"] == .bool(false))
        #expect(args["rows"] == .array([.string("a"), .string("b")]))
        #expect(args["options"] == .object(["nested": .object(["ready": .bool(true)]), "nothing": .null]))
        #expect(args["ratio"] == .double(1.5))
        #expect(value.singleTextField == nil)
    }

    @Test func missingRequiredAndWrongTypesAreRefused() throws {
        let value = try form(#"{"type":"object","properties":{"count":{"type":"integer"},"enabled":{"type":"boolean"},"rows":{"type":"array"},"options":{"type":"object"}},"required":["count"]}"#)
        #expect(throws: AgentWorkspaceForm.Failure.self) { try value.arguments(fields: nil, text: nil) }
        for (name, raw) in [("count", "1.5"), ("count", "true"), ("enabled", "1"),
                            ("rows", "{}"), ("rows", "["), ("options", "[]")] {
            var entries = [("count", "2")]
            if name == "count" { entries = [(name, raw)] } else { entries.append((name, raw)) }
            #expect(throws: AgentWorkspaceForm.Failure.self) { try value.arguments(fields: fields(entries), text: nil) }
        }
    }

    @Test func selectedTargetCannotBeReplacedByUserFields() throws {
        let value = try form(#"{"type":"object","properties":{"target":{"type":"string"},"message":{"type":"string"}},"required":["target","message"]}"#,
            bound: ["target": .string("peer:exact-selected-contact")])
        #expect(value.required == ["message"])
        #expect(value.properties["target"] == nil)
        let args = try value.arguments(fields: nil, text: "Hello")
        #expect(args == ["target": .string("peer:exact-selected-contact"), "message": .string("Hello")])
        #expect(throws: AgentWorkspaceForm.Failure.self) {
            try value.arguments(fields: fields([("target", "peer:different-contact"), ("message", "Hello")]), text: nil)
        }
        #expect(throws: AgentWorkspaceForm.Failure.self) {
            try form(#"{"type":"object","properties":{"message":{"type":"string"}}}"#, bound: ["unknown": .string("target")])
        }
    }

    @Test func duplicateUnknownHarnessAndMalformedFieldsAreRefused() throws {
        let value = try form(#"{"type":"object","properties":{"message":{"type":"string"},"__session_id":{"type":"string"},"current_session_id":{"type":"string"},"sender":{"type":"string"},"surface":{"type":"string"}},"required":["message","__session_id"]}"#)
        #expect(value.required == ["message"])
        #expect(Set(value.properties.keys) == ["message"])
        #expect(throws: AgentWorkspaceForm.Failure.self) {
            try value.arguments(fields: fields([("message", "a"), ("message", "b")]), text: nil)
        }
        for forbidden in ["unknown", "__session_id", "current_session_id", "sender", "surface"] {
            #expect(throws: AgentWorkspaceForm.Failure.self) {
                try value.arguments(fields: fields([("message", "hello"), (forbidden, "injected")]), text: nil)
            }
        }
        let malformed: [JSONValue] = [
            .object(["message": .string("hello")]),
            .array([.object(["field": .string("message"), "value": .string("hello"), "extra": .bool(true)])]),
            .array([.object(["field": .string("message"), "value": .bool(true)])]),
        ]
        for supplied in malformed {
            #expect(throws: AgentWorkspaceForm.Failure.self) { try value.arguments(fields: supplied, text: nil) }
        }
    }

    @Test func textShortcutFillsOnlyTheSingleRequiredString() throws {
        let value = try form(#"{"type":"object","properties":{"message":{"type":"string"},"urgent":{"type":"boolean"}},"required":["message"]}"#)
        #expect(value.singleTextField == "message")
        let args = try value.arguments(fields: fields([("urgent", "true")]), text: "A plain message")
        #expect(args == ["message": .string("A plain message"), "urgent": .bool(true)])
        #expect(throws: AgentWorkspaceForm.Failure.self) {
            try value.arguments(fields: fields([("message", "first")]), text: "second")
        }
        let two = try form(#"{"type":"object","properties":{"title":{"type":"string"},"body":{"type":"string"}},"required":["title","body"]}"#)
        #expect(two.singleTextField == nil)
        #expect(throws: AgentWorkspaceForm.Failure.self) { try two.arguments(fields: nil, text: "ambiguous") }
    }

    @Test func nullEmptyAndOmittedValuesKeepDistinctMeanings() throws {
        let value = try form(#"{"type":"object","properties":{"message":{"type":["string","null"]},"count":{"type":["integer","null"]},"optional":{"type":"boolean"}},"required":["message"]}"#)
        let empty = try value.arguments(fields: .null, text: "")
        #expect(empty == ["message": .string("")], "An explicit empty string remains for the owner to validate.")
        let args = try value.arguments(fields: fields([("message", "null"), ("count", "null")]), text: nil)
        #expect(args["message"] == .string("null"), "String fields preserve literal text, including the word null.")
        #expect(args["count"] == .null)
        #expect(args["optional"] == nil)
        let cleared = try value.arguments(fields: .array([
            .object(["field": .string("message"), "value": .null]),
            .object(["field": .string("count"), "value": .null]),
        ]), text: nil)
        #expect(cleared == ["message": .null, "count": .null])
        #expect(throws: AgentWorkspaceForm.Failure.self) {
            try value.arguments(fields: .array([
                .object(["field": .string("message"), "value": .string("hello")]),
                .object(["field": .string("optional"), "value": .null]),
            ]), text: nil)
        }
        #expect(throws: AgentWorkspaceForm.Failure.self) { try value.arguments(fields: .null, text: nil) }
        #expect(throws: AgentWorkspaceForm.Failure.self) {
            try value.arguments(fields: fields([("message", "hello"), ("count", "")]), text: nil)
        }
    }

    @Test func nullablePrimitiveUnionsAcceptPlainTextAndExplicitNull() throws {
        for keyword in ["anyOf", "oneOf"] {
            let value = try form("""
            {"type":"object","properties":{"message":{"\(keyword)":[{"type":"string"},{"type":"null"}]}},"required":["message"]}
            """)
            #expect(value.singleTextField == "message")
            #expect(try value.arguments(fields: nil, text: "hello") == ["message": .string("hello")])
            #expect(try value.arguments(fields: nil, text: "null") == ["message": .string("null")])
            #expect(try value.arguments(fields: .array([
                .object(["field": .string("message"), "value": .null]),
            ]), text: nil) == ["message": .null])
        }
    }

    @Test func explicitNullRespectsOwnerEnumAndCombinedTypeRestrictions() throws {
        let schemas = [
            #"{"type":"object","properties":{"value":{"type":["string","null"],"enum":["keep"]}},"required":["value"]}"#,
            #"{"type":"object","properties":{"value":{"type":"string","anyOf":[{"type":"string"},{"type":"null"}]}},"required":["value"]}"#,
            #"{"type":"object","properties":{"value":{"oneOf":[{"type":["string","null"]},{"type":"null"}]}},"required":["value"]}"#,
        ]
        for schema in schemas {
            let value = try form(schema)
            #expect(throws: AgentWorkspaceForm.Failure.self) {
                try value.arguments(fields: .array([
                    .object(["field": .string("value"), "value": .null]),
                ]), text: nil)
            }
        }
    }

    @Test func enumChoicesAreEnforcedAfterConversion() throws {
        let value = try form(#"{"type":"object","properties":{"mode":{"type":"string","enum":["brief","full"]},"level":{"type":"integer","enum":[1,2]}},"required":["mode"]}"#)
        let args = try value.arguments(fields: fields([("mode", "brief"), ("level", "2")]), text: nil)
        #expect(args["mode"] == .string("brief"))
        #expect(args["level"] == .int(2))
        #expect(throws: AgentWorkspaceForm.Failure.self) { try value.arguments(fields: nil, text: "unlisted") }
        #expect(throws: AgentWorkspaceForm.Failure.self) {
            try value.arguments(fields: fields([("mode", "full"), ("level", "3")]), text: nil)
        }
    }

    @Test func residentDraftKeepsPartialInputsThroughCorrectionAndExplicitSubmission() throws {
        let original = try form(#"{"type":"object","properties":{"title":{"type":"string"},"count":{"type":"integer"},"target":{"type":"string"}},"required":["title","count","target"]}"#,
            bound: ["target": .string("selected")])
        let partial = try original.editing(field: "title", text: "A useful task")
        #expect(partial.draftID == original.draftID)
        #expect(partial.missingRequired == ["count"])
        #expect(throws: AgentWorkspaceForm.Failure.self) { try partial.arguments(fields: nil, text: nil) }
        let invalid = try partial.editing(field: "count", text: "several")
        #expect(invalid.draftValues["title"] == .string("A useful task"))
        #expect(invalid.draftValues["count"] == .string("several"))
        let countItem = try #require(invalid.projection.items.first { $0.title == "Count" })
        guard case .object(let content) = countItem.content else { Issue.record("Expected field content"); return }
        #expect(content["needs_correction"] != nil)
        #expect(throws: AgentWorkspaceForm.Failure.self) { try invalid.arguments(fields: nil, text: nil) }
        let corrected = try invalid.editing(field: "count", text: "3")
        #expect(try corrected.arguments(fields: nil, text: nil) == [
            "target": .string("selected"), "title": .string("A useful task"), "count": .int(3)
        ])
        #expect(original.draftValues.isEmpty)
    }

    @Test func optionalFieldsAreDiscoverableAndChosenValuesRemainVisible() throws {
        let original = try form(#"{"type":"object","properties":{"title":{"type":"string"},"urgent":{"type":"boolean"}},"required":["title"]}"#)
        #expect(original.projection.items.map(\.title) == ["Title"])
        let expanded = original.showingOptionalFields(true)
        #expect(expanded.projection.items.map(\.title) == ["Title", "Urgent"])
        let item = try #require(expanded.projection.items.first { $0.title == "Urgent" })
        guard case .open(.form(let chooser)) = item.actions.first?.action else { Issue.record("Expected simple choice"); return }
        #expect(chooser.projection.items.count == 2)
        guard case .open(.form(let chosen)) = chooser.projection.items.first?.actions.first?.action else {
            Issue.record("Expected selected option in draft"); return
        }
        #expect(chosen.draftValues["urgent"] == .bool(true))
        let collapsed = chosen.showingOptionalFields(false)
        #expect(collapsed.projection.items.contains { $0.title == "Urgent" })
        #expect(try collapsed.arguments(fields: nil, text: "Hello")["urgent"] == .bool(true))
        let cleared = collapsed.clearing("urgent")
        #expect(cleared.draftValues["urgent"] == nil)
        #expect(!cleared.projection.items.contains { $0.title == "Urgent" })
    }

    @Test func choicesRetainExactTypedOwnerValuesAndEveryOption() throws {
        let value = try form(#"{"type":"object","properties":{"level":{"type":"integer","enum":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18]}},"required":["level"]}"#)
        guard case .open(.form(let chooser)) = value.projection.items.first?.actions.first?.action else {
            Issue.record("Expected selection view"); return
        }
        #expect(chooser.projection.items.count == 18, "Navigation paginates without dropping owner choices.")
        guard case .open(.form(let chosen)) = chooser.projection.items.last?.actions.first?.action else {
            Issue.record("Expected selected final option"); return
        }
        #expect(try chosen.arguments(fields: nil, text: nil) == ["level": .int(18)])
        #expect(chosen.draftID == value.draftID)
    }

    @Test func draftRejectsTargetReplacementAndOversizeWithoutLosingEarlierInput() throws {
        let original = try form(#"{"type":"object","properties":{"target":{"type":"string"},"message":{"type":"string"}},"required":["target","message"]}"#,
            bound: ["target": .string("exact")])
        let draft = try original.editing(field: "message", text: "Keep this")
        #expect(throws: AgentWorkspaceForm.Failure.self) { try draft.editing(field: "target", text: "different") }
        #expect(throws: AgentWorkspaceForm.Failure.self) {
            try draft.editing(field: "message", text: String(repeating: "é", count: 32_769))
        }
        #expect(try draft.arguments(fields: nil, text: nil) == ["target": .string("exact"), "message": .string("Keep this")])
        let noticed = draft.withNotice("Fix the value")
        #expect(noticed.draftID == draft.draftID)
        #expect(noticed.draftValues == draft.draftValues)
        #expect(noticed.notice == "Fix the value")
    }

    @Test func draftValuesRemainResidentOnlyAndEmptyEditsArePreserved() throws {
        let original = try form(#"{"type":"object","properties":{"message":{"type":"string"}},"required":["message"]}"#)
        let draft = try original.editing(field: "message", text: "")
        #expect(draft.missingRequired.isEmpty)
        #expect(try draft.arguments(fields: nil, text: nil) == ["message": .string("")])
        #expect(AgentWorkspaceDesktopStore.durable(.form(draft)) == nil)
    }


    @Test func mixedTypeChoiceDoesNotTurnNumericOptionIntoString() throws {
        let value = try form(#"{"type":"object","properties":{"mode":{"type":["string","integer"],"enum":["auto",2]}},"required":["mode"]}"#)
        guard case .open(.form(let chooser)) = value.projection.items.first?.actions.first?.action,
              case .open(.form(let chosen)) = chooser.projection.items.last?.actions.first?.action else {
            Issue.record("Expected owner choice"); return
        }
        #expect(try chosen.arguments(fields: nil, text: nil) == ["mode": .int(2)])
    }

}
