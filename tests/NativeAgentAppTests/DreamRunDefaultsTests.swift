import Testing
import Foundation
import DreamREMCycle
import NativeAgentCore
import PersistenceCore
import TriggerScheduler
@testable import NativeAgentApp

@Test
func defaultDreamScheduleUsesCentralTime() throws {
    #expect(NativeAgentDreamCycleSchedule.timeZoneIdentifier == "America/Chicago")
    let schedule = NativeAgentDreamCycleSchedule.dreamSchedule
    #expect(schedule["at"] == .string("03:30"))
    #expect(schedule["timezone"] == .string("America/Chicago"))

    let now = try #require(utcDate(year: 2026, month: 6, day: 17, hour: 5, minute: 0))
    let next = try #require(try SchedulerJobRuntime.nextRunEpochAfterNow(
        for: .object([
            "oneShot": .bool(false),
            "schedule": .object(schedule),
        ]),
        now: { now }
    ))

    let date = Date(timeIntervalSince1970: next)
    let central = NativeAgentDreamCycleSchedule.calendar().dateComponents(
        [.year, .month, .day, .hour, .minute],
        from: date
    )
    #expect(central.year == 2026)
    #expect(central.month == 6)
    #expect(central.day == 17)
    #expect(central.hour == 3)
    #expect(central.minute == 30)
}

@Test
func dreamEntryDateKeyUsesPreviousCentralDay() throws {
    let runTime = try #require(utcDate(year: 2026, month: 6, day: 17, hour: 8, minute: 30))
    #expect(NativeAgentDreamCycleSchedule.runDateKey(runTime) == "2026-06-17")
    #expect(NativeAgentDreamCycleSchedule.dreamEntryDateKey(runTime) == "2026-06-16")
}

@Test
func dreamNotificationPolicyArchivesOlderVisibleDreamCards() throws {
    let oldUnread: JSONValue = .object([
        "id": .string("dream-cycle-2026-06-16-old"),
        "source": .string("dream_cycle"),
        "status": .string("unread"),
    ])
    let current: JSONValue = .object([
        "id": .string("dream-cycle-2026-06-17-current"),
        "source": .string("dream_cycle"),
        "status": .string("unread"),
    ])
    let dismissed: JSONValue = .object([
        "id": .string("dream-cycle-2026-06-15-dismissed"),
        "source": .string("dream_cycle"),
        "status": .string("dismissed"),
    ])
    let heartbeat: JSONValue = .object([
        "id": .string("heartbeat-current"),
        "source": .string("heartbeat"),
        "status": .string("unread"),
    ])

    let result = NativeAgentDreamNotificationInboxPolicy.archiveOlderDreamRows(
        [oldUnread, current, dismissed, heartbeat],
        keeping: "dream-cycle-2026-06-17-current"
    )

    #expect(result.archivedCount == 1)
    #expect(status(result.rows, id: "dream-cycle-2026-06-16-old") == "archived")
    #expect(status(result.rows, id: "dream-cycle-2026-06-17-current") == "unread")
    #expect(status(result.rows, id: "dream-cycle-2026-06-15-dismissed") == "dismissed")
    #expect(status(result.rows, id: "heartbeat-current") == "unread")
}

@Test
func dreamFailureInboxMessageDoesNotReadAsCleanNoOp() {
    let message = SchedulerDueJobRunner.dreamInboxMessage(
        entriesWritten: 0,
        sessionsProcessed: 2,
        errors: ["llm error: transient(message: \"network connection was lost\")"],
        entries: []
    )

    #expect(message.contains("before writing a diary entry"))
    #expect(message.contains("retry automatically"))
    #expect(message.contains("Recent sessions scanned: 2."))
    #expect(!message.contains("no new dream entries to write"))
}

@Test
func dreamRetryEpochUsesBoundedRetryHint() {
    let runDate = Date(timeIntervalSince1970: 1_800_000_000)
    let output: JSONValue = .object([
        "retryAfterSeconds": .int(15 * 60),
    ])

    let retry = SchedulerDueJobRunner.retryEpoch(from: output, runDate: runDate)

    #expect(retry == runDate.addingTimeInterval(15 * 60).timeIntervalSince1970)
}

@Test
func dreamErrorsClassifyProviderConfigAsNonRetryable() {
    #expect(SchedulerDueJobRunner.dreamErrorsAreRetryable([
        "llm error: transient(message: network connection was lost)",
    ]))
    #expect(!SchedulerDueJobRunner.dreamErrorsAreRetryable([
        "llm error: notConfigured(provider: anthropic_oauth_direct)",
    ]))
}

@Test
func disabledDreamGateIsAQuietSchedulerSkip() throws {
    let result = try #require(SchedulerDueJobRunner.disabledDreamResult(
        for: DreamREMCycleError.cycleDisabled(
            error: "dream_cycle_disabled",
            detail: "Dream cycle is disabled."
        )
    ))

    #expect(result.status == "skipped")
    #expect(result.detail == "dream cycle disabled")
    guard case .object(let output) = result.output else {
        Issue.record("expected disabled dream output")
        return
    }
    #expect(output["disabled"] == .bool(true))
    #expect(output["error"] == .string("dream_cycle_disabled"))
}

private func utcDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date? {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: DateComponents(
        timeZone: TimeZone(identifier: "UTC")!,
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute
    ))
}

private func status(_ rows: [JSONValue], id: String) -> String? {
    for row in rows {
        guard case .object(let obj) = row,
              case .string(let rowID)? = obj["id"],
              rowID == id,
              case .string(let status)? = obj["status"] else {
            continue
        }
        return status
    }
    return nil
}
