import Foundation
import NativeAgentCore
import PersistenceCore
import ChatTurnContracts
import AgentWorkspace
import MemoryV2
import ProviderRouting
import ToolRegistry
import NativeAgentShared
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Dispatcher
import MacControl
import Senses
import StandingBots
// Blueprint: | `BuiltInToolSchemaFactory+WorkspaceSchemas.swift` | `BuiltInToolSchemaFactory`: `workspaceSchemas` |

extension BuiltInToolSchemaFactory {
    func workspaceSchemas() -> [LLMToolSchema?] {
        [
            requestedSchema(name: "workspace", toolClass: .read,
                description: "Your world as text. No args: home (what waits, working, people, helpers, every place: mail, calendar, files, music…). action: a name (desk.4, mail, music, an agent's name) opens it with its one-call actions. What changed already rides in your glance line (none = nothing new). action also takes an exact ref from a view (+text if needs_text, fields for forms). query: a name opens, else searches.",
                parametersJSON: ToolSchema.params(properties: [
                    ("query", ToolSchema.nullable(ToolSchema.strSchema("Find across work, recorded files, memory and conversation evidence, up to 400 characters; otherwise null."))),
                    ("action", ToolSchema.nullable(ToolSchema.strSchema("Exact action reference offered in this chat's current workspace view; otherwise null."))),
                    ("text", ToolSchema.nullable(ToolSchema.strSchema("Text for an action that needs_text, otherwise null."))),
                    ("conversation", ToolSchema.nullable(ToolSchema.strSchema("Optional conversation label for an agent message; helpers use their existing conversation."))),
                    ("fields", ToolSchema.obj([
                        ("type", .array([.string("array"), .string("object"), .string("null")])),
                        ("description", .string("Values for the displayed form when submitting it, or to fill a Desk form as you open it (for example desk.add); otherwise null. Use a list of field/value pairs; Desk forms also accept an object mapping field names to values. Values are strings: plain text for text fields, numbers/booleans as text, JSON text for lists/objects; use JSON null only to clear a nullable field. The app already carries selected target fields.")),
                        ("additionalProperties", ToolSchema.nullable(ToolSchema.strSchema())),
                        ("items", ToolSchema.obj([("type", .string("object")), ("properties", ToolSchema.obj([
                            ("field", ToolSchema.strSchema("Field name shown in the form.")),
                            ("value", ToolSchema.nullable(ToolSchema.strSchema("Value in the form field's declared type. Use JSON null only to explicitly clear a nullable field; the text null remains literal text in string fields.")))
                        ])), ("required", .array([.string("field"), .string("value")])), ("additionalProperties", .bool(false))]))
                    ])),
                ], required: [])
            ),
            requestedSchema(name: "work_context", toolClass: .read,
                description: "Read current Desk status, original conversation evidence and recent Mail sender/subject matches for a topic, with dates and exact source links. Mail Read must be allowed and ready; its search is bounded to 1.5 seconds, five newest inbox matches from the last 90 days, with mail.N names to open bodies. Mail, Messages and Notes can hold personal facts; Messages and Notes require their own readers. This detailed reader also supports conversation and result limits. Historical reports are not fresh verification; nothing is restarted.",
                parametersJSON: ToolSchema.params(properties: [
                    ("query", ToolSchema.strSchema("The work or topic to pick back up, in ordinary words (1–400 characters).")),
                    ("session_id", ToolSchema.nullable(ToolSchema.strSchema("Optional exact conversation to restrict historical evidence; null searches across conversations. Desk remains the current shared Desk."))),
                    ("limit", ToolSchema.nullable(ToolSchema.intSchema("Maximum Desk items and chat excerpts per source, default 3, range 1–4; null uses the default. Mail returns at most five matches."))),
                    ("desk_offset", ToolSchema.nullable(ToolSchema.intSchema("Omit initially; retained continuation for more current work."))),
                    ("history_offset", ToolSchema.nullable(ToolSchema.intSchema("Omit initially; retained continuation for more history with the same topic and selection policy."))),
                ], required: ["query"])
            ),
            requestedSchema(name: "artifact_find", toolClass: .read,
                description: "Find a document, image, mockup or handoff by what it was for or the conversation around it. Searches recorded chat attachments, structured tool artifact references and current Desk links; returns exact references with source conversation and version evidence when recorded. Does not crawl disk, open files, infer approval from filenames, or prove current file availability. Use the returned evidence to distinguish approved work from a later draft.",
                parametersJSON: ToolSchema.params(properties: [
                    ("query", ToolSchema.strSchema("Describe the artifact or its topic in ordinary words.")),
                    ("session_id", ToolSchema.strSchema("Optional exact conversation to search. When supplied, excludes shared Desk links.")),
                    ("limit", ToolSchema.intSchema("Maximum artifact candidates, default 6, range 1–12.")),
                    ("session_offset", ToolSchema.intSchema("Omit initially; use returned continuation for older conversation evidence.")),
                ], required: ["query"])
            ),
        ]
    }
}
