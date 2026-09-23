import Foundation
import Testing
import PersistenceCore
@testable import ChatOrchestration

@Suite("Workspace activity owner projections")
struct AgentWorkspaceActivityTests {
    private let botID = "91B1C573-6281-4D41-A7DE-A3B13759FC4A"
    private let entryID = "3CA75BD8-4A36-4474-ACD1-01F62CD70AAB"

    @Test func helperActionsKeepExactIdentityAndExplicitModelChoice() throws {
        let view = try #require(AgentWorkspaceActivity.project(tool: "bot_list", input: [:], result: .object([
            "status": .string("ok"), "model_choices": .array([.string("owner choices")]),
            "bots": .array([.object(["id": .string(botID), "name": .string("Same name"), "paused": .bool(true),
                "scheduler_status": .string("paused"), "actions": .object(["tool": .string("shell_exec")])])])
        ])))
        #expect(view.items.count == 1)
        #expect(view.items[0].actions.count == 5)
        #expect(object(view.items[0].content)["actions"] == nil)
        #expect(object(view.content)["model_choices"] != nil)
        for button in view.items[0].actions {
            switch button.action {
            case .message(let agent, _, _, _): #expect(agent == "bot:" + botID)
            case .open(.record(let tool, let input, _)):
                #expect(tool == "agent_read")
                #expect(input["agent"] == .string("bot:" + botID))
            case .perform(let tool, let input, _, _, let isEffect):
                #expect(isEffect)
                #expect(input["id"] == .string(botID))
                #expect(tool == "bot_run_once" || tool == "bot_pause")
                if tool == "bot_pause" { #expect(input["paused"] == .bool(false)) }
            case .configure(let tool, let input, _):
                #expect(tool == "bot_update")
                #expect(input == ["id": .string(botID)])
            default: Issue.record("Unexpected bot action")
            }
        }
        let create = try #require(view.actions.first { $0.label == "Create a helper" })
        guard case .configure(let tool, let input, _) = create.action else {
            Issue.record("Creation must require a form with explicit choices"); return
        }
        #expect(tool == "bot_create")
        #expect(input.isEmpty)
    }

    @Test func malformedBotIdentityDoesNotPromoteEmbeddedRecipes() throws {
        let view = try #require(AgentWorkspaceActivity.project(tool: "bot_list", input: [:], result: .object([
            "bots": .array([.object(["name": .string("Helper"), "id": .string("invented"),
                "actions": .object(["talk": .object(["tool": .string("agent_message"), "input": .object(["agent": .string("claude")])])])])])
        ])))
        #expect(view.items[0].actions.isEmpty)
    }

    @Test func savedRepliesRetainActualOutcomeAndOwnerBoundRead() throws {
        for status in ["queued", "failed", "completed"] {
            let view = try #require(AgentWorkspaceActivity.project(tool: "shelf_read", input: ["bot_id": .string(botID), "topic": .string("review"), "limit": .int(16)], result: .object([
                "status": .string("ok"), "nextCursor": .string("owner-cursor"), "entries": .array([.object([
                    "id": .string(entryID), "bot": .string(botID), "status": .string(status), "headline": .string("Review")])])
            ])))
            #expect(object(view.items[0].content)["status"] == .string(status))
            guard case .open(.record(let tool, let input, _)) = view.items[0].actions[0].action else {
                Issue.record("Reply needs a read action"); return
            }
            #expect(tool == "shelf_entry")
            #expect(input == ["id": .string(entryID), "bot_id": .string(botID)])
            guard case .open(.record(let nextTool, let next, _)) = view.actions[0].action else {
                Issue.record("Pagination needs an exact read"); return
            }
            #expect(nextTool == "shelf_read")
            #expect(next["cursor"] == .string("owner-cursor"))
            #expect(next["topic"] == .string("review"))
            #expect(next["bot_id"] == .string(botID))
        }
    }

    @Test func taskAndCalendarKeepOwnerIDs() throws {
        let tasks = try #require(AgentWorkspaceActivity.project(tool: "task_ledger_list", input: [:], result: .object([
            "status": .string("ok"), "tasks": .array([.object(["taskId": .string("source-task"), "title": .string("Review"), "status": .string("blocked")])])
        ])))
        guard case .open(.record(let tool, let input, _)) = tasks.items[0].actions[0].action else {
            Issue.record("Task needs a read action"); return
        }
        #expect(tool == "task_ledger_list")
        #expect(input == ["task_id": .string("source-task")])
        #expect(object(tasks.items[0].content)["status"] == .string("blocked"))
        let calendar = try #require(AgentWorkspaceActivity.project(tool: "mac_calendar_list_upcoming", input: [:], result: .object([
            "status": .string("completed"), "events": .array([.object(["id": .string("exact-event"), "title": .string("Meeting")])])
        ])))
        guard case .configure(let edit, let bound, _) = calendar.items[0].actions[0].action else {
            Issue.record("Event edit needs a form"); return
        }
        #expect(edit == "mac_calendar_modify_event")
        #expect(bound == ["id": .string("exact-event")])
    }

    @Test func chatIdentifiersAndMailPreviewsNeverBecomeUnverifiedRecipients() throws {
        let messages = try #require(AgentWorkspaceActivity.project(tool: "messages_recent_threads", input: [:], result: .object([
            "status": .string("completed"), "threads": .array([.object(["handle": .string("iMessage;+;chat-42"), "lastMessage": .string("Hi")])])
        ])))
        #expect(messages.items[0].actions.allSatisfy { $0.label == "Open Messages view" })
        guard case .configure(let tool, let input, _) = try #require(messages.actions.first { $0.label == "Compose message" }).action else {
            Issue.record("Compose should require explicit recipient"); return
        }
        #expect(tool == "messages_send")
        #expect(input["to"] == nil)
        let mail = try #require(AgentWorkspaceActivity.project(tool: "mail_list_recent", input: [:], result: .object([
            "status": .string("completed"), "messages": .array([.object(["subject": .string("Repeated subject"), "sender": .string("sender@example.invalid")])])
        ])))
        #expect(mail.items[0].actions.allSatisfy { $0.label == "Open Mail view" })
    }

    @Test func noReminderTargetIsInventedAndFailedReadsStayFailed() throws {
        let reminders = try #require(AgentWorkspaceActivity.project(tool: "mac_reminders_list_due_today", input: [:], result: .object([
            "status": .string("completed"), "reminders": .array([.object(["title": .string("Remember"), "completed": .bool(false)])])
        ])))
        #expect(reminders.items[0].actions.isEmpty)
        let denied: JSONValue = .object(["status": .string("denied"), "reason": .string("Owner permission required")])
        let view = try #require(AgentWorkspaceActivity.project(tool: "bot_list", input: [:], result: denied))
        #expect(view.content == denied)
        #expect(view.items.isEmpty)
    }

    private func object(_ value: JSONValue) -> [String: JSONValue] {
        guard case .object(let row) = value else { return [:] }; return row
    }
}
