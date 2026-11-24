import Foundation
import NativeAgentCore
import PersistenceCore
import MindCore
import ProviderRouting
import DeskCore
import NativeAgentShared
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MacNerves
import SenseCore
// Blueprint: | `QuietAdminActions+Persona.swift` | persona action contracts and execution |

enum QuietAdminActions {}

struct GetPersonaDocArgs: DoorArgs {
    static let docField = DoorFieldDescriptor.string("doc", "One of: SOUL, USER, AGENTS, VOICE, GROWTH, MEMORY")
    static let kindField = DoorFieldDescriptor.string("kind", "Same as doc; accepted so it matches persona.read.")
    static let doorFields: [DoorFieldDescriptor] = [docField, kindField]
    let doc: String?
    let kind: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        doc = try door.string(Self.docField)
        kind = try door.string(Self.kindField)
    }
}

struct PersonaReadArgs: DoorArgs {
    static let kindField = DoorFieldDescriptor.suggestedString("kind", ["soul", "user", "voice", "growth", "agents"], "One of: soul, user, voice, growth, agents.", required: true)
    static let doorFields: [DoorFieldDescriptor] = [kindField]
    let kind: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        kind = try door.requiredString(Self.kindField)
    }
}

struct PersonaWriteArgs: DoorArgs {
    static let kindField = DoorFieldDescriptor.string("kind", "One of: soul, voice, growth, agents. Do not use user; USER.md is generated from Memories.", required: true)
    static let contentField = DoorFieldDescriptor.string("content", "Full replacement document content.", required: true)
    static let retireField = DoorFieldDescriptor.openObject("retire", reason: "Each retired line names its reason.", description: """
                growth only: each REM-approved line this rewrite drops, exactly as written, mapped to why it goes. A retired line \
                is not offered again.
                """, values: .typed(ToolSchema.strSchema()))
    static let doorFields: [DoorFieldDescriptor] = [kindField, contentField, retireField]
    let kind: String
    let content: String
    let retire: [String: String]?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        kind = try door.requiredString(Self.kindField)
        content = try door.requiredString(Self.contentField)
        retire = try door.stringMap(Self.retireField)
    }
}

struct PersonaAppendSectionArgs: DoorArgs {
    static let kindField = DoorFieldDescriptor.string("kind", "One of: soul, voice, growth, agents. Do not use user; USER.md is generated from Memories.", required: true)
    static let titleField = DoorFieldDescriptor.string("title", "Markdown section title. Do not include the leading ##.", required: true)
    static let contentField = DoorFieldDescriptor.string("content", "Section body to append.", required: true)
    static let doorFields: [DoorFieldDescriptor] = [kindField, titleField, contentField]
    let kind: String
    let title: String
    let content: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        kind = try door.requiredString(Self.kindField)
        title = try door.requiredString(Self.titleField)
        content = try door.requiredString(Self.contentField)
    }
}

struct AgentIntrospectArgs: DoorArgs {
    static let detailField = DoorFieldDescriptor.choice("detail", ["compact", "full"], "compact (default) or full diagnostics")
    static let sessionIDField = DoorFieldDescriptor.string("session_id", "Optional conversation scope; supplied automatically in a turn.")
    static let doorFields: [DoorFieldDescriptor] = [detailField, sessionIDField]
    let detail: String?
    let sessionID: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        detail = try door.string(Self.detailField)
        sessionID = try door.string(Self.sessionIDField)
    }
}

extension QuietAdminActions {
    static let personaActions: [ActionDescriptor] = {
        [
            ActionDescriptor(GetPersonaDocArgs.self, name: "get_persona_doc",
                run: { context, input in
                    try await context.client.impl_get_persona_doc(turn: context.turn, input: input)
                }, toolClass: .read,
                description: """
                    Read a canonical persona document on demand: SOUL.md, USER.md, AGENTS.md, VOICE.md, GROWTH.md or MEMORY.md. Documents above 64 \
                    KiB report truncation; not a complete turn-context readout.
                    """
            ),
            ActionDescriptor(PersonaReadArgs.self, name: "persona_read",
                run: { context, input in
                    try await context.client.impl_persona_read(turn: context.turn, input: input)
                }, toolClass: .read,
                description: "Read a canonical persona document by kind: growth=GROWTH.md, user=USER.md, soul=SOUL.md, voice=VOICE.md, agents=AGENTS.md."
            ),
            ActionDescriptor(PersonaWriteArgs.self, name: "persona_write",
                run: { context, input in
                    try await context.client.impl_persona_write(input: input)
                },
                toolClass: .write, capabilities: [.filesystemWrite, .outsideAppDataWrite, .toolCall],
                description: "Replace your own persona document. USER.md is read-only, generated from Memories; use memory.commit for durable user facts."
            ),
            ActionDescriptor(PersonaAppendSectionArgs.self, name: "persona_append_section",
                run: { context, input in
                    try await context.client.impl_persona_append_section(input: input)
                },
                toolClass: .write, capabilities: [.filesystemWrite, .outsideAppDataWrite, .toolCall],
                description: """
                    Append a titled markdown section to your persona document. USER.md is read-only, generated from Memories; use memory.commit for \
                    durable user facts.
                    """
            ),
            ActionDescriptor(AgentIntrospectArgs.self, name: "agent_introspect",
                run: { context, input in
                    try await context.client.impl_agent_introspect(turn: context.turn, input: input, session: context.transportMetadata["__session_id"]?.trimmedString, surface: context.surface)
                }, toolClass: .read, capabilities: [.toolCall],
                description: """
                    Inspect your live runtime, provider and conversation identity. app {find} finds actions by what you want done. detail=full \
                    includes diagnostic roots and the seven-day outcome population audit.
                    """
            ),
        ]
    }()
}
