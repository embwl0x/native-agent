import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore
import SenseCore
import Foundation
import ProviderRouting
import MindCore
// Blueprint: | `AppActions+QueueGroup.swift` | Queue action declarations |

extension AppActions {
    static func queueGroup() throws -> [AppAction] {
        try [
        // Version-exempt: done/drop close an exact id idempotently; add appends or updates the open step's ref, retaining its prior ref.
        AppAction("undo", "desk", "Undo this conversation's last layout, recipe or setting change",
                  tool: "undo", versionExempt: true),
        AppAction("queue.add", "desk", """
            Mean to do something later (an intention, reminder, check-in or habit): it comes back at its moment, in your own words
            """, ToolSignature.doorArgs(queueAddSchema.parametersJSON).map { ["until?", "action?"].contains($0) ? $0 + ":any" : $0 }.map(DoorActionArguments.Field.init(admitted:)),
                 warn: "when is next_turn (the default), own_turn, when_user_messages with an optional door (\(MyQueue.Door.listed)), "
                      + """
                          when_user_here, when_user_away, on_news <words>, on <signal> (e.g. \"on file.changed:~/Downloads\", \"on message.arrived:telegram\"; \
                          use rhythms for schedule:),\u{20}
                          """
                      + """
                          after_card <card id>, at <ISO time>, a local date/time with optional weekday (Sun Nov 1 at 06:00), \"in 20 minutes\" or \
                          {seconds:120}, or a rhythm that brings it back each time:\u{20}
                          """
                      + "\"every 0 9,16 * * *\" (cron, Mac clock), \"every 2 hours\", or a schedule object {type: daily|weekly|cron|…}. "
                      + """
                          until takes a moment as when does: at <ISO time>, in N minutes|hours|days, {at:\"<ISO time>\"} or {seconds:N} (it ends itself \
                          then); also words you check when it comes up, or standing (a rhythm's default).\u{20}
                          """
                      + """
                          say is fixed words said to the person as they are at its moment, and the step still comes back to you. \
                          action:{action:\"authored.<id>\",args:{…}} binds a habit: it runs through your \
                          door at its moment, waking you only for needs_me or an unfinished/refused run. An action id string also works. With say, the habit \
                          runs first. A read as action (action:{action:\"agent.read\",args:{…}}, desk.read, files.read…) has already run when the \
                          step comes back: the step wakes you with that read's receipt and when it ran, so you start from it.\u{20}
                          """
                      + "The receipt shows the next times the clock heard",
                  tool: "my_queue", input: verb("add"), versionExempt: true,
                  schema: queueAddSchema),
        AppAction("queue.update", "desk", "Edit a carried step or bind/drop its habit", [.required("id"), .optional("action", .any), .optional("say", .any), .optional("when", .any), .optional("until", .any)],
            subject: ["id"],
                  warn: """
                      Only named fields change. action:{action:\"authored.<id>\",args:{…}} binds a habit; action:null drops it. \
                      say is said at its moment and the step still comes back to you; say:null clears it. \
                      when and until use queue.add's grammar. The receipt names the stored habit.
                      """,
                  tool: "my_queue", input: verb("update"), versionExempt: true, schema: queueUpdateSchema),
        AppAction("queue.done", "desk", "Mark a MY QUEUE step done; put why it is done in reason", [.required("id"), .optional("reason")], subject: ["id"],tool: "my_queue",
                  input: verb("done"), argumentNames: ["reason": ["evidence", "summary"]], versionExempt: true),
        AppAction("queue.drop", "desk", "Drop a MY QUEUE step", [.required("id"), .optional("reason")], subject: ["id"],tool: "my_queue",
                  input: verb("drop"), versionExempt: true),
        // Her turn frame names queue.list for the steps it does not show.
        .fold("desk_read", "desk", id: "queue.list", "Read MY QUEUE: every open step with its handle, words and moment",
              [.optional("limit", .integer), .optional("offset", .integer)], input: ["query": .string(MyQueue.project)], read: true),
        // Owed repair settles only when its operation works again or an explicit reason releases it.
        AppAction("repair.let_go", "desk", """
            Let go of something you owe (a repair on your home's OWED line, or a reply no door can carry), saying why. \
            operation_prefix instead of id lets go of every open repair whose operation starts with it, each through the same checks
            """, [.optional("id"), .optional("operation_prefix"), .required("reason")], subject: ["id"],
                  tool: "repair_let_go", versionExempt: true),
        AppAction("record.read", "desk", """
            Read your own committed experiences or details, newest first. of selects experiences or details; filters combine. \
            Experiences take id, id_prefix, kind and open_only (default false). Details take subject, subject_prefix, kind, source and \
            since (inclusive ISO 8601 time). Prefixes are literal. limit defaults to 20; raise it for more. matched_total and returned \
            distinguish the page from all matches. Detail rows return whole parsed JSON up to the store's 8 MiB row cap; unreadable rows name gaps
            """, [.required("of", .options("experiences", "details")), .optional("id"), .optional("id_prefix"), .optional("kind"), .optional("open_only", .boolean), .optional("subject"), .optional("subject_prefix"), .optional("source"), .optional("since"),
                  .optional("limit", .integer)],
            capabilities: [.appDataRead], tool: "record_read", read: true),
        AppAction("abilities.restore_state", "diagnostics",
            "Restore recovered ability run state, preserving damaged bytes and existing authority", [.required("state", .fromOwner), .required("expected_digest")],
                  warn: """
                      Read abilities/state.json with files.read and recover its accounting rows, including pending work. Do not invent run evidence. \
                      expected_digest is supplied by the unreadable-state refusal.
                      """,
                  tool: "abilities_restore_state", versionExempt: true, lifecycle: .change,
                  schema: arguments("abilities_restore_state", ["state": AbilityStore.recoveryStateSchema, "expected_digest": ToolSchema.strSchema()])),
        AppAction("turn.reconcile", "chat", "Reconcile a saved turn without repeating completed effects", [.required("session_id"), .optional("turn_id")], subject: ["session_id"],
            tool: "turn_reconcile", versionExempt: true),
        ]
    }
}
