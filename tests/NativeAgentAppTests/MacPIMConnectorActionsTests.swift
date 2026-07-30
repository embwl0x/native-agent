import Foundation
import EventKit
import Testing
@testable import NativeAgentApp
import NativeAgentCore

@MainActor
@Test("calendar list day=today uses a local-day range, not a 24-hour bleed")
func macCalendarListWindowTodayUsesLocalDayScope() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = ISO8601DateFormatter().date(from: "2026-06-20T13:30:00Z")!

    let window = MacPIMConnectorActions.calendarListWindow(
        input: ["day": .string("today")],
        now: now,
        calendar: calendar
    )

    let todayStart = calendar.startOfDay(for: now)
    let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart)!
    #expect(window.day == "today")
    #expect(window.start == todayStart)
    #expect(window.end == tomorrowStart.addingTimeInterval(-1))
    #expect(window.end < tomorrowStart)
}

@MainActor
@Test("calendar list without day keeps the legacy hours-ahead window")
func macCalendarListWindowWithoutDayKeepsHoursAhead() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = ISO8601DateFormatter().date(from: "2026-06-20T13:30:00Z")!

    let window = MacPIMConnectorActions.calendarListWindow(
        input: ["hours_ahead": .int(6)],
        now: now,
        calendar: calendar
    )

    #expect(window.day == nil)
    #expect(window.start == now)
    #expect(window.end == calendar.date(byAdding: .hour, value: 6, to: now))
    #expect(window.hoursAhead == 6)
}

@MainActor
@Test("calendar authorization plan upgrades reads and keeps write-only writes narrow")
func macCalendarAuthorizationPlanUsesExactAccessLevel() {
    #expect(MacPIMConnectorActions.calendarAuthorizationAction(for: .fullAccess, intent: .read) == .ready)
    #expect(MacPIMConnectorActions.calendarAuthorizationAction(for: .writeOnly, intent: .read) == .requestFull)
    #expect(MacPIMConnectorActions.calendarAuthorizationAction(for: .notDetermined, intent: .read) == .requestFull)
    #expect(MacPIMConnectorActions.calendarAuthorizationAction(for: .denied, intent: .read) == .unavailable)

    #expect(MacPIMConnectorActions.calendarAuthorizationAction(for: .fullAccess, intent: .write) == .ready)
    #expect(MacPIMConnectorActions.calendarAuthorizationAction(for: .writeOnly, intent: .write) == .ready)
    #expect(MacPIMConnectorActions.calendarAuthorizationAction(for: .notDetermined, intent: .write) == .requestWriteOnly)
    #expect(MacPIMConnectorActions.calendarAuthorizationAction(for: .restricted, intent: .write) == .unavailable)
}
