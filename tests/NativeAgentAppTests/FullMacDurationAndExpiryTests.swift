// FULL MAC DURATION PICKER + EXPIRY SURFACING (2026-06-10)
//
// Covers the three layers of the feature:
//   1. Duration selection writes the right policy fields through the REAL
//      save path (NativeClient.fullMacDurationPatchBody →
//      NativeClient.applyTrustPolicyPatch — the same deep-merge + flock +
//      normalize-reload chokepoint postTrustWrite uses, against a tmp root).
//   2. FullMacExpiry state/string mirror for the four operator-visible
//      cases (active / expiring-soon / expired / never) plus the 24h
//      gate-clamp mirror and the explicit-expiresAt 48h path.
//   3. FullMacExpiryNotifier idempotency: two ticks in the warning window →
//      one card; expiry → one card; reconfirm (new fullMacConfirmedAt) →
//      a new cycle can card again; neverExpires → no cards ever.
//
// All roots are tmp dirs — no production data is touched.
import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import NativeAgentApp

// MARK: - helpers

private func makeFullMacTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FullMacDurationAndExpiryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func isoUTC(_ date: Date) -> String {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fmt.string(from: date)
}

/// Seed `<root>/trust/policy.json` with a Full-Mac-shaped policy.
/// `confirmedAt: nil` OMITS the key entirely (the missing-on-disk-stamp
/// shape the notifier cycle-key blocker is about).
private func seedTrustPolicy(
    root: URL,
    permissionLevel: String = "full_mac_os",
    outsideDefault: String = "allow",
    confirmedAt: String?,
    maxDurationHours: Double = 4,
    neverExpires: Bool = false,
    expiresAt: String = ""
) throws {
    let trustDir = root.appendingPathComponent("trust", isDirectory: true)
    try FileManager.default.createDirectory(at: trustDir, withIntermediateDirectories: true)
    var policy: [String: Any] = [
        "permissionLevel": permissionLevel,
        "autonomyDefault": "workspace_autonomous",
        "developerMode": false,
        "filePolicy": [
            "outsideWorkspaceDefault": outsideDefault,
            "requireBackupBeforeWrite": false,
        ],
        "fullMacMaxDurationHours": maxDurationHours,
        "fullMacNeverExpires": neverExpires,
        "fullMacExpiresAt": expiresAt,
    ]
    if let confirmedAt {
        policy["fullMacConfirmedAt"] = confirmedAt
    }
    let data = try JSONSerialization.data(withJSONObject: policy, options: [.prettyPrinted])
    try data.write(to: trustDir.appendingPathComponent("policy.json"))
}

/// All cards currently in `<root>/notifications/inbox.jsonl` whose id has
/// the given prefix.
private func inboxCardIds(root: URL, prefix: String) throws -> [String] {
    let path = root
        .appendingPathComponent("notifications", isDirectory: true)
        .appendingPathComponent("inbox.jsonl")
    guard let data = try? Data(contentsOf: path),
          let text = String(data: data, encoding: .utf8) else { return [] }
    var ids: [String] = []
    for line in text.split(separator: "\n") {
        guard let obj = try JSONSerialization.jsonObject(
            with: Data(line.utf8)) as? [String: Any],
              let id = obj["id"] as? String else { continue }
        if id.hasPrefix(prefix) { ids.append(id) }
    }
    return ids
}

// MARK: - 1. duration patch body + real save path

@Test
func trustPatch_preservesMalformedExistingPolicy() async throws {
    let root = try makeFullMacTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trustDir = root.appendingPathComponent("trust", isDirectory: true)
    try FileManager.default.createDirectory(at: trustDir, withIntermediateDirectories: true)
    let path = trustDir.appendingPathComponent("policy.json")
    let damaged = Data("not-json".utf8)
    try damaged.write(to: path)

    await #expect(throws: (any Error).self) {
        _ = try await NativeClient.applyTrustPolicyPatch(
            body: ["enableAutonomy": true],
            dataRoot: root
        )
    }
    #expect(try Data(contentsOf: path) == damaged)
}

@Test
func trustPatch_rejectsWrongTypedKnownAuthorityFieldBeforeWriting() async throws {
    let root = try makeFullMacTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("trust/policy.json")

    await #expect(throws: (any Error).self) {
        _ = try await NativeClient.applyTrustPolicyPatch(
            body: ["securityPolicy": ["killSwitchEnabled": "false"]],
            dataRoot: root
        )
    }
    #expect(!FileManager.default.fileExists(atPath: path.path))
}

@Test
func developerModePatch_persistsAndMirrorsDependentGatesWithoutRenewingFullMac() async throws {
    let root = try makeFullMacTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let confirmedAt = isoUTC(Date(timeIntervalSince1970: 1_700_000_000))
    try seedTrustPolicy(root: root, confirmedAt: confirmedAt)

    let enabled = try await NativeClient.applyTrustPolicyPatch(
        body: NativeClient.developerModePatchBody(enabled: true),
        dataRoot: root
    )
    #expect(enabled.developerMode == true)
    #expect(enabled.filePolicy?.allowDestructiveActions == true)
    #expect(enabled.macControlPolicy?.shellAllowed == true)
    #expect(enabled.macControlPolicy?.systemControlAllowed == true)
    #expect(enabled.fullMacConfirmedAt == confirmedAt)

    let persistedData = try Data(contentsOf: root.appendingPathComponent("trust/policy.json"))
    let persisted = try #require(
        JSONSerialization.jsonObject(with: persistedData) as? [String: Any]
    )
    #expect(persisted["developerMode"] as? Bool == true)
    #expect(persisted["fullMacConfirmedAt"] as? String == confirmedAt)

    let disabled = try await NativeClient.applyTrustPolicyPatch(
        body: NativeClient.developerModePatchBody(enabled: false),
        dataRoot: root
    )
    #expect(disabled.developerMode == false)
    #expect(disabled.filePolicy?.allowDestructiveActions == false)
    #expect(disabled.macControlPolicy?.shellAllowed == false)
    #expect(disabled.macControlPolicy?.systemControlAllowed == false)
    #expect(disabled.fullMacConfirmedAt == confirmedAt)
}

@Test
func durationPatchBody_fourAndTwentyFourHours_writeWindowFields() {
    for hours in [4.0, 24.0] {
        let body = NativeClient.fullMacDurationPatchBody(hours: hours, neverExpires: false)
        #expect(body["fullMacMaxDurationHours"] as? Double == hours)
        #expect(body["fullMacNeverExpires"] as? Bool == false)
        // ≤24h must NOT pin an explicit instant — the confirmedAt sliding
        // window (which the gate reads un-clamped at these values) governs.
        #expect(body["fullMacExpiresAt"] as? String == "")
        // No derive intent either: the lock-side transform must be a no-op.
        #expect(body[NativeClient.fullMacExpiryDurationIntentKey] == nil)
    }
}

@Test
func durationPatchBody_neverExpires_writesNeverAndKeepsDuration() {
    let body = NativeClient.fullMacDurationPatchBody(hours: nil, neverExpires: true)
    #expect(body["fullMacNeverExpires"] as? Bool == true)
    #expect(body["fullMacExpiresAt"] as? String == "never")
    // Stored duration is untouched so flipping back from Never keeps the
    // previous window length.
    #expect(body["fullMacMaxDurationHours"] == nil)
    #expect(body[NativeClient.fullMacExpiryDurationIntentKey] == nil)
}

@Test
func durationPatchBody_fortyEightHours_carriesIntentNotATimestamp() {
    // Review blocker fix (2026-06-10): the body must NOT precompute the
    // expiry — it carries the duration intent, and applyTrustPolicyPatch
    // derives the instant from the ON-DISK confirmedAt under the policy
    // lock (a concurrent reconfirm can't stale-anchor it).
    let body = NativeClient.fullMacDurationPatchBody(hours: 48, neverExpires: false)
    #expect(body["fullMacMaxDurationHours"] as? Double == 48)
    #expect(body["fullMacNeverExpires"] as? Bool == false)
    #expect(body["fullMacExpiresAt"] as? String == "")
    #expect(body[NativeClient.fullMacExpiryDurationIntentKey] as? Double == 48)
}

@Test
func durationPatch_fortyEightHoursWithoutOnDiskConfirmStamp_leavesExpiryCleared() async throws {
    // No confirmedAt on disk → the lock-side derive has no anchor and the
    // explicit expiry stays cleared (reconfirm flow fills it in later).
    let root = try makeFullMacTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedTrustPolicy(root: root, confirmedAt: nil, maxDurationHours: 4)
    let saved = try await NativeClient.applyTrustPolicyPatch(
        body: NativeClient.fullMacDurationPatchBody(hours: 48, neverExpires: false),
        dataRoot: root
    )
    #expect(saved.fullMacMaxDurationHours == 48)
    // The reload path backfills confirmedAt in memory, but the explicit
    // expiry on disk must be "" — never derived from a backfilled stamp.
    let data = try Data(contentsOf: root
        .appendingPathComponent("trust", isDirectory: true)
        .appendingPathComponent("policy.json"))
    let onDisk = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(onDisk?["fullMacExpiresAt"] as? String == "")
    #expect(onDisk?[NativeClient.fullMacExpiryDurationIntentKey] == nil)
}

@Test
func durationPatch_staleReconfirmRace_derivesFromOnDiskStampAtWriteTime() async throws {
    // Review blocker (2026-06-10): the OLD shape computed expiresAt from a
    // confirmedAt snapshot read BEFORE the policy lock. Simulate the race:
    // the patch body is built while T0 is current, a reconfirm lands (T1),
    // THEN the patch applies. The explicit expiry (gate precedence!) must
    // anchor to T1 — the on-disk stamp at write time — never T0.
    let root = try makeFullMacTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let t0 = Date(timeIntervalSince1970: 1_780_000_000)
    try seedTrustPolicy(root: root, confirmedAt: isoUTC(t0))

    // Body built against the T0 world (carries only intent — no timestamp).
    let body = NativeClient.fullMacDurationPatchBody(hours: 48, neverExpires: false)

    // Concurrent reconfirm wins the race to disk.
    let t1 = t0.addingTimeInterval(2 * 3600)
    try seedTrustPolicy(root: root, confirmedAt: isoUTC(t1))

    let saved = try await NativeClient.applyTrustPolicyPatch(body: body, dataRoot: root)
    #expect(AppModel.tolerantISO8601Date(from: saved.fullMacExpiresAt ?? "")
        == t1.addingTimeInterval(48 * 3600))
    #expect(saved.fullMacConfirmedAt == isoUTC(t1))

    // The transport-only intent key never persists.
    let data = try Data(contentsOf: root
        .appendingPathComponent("trust", isDirectory: true)
        .appendingPathComponent("policy.json"))
    let onDisk = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(onDisk?[NativeClient.fullMacExpiryDurationIntentKey] == nil)
}

@Test
func durationPatch_gateValidNaiveConfirmedAt_still48h() async throws {
    // Review blocker (2026-06-10): the gate parser accepts naive
    // (offset-less) timestamps as UTC; AppModel.tolerantISO8601Date does
    // not. With a gate-valid-but-ISO-invalid confirmedAt on disk the OLD
    // derive produced an empty expiresAt → the gate clamped the "48h" pick
    // to its 24h sliding window while the picker claimed 48h. The derive
    // must use the gate's own parser.
    let root = try makeFullMacTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let naive = "2026-06-10T12:00:00" // gate-valid (UTC-naive), ISO-formatter-invalid
    #expect(AppModel.tolerantISO8601Date(from: naive) == nil)        // the mismatch
    let anchor = try #require(FullMacExpiry.parseGateISO8601(naive)) // the gate's read
    try seedTrustPolicy(root: root, confirmedAt: naive)

    let saved = try await NativeClient.applyTrustPolicyPatch(
        body: NativeClient.fullMacDurationPatchBody(hours: 48, neverExpires: false),
        dataRoot: root
    )
    #expect(saved.fullMacMaxDurationHours == 48)
    #expect(AppModel.tolerantISO8601Date(from: saved.fullMacExpiresAt ?? "")
        == anchor.addingTimeInterval(48 * 3600))
}

@Test
func durationSelection_writesThroughRealSavePath() async throws {
    let root = try makeFullMacTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let confirmed = Date(timeIntervalSince1970: 1_780_000_000)
    try seedTrustPolicy(root: root, confirmedAt: isoUTC(confirmed))

    // 48h: duration + neverExpires=false + explicit expiry instant
    // (derived under the policy lock from the on-disk confirmedAt).
    let saved48 = try await NativeClient.applyTrustPolicyPatch(
        body: NativeClient.fullMacDurationPatchBody(hours: 48, neverExpires: false),
        dataRoot: root
    )
    #expect(saved48.fullMacMaxDurationHours == 48)
    #expect(saved48.fullMacNeverExpires == false)
    #expect(AppModel.tolerantISO8601Date(from: saved48.fullMacExpiresAt ?? "")
        == confirmed.addingTimeInterval(48 * 3600))
    // Untouched fields survive the deep merge.
    #expect(saved48.fullMacConfirmedAt == isoUTC(confirmed))
    #expect(saved48.permissionLevel == "full_mac_os")

    // Never: the normalizer keeps neverExpires=true and forces
    // expiresAt="never".
    let savedNever = try await NativeClient.applyTrustPolicyPatch(
        body: NativeClient.fullMacDurationPatchBody(hours: nil, neverExpires: true),
        dataRoot: root
    )
    #expect(savedNever.fullMacNeverExpires == true)
    #expect(savedNever.fullMacExpiresAt == "never")
    #expect(savedNever.fullMacMaxDurationHours == 48) // untouched

    // Back to 4h: never flag drops, the "never" literal is cleared.
    let saved4 = try await NativeClient.applyTrustPolicyPatch(
        body: NativeClient.fullMacDurationPatchBody(hours: 4, neverExpires: false),
        dataRoot: root
    )
    #expect(saved4.fullMacMaxDurationHours == 4)
    #expect(saved4.fullMacNeverExpires == false)
    #expect(saved4.fullMacExpiresAt == "")

    // And the bytes on disk agree (not just the returned model).
    let data = try Data(contentsOf: root
        .appendingPathComponent("trust", isDirectory: true)
        .appendingPathComponent("policy.json"))
    let onDisk = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(onDisk?["fullMacMaxDurationHours"] as? Double == 4)
    #expect(onDisk?["fullMacNeverExpires"] as? Bool == false)
    #expect(onDisk?["fullMacExpiresAt"] as? String == "")
}

// MARK: - 2. expiry-state mirror + status strings

@Test
func expiryState_active_showsCountdown() {
    let confirmed = Date(timeIntervalSince1970: 1_780_000_000)
    let now = confirmed.addingTimeInterval(1 * 3600 + 45 * 60) // 1h45m in
    let state = FullMacExpiry.state(
        permissionLevel: "full_mac_os",
        outsideWorkspaceDefault: "allow",
        neverExpires: false,
        expiresAt: "",
        confirmedAt: isoUTC(confirmed),
        maxDurationHours: 4,
        now: now
    )
    #expect(state == .active(expiresAt: confirmed.addingTimeInterval(4 * 3600)))
    #expect(FullMacExpiry.statusLine(state, now: now)
        == "Full Mac active — expires in 2h 15m")
}

@Test
func expiryState_expiringSoon_isActiveInsideWarningWindow() {
    let confirmed = Date(timeIntervalSince1970: 1_780_000_000)
    let now = confirmed.addingTimeInterval(4 * 3600 - 13 * 60) // 13m left
    let state = FullMacExpiry.state(
        permissionLevel: "full_mac_os",
        outsideWorkspaceDefault: "allow",
        neverExpires: false,
        expiresAt: "",
        confirmedAt: isoUTC(confirmed),
        maxDurationHours: 4,
        now: now
    )
    guard case .active(let expiresAt) = state else {
        Issue.record("expected .active, got \(state)")
        return
    }
    #expect(expiresAt.timeIntervalSince(now) <= FullMacExpiry.warningWindow)
    #expect(FullMacExpiry.statusLine(state, now: now)
        == "Full Mac active — expires in 13m")
}

@Test
func expiryState_expired_showsAgoAndReconfirmHint() {
    let confirmed = Date(timeIntervalSince1970: 1_780_000_000)
    let now = confirmed.addingTimeInterval(7 * 3600 + 12 * 60) // 3h12m past 4h
    let state = FullMacExpiry.state(
        permissionLevel: "full_mac_os",
        outsideWorkspaceDefault: "allow",
        neverExpires: false,
        expiresAt: "",
        confirmedAt: isoUTC(confirmed),
        maxDurationHours: 4,
        now: now
    )
    #expect(state == .expired(at: confirmed.addingTimeInterval(4 * 3600)))
    #expect(FullMacExpiry.statusLine(state, now: now)
        == "Full Mac EXPIRED 3h 12m ago — reconfirm to restore file tools")
}

@Test
func expiryState_neverExpires_evenWayPastTheWindow() {
    let confirmed = Date(timeIntervalSince1970: 1_780_000_000)
    let now = confirmed.addingTimeInterval(50 * 3600)
    let state = FullMacExpiry.state(
        permissionLevel: "full_mac_os",
        outsideWorkspaceDefault: "allow",
        neverExpires: true,
        expiresAt: "never",
        confirmedAt: isoUTC(confirmed),
        maxDurationHours: 4,
        now: now
    )
    #expect(state == .never)
    #expect(FullMacExpiry.statusLine(state, now: now)
        == "Full Mac active — expires never")
}

@Test
func expiryState_offWhenPermissionGateIsClosed() {
    let state = FullMacExpiry.state(
        permissionLevel: "balanced",
        outsideWorkspaceDefault: "deny",
        neverExpires: false,
        expiresAt: "",
        confirmedAt: isoUTC(Date()),
        maxDurationHours: 4,
        now: Date()
    )
    #expect(state == .off)
    #expect(FullMacExpiry.statusLine(state) == "Full Mac not active")
}

@Test
func expiryState_explicitExpiresAtHonors48hUnclamped() {
    // The 48h option's write shape: explicit instant + duration 48.
    let confirmed = Date(timeIntervalSince1970: 1_780_000_000)
    let expires = confirmed.addingTimeInterval(48 * 3600)
    let now = confirmed.addingTimeInterval(40 * 3600) // 40h in — past any 24h clamp
    let state = FullMacExpiry.state(
        permissionLevel: "full_mac_os",
        outsideWorkspaceDefault: "allow",
        neverExpires: false,
        expiresAt: isoUTC(expires),
        confirmedAt: isoUTC(confirmed),
        maxDurationHours: 48,
        now: now
    )
    #expect(state == .active(expiresAt: expires))
}

@Test
func expiryState_slidingWindowMirrorsGate24hClamp() {
    // WITHOUT the explicit instant, 48 in fullMacMaxDurationHours behaves
    // as 24h at the gate — the mirror must reproduce that, not flatter it.
    let confirmed = Date(timeIntervalSince1970: 1_780_000_000)
    let now = confirmed.addingTimeInterval(30 * 3600)
    let state = FullMacExpiry.state(
        permissionLevel: "full_mac_os",
        outsideWorkspaceDefault: "allow",
        neverExpires: false,
        expiresAt: "",
        confirmedAt: isoUTC(confirmed),
        maxDurationHours: 48,
        now: now
    )
    #expect(state == .expired(at: confirmed.addingTimeInterval(24 * 3600)))
}

// MARK: - 3. notifier idempotency

@Test
func notifier_warnsOnceThenExpiresOnce_andReconfirmRearms() async throws {
    let root = try makeFullMacTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let confirmed = Date(timeIntervalSince1970: 1_780_000_000)
    try seedTrustPolicy(root: root, confirmedAt: isoUTC(confirmed), maxDurationHours: 4)

    // Two ticks inside the 30m warning window → exactly ONE warning card.
    let warnNow = confirmed.addingTimeInterval(4 * 3600 - 15 * 60)
    let warnNotifier = FullMacExpiryNotifier(dataRoot: root, now: { warnNow })
    let firstWarning = await warnNotifier.runOnce()
    let duplicateWarning = await warnNotifier.runOnce()
    #expect(firstWarning == .completed("warning card and expiry stamp are durable"))
    #expect(duplicateWarning == .skipped("warning card already staged for this expiry cycle"))
    #expect(try inboxCardIds(root: root, prefix: "fullmac_expiry_warning_").count == 1)
    #expect(try inboxCardIds(root: root, prefix: "fullmac_expiry_expired_").isEmpty)

    // Two ticks past expiry → exactly ONE expired card (warning unchanged).
    let expiredNow = confirmed.addingTimeInterval(4 * 3600 + 5 * 60)
    let expiredNotifier = FullMacExpiryNotifier(dataRoot: root, now: { expiredNow })
    await expiredNotifier.runOnce()
    await expiredNotifier.runOnce()
    #expect(try inboxCardIds(root: root, prefix: "fullmac_expiry_warning_").count == 1)
    #expect(try inboxCardIds(root: root, prefix: "fullmac_expiry_expired_").count == 1)

    // Reconfirm: a fresh fullMacConfirmedAt starts a new cycle — the
    // warning can fire again (new deterministic card id).
    let reconfirmed = confirmed.addingTimeInterval(6 * 3600)
    try seedTrustPolicy(root: root, confirmedAt: isoUTC(reconfirmed), maxDurationHours: 4)
    let secondWarnNow = reconfirmed.addingTimeInterval(4 * 3600 - 10 * 60)
    let secondWarn = FullMacExpiryNotifier(dataRoot: root, now: { secondWarnNow })
    await secondWarn.runOnce()
    await secondWarn.runOnce()
    let warnIds = try inboxCardIds(root: root, prefix: "fullmac_expiry_warning_")
    #expect(warnIds.count == 2)
    #expect(Set(warnIds).count == 2) // distinct cycles → distinct ids
}

@Test
func notifier_cardPersistenceFailureReachesTypedOutcomeAndLeavesStampUntouched() async throws {
    let root = try makeFullMacTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let confirmed = Date(timeIntervalSince1970: 1_780_000_000)
    try seedTrustPolicy(root: root, confirmedAt: isoUTC(confirmed), maxDurationHours: 4)
    // A file where the notifications directory must be makes ensureCard fail.
    try Data("collision".utf8).write(to: root.appendingPathComponent("notifications"))

    let now = confirmed.addingTimeInterval(4 * 3600 + 60)
    let outcome = await FullMacExpiryNotifier(dataRoot: root, now: { now }).runOnce()

    guard case .failed(let detail) = outcome else {
        Issue.record("expected typed persistence failure, got \(outcome)")
        return
    }
    #expect(detail.contains("card persistence failed"))
    #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent("notifications/fullmac_expiry_state.json").path
    ))
}

@Test
func notifier_malformedExistingTrustPolicyFailsInsteadOfAssumingDefaults() async throws {
    let root = try makeFullMacTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = root.appendingPathComponent("trust", isDirectory: true)
    try FileManager.default.createDirectory(at: trust, withIntermediateDirectories: true)
    try Data("{not-json".utf8).write(to: trust.appendingPathComponent("policy.json"))

    let outcome = await FullMacExpiryNotifier(dataRoot: root).runOnce()

    guard case .failed(let detail) = outcome else {
        Issue.record("expected malformed policy failure, got \(outcome)")
        return
    }
    #expect(detail.contains("trust policy unreadable"))
}

@Test
func notifier_neverExpires_neverCards() async throws {
    let root = try makeFullMacTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let confirmed = Date(timeIntervalSince1970: 1_780_000_000)
    // Way past the 4h window — but neverExpires wins at the gate, so there
    // is no expiry and there must be NO cards.
    try seedTrustPolicy(
        root: root,
        confirmedAt: isoUTC(confirmed),
        maxDurationHours: 4,
        neverExpires: true,
        expiresAt: "never"
    )
    let now = confirmed.addingTimeInterval(50 * 3600)
    let notifier = FullMacExpiryNotifier(dataRoot: root, now: { now })
    await notifier.runOnce()
    await notifier.runOnce()
    #expect(try inboxCardIds(root: root, prefix: "fullmac_expiry_").isEmpty)
}

@Test
func notifier_missingOnDiskConfirmedAtWithExplicitExpiry_cardsExactlyOnceAcrossManyTicks() async throws {
    // Review blocker (2026-06-10): with fullMacConfirmedAt MISSING on disk,
    // loadTrustPolicy backfills a fresh in-memory stamp on every load. The
    // old cycle key included that stamp → a new cycle (and a new card id)
    // every 5-minute tick. The key must come from on-disk values only —
    // here the explicit fullMacExpiresAt — so many ticks card exactly once.
    let root = try makeFullMacTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let expires = Date(timeIntervalSince1970: 1_780_000_000)
    try seedTrustPolicy(
        root: root,
        confirmedAt: nil,                 // ← missing on disk
        maxDurationHours: 4,
        expiresAt: isoUTC(expires)        // ← explicit on-disk expiry
    )
    let now = expires.addingTimeInterval(45 * 60) // window closed 45m ago
    let notifier = FullMacExpiryNotifier(dataRoot: root, now: { now })
    for _ in 0..<6 {
        await notifier.runOnce()
    }
    let ids = try inboxCardIds(root: root, prefix: "fullmac_expiry_expired_")
    #expect(ids.count == 1)
    #expect(try inboxCardIds(root: root, prefix: "fullmac_expiry_warning_").isEmpty)
}

@Test
func notifier_permissionGateOff_noCards() async throws {
    let root = try makeFullMacTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let confirmed = Date(timeIntervalSince1970: 1_780_000_000)
    // Expired-looking stamps, but the operator left Full Mac mode — the
    // gate is off, not expired. No spam.
    try seedTrustPolicy(
        root: root,
        permissionLevel: "balanced",
        outsideDefault: "deny",
        confirmedAt: isoUTC(confirmed),
        maxDurationHours: 4
    )
    let now = confirmed.addingTimeInterval(10 * 3600)
    let notifier = FullMacExpiryNotifier(dataRoot: root, now: { now })
    await notifier.runOnce()
    #expect(try inboxCardIds(root: root, prefix: "fullmac_expiry_").isEmpty)
}
