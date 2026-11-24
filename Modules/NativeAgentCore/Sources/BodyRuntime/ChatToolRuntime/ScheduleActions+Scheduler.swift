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
// Blueprint: | `ScheduleActions+Scheduler.swift` | scheduler action contracts and execution |

enum ScheduleActions {}

private struct SchedulerCreateJobArgs: PersonalIntegrationArgs {
    static let kindField = DoorFieldDescriptor("kind", ToolSchema.enumStringSchema(["connector_action", "proactive_scan"], """
        connector_action (a watch) or proactive_scan. Use queue.add for something you mean to do later, with say for fixed \
        reminder words.
        """), required: true)
    static let payloadField = DoorFieldDescriptor("payload", ToolSchema.nullable(ActionDescriptor.looseObjectSchema("""
        connector_action requires actionId (a read) and takes input; proactive_scan accepts only reason, limit (integer \
        1–50), surfaceLimit (integer 0–12) and staleDays (positive integer).
        """)), required: false)
    static let nameField = DoorFieldDescriptor("name", ToolSchema.nullable(ToolSchema.strSchema("A name for the read (at most 160 characters).")), required: false)
    static let idField = DoorFieldDescriptor("id", ToolSchema.nullable(ToolSchema.strSchema("An id for the read; omit for a new one.")), required: false)
    static let inMinutesField = DoorFieldDescriptor("in_minutes", ToolSchema.nullable(ActionDescriptor.numSchema("""
        One read after this many minutes. Supply this alone instead of schedule or interval_seconds.
        """)), required: false)
    static let scheduleField = DoorFieldDescriptor("schedule", ActionDescriptor.stringOrLooseObjectSchema("""
        When to read. Supply this, in_minutes or interval_seconds; omit or null unused fields. An ISO-8601 datetime (one read), \
        every N minutes|hours|days, cron <5 fields>, or an object with type once/every/hourly/daily/weekly/monthly/cron. Cron \
        accepts expression or cron. Times are on this Mac's local clock and follow it when it changes zone; there is no \
        timezone field. Example: {\"type\":\"every\",\"minutes\":30}.
        """), required: false)
    static let intervalSecondsField = DoorFieldDescriptor("interval_seconds", ToolSchema.nullable(ToolSchema.intSchema("Repeating interval in seconds when schedule is omitted or null. Example: 86400.",
        minimum: 60)), required: false)
    static let doorFields = [kindField, payloadField, nameField, idField, inMinutesField, scheduleField, intervalSecondsField]
    let kind: String
    let payload: [String: JSONValue]?
    let name: String?
    let id: String?
    let inMinutes: DoorNumberLiteral?
    let schedule: DoorStringOrObject?
    let intervalSeconds: DoorNumberLiteral?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        kind = try door.requiredString(Self.kindField)
        payload = try door.objectValue(Self.payloadField)
        name = try door.string(Self.nameField)
        id = try door.string(Self.idField)
        inMinutes = try door.numberLiteral(Self.inMinutesField)
        schedule = try door.stringOrObject(Self.scheduleField)
        intervalSeconds = try door.numberLiteral(Self.intervalSecondsField)
    }

    var wire: [String: JSONValue] {
        [
            Self.kindField.name: .string(kind),
            Self.payloadField.name: payload.map(JSONValue.object),
            Self.nameField.name: name.map(JSONValue.string),
            Self.idField.name: id.map(JSONValue.string),
            Self.inMinutesField.name: inMinutes?.wire,
            Self.scheduleField.name: schedule?.wire,
            Self.intervalSecondsField.name: intervalSeconds?.wire,
        ].compactMapValues { $0 }
    }
}

private struct SchedulerCancelJobArgs: PersonalIntegrationArgs {
    static let jobIDField = DoorFieldDescriptor.string("job_id", "The read's id from schedule.list, with or without its watch: or scan: prefix.", required: true)
    static let doorFields = [jobIDField]
    let jobID: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        jobID = try door.requiredString(Self.jobIDField)
    }

    var wire: [String: JSONValue] {
        [
            Self.jobIDField.name: .string(jobID),
        ]
    }
}

extension ScheduleActions {
    static let schedulerActions: [ActionDescriptor] = {
        [
            ActionDescriptor(EmptyPersonalIntegrationArgs.self, name: "scheduler_list_jobs",
                run: EmptyPersonalIntegrationArgs.run, toolClass: .read, reach: .person,
                macIntegration: .init(MacIntegrationID.scheduler, .read),
                description: """
                    List your scheduled reads: watches and proactive scans on the clock (id, kind, name, rhythm, next, payload). It is a Scheduler \
                    read, and the Scheduler has only a Write switch, so nothing refuses it.
                    """
            ),
            ActionDescriptor(SchedulerCreateJobArgs.self, name: "scheduler_create_job",
                run: SchedulerCreateJobArgs.run,
                toolClass: .write, reach: .person, capabilities: [.filesystemWrite, .outsideAppDataWrite, .toolCall],
                macIntegration: .init(MacIntegrationID.scheduler, .write),
                description: """
                    Schedule a read on the clock: connector_action (a watch: a read through the app door whose rows new since its last read come \
                    to you as news) or proactive_scan. Intentions, check-ins, reports and reminders go through queue.add {text, when, until?, \
                    say?}; a part wakes on a schedule:<cron> in its own header; a recurring helper uses bot.create/bot.update with \
                    schedule/cadence. Repeating intervals: ≥60 seconds. Requires Scheduler → Write (defaults on).
                    """
            ),
            ActionDescriptor(SchedulerCancelJobArgs.self, name: "scheduler_cancel_job",
                run: SchedulerCancelJobArgs.run,
                toolClass: .write, reach: .person, capabilities: [.filesystemWrite, .outsideAppDataWrite, .toolCall],
                macIntegration: .init(MacIntegrationID.scheduler, .write),
                description: """
                    Cancel a scheduled read by its id from schedule.list: it leaves the clock and never reads again. Does not stop a read already \
                    running. Drop an intention with queue.drop. Requires Scheduler → Write permission (defaults on).
                    """
            ),
        ]
    }()
}
