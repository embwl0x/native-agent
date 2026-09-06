import Testing
import Foundation
@testable import BackgroundLoops
import NativeAgentCore
import PersistenceCore

// HER HOUR — personality-depth item 9. The gates, the ceiling, and the two
// promises that matter: a decline writes no journal, and an unobtainable
// artifact never becomes an encounter.
//
// Hermetic: injected clock, injected booleans, a temporary data root. Nothing
// here reads `Date()` and nothing calls a provider.

private func wanderRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("studio-wander-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private let t0 = Date(timeIntervalSince1970: 1_756_000_000)

@Test func studioWanderCorruptionIsPreservedAndCannotAdmitAnHour() async throws {
    let root = try wanderRoot("corrupt")
    defer { try? FileManager.default.removeItem(at: root) }
    let path = StudioWanderLane.statePath(dataRoot: root)
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    for raw in ["{broken", "[]", "{\"last_wander_at\":\"invalid\",\"trace\":[]}", "{\"trace\":[{}]}"] {
        let bytes = Data(raw.utf8)
        try bytes.write(to: path)
        await #expect(throws: (any Error).self) { try await StudioWanderLane.loadState(dataRoot: root) }
        await #expect(throws: (any Error).self) { try await StudioWanderLane.beginHour(dataRoot: root, at: t0) }
        #expect(try Data(contentsOf: path) == bytes)
    }
}

@Test func studioWanderAdmissionSurvivesMissingCompletionAndPreventsReplay() async throws {
    let root = try wanderRoot("interrupted")
    defer { try? FileManager.default.removeItem(at: root) }
    try await StudioWanderLane.beginHour(dataRoot: root, at: t0)
    let restarted = try await StudioWanderLane.loadState(dataRoot: root)
    #expect(restarted.lastWanderAt == t0)
    #expect(restarted.trace.isEmpty)
    await #expect(throws: StudioWanderLane.StateError.self) {
        try await StudioWanderLane.beginHour(dataRoot: root, at: t0.addingTimeInterval(60))
    }
}

@Test func studioWanderPersistenceFailureIsThrownInsteadOfCertified() async throws {
    let root = try wanderRoot("write-failure")
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("not a directory".utf8).write(to: root.appendingPathComponent("studio"))
    await #expect(throws: (any Error).self) {
        try await StudioWanderLane.recordEndedHour(dataRoot: root,
            entry: .init(at: StudioClock.nowISO(t0), outcome: .declined, line: "Declined"), at: t0)
    }
}

// MARK: - Installation: OFF means NOT INSTALLED

@Test func studioWander_isNotInstalledUntilDeliberatelyTurnedOn() {
    // The default. Nobody has opened Settings; her hour does not exist.
    #expect(
        StudioWanderLane.resolveInstallation(
            enabled: nil, forcedNeutral: false, subconsciousEnabled: true
        ) == .notInstalled(reason: "switch_off")
    )
    // Explicitly off is the same absence, named the same way.
    #expect(
        StudioWanderLane.resolveInstallation(
            enabled: false, forcedNeutral: false, subconsciousEnabled: true
        ) == .notInstalled(reason: "switch_off")
    )
}

@Test func studioWander_publicSafeBuildCannotInstallItEvenWhenSwitchedOn() {
    // A public clean-room build before onboarding: the switch is not enough,
    // and the reason is distinct so "off" and "public build" are never the same
    // observable state.
    #expect(
        StudioWanderLane.resolveInstallation(
            enabled: true, forcedNeutral: true, subconsciousEnabled: true
        ) == .notInstalled(reason: "public_safe_before_onboarding")
    )
}

@Test func studioWander_cannotOutliveTheSubconsciousMaster() {
    #expect(
        StudioWanderLane.resolveInstallation(
            enabled: true, forcedNeutral: false, subconsciousEnabled: false
        ) == .notInstalled(reason: "subconscious_off")
    )
}

@Test func studioWander_installsOnlyWhenUserTurnsItOn() {
    #expect(
        StudioWanderLane.resolveInstallation(
            enabled: true, forcedNeutral: false, subconsciousEnabled: true
        ) == .installed
    )
}

/// The kill switch is structural, not a skip: an uninstalled lane leaves NO
/// state file behind, because nothing reads or writes one.
@Test func studioWander_uninstalledLaneLeavesNoStateOnDisk() async throws {
    let root = try wanderRoot("uninstalled")
    defer { try? FileManager.default.removeItem(at: root) }

    let installation = StudioWanderLane.resolveInstallation(
        enabled: false, forcedNeutral: false, subconsciousEnabled: true
    )
    #expect(!installation.isInstalled)
    // The app-side caller returns before touching anything when this is false.
    // Prove the file is only ever created by a completed hour.
    #expect(!FileManager.default.fileExists(
        atPath: StudioWanderLane.statePath(dataRoot: root).path
    ))
    let state = try await StudioWanderLane.loadState(dataRoot: root)
    #expect(state == .empty)
    #expect(!FileManager.default.fileExists(
        atPath: StudioWanderLane.statePath(dataRoot: root).path
    ))
}

// MARK: - The gates

@Test func studioWander_everyGateRefusesOnItsOwn() {
    let quietFor2Hours = t0.addingTimeInterval(-2 * 60 * 60)

    // A turn is running — or still settling.
    #expect(StudioWanderLane.decide(
        now: t0, turnInFlight: true, dreamIsDue: false,
        lastTurnActivityAt: quietFor2Hours, lastWanderAt: nil, inQuietHours: false
    ) == .turnInFlight)

    // A due dream outranks her hour. Her own encounter rule, unchanged.
    #expect(StudioWanderLane.decide(
        now: t0, turnInFlight: false, dreamIsDue: true,
        lastTurnActivityAt: quietFor2Hours, lastWanderAt: nil, inQuietHours: false
    ) == .dreamOutranks)

    // The user's sleep window.
    #expect(StudioWanderLane.decide(
        now: t0, turnInFlight: false, dreamIsDue: false,
        lastTurnActivityAt: quietFor2Hours, lastWanderAt: nil, inQuietHours: true
    ) == .quietHours)

    // Something happened 29 minutes ago: not quiet.
    #expect(StudioWanderLane.decide(
        now: t0, turnInFlight: false, dreamIsDue: false,
        lastTurnActivityAt: t0.addingTimeInterval(-29 * 60),
        lastWanderAt: nil, inQuietHours: false
    ) == .notQuiet)

    // Exactly at the boundary the quiet window is satisfied.
    #expect(StudioWanderLane.decide(
        now: t0, turnInFlight: false, dreamIsDue: false,
        lastTurnActivityAt: t0.addingTimeInterval(-StudioWanderLane.quietInterval),
        lastWanderAt: nil, inQuietHours: false
    ) == .wander)
}

@Test func studioWander_noTurnEverSeenIsQuiet() {
    #expect(StudioWanderLane.decide(
        now: t0, turnInFlight: false, dreamIsDue: false,
        lastTurnActivityAt: nil, lastWanderAt: nil, inQuietHours: false
    ) == .wander)
}

/// AT MOST ONCE A DAY, and it is a ceiling rather than a cadence: nothing here
/// makes an hour happen, it only refuses a second one.
@Test func studioWander_atMostOncePerDayUnderEveryOtherGatePassing() {
    let quiet = t0.addingTimeInterval(-60 * 60)

    // 23h59m after the last hour: still refused.
    #expect(StudioWanderLane.decide(
        now: t0, turnInFlight: false, dreamIsDue: false,
        lastTurnActivityAt: quiet,
        lastWanderAt: t0.addingTimeInterval(-(24 * 60 * 60 - 60)),
        inQuietHours: false
    ) == .alreadyToday)

    // A full 24 hours later: hers again.
    #expect(StudioWanderLane.decide(
        now: t0, turnInFlight: false, dreamIsDue: false,
        lastTurnActivityAt: quiet,
        lastWanderAt: t0.addingTimeInterval(-StudioWanderLane.refractoryInterval),
        inQuietHours: false
    ) == .wander)
}

/// The refractory is not a calendar day: a wander at 23:50 does not license a
/// second one twenty minutes later.
@Test func studioWander_refractoryIsAWindowNotACalendarDay() {
    let lateLastNight = t0.addingTimeInterval(-20 * 60)
    #expect(StudioWanderLane.decide(
        now: t0, turnInFlight: false, dreamIsDue: false,
        lastTurnActivityAt: t0.addingTimeInterval(-60 * 60),
        lastWanderAt: lateLastNight, inQuietHours: false
    ) == .alreadyToday)
}

// MARK: - Ending the hour

/// A DECLINE WRITES NOTHING but the trace. No journal, no canon, no seed — and
/// the refractory advances all the same, because the hour was hers to decline.
@Test func studioWander_declineWritesOnlyTheTraceAndConsumesTheHour() async throws {
    let root = try wanderRoot("decline")
    defer { try? FileManager.default.removeItem(at: root) }

    try await StudioWanderLane.recordEndedHour(
        dataRoot: root,
        entry: StudioWanderLane.TraceEntry(
            at: StudioClock.nowISO(t0),
            outcome: .declined,
            line: "Nothing I wanted to sit with tonight."
        ),
        at: t0
    )

    let state = try await StudioWanderLane.loadState(dataRoot: root)
    #expect(state.lastWanderAt.map { abs($0.timeIntervalSince(t0)) < 1 } == true)
    #expect(state.trace.count == 1)
    #expect(state.trace.first?.outcome == .declined)
    #expect(state.trace.first?.journalEntryID == nil)

    // Nothing of hers was written anywhere else.
    let store = SwiftNativeStudioStore(dataRoot: root)
    #expect(!FileManager.default.fileExists(atPath: store.journalPath.path))
    #expect(!FileManager.default.fileExists(atPath: store.canonPath.path))
    #expect(!FileManager.default.fileExists(atPath: store.sensibilityPath.path))

    // And it is genuinely spent: the next reading refuses.
    #expect(StudioWanderLane.decide(
        now: t0.addingTimeInterval(60 * 60), turnInFlight: false, dreamIsDue: false,
        lastTurnActivityAt: nil, lastWanderAt: state.lastWanderAt, inQuietHours: false
    ) == .alreadyToday)
}

/// THE HONESTY VETO. An hour where the artifact could not be obtained records
/// `no_artifact` and carries NO journal entry — the encounter did not happen, so
/// there is nothing to have written about.
@Test func studioWander_noArtifactPathNeverCarriesAJournalEntry() async throws {
    let root = try wanderRoot("no-artifact")
    defer { try? FileManager.default.removeItem(at: root) }

    try await StudioWanderLane.recordEndedHour(
        dataRoot: root,
        entry: StudioWanderLane.TraceEntry(
            at: StudioClock.nowISO(t0),
            outcome: .noArtifact,
            line: "I went for it and could not actually get the work. So: nothing."
        ),
        at: t0
    )

    let state = try await StudioWanderLane.loadState(dataRoot: root)
    #expect(state.trace.first?.outcome == .noArtifact)
    #expect(state.trace.first?.journalEntryID == nil)
    #expect(!FileManager.default.fileExists(
        atPath: SwiftNativeStudioStore(dataRoot: root).journalPath.path
    ))
    #expect(StudioWanderLane.Outcome.noArtifact.receiptKind == "studio.wander_no_artifact")
    #expect(StudioWanderLane.Outcome.declined.receiptKind == "studio.wander_declined")
    #expect(StudioWanderLane.Outcome.chose.receiptKind == "studio.wander_chose")
}

@Test func studioWander_traceIsBoundedAndKeepsTheNewest() async throws {
    let root = try wanderRoot("trace-cap")
    defer { try? FileManager.default.removeItem(at: root) }

    let total = StudioWanderLane.maximumTraceLines + 5
    for index in 0..<total {
        try await StudioWanderLane.recordEndedHour(
            dataRoot: root,
            entry: StudioWanderLane.TraceEntry(
                at: StudioClock.nowISO(t0.addingTimeInterval(Double(index) * 86_400)),
                outcome: .declined,
                line: "hour \(index)"
            ),
            at: t0.addingTimeInterval(Double(index) * 86_400)
        )
    }
    let state = try await StudioWanderLane.loadState(dataRoot: root)
    #expect(state.trace.count == StudioWanderLane.maximumTraceLines)
    #expect(state.trace.last?.line == "hour \(total - 1)")
}

// MARK: - What she is handed

/// The prompt OFFERS. It never assigns, never counts, and says "decline" every
/// time it says "choose".
@Test func studioWander_promptOffersAndNeverNags() {
    let prompt = StudioWanderLane.prompt(
        StudioWanderLane.Material(
            curiosity: ["why does that stair detail keep bothering me"],
            invitations: ["Bruder's Meuser house is on the table, unanswered."],
            recentJournalTitles: ["Hollow Knight"]
        )
    )
    #expect(prompt.contains("This hour is yours"))
    #expect(prompt.contains("or decline"))
    #expect(prompt.contains("HONEST"))
    #expect(prompt.contains("studio_journal"))

    // THE DECLINE CASE IS STATED POSITIVELY. Saying "no streak, no quota" puts
    // both words in front of her and invites her to wonder what is being
    // counted; the only way to mean it is to say nothing about counting.
    #expect(prompt.contains("a full answer, complete in itself"))
    let lower = prompt.lowercased()
    for scoreboard in ["streak", "quota", "count", "you haven't", "days since",
                       "should", "backlog", "owe you", "behind"] {
        #expect(!lower.contains(scoreboard), "'\(scoreboard)' must not appear at all")
    }
}

/// AN INVITATION SHE CANNOT OPEN IS A TEASE. The prompt has to name the organs,
/// or she is being shown one-line summaries of works and asked to judge them —
/// which is the description-only encounter her own rule forbids.
@Test func studioWander_promptNamesHowToActuallyReceiveTheWork() {
    let prompt = StudioWanderLane.prompt(
        StudioWanderLane.Material(invitations: ["something is on the table, unanswered."])
    )
    #expect(prompt.contains("browser.open_url"))
    #expect(prompt.contains("browser.read_text"))
    #expect(prompt.contains("read_file"))
    // The read half of the consult lane, by name, with the field she needs.
    #expect(prompt.contains("studio_consult_read"))
    #expect(prompt.contains("consult_id"))
    // And never the write half: an unattended hour does not file consults.
    #expect(!prompt.contains("studio_consult "))
}

@Test func studioWander_nothingInReachIsAnEmptyMaterial() {
    #expect(StudioWanderLane.Material().isEmpty)
    // Journal titles alone are not something to look at — they are context.
    #expect(StudioWanderLane.Material(recentJournalTitles: ["Solaris"]).isEmpty)
    #expect(!StudioWanderLane.Material(curiosity: ["why"]).isEmpty)
    #expect(!StudioWanderLane.Material(invitations: ["x is on the table."]).isEmpty)
}
