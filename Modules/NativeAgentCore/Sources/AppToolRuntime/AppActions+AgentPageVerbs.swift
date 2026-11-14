import Foundation
import NativeAgentCore
// Blueprint: | `AppActions+AgentPageVerbs.swift` | Owner page commands for Desk, memory, Graph, identity and helpers |

extension AppActions {
    /// What a row of Desk, Memories, Personality or Helpers does when no existing verb does it, declared once beside every other verb: the
    /// person's tap and the agent's call are the same call. Each runs its page owner's code through the page buttons' host (`upkeep`).
    /// A control's new value arrives as `value`.
    static var agentPageVerbs: [AppAction] {
        get throws {
            [
                AppAction("desk.refresh", "desk", "Read every Desk source again; the page names any that stays unavailable",
                          tool: "upkeep", input: verb("desk_refresh"), read: true),
                AppAction("desk.remind", "desk", """
                    Turn Desk reminders on or off: scope_kind global (every project), project (scope_id: the project's name) or item \
                    (scope_id: the item's handle)
                    """, ["scope_kind", "scope_id?", "value:bool"], subject: ["scope_kind", "scope_id"],
                          tool: "upkeep", input: verb("desk_remind")),
                AppAction("desk.veto", "desk", "Veto a pursuit: close it as the person's no", ["handle"], subject: ["handle"],
                          owner: .person("a veto is the person's no to the agent's own pursuit",
                                         instead: "desk.close {handle, reason} closes a pursuit of your own", asks: false, name: "Vetoing one of my pursuits"),
                          irreversible: true, tool: "upkeep", input: verb("desk_veto")),
                AppAction("memories.search", "memories", "Search the Memories page (three letters or more; empty shows every memory)",
                          ["value"], tool: "upkeep", input: verb("memories_search"), read: true),
                AppAction("memories.refresh", "memories", "Read the kept memories again", tool: "upkeep", input: verb("memories_refresh"),
                          read: true),
                AppAction("graph.refresh", "memories", "Read the canonical graph again", tool: "upkeep", input: verb("graph_refresh"), read: true),
                AppAction("graph.apply", "memories", "Remove exactly the orphan identities in the reviewed Graph upkeep item",
                          ["previewToken", "expectedIDs:[string]"], irreversible: true, capabilities: ["memory_write", "tool_call"],
                          tool: "upkeep", input: verb("graph_apply")),
                AppAction("personality.mind", "personality", """
                    Choose the Memory and mind model: value is an option id the Personality page's mind row offers
                    """, ["value"], owner: .person("the Memory and mind model is the person's choice of the agent's mind",
                        name: "Choosing my Memory and mind model"),
                          tool: "upkeep", input: verb("personality_mind")),
                AppAction("personality.reset", "personality", "Reset identity: back up, then clear SOUL, VOICE, USER, GROWTH and AGENTS",
                          owner: .person("resetting identity clears who the agent is; the person does it on the Mac", asks: false, name: "Resetting who I am"),
                          irreversible: true, tool: "upkeep", input: verb("personality_reset")),
                AppAction("bots.check", "bots", "Run a helper once; its reply stays in the helper's own conversation", ["id"], subject: ["id"],
                          tool: "upkeep", input: verb("bots_check")),
                AppAction("bots.paused", "bots", "Pause (value true) or resume a helper's scheduled and event work", ["id", "value:bool"],
                          subject: ["id"], tool: "upkeep", input: verb("bots_paused")),
            ]
        }
    }
}
