import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore
import SenseCore
import Foundation
import ProviderRouting
import MindCore
// Blueprint: | `AppActions+AgentGroup.swift` | Agent action declarations |

extension AppActions {
    static func agentGroup() throws -> [AppAction] {
        try [
        // The peer-data latch binds subsequent scripted calls as it does a turn.
        .fold("agent_contacts", "agents", read: true),
        // The send schema owns wait_seconds and the live/async receipt contract.
        .fold("agent_message", "agents", subject: ["agent"], argumentNames: ["agent": ["to"]]),
        .fold("agent_read", "agents", read: true),
        AppAction("claude.worklog", "agents", """
            Read what Claude has been doing and working on, newest first: the worklog of shipped features, fixes, builds and work in progress
            """,
                  [.optional("since"), .optional("limit", .integer)],
                  warn: """
                      since: today or an ISO 8601 timestamp with timezone. limit: 1–50, default 10, newest first. Reads the bounded recent worklog tail; \
                      refs \
                      are clipped. Reading never sends a message.
                      """,
                  tool: "claude_worklog", read: true),
        .fold("agent_connect", "agents"),
        AppAction("agent.rename", "agents", "Rename an agent: call it by a new name or nickname when the person asks; its identity and handles stay the same",
                  [.required("agent"), .required("name")], subject: ["agent"], tool: "agent_connect", scope: "call it name it nickname rename an agent"),
        // Recipe writes change connection authority and require other_app_settings_write below Full Mac.
        AppAction("agent.recipe", "agents", "Read a host's connection recipe and the version a write replaced; omit host for all hosts",
                  [.optional("host")], subject: ["host"],tool: "agent_contacts", read: true),
        AppAction("agent.recipe_write", "agents", """
            Create a recipe using agent.recipe's shape and a new host.id, or replace at the version read; keeps the prior version for undo
            """,
                  [.required("host"), .required("recipe", .fromOwner)], subject: ["host"], reach: .person, capabilities: [.otherAppSettingsWrite, .toolCall], tool: "agent_connect",
                  schema: arguments("agent_connect", ["host": ToolSchema.strSchema(), "recipe": AgentRecipeStore.writeArgumentSchema])),
        // Discovery refusal changes only discovery.json.
        AppAction("agent.discovery_dismiss", "agents", "Decline an agent found on this Mac; it is not offered or connected automatically again",
                  [.required("name")],tool: "agent_discovery_dismiss"),
        // Verification is explicit; a failed send returns its first outcome without retry.
        AppAction("agent.verify", "agents", """
            Dry-run a host recipe or contact settings, handshake or window controls; sends nothing. A pass proves only the named checks; a reply needs \
            separate proof
            """,
                  [.required("agent"), .optional("workspace")], subject: ["agent"], tool: "agent_message"),
        .fold("agent_cancel", "agents", "Stop the reply an agent is working on in your conversation with it"),
        // The organ brings its own model and sign-in: the job carries no model of any kind, and what it makes comes back as the agent's.
        AppAction("agent.job", "agents", """
            Give another agent, or a line of your own (agent self), a whole piece of your work: what it makes comes back to you as yours, checked by \
            done, and wakes you here when it ends; several at once run side by side; agent.read and agent.cancel with job:<job id> read or stop it
            """,
                  [.required("agent"), .required("brief"), .optional("instructions"), .optional("where"), .optional("reach", .fromOwner), .optional("done", .fromOwner), .optional("desk")], subject: ["agent"], toolClass: .send,
                  capabilities: [.appDataWrite, .externalSend, .networkRead, .networkWrite, .processSpawn, .shell, .toolCall],
                  tool: "agent_job", schema: agentJobSchema),
        // The agent's hands on a repo job's branch. Apply's merge runs as the agent's own git call, under that tool's gates, Trust and cards; the stem only
        // reads first.
        AppAction("agent.apply", "agents", """
            Merge a finished repo job's branch into the repository's current branch with your own git; read its diff first with agent.read. A conflict is \
            reported and changes nothing
            """,
                  [.required("job")], subject: ["job"], capabilities: [.appDataWrite, .processSpawn, .toolCall], tool: "agent_job"),
        AppAction("agent.discard", "agents", """
            Drop a repo job's worktree, uncommitted work included, and delete its branch; your repository's own branches stay, and its patch stays in Make
            """,
                  [.required("job")], subject: ["job"], irreversible: true, capabilities: [.appDataWrite, .filesystemDelete, .processSpawn, .toolCall],
                  tool: "agent_job"),
        AppAction("agent.reply", "agents", "From a contact's connecting ability, answer as that contact in its conversation; done:false marks progress",
                  [.required("text"), .optional("done", .boolean), .optional("agent"), .optional("exchange")], tool: "agent_message"),
        .fold("delegation_status", "agents", read: true),
        ]
    }
}
