import Foundation
import NativeAgentCore
import PersistenceCore

extension BuiltInToolSchemaFactory {
    func standingBotSchemas() -> [LLMToolSchema?] {
        let names: Set<String> = ["bot_create", "bot_update", "bot_pause", "bot_run_once", "bot_list", "shelf_read", "shelf_entry", "bot_ask", "shelf_documents", "shelf_document"]
        guard requestedNames == nil || !names.isDisjoint(with: requestedNames!) else { return [] }
        func object(_ properties: [(String, JSONValue)], required: [String]) -> JSONValue {
            obj([("type", .string("object")), ("properties", obj(properties)),
                 ("required", .array(required.map(JSONValue.string))), ("additionalProperties", .bool(false))])
        }
        func params(properties: [(String, JSONValue)], required: [String]) -> Data {
            (try? object(properties, required: required).serializedData(pretty: false)) ?? Data("{}".utf8)
        }
        let nonempty = obj([("type", .string("string")), ("minLength", .int(1))])
        let positive = obj([("type", .string("number")), ("exclusiveMinimum", .int(0))])
        let cadence = obj([("oneOf", .array([
            object([("interval", object([("seconds", positive)], required: ["seconds"]))], required: ["interval"]),
            object([("cron", object([("expression", nonempty), ("timeZone", nonempty)], required: ["expression", "timeZone"]))], required: ["cron"]),
        ])), ("description", .string("Schedule as interval:{seconds:3600} or cron:{expression:'0 9 * * *',timeZone:'America/New_York'}. The person sets Minimum cadence on the Bots page (15 minutes by default, as low as 1 minute). The agent cannot lower that setting. Intervals below the floor are rejected; cron checks respect the same minimum gap after completion."))])
        let fields: [(String, JSONValue)] = [
            ("name", nonempty), ("brief", nonempty), ("cadence", cadence),
            ("sources", obj([("type", .string("array")), ("items", obj([("oneOf", .array([
                strSchema("Public http(s) URL."),
                object([("type", obj([("const", .string("http"))])), ("url", nonempty)], required: ["type", "url"]),
                object([("type", obj([("const", .string("tool"))])), ("name", strSchema("Exact name of a read tool from the agent's catalog. A tool source lets the agent call that tool during a bot check, choosing arguments from the brief, for example to read a connector, an allowed file, or search results. A bot source may read but never act: write, send, Mac-control, browser, shell and connector-server tools are refused. Every call uses the existing Trust checks and bot file-access policy; adding a source grants no permission."))], required: ["type", "name"]),
            ]))]))])),
            ("output_format", strSchema("Optional free-text body format, including shorthand or freeform. The dated book envelope stays stable. Empty string restores the default.")),
            ("budget", object([("tokens", intSchema(minimum: 1)), ("seconds", positive)], required: ["tokens", "seconds"])),
        ]
        let id = strSchema("Exact bot ID from bot_list or bot_create.")
        return [
            requestedSchema(name: "bot_ask", description: "Ask a bot a question using only its retained working context and kept reports. No sources run or reports change. Uses the bot's unattended provider, admission, per-run budget, deadline and daily allowance. Only the answer returns to this requesting turn.", parametersJSON: params(properties: [("id", id), ("question", strSchema("Question, at most 4000 UTF-8 bytes."))], required: ["id", "question"])),
            requestedSchema(name: "shelf_documents", description: "List a bot's named kept documents alongside its per-run shelf books. Returns latest and previous revision IDs; nothing is acknowledged or pushed.", parametersJSON: params(properties: [
                ("bot", id), ("offset", intSchema("Default 0; continue with nextOffset.", minimum: 0)),
                ("limit", intSchema("Default 20.", minimum: 1, maximum: 100)),
            ], required: ["bot"])),
            requestedSchema(name: "shelf_document", description: "Read a kept document by name, in bounded character pages. Continue with the returned version and nextOffset for a stable read. Omit version for latest; follow previousVersion to read preserved history. Does not acknowledge run entries.", parametersJSON: params(properties: [
                ("bot", id), ("name", nonempty), ("version", strSchema("Optional exact revision UUID; pin for continuation pages.")),
                ("offset", intSchema("Character offset, default 0.", minimum: 0)),
                ("limit", intSchema("Characters, default 4000.", minimum: 1, maximum: 8000)),
            ], required: ["bot", "name"])),
            requestedSchema(name: "bot_create", description: "Create a saved bot for any purpose, including the agent's own work, with a brief, schedule, typed sources, optional output_format, and per-run budget. No preset bots.", parametersJSON: params(properties: fields, required: fields.map(\.0).filter { $0 != "output_format" })),
            requestedSchema(name: "bot_update", description: "Update selected bot settings. Omitted or null settings stay unchanged; include at least one setting to change. A changed brief gets a new version. Use bot_pause to pause or resume.", parametersJSON: params(properties: [("id", id), ("fields", object(fields.map { ($0.0, obj([("anyOf", .array([$0.1, obj([("type", .string("null"))])]))])) }, required: []))], required: ["id", "fields"])),
            requestedSchema(name: "bot_pause", description: "Pause or resume a saved bot's scheduled checks.", parametersJSON: params(properties: [("id", id), ("paused", boolSchema())], required: ["id", "paused"])),
            requestedSchema(name: "bot_run_once", description: "Queue one bot check and return immediately. Results appear on the shelf when the check finishes.", parametersJSON: params(properties: [("id", id)], required: ["id"])),
            requestedSchema(name: "bot_list", description: "List saved bots and current settings.", parametersJSON: params(properties: [], required: [])),
            requestedSchema(name: "shelf_read", description: "Read a compact index of unread bot results in saved order. Only returned entries are marked read. Follow nextCursor with the same filters; omit cursor to revisit unread gaps. Use shelf_entry for full findings and shelf_documents for named kept reports.", parametersJSON: params(properties: [
                ("bot", nullableRecallField(id)),
                ("since", nullableRecallField(strSchema("Exclusive run time, ISO 8601 with time zone."))),
                ("topic", nullableRecallField(strSchema("Literal text to find in results."))),
                ("limit", nullableRecallField(intSchema("Default 20.", minimum: 1, maximum: 100))),
                ("cursor", nullableRecallField(strSchema("Exact nextCursor from the previous page with the same filters."))),
            ], required: [])),
            requestedSchema(name: "shelf_entry", description: "Read one complete shelf result, including findings, changes, dated sources, uncertainties, health, coverage, and spend. Mark only this entry read.", parametersJSON: params(properties: [("id", strSchema("Exact shelf entry ID."))], required: ["id"])),
        ]
    }
}
