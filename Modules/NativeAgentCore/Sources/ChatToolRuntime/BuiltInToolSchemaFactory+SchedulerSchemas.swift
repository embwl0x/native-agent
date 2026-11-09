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
                    List your scheduled reads: watches and proactive scans on the clock (id, kind, name, rhythm, next, payload). It is a Scheduler \
                    read, and the Scheduler has only a Write switch, so nothing refuses it.
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
                    Schedule a read on the clock: connector_action (a watch: a read through the app door whose rows new since its last read come \
                    to you as news) or proactive_scan. Intentions, check-ins, reports and reminders go through queue.add {text, when, until?, \
                    say?}; a part wakes on a schedule:<cron> in its own header; a recurring helper uses bot.create/bot.update with \
                    schedule/cadence. Repeating intervals: ≥60 seconds. Requires Scheduler → Write (defaults on).
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("kind", ToolSchema.enumStringSchema(["connector_action", "proactive_scan"], """
                            connector_action (a watch) or proactive_scan. Use queue.add for something you mean to do later, with say for fixed \
                            reminder words.
                            """)),
                        ("payload", ToolSchema.nullable(looseObjectSchema("""
                            connector_action requires actionId (a read) and takes input; proactive_scan accepts only reason, limit (integer \
                            1–50), surfaceLimit (integer 0–12) and staleDays (positive integer).
                            """))),
                        ("name", ToolSchema.nullable(ToolSchema.strSchema("A name for the read (at most 160 characters)."))),
                        ("id", ToolSchema.nullable(ToolSchema.strSchema("An id for the read; omit for a new one."))),
                        ("in_minutes", ToolSchema.nullable(numSchema("""
                            One read after this many minutes. Supply this alone instead of schedule or interval_seconds.
                            """))),
                        ("schedule", stringOrLooseObjectSchema("""
                            When to read. Supply this, in_minutes or interval_seconds; omit or null unused fields. An ISO-8601 datetime (one read), \
                            every N minutes|hours|days, cron <5 fields>, or an object with type once/every/hourly/daily/weekly/monthly/cron. Cron \
                            accepts expression or cron. Times are on this Mac's local clock and follow it when it changes zone; there is no \
                            timezone field. Example: {\"type\":\"every\",\"minutes\":30}.
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
                    Cancel a scheduled read by its id from schedule.list: it leaves the clock and never reads again. Does not stop a read already \
                    running. Drop an intention with queue.drop. Requires Scheduler → Write permission (defaults on).
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [("job_id", ToolSchema.strSchema("The read's id from schedule.list, with or without its watch: or scan: prefix."))],
                    required: ["job_id"]
                )
            ),
        ]
    }
}
