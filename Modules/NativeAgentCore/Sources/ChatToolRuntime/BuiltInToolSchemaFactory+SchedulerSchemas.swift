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
            requestedSchema(name: "scheduler_list_jobs", toolClass: .read, reach: .his,
                description: "List queued and scheduled TriggerScheduler jobs (id, title, action_id, trigger time, status). Requires Scheduler → Write permission (scheduler has no read axis; defaults on).",
                parametersJSON: ToolSchema.params(
                    properties: [],
                    required: []
                )
            ),
            requestedSchema(name: "scheduler_create_job",
                toolClass: .write, reach: .his, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Schedule a task/notification with kind, its payload, and one of in_minutes, schedule or interval_seconds (forms/required payloads below). Workshop queues a Desk task each time; scheduling is not completion. For a recurring helper use bot.create/bot.update with schedule/cadence. Repeating intervals: ≥60 seconds. A repeating dream reuses/reactivates the nightly reflection job; once adds an extra dream. Requires Scheduler → Write (defaults on). Example: {\"kind\":\"notify\",\"payload\":{\"title\":\"Reminder\",\"message\":\"Review the notes.\"},\"interval_seconds\":86400}.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("kind", ToolSchema.enumStringSchema(["turn", "notify", "connector_action", "dream", "rem", "harness_benchmark", "proactive_scan", "workshop"], "Use turn for recurring work you do yourself (a check-in, a report, a look at something): payload.prompt runs as one turn of yours with your full tools each time and the reply lands in the inbox. Use workshop to queue a Desk task of planned steps; notify delivers a fixed message.")),
                        ("payload", ToolSchema.nullable(looseObjectSchema("Per-kind parameters. turn: {prompt, title}. workshop: {title, objective}; include result delivery instructions in objective. notify: {title, message, delivery}; delivery selects notification channels only. connector_action requires actionId; input is optional. dream/rem accept objective; proactive_scan accepts reason and limit."))),
                        ("in_minutes", ToolSchema.nullable(numSchema("One-time delay from now in minutes, e.g. 10 for a ten-minute timer. Use kind notify and payload.message. Supply this alone instead of schedule or interval_seconds; no time.now call is needed."))),
                        ("schedule", stringOrLooseObjectSchema("When to fire. Supply this, in_minutes or interval_seconds; omit or null unused fields. ISO-8601 datetime, 'in 10 minutes', or object with type once/every/hourly/daily/weekly/monthly/cron. Cron accepts expression or cron. Times are on this Mac's local clock and follow it when it changes zone; there is no timezone field. Example: {\"type\":\"every\",\"interval_seconds\":86400}.")),
                        ("interval_seconds", ToolSchema.nullable(ToolSchema.intSchema("Repeating interval in seconds when schedule is omitted or null. Example: 86400.", minimum: 60))),
                    ],
                    required: ["kind"]
                )
            ),
            requestedSchema(name: "scheduler_cancel_job",
                toolClass: .write, reach: .his, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Cancel a reminder or scheduled job by id from schedule.list. Stops future runs and keeps the job in history; schedule.resume can re-enable it. Does not stop an already running action. Requires Scheduler → Write permission (defaults on).",
                parametersJSON: ToolSchema.params(
                    properties: [("job_id", ToolSchema.strSchema("Job id from schedule.list, or a start of it no other job's id shares."))],
                    required: ["job_id"]
                )
            ),
            requestedSchema(name: "scheduler_pause_job",
                toolClass: .write, reach: .his, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Pause a job or reminder by id from schedule.list. Stops future runs until schedule.resume; preserves its schedule and payload. Does not stop an already running action. Requires Scheduler → Write permission (defaults on).",
                parametersJSON: ToolSchema.params(
                    properties: [("job_id", ToolSchema.strSchema("Job id from schedule.list, or a start of it no other job's id shares."))],
                    required: ["job_id"]
                )
            ),
            requestedSchema(name: "scheduler_resume_job",
                toolClass: .write, reach: .his, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Resume a paused or cancelled scheduled job or reminder by id from schedule.list. Re-enables its saved schedule; an overdue job may run immediately. Requires Scheduler → Write permission (defaults on).",
                parametersJSON: ToolSchema.params(
                    properties: [("job_id", ToolSchema.strSchema("Job id from schedule.list, or a start of it no other job's id shares."))],
                    required: ["job_id"]
                )
            ),
            requestedSchema(name: "scheduler_update_job",
                toolClass: .write, reach: .his, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Edit a scheduled job using job_id from schedule.list and at least one top-level change: name, kind, payload, schedule or interval_seconds. Omit or null unused fields; do not wrap changes in fields. Changing kind requires its complete payload. Supply schedule or interval_seconds, never both; intervals must be integers of at least 60 seconds. Preserves identity, history and paused/cancelled state. A new schedule recalculates the next run; other edits keep it. Does not alter an already running action. Requires Scheduler → Write permission (defaults on). Example for an existing job: {\"job_id\":\"J\",\"schedule\":{\"type\":\"daily\",\"at\":\"09:00\"}}.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("job_id", ToolSchema.strSchema("Job id from schedule.list, or a start of it no other job's id shares.")),
                        ("name", ToolSchema.nullable(ToolSchema.strSchema("New job name (1-160 characters)."))),
                        ("kind", ToolSchema.nullable(ToolSchema.enumStringSchema(["turn", "notify", "connector_action", "dream", "rem", "harness_benchmark", "proactive_scan", "workshop"], "When changing kind, supply the complete payload for that kind. Example: \"turn\" with {prompt, title}."))),
                        ("payload", ToolSchema.nullable(looseObjectSchema("Changed per-kind parameters, merged into the existing payload unless kind changes. turn: {prompt, title}. notify: {title, message, delivery}. connector_action: {actionId, input}. Nested values such as input are replaced in full."))),
                        ("schedule", stringOrLooseObjectSchema("Complete replacement schedule: ISO-8601 datetime string, e.g. '2026-09-29T09:00:00-06:00', or {type:'once', at:'ISO-8601'}, {type:'every', interval_seconds:3600}, {type:'hourly', minute:0}, {type:'daily', at:'09:00'}, {type:'weekly', weekdays:['mon'], at:'09:00'}, {type:'monthly', day:1, at:'09:00'}, or {type:'cron', expression:'0 9 * * mon-fri'}. Times are on this Mac's local clock and follow it when it changes zone. Omit interval_seconds when supplying schedule.")),
                        ("interval_seconds", ToolSchema.nullable(ToolSchema.intSchema("Replace the schedule with a repeating interval of at least 60 seconds. Supply this or schedule, not both.", minimum: 60))),
                    ],
                    required: ["job_id"]
                )
            ),
        ]
    }
}
