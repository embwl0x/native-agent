import DoctorChecks
import Foundation
import NativeAgentCore
import PersistenceCore
import Testing

// MARK: - INVARIANT (7) — THE TWO TRACE CHECKS ARE HONEST AND UNATTENDED-SAFE
//
// `prompt_prefix_health` and `subconscious_vitals` are the two Doctor rows that
// grade a MEASUREMENT WINDOW of `data/turn_traces/*.jsonl`. Both were added
// because the things they watch fail silently. Both then caused the failure
// they were meant to prevent, in a different key:
//
//   2026-09-02, live: the two rows graded a rolling history window, went red on
//   PRE-FIX history, and the heartbeat pushed "Doctor has 2 failing checks" to
//   User's phone at 3am. The rows were RIGHT and the notification was still
//   WRONG — they are for a person LOOKING at Doctor, not for a robot deciding
//   to wake someone.
//
// Three properties, and every one of them is a way of not lying:
//   * an empty window reads UNMEASURED, never "0 problems";
//   * a day file that exists and will not read is a FAIL, never a zero;
//   * neither row is heartbeat-eligible, and the id-level policy set that the
//     heartbeat actually filters by agrees with the flags on the checks.

private let doctorAnchor = Date(timeIntervalSince1970: 1_788_000_000)

private func traceRoot(_ label: String) -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("turn-regression-doctor-\(label)-\(UUID().uuidString)",
                                isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func dayFileName(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

/// A day file that EXISTS and cannot be read: a directory sitting where the
/// JSONL has to be. The reader opens it, fails, and must say so.
private func plantUnreadableDayFile(in root: URL, on date: Date) throws {
    let dir = root.appendingPathComponent("turn_traces", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: dir.appendingPathComponent("\(dayFileName(date)).jsonl", isDirectory: true),
        withIntermediateDirectories: true
    )
}

private let testIdentity = NativeAgentBuildIdentity(
    version: "9.9.9-test",
    build: "9.9.9",
    sourceRevision: "turnregression",
    sourceDirty: false
)

@Suite("TurnRegression.Doctor")
struct DoctorTraceTurnRegressionTests {

    // MARK: - An empty window is UNMEASURED, never a clean bill

    /// NORTHSTAR clause 2, in one sentence: a check with nothing to look at
    /// must not report that it looked and found nothing wrong. "0 problems" on
    /// an empty feed is the most expensive kind of green.
    @Test("prompt_prefix_health reads unmeasured on an empty window")
    func promptPrefixHealthReadsUnmeasuredOnAnEmptyWindow() async {
        let root = traceRoot("prefix-empty")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await PromptPrefixHealthCheck(
            root: root,
            now: { doctorAnchor },
            killSwitchRaw: { nil },
            identity: testIdentity,
            cacheTTL: 0
        ).run()
        #expect(
            result.status != "ok",
            "an empty window graded itself green: \(result.status) — \(result.detail)"
        )
        #expect(
            result.status.lowercased().contains("unmeasured")
                || result.detail.lowercased().contains("unmeasured"),
            "an empty window has to SAY unmeasured: \(result.status) — \(result.detail)"
        )
    }

    @Test("subconscious_vitals reads unmeasured on an empty window")
    func subconsciousVitalsReadsUnmeasuredOnAnEmptyWindow() async {
        let root = traceRoot("vitals-empty")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await SubconsciousVitalsCheck(
            root: root,
            now: { doctorAnchor },
            identity: testIdentity,
            cacheTTL: 0
        ).run()
        #expect(
            result.status != "ok",
            "an empty capsule window graded itself green: \(result.status)"
        )
        #expect(
            result.status.lowercased().contains("unmeasured")
                || result.detail.lowercased().contains("unmeasured"),
            "an empty window has to SAY unmeasured: \(result.status) — \(result.detail)"
        )
    }

    // MARK: - An unreadable day file is a FAIL, never a zero

    /// A file that exists and will not read is EVIDENCE THE CHECK COULD NOT SEE.
    /// Counting it as zero turns a broken feed into a clean bill — the same
    /// failure the row exists to catch, wearing the row's own uniform.
    @Test("prompt_prefix_health fails on a day file it cannot read")
    func promptPrefixHealthFailsOnAnUnreadableDayFile() async throws {
        let root = traceRoot("prefix-unreadable")
        defer { try? FileManager.default.removeItem(at: root) }
        try plantUnreadableDayFile(in: root, on: doctorAnchor)
        let result = await PromptPrefixHealthCheck(
            root: root,
            now: { doctorAnchor },
            killSwitchRaw: { nil },
            identity: testIdentity,
            cacheTTL: 0
        ).run()
        #expect(
            result.status == "fail",
            "an unreadable day file was not a failure: \(result.status) — \(result.detail)"
        )
    }

    @Test("subconscious_vitals fails on a day file it cannot read")
    func subconsciousVitalsFailsOnAnUnreadableDayFile() async throws {
        let root = traceRoot("vitals-unreadable")
        defer { try? FileManager.default.removeItem(at: root) }
        try plantUnreadableDayFile(in: root, on: doctorAnchor)
        let result = await SubconsciousVitalsCheck(
            root: root,
            now: { doctorAnchor },
            identity: testIdentity,
            cacheTTL: 0
        ).run()
        #expect(
            result.status == "fail",
            "an unreadable day file was not a failure: \(result.status) — \(result.detail)"
        )
    }

    // MARK: - Heartbeat ineligibility

    /// THE 3AM PUSH. A window verdict must never become an unattended
    /// notification. Both rows opt out, and the flag is the thing the check
    /// itself carries.
    @Test("both trace checks declare themselves heartbeat-ineligible")
    func bothTraceChecksAreHeartbeatIneligible() {
        #expect(!PromptPrefixHealthCheck().heartbeatEligible)
        #expect(!SubconsciousVitalsCheck().heartbeatEligible)
    }

    /// …and the ID SET the heartbeat actually filters by agrees with those
    /// flags. A reader holding only a persisted `doctor/latest.json` has no
    /// check instances to ask, so it asks the policy — and the two answers must
    /// not be able to drift apart.
    @Test("the heartbeat policy set names exactly the ineligible rows")
    func theHeartbeatPolicySetAgreesWithTheFlags() {
        #expect(DoctorHeartbeatPolicy.ineligibleCheckIDs.contains("prompt_prefix_health"))
        #expect(DoctorHeartbeatPolicy.ineligibleCheckIDs.contains("subconscious_vitals"))
        #expect(!DoctorHeartbeatPolicy.isEligible("prompt_prefix_health"))
        #expect(!DoctorHeartbeatPolicy.isEligible("subconscious_vitals"))
        // The default is ELIGIBLE, so an ordinary row is unaffected and a new
        // check has to opt out deliberately.
        #expect(DoctorHeartbeatPolicy.isEligible("some_ordinary_check"))
    }

    /// The policy set is DERIVED from the real default check list rather than
    /// restated, so it cannot name a row that no longer opts out.
    @Test("every id in the ineligible set is a real check that really opted out")
    func everyIneligibleIDIsARealCheckThatOptedOut() {
        let ineligible = DoctorHeartbeatPolicy.ineligibleCheckIDs
        let opted = Set(
            SwiftNativeDoctorChecks.defaultChecks
                .filter { !$0.heartbeatEligible }
                .map(\.id)
        )
        #expect(ineligible == opted, "the policy set and the flags disagree")
        #expect(!ineligible.isEmpty, "an empty set would make every assertion above vacuous")
    }

    // MARK: - The window is named, every time

    /// A verdict that does not say what it looked at is not a measurement.
    /// Both rows name their window in the row a person reads.
    @Test("both trace checks name the window they measured")
    func bothTraceChecksNameTheirWindow() async {
        let root = traceRoot("window-named")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = await PromptPrefixHealthCheck(
            root: root, now: { doctorAnchor }, killSwitchRaw: { nil },
            identity: testIdentity, cacheTTL: 0
        ).run()
        let vitals = await SubconsciousVitalsCheck(
            root: root, now: { doctorAnchor }, identity: testIdentity, cacheTTL: 0
        ).run()
        for result in [prefix, vitals] {
            #expect(
                !result.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(result.id) produced a verdict with no detail at all"
            )
        }
        #expect(prefix.id == "prompt_prefix_health")
        #expect(vitals.id == "subconscious_vitals")
    }

    /// Neither row throws, ever. A check that throws aborts the whole `runAll`
    /// traversal and takes every later row down with it.
    @Test("neither trace check throws on a hostile data root")
    func neitherTraceCheckThrowsOnAHostileRoot() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("turn-regression-doctor-absent-\(UUID().uuidString)",
                                    isDirectory: true)
        let prefix = await PromptPrefixHealthCheck(
            root: missing, now: { doctorAnchor }, killSwitchRaw: { nil },
            identity: testIdentity, cacheTTL: 0
        ).run()
        let vitals = await SubconsciousVitalsCheck(
            root: missing, now: { doctorAnchor }, identity: testIdentity, cacheTTL: 0
        ).run()
        #expect(!prefix.status.isEmpty)
        #expect(!vitals.status.isEmpty)
    }
}
