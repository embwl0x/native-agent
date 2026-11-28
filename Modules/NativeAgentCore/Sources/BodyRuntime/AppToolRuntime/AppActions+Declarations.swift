import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore
import SenseCore
import Foundation
import ProviderRouting
import MindCore
// Blueprint: | `AppActions+Declarations.swift` | Seed actions, owner schemas, fixed input and hot-action vocabulary |

extension AppActions {
    static let abilitySaveSchema = LLMToolSchema(name: "ability_manage", toolClass: .write,
        description: """
            Save a new ability or revise one. Only id is always required; a new ability also needs description and code. Revisions inherit omitted fields. \
            Code is function run(input) or async function run(input), returning plain JSON; call the app as app.<page>.<action>(args) or app({action, args}) \
            / app({actions:[…]}) (app and host calls answer at once and may be awaited).
            """,
        parametersJSON: try! Parts.saveArgumentsSchema.serializedData(pretty: false))

    /// Every door argument's shape, complex ones from their owners; the declaration owns which are required. Discovery reads only this schema, so an argument
    /// missing here is unusable.
    static func arguments(_ tool: String, _ properties: [String: JSONValue], required: [String] = [], read: Bool = false) -> LLMToolSchema {
        LLMToolSchema(name: tool, toolClass: read ? .read : .write, description: "",
            parametersJSON: try! JSONValue.object(["type": .string("object"), "properties": .object(properties),
                "required": .array(required.map(JSONValue.string))]).serializedData(pretty: false))
    }

    static let queueAddSchema = arguments("my_queue", ["text": ToolSchema.strSchema(),
        "when": SchedulerJobNormalizer.intentionWhenSchema, "until": .object([:]),
        "say": ToolSchema.strSchema(), "action": .object([:])], required: ["text"])
    static let queueWaitSchema: JSONValue = {
        func exact(_ fields: [String: JSONValue]) -> JSONValue {
            .object(["type": .string("object"), "properties": .object(fields),
                     "required": .array(fields.keys.sorted().map(JSONValue.string)), "additionalProperties": .bool(false)])
        }
        return ToolSchema.nullable(.object(["oneOf": .array([
            exact(["at": ToolSchema.strSchema()]), exact(["desk": ToolSchema.strSchema()]),
            exact(["happening": exact(["kind": ToolSchema.enumStringSchema(Happening.Kind.allCases.map(\.rawValue)),
                                      "subject": ToolSchema.strSchema()])]),
        ])]))
    }()
    static let queueUpdateSchema = arguments("my_queue", ["id": ToolSchema.strSchema(),
        "action": .object([:]), "say": .object([:]), "when": SchedulerJobNormalizer.intentionWhenSchema,
        "until": .object([:]), "wait_for": queueWaitSchema], required: ["id"])

    /// AgentJobs.commission owns these shapes and refuses anything else.
    static let agentJobSchema = arguments("agent_job", [
        "agent": ToolSchema.strSchema("""
            Who takes the job: a contact's name or peer:<id> from agent.contacts, or self for a line of your own: a turn of yours in its own work \
            conversation, with your hand, Trust and present.
            """),
        "instructions": ToolSchema.strSchema("""
            For agent self only: who this line is (a researcher, a critic, a specialist), in your words; they stand in place of your persona. Omit and \
            the line is you.
            """),
        "brief": ToolSchema.strSchema("The job in your words: what to make or change, and what done looks like."),
        "where": ToolSchema.strSchema("""
            Another agent only: the one folder it works in, or a git repository's folder; omit for work that needs no place. It cannot overlap your \
            data or credential roots, including their parents. A Git checkout is allowed; Git metadata directories are refused, including for linked \
            worktrees. An omitted where's saved starting folder still passes the credential fence. Your own line has your hands.
            """),
        "reach": .object(["type": .string("object"), "additionalProperties": .bool(false), "description": .string("""
            Another agent only: what it may touch within Trust and this turn's file access: writes default true with where, false under read_only; \
            explicit writes under read_only and jobs under none are refused. Network (default false) needs Full Mac. Your own line has your Trust.
            """), "properties": .object(["writes": ToolSchema.boolSchema(), "network": ToolSchema.boolSchema()])]),
        "done": .object(["type": .string("object"), "additionalProperties": .bool(false), "description": .string("""
            Your check of the result, one of {command} (another agent only: a shell command run in where under reach; exit 0 passes), {file} (that \
            path exists) or {grep, in} (the regex matches in that file). Without it the job ends delivered, unchecked, never done.
            """), "properties": .object(["command": ToolSchema.strSchema(), "file": ToolSchema.strSchema(), "grep": ToolSchema.strSchema(),
                "in": ToolSchema.strSchema()])]),
        "desk": ToolSchema.strSchema("The Desk item this job carries, as desk.read names it."),
    ], required: ["agent", "brief"])

    static func composer(_ verb: String) -> [String: JSONValue] {
        ["target": .string("composer"), "verb": .string(verb)]
    }
    static func verb(_ verb: String) -> [String: JSONValue] { ["verb": .string(verb)] }
    static func press(_ button: String) -> [String: JSONValue] {
        ["verb": .string("act"), "action": .string(button)]
    }
    static func card(_ action: String) -> [String: JSONValue] { ["action": .string(action)] }

    package static var seedActions: [AppAction] { get throws { try seedInventory.get() } }
    private static let seedInventory: Result<[AppAction], Error> = Result {
        var actions = homeGroup()
        actions += chatGroup()
        actions += studioGroup()
        actions += settingsGroup()
        actions += mindGroup()
        actions += try abilityGroup()
        actions += try queueGroup()
        actions += try traceGroup()
        actions += try deskGroup()
        actions += try memoryGroup()
        actions += try botGroup()
        actions += try personalityGroup()
        actions += try agentGroup()
        actions += try personalAppsGroup()
        actions += try filesGroup()
        actions += try browserGroup()
        actions += try chatHistoryGroup()
        actions += try macGroup()
        actions += try agentPageVerbs + trustSettingsInboxVerbs + providersConnectorsCapabilitiesVerbs
        return actions
    }

    /// Flows carry their own verbs/targets; recursive credential checks must still inspect typed text/value inside every step.
    static var actArgs: [DoorActionArguments.Field]? { get throws { try foldSchemas["act"].map {
        try ToolSignature.doorArgs($0.parametersJSON).map {
            DoorActionArguments.Field(admitted: ["verb", "target"].contains($0) ? $0 + "?" : $0)
        }
    } } }

    static let layoutScope = SurfaceLayout.vocabulary.map { surface, about, blocks in
        ([surface, about] + blocks.map { $0.name + " " + $0.shows }).joined(separator: " ")
    }.joined(separator: " ") + " " + SurfaceLayout.profilesAbout

    /// What every agent's hand is born knowing. The agent's hand in `app`'s own description is these and everything the agent's own mind has done, a native
    /// action and an ability the agent wrote alike, from the next turn on (`AppToolExecutor.Hand`).
    public static let bornKnowing = ["undo", "time.now", "context.expand", "mind.inner_state", "agent.introspect", "ability.list",
                             "ability.read", "trace.recent", "desk.read", "memory.recall", "memory.commit",
                             "bot.reply", "agent.contacts", "agent.message", "agent.read", "agent.connect",
                             "agent.jobs", "mail.recent",
                             "calendar.upcoming", "files.read", "files.list", "files.write", "files.trash", "chat.search",
                             "result.page", "mac.look", "mac.system_info", "mac.volume", "mac.act", "mac.go", "sense.make"]
}
