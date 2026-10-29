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
// Blueprint: | `BuiltInToolSchemaFactory+PersonaSchemas.swift` | `BuiltInToolSchemaFactory`: `personaSchemas` |

extension BuiltInToolSchemaFactory {
    func personaSchemas() -> [LLMToolSchema?] {
        [
            requestedSchema(name: "get_persona_doc", toolClass: .read,
                description: "Read a canonical persona document on demand: SOUL.md, USER.md, AGENTS.md, VOICE.md, GROWTH.md or MEMORY.md. Documents above 64 KiB report truncation; not a complete turn-context readout.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("doc", ToolSchema.strSchema("One of: SOUL, USER, AGENTS, VOICE, GROWTH, MEMORY")),
                        ("kind", ToolSchema.strSchema("Same as doc; accepted so it matches persona.read.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "persona_read", toolClass: .read,
                description: "Read a canonical persona document by kind: growth=GROWTH.md, user=USER.md, soul=SOUL.md, voice=VOICE.md, agents=AGENTS.md.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        // The reader canonicalizes kind; keep those string forms accepted.
                        ("kind", ToolSchema.obj([("description", .string("One of: soul, user, voice, growth, agents.")), ("anyOf", .array([
                            ToolSchema.enumStringSchema(["soul", "user", "voice", "growth", "agents"]),
                            ToolSchema.strSchema(),
                        ]))])),
                    ],
                    required: ["kind"]
                )
            ),
            requestedSchema(name: "persona_write",
                toolClass: .write, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Replace your own persona document. USER.md is read-only, generated from Memories; use memory.commit for durable user facts.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("kind", ToolSchema.strSchema("One of: soul, voice, growth, agents. Do not use user; USER.md is generated from Memories.")),
                        ("content", ToolSchema.strSchema("Full replacement document content.")),
                        ("retire", ToolSchema.obj([
                            ("type", .string("object")),
                            ("description", .string("growth only: each REM-approved line this rewrite drops, exactly as written, mapped to why it goes. A retired line is not offered again.")),
                            ("additionalProperties", ToolSchema.strSchema()),
                        ])),
                    ],
                    required: ["kind", "content"]
                )
            ),
            requestedSchema(name: "persona_append_section",
                toolClass: .write, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Append a titled markdown section to your persona document. USER.md is read-only, generated from Memories; use memory.commit for durable user facts.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("kind", ToolSchema.strSchema("One of: soul, voice, growth, agents. Do not use user; USER.md is generated from Memories.")),
                        ("title", ToolSchema.strSchema("Markdown section title. Do not include the leading ##.")),
                        ("content", ToolSchema.strSchema("Section body to append.")),
                    ],
                    required: ["kind", "title", "content"]
                )
            ),
            requestedSchema(name: "agent_introspect", toolClass: .read, capabilities: ["tool_call"],
                description: "Inspect your live runtime, provider and conversation identity. app {find} finds actions by what you want done. detail=full includes diagnostic roots and the seven-day outcome population audit.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("detail", ToolSchema.enumStringSchema(["compact", "full"], "compact (default) or full diagnostics")),
                        ("session_id", ToolSchema.strSchema("Optional conversation scope; supplied automatically in a turn.")),
                    ],
                    required: []
                )
            ),
        ]
    }
}
