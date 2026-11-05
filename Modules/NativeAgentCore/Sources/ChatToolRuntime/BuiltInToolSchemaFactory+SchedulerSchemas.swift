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
// Blueprint: | `BuiltInToolSchemaFactory+SchedulerSchemas.swift` | `BuiltInToolSchemaFactory`: `schedulerSchemas` |

extension BuiltInToolSchemaFactory {
    func schedulerSchemas() -> [LLMToolSchema?] {
        [
            requestedSchema(name: "scheduler_list_jobs", toolClass: .read, reach: .person,
                macIntegration: .init(MacIntegrationID.scheduler, .read),
                description: """
                    List queued and scheduled TriggerScheduler jobs (id, title, action_id, trigger time, status). It is a Scheduler read, and the \
                    Scheduler has only a Write switch (creating and changing jobs), so nothing refuses it.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [],
                    required: []
                )
            ),
            requestedSchema(name: "scheduler_create_job",
                toolClass: .write, reach: .person, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                macIntegration: .init(MacIntegrationID.scheduler, .write),
                description: """
                    Schedule a body rhythm: dream, rem, part, connector_action, harness_benchmark or proactive_scan. Intentions, check-ins, reports \
                    and reminders go through queue.add {text, when, until?, say?}; For a recurring helper use bot.create/bot.update with \
                    schedule/cadence. Repeating intervals: ≥60 seconds. A repeating dream reuses/reactivates the nightly reflection job; once adds \
                    an extra dream. Requires Scheduler → Write (defaults on).
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("kind", ToolSchema.enumStringSchema(["dream", "rem", "part", "connector_action", "harness_benchmark", "proactive_scan"], """
                            Body rhythms: dream, rem, part, connector_action, harness_benchmark, proactive_scan. Use queue.add for something you \
                            mean to do later, with say for fixed reminder words.
                            """)),
                        ("payload", ToolSchema.nullable(looseObjectSchema("""
                            Rhythm parameters. connector_action requires actionId; input is optional. dream/rem accept objective. part requires \
                            part and signal (schedule:<cron>). proactive_scan accepts only reason, limit (integer 1–50), surfaceLimit (integer \
                            0–12) and staleDays (positive integer). Intentions belong in queue.add, not a job payload.
                            """))),
                        ("in_minutes", ToolSchema.nullable(numSchema("""
                            One-time delay for a body rhythm, in minutes. Supply this alone instead of schedule or interval_seconds. For a reminder \
                            use queue.add with when: at <ISO time> and say.
                            """))),
                        ("schedule", stringOrLooseObjectSchema("""
                            When to fire. Supply this, in_minutes or interval_seconds; omit or null unused fields. ISO-8601 datetime, 'in 10 \
                            minutes', or object with type once/every/hourly/daily/weekly/monthly/cron. Cron accepts expression or cron. Times are \
                            on this Mac's local clock and follow it when it changes zone; there is no timezone field. Example: \
                            {\"type\":\"every\",\"interval_seconds\":86400}.
                            """)),
                        ("interval_seconds",
                            ToolSchema.nullable(ToolSchema.intSchema("Repeating interval in seconds when schedule is omitted or null. Example: 86400.",
                            minimum: 60))),
                    ],
                    required: ["kind"]
                )
            ),
            requestedSchema(name: "scheduler_cancel_job",
                toolClass: .write, reach: .person, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                macIntegration: .init(MacIntegrationID.scheduler, .write),
                description: """
                    Cancel a body rhythm by id from schedule.list. Stops future runs and keeps the job in history; schedule.resume can re-enable \
                    it. Does not stop an already running action. Drop an intention with queue.drop. Requires Scheduler → Write permission (defaults \
                    on).
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [("job_id", ToolSchema.strSchema("Job id from schedule.list, or a start of it no other job's id shares."))],
                    required: ["job_id"]
                )
            ),
            requestedSchema(name: "scheduler_pause_job",
                toolClass: .write, reach: .person, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                macIntegration: .init(MacIntegrationID.scheduler, .write),
                description: """
                    Pause a body rhythm by id from schedule.list. Stops future runs until schedule.resume; preserves its schedule and payload. Does \
                    not stop an already running action. Requires Scheduler → Write permission (defaults on).
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [("job_id", ToolSchema.strSchema("Job id from schedule.list, or a start of it no other job's id shares."))],
                    required: ["job_id"]
                )
            ),
            requestedSchema(name: "scheduler_resume_job",
                toolClass: .write, reach: .person, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                macIntegration: .init(MacIntegrationID.scheduler, .write),
                description: """
                    Resume a paused or cancelled body rhythm by id from schedule.list. Re-enables its saved schedule; an overdue job may run \
                    immediately. Requires Scheduler → Write permission (defaults on).
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [("job_id", ToolSchema.strSchema("Job id from schedule.list, or a start of it no other job's id shares."))],
                    required: ["job_id"]
                )
            ),
            requestedSchema(name: "scheduler_update_job",
                toolClass: .write, reach: .person, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                macIntegration: .init(MacIntegrationID.scheduler, .write),
                description: """
                    Edit a body rhythm using job_id from schedule.list and at least one top-level change: name, kind, payload, schedule or \
                    interval_seconds. Intentions, check-ins and reminders use queue.add. Omit or null unused fields; do not wrap changes in fields. \
                    Changing kind requires its complete payload. Supply schedule or interval_seconds, never both; intervals must be integers of at \
                    least 60 seconds. Preserves identity, history and paused/cancelled state. A new schedule recalculates the next run; other edits \
                    keep it. Does not alter an already running action. Requires Scheduler → Write permission (defaults on).
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("job_id", ToolSchema.strSchema("Job id from schedule.list, or a start of it no other job's id shares.")),
                        ("name", ToolSchema.nullable(ToolSchema.strSchema("New job name (1-160 characters)."))),
                        ("kind", ToolSchema.nullable(ToolSchema.enumStringSchema(["dream", "rem", "part", "connector_action", "harness_benchmark",
                            "proactive_scan"], "Change to a body rhythm with its complete payload. Intentions use queue.add."))),
                        ("payload", ToolSchema.nullable(looseObjectSchema("""
                            Changed rhythm parameters, merged into the existing payload unless kind changes. connector_action: {actionId, input}; \
                            dream/rem: {objective}; part: {part, signal}. Nested values such as input are replaced in full. Intentions use \
                            queue.add.
                            """))),
                        ("schedule", stringOrLooseObjectSchema("""
                            Complete replacement schedule: ISO-8601 datetime string, e.g. '2026-09-29T09:00:00-06:00', or {type:'once', \
                            at:'ISO-8601'}, {type:'every', interval_seconds:3600}, {type:'hourly', minute:0}, {type:'daily', at:'09:00'}, \
                            {type:'weekly', weekdays:['mon'], at:'09:00'}, {type:'monthly', day:1, at:'09:00'}, or {type:'cron', expression:'0 9 * \
                            * mon-fri'}. Times are on this Mac's local clock and follow it when it changes zone. Omit interval_seconds when \
                            supplying schedule.
                            """)),
                        ("interval_seconds", ToolSchema.nullable(ToolSchema.intSchema("""
                            Replace the schedule with a repeating interval of at least 60 seconds. Supply this or schedule, not both.
                            """, minimum: 60))),
                    ],
                    required: ["job_id"]
                )
            ),
        ]
    }
}
