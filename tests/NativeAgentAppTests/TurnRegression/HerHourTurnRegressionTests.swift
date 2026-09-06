import BackgroundLoops
import ChatOrchestration
import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import NativeAgentApp

// MARK: - INVARIANT (6b) — HER HOUR IS OFF, BOUNDED, AND READ-ONLY
//
// User, 2026-09-02: "give it to her." An unattended lane that spends a provider
// turn nobody asked for is the one organ in this wave that can do something in
// the world while nobody is watching, so its failure modes are not "she reads
// the wrong number" — they are "it ran twice", "it ran while he was asleep",
// "it sent something".
//
// `StudioWanderLaneTests` pins the installation booleans and the state file.
// This file pins the three properties that only hold across the ASSEMBLED lane:
//   * OFF means NOT INSTALLED — the call reads nothing and writes nothing;
//   * at most once a day, under every gate, in every order;
//   * it cannot act, cannot commit memory, and cannot send.

private let hourT0 = Date(timeIntervalSince1970: 1_756_000_000)

@Suite("TurnRegression.HerHour")
struct HerHourTurnRegressionTests {

    // MARK: - Installation

    /// THE DEFAULT IS ABSENCE. An unset key reads `nil`, not true, so a fresh
    /// install has no hour at all until someone opens Settings and says so.
    @Test("her hour is not installed until it is deliberately switched on")
    func herHourIsNotInstalledUntilDeliberatelySwitchedOn() {
        #expect(
            StudioWanderLane.resolveInstallation(
                enabled: nil, forcedNeutral: false, subconsciousEnabled: true
            ) == .notInstalled(reason: "switch_off")
        )
        #expect(
            StudioWanderLane.resolveInstallation(
                enabled: false, forcedNeutral: false, subconsciousEnabled: true
            ) == .notInstalled(reason: "switch_off")
        )
        #expect(
            StudioWanderLane.resolveInstallation(
                enabled: true, forcedNeutral: true, subconsciousEnabled: true
            ) == .notInstalled(reason: "public_safe_before_onboarding")
        )
        #expect(
            StudioWanderLane.resolveInstallation(
                enabled: true, forcedNeutral: false, subconsciousEnabled: false
            ) == .notInstalled(reason: "subconscious_off")
        )
        #expect(
            StudioWanderLane.resolveInstallation(
                enabled: true, forcedNeutral: false, subconsciousEnabled: true
            ) == .installed
        )
    }

    /// An uninstalled lane leaves NO state behind. The kill switch is
    /// structural, not a skip that still touched the disk on the way past.
    @Test("an uninstalled lane reads nothing and writes nothing")
    func anUninstalledLaneReadsNothingAndWritesNothing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("her-hour-off-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let installation = StudioWanderLane.resolveInstallation(
            enabled: false, forcedNeutral: false, subconsciousEnabled: true
        )
        #expect(!installation.isInstalled)
        let state = try await StudioWanderLane.loadState(dataRoot: root)
        #expect(state == .empty)
        #expect(
            !FileManager.default.fileExists(
                atPath: StudioWanderLane.statePath(dataRoot: root).path
            ),
            "a read of an absent hour created its state file"
        )
    }

    // MARK: - At most once a day, under every gate

    /// THE REFRACTORY IS A ROLLING WINDOW, not a calendar day: a wander at
    /// 23:50 cannot be followed by another at 00:10.
    @Test("at most one hour per rolling 24 hours, never per calendar day")
    func atMostOneHourPerRollingDay() {
        let lastWander = hourT0
        // Twenty minutes later — a new calendar day in some zones, still the
        // same rolling window everywhere.
        #expect(
            StudioWanderLane.decide(
                now: lastWander.addingTimeInterval(20 * 60),
                turnInFlight: false, dreamIsDue: false,
                lastTurnActivityAt: nil, lastWanderAt: lastWander, inQuietHours: false
            ) == .alreadyToday
        )
        // One second short of the refractory: still no.
        #expect(
            StudioWanderLane.decide(
                now: lastWander.addingTimeInterval(StudioWanderLane.refractoryInterval - 1),
                turnInFlight: false, dreamIsDue: false,
                lastTurnActivityAt: nil, lastWanderAt: lastWander, inQuietHours: false
            ) == .alreadyToday
        )
        // Past it: yes.
        #expect(
            StudioWanderLane.decide(
                now: lastWander.addingTimeInterval(StudioWanderLane.refractoryInterval + 1),
                turnInFlight: false, dreamIsDue: false,
                lastTurnActivityAt: nil, lastWanderAt: lastWander, inQuietHours: false
            ) == .wander
        )
    }

    /// EVERY GATE, INDEPENDENTLY. A lane that only refused on the refractory
    /// would still be able to run in the middle of a conversation or across the
    /// user's sleep window.
    @Test("every gate refuses on its own, and only an all-clear wanders")
    func everyGateRefusesOnItsOwn() {
        let clear = hourT0.addingTimeInterval(48 * 3_600)
        #expect(
            StudioWanderLane.decide(
                now: clear, turnInFlight: true, dreamIsDue: false,
                lastTurnActivityAt: nil, lastWanderAt: nil, inQuietHours: false
            ) == .turnInFlight,
            "her hour is not for the middle of a conversation"
        )
        #expect(
            StudioWanderLane.decide(
                now: clear, turnInFlight: false, dreamIsDue: true,
                lastTurnActivityAt: nil, lastWanderAt: nil, inQuietHours: false
            ) == .dreamOutranks,
            "a due dream outranks an hour spent looking at pictures"
        )
        #expect(
            StudioWanderLane.decide(
                now: clear, turnInFlight: false, dreamIsDue: false,
                lastTurnActivityAt: nil, lastWanderAt: nil, inQuietHours: true
            ) == .quietHours,
            "nothing of hers runs across his sleep window"
        )
        #expect(
            StudioWanderLane.decide(
                now: clear, turnInFlight: false, dreamIsDue: false,
                lastTurnActivityAt: clear.addingTimeInterval(-StudioWanderLane.quietInterval + 1),
                lastWanderAt: nil, inQuietHours: false
            ) == .notQuiet
        )
        #expect(
            StudioWanderLane.decide(
                now: clear, turnInFlight: false, dreamIsDue: false,
                lastTurnActivityAt: clear.addingTimeInterval(-StudioWanderLane.quietInterval - 1),
                lastWanderAt: nil, inQuietHours: false
            ) == .wander,
            "an all-clear has to actually clear, or every gate above is vacuous"
        )
    }

    /// A gate that fires does not consume the day. A deferral is not an hour
    /// spent — she must still get one when the gate lifts.
    @Test("a refused hour is not a spent hour")
    func aRefusedHourIsNotASpentHour() {
        let clear = hourT0.addingTimeInterval(48 * 3_600)
        // Refused for quiet hours, with no prior wander recorded.
        let refused = StudioWanderLane.decide(
            now: clear, turnInFlight: false, dreamIsDue: false,
            lastTurnActivityAt: nil, lastWanderAt: nil, inQuietHours: true
        )
        #expect(refused == .quietHours)
        // The refractory is keyed on `lastWanderAt`, which a refusal never
        // sets, so the very next all-clear still wanders.
        #expect(
            StudioWanderLane.decide(
                now: clear.addingTimeInterval(60), turnInFlight: false, dreamIsDue: false,
                lastTurnActivityAt: nil, lastWanderAt: nil, inQuietHours: false
            ) == .wander
        )
    }

    // MARK: - It cannot act, commit memory, or send

    /// THE ADMITTED SET IS AN ALLOWLIST, and the things an unattended hour must
    /// never reach are named here explicitly so the refusal is a test rather
    /// than an argument about what is "obviously" excluded.
    @Test("her hour cannot act, cannot commit memory, and cannot send")
    func herHourCannotActCommitOrSend() {
        let forbidden = [
            // Acting on the world.
            "act", "run_shell", "shell", "workshop_submit", "mac_click",
            "mac_type", "mac_key", "mac_control", "browser.chrome_click",
            "browser.chrome_type", "browser.navigate",
            // Changing what she knows.
            "commit_memory", "memory_write", "studio_canon_resolve",
            "studio_consult", "save_skill",
            // Speaking to anyone.
            "telegram_send", "slack_send", "send_message", "notify",
            "codex_message", "claude_message", "omp_message", "invoke_codex",
            "x_post", "gmail_send",
        ]
        for tool in forbidden {
            #expect(
                !StudioWanderToolAllowlist.admitted.contains(tool),
                "her unattended hour was allowed to call \(tool)"
            )
        }
    }

    /// `studio_journal` is the ONE write in the whole list, and it is hers.
    /// Everything else admitted is documented read-only.
    @Test("studio_journal is the only write in the admitted set")
    func studioJournalIsTheOnlyWriteInTheAdmittedSet() {
        #expect(StudioWanderToolAllowlist.admitted.contains("studio_journal"))
        // The read organs she needs to hold an honest encounter.
        for tool in ["read", "read_file", "mac_look", "browser.read_text", "inner_state"] {
            #expect(
                StudioWanderToolAllowlist.admitted.contains(tool),
                "\(tool) left the admitted set; an hour that cannot look is not an hour"
            )
        }
        // …and the set stays small enough to read in one sitting, which is what
        // keeps "allowlist" meaningful.
        #expect(StudioWanderToolAllowlist.admitted.count <= 40)
    }

    /// A BLOCKED TOOL REFUSES OUT LOUD. Silence would leave her guessing at her
    /// own edges, and an hour spent guessing is not an hour spent looking.
    @Test("a blocked tool throws instead of silently returning nothing")
    func aBlockedToolThrowsInsteadOfSilentlyReturningNothing() async {
        let wrapper = StudioWanderToolAllowlist(inner: RecordingWanderTools())
        await #expect(throws: (any Error).self) {
            _ = try await wrapper.dispatch(
                tool: "commit_memory",
                input: ["text": .string("remember this")],
                surface: "studio_wander"
            )
        }
    }

    /// THE ENFORCEMENT IS TWICE: at dispatch AND on the advertised catalog, so
    /// an unadmitted tool never even enters the request. One of the two alone
    /// would leave her reading a menu she may not order from.
    @Test("an unadmitted tool is never advertised, not merely refused at dispatch")
    func anUnadmittedToolIsNeverAdvertised() async throws {
        let inner = RecordingWanderTools(
            available: ["read", "studio_journal", "commit_memory", "act", "telegram_send"]
        )
        let wrapper = StudioWanderToolAllowlist(inner: inner)
        let advertised = try await wrapper.listAvailableTools()
        #expect(advertised.contains("read"))
        #expect(advertised.contains("studio_journal"))
        for hidden in ["commit_memory", "act", "telegram_send"] {
            #expect(
                !advertised.contains(hidden),
                "\(hidden) was advertised to an unattended hour"
            )
        }
        // And the inner dispatcher never saw the blocked call at all.
        #expect(await inner.dispatched.isEmpty)
    }
}

// MARK: - A recording inner dispatcher

private actor RecordingWanderTools: ToolDispatchClient {
    private let available: [String]
    private(set) var dispatched: [String] = []

    init(available: [String] = []) {
        self.available = available
    }

    func dispatch(
        tool: String,
        input: [String: JSONValue],
        surface: String
    ) async throws -> JSONValue {
        dispatched.append(tool)
        return .object(["status": .string("ok")])
    }

    func listAvailableTools() async throws -> [String] { available }
}
