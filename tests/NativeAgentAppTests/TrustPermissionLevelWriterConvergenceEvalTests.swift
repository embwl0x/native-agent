import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import NativeAgentApp

/// Coverage-ledger fence `app.settings` — Trust Center "Access & Policy".
///
/// Rows closed here (docs/evals/ledger.json):
///   * `setting.trust.permissionLevel`   (REPORTS-ONLY → wrong value, two writers)
///   * `ui.TrustCenter.savePolicyButton` (REPORTS-ONLY)
///   * `ui.TrustCenter.presetButtons`    (REPORTS-ONLY)
///
/// The Trust Center has TWO pickers over one authority. "Agent access"
/// (auto/read_only/workspace/full) saves through `saveAgentAccessMode`;
/// "Permission level" (balanced/strict/wide_open_receipts/full_mac_os) saves
/// through `saveTrustPolicy` — EXCEPT `full_mac_os`, which Save Policy routes
/// back through `saveAgentAccessMode("full")`. If the two writers stop
/// agreeing on `trust/policy.json["permissionLevel"]`, one picker's value is
/// silently unpersisted and the other page keeps showing the stale one.
///
/// Everything below writes through the REAL chokepoint
/// (`NativeClient.applyTrustPolicyPatch`, the root-injectable form of
/// `postTrustWrite`) into a throwaway root.
@Suite("app.settings · Trust permission-level writer convergence")
struct TrustPermissionLevelWriterConvergenceEvalTests {

    private func tempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trust-level-eval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The body `saveTrustPolicy` sends for a non-Full-Mac permission level.
    /// Pinned against the production writer by
    /// `saveTrustPolicyEmitsExactlyTheseAuthorityKeys` below, so this fixture
    /// cannot drift away from the real one in silence.
    private func nonFullMacBody(level: String, outsideDefault: String) -> [String: Any] {
        [
            "permissionLevel": level,
            "autonomyDefault": "supervised",
            "developerMode": false,
            "filePolicy": [
                "requireBackupBeforeWrite": true,
                "outsideWorkspaceDefault": outsideDefault,
            ],
        ]
    }

    /// Every one of the picker's four options must land in
    /// `trust/policy.json` as the SAME string the segment carries. A level
    /// that silently normalizes to something else is the wrong-value class:
    /// the picker keeps showing the choice while the gates read another one.
    @Test func allFourPermissionLevelsPersistUnderTheirOwnName() async throws {
        for level in ["balanced", "strict", "wide_open_receipts"] {
            let root = try tempRoot()
            defer { try? FileManager.default.removeItem(at: root) }

            let outside = level == "wide_open_receipts" ? "allow" : "deny"
            let policy = try await NativeClient.applyTrustPolicyPatch(
                body: nonFullMacBody(level: level, outsideDefault: outside),
                dataRoot: root
            )
            #expect(policy.permissionLevel == level,
                    "permission level \(level) must persist verbatim, got \(policy.permissionLevel)")
            #expect(policy.filePolicy?.outsideWorkspaceDefault == outside)

            // …and the value survives a reload from disk, not just the
            // in-memory return of the write.
            let reread = try await NativeClient.applyTrustPolicyPatch(
                body: [:], dataRoot: root
            ).permissionLevel
            #expect(reread == level, "the level must survive a reload, not just the write's return value")
        }
    }

    /// The fourth option is the one that changes writers. `full_mac_os` on the
    /// Permission-level picker routes through `saveAgentAccessMode("full")`,
    /// whose body must still write `permissionLevel: "full_mac_os"` — the
    /// exact key the picker renders. This is the convergence assertion: two
    /// writers, one key, one value.
    @Test func fullMacRoutesThroughTheOtherWriterAndStillLandsOnTheSameKey() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // The literal body `saveAgentAccessMode("full")` posts.
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let nowISO = isoFormatter.string(from: Date())
        let policy = try await NativeClient.applyTrustPolicyPatch(
            body: [
                "permissionLevel": "full_mac_os",
                "autonomyDefault": "workspace_autonomous",
                "developerMode": false,
                "fullMacMaxDurationHours": 4.0,
                "fullMacNeverExpires": false,
                "fullMacConfirmedAt": nowISO,
                "fullMacExpiresAt": "",
                "filePolicy": [
                    "requireBackupBeforeWrite": false,
                    "outsideWorkspaceDefault": "allow",
                    "allowDestructiveActions": false,
                ],
                "macControlPolicy": NativeClient.macControlPolicyForAccessMode(
                    "full", remoteFromIosAllowed: true, developerMode: false
                ),
            ],
            dataRoot: root
        )

        #expect(policy.permissionLevel == "full_mac_os",
                "the Agent-access writer must land on the SAME permissionLevel string the other picker shows")
        // …and the OTHER picker reads that state back as "full", so neither
        // page shows a value the other one didn't write.
        #expect(AppModel.agentAccessMode(from: policy) == "full")
        #expect(AppModel.normalizedAgentAccessMode("full") == "full")
    }

    /// The read-back mapping is total: every permission level the picker can
    /// select resolves to an Agent-access mode the OTHER picker can render.
    /// A level with no mapping would leave the Agent-access segmented control
    /// with no selected segment — the silent "picker shows nothing" bug.
    @Test func everyPermissionLevelMapsToARenderableAgentAccessMode() throws {
        let renderable: Set<String> = ["auto", "read_only", "workspace", "full"]
        let cases: [(level: String, outside: String, expected: String)] = [
            ("balanced", "deny", "auto"),
            ("strict", "deny", "read_only"),
            ("wide_open_receipts", "deny", "auto"),
        ]
        for (level, outside, expected) in cases {
            let policy = TrustPolicy.decodedFromJSONObject([
                "permissionLevel": level,
                "autonomyDefault": "supervised",
                "filePolicy": ["outsideWorkspaceDefault": outside],
            ])
            let mode = AppModel.agentAccessMode(from: policy)
            #expect(renderable.contains(mode), "\(level) mapped to unrenderable mode \(mode)")
            #expect(mode == expected, "\(level) should read back as \(expected), got \(mode)")
        }
    }

    /// 2026-09-10: Full Mac has no timer. A SAVED Full Mac policy reads back
    /// as "full" whatever expiry stamps an older install left on disk, and a
    /// policy that is not Full Mac never reads back as "full".
    @Test func fullMacReadBackFollowsTheSavedPolicyNotAClock() throws {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let longAgo = fmt.string(from: Date().addingTimeInterval(-72 * 3600))

        let staleStamps = TrustPolicy.decodedFromJSONObject([
            "permissionLevel": "full_mac_os",
            "autonomyDefault": "supervised",
            "filePolicy": ["outsideWorkspaceDefault": "allow"],
            "fullMacMaxDurationHours": 4.0,
            "fullMacNeverExpires": false,
            "fullMacConfirmedAt": longAgo,
            "fullMacExpiresAt": longAgo,
        ])
        #expect(AppModel.fullMacGrantIsActive(staleStamps) == true,
                "a stale stored expiry must not switch Full Mac off")
        #expect(AppModel.agentAccessMode(from: staleStamps) == "full")

        let notFullMac = TrustPolicy.decodedFromJSONObject([
            "permissionLevel": "balanced",
            "autonomyDefault": "supervised",
            "filePolicy": ["outsideWorkspaceDefault": "deny"],
            "fullMacNeverExpires": true,
        ])
        #expect(AppModel.fullMacGrantIsActive(notFullMac) == false)
        #expect(AppModel.agentAccessMode(from: notFullMac) != "full")
    }

    /// Fixture-drift guard for `nonFullMacBody` above: the production writer
    /// must still emit exactly the authority keys this suite replays, and must
    /// still route through the single `postTrustWrite` chokepoint.
    @Test func saveTrustPolicyEmitsExactlyTheseAuthorityKeys() throws {
        let source = try AppSourceScraping.appSource("NativeClient+TrustBackupOps.swift")
        let body = try AppSourceScraping.functionBody(named: "saveTrustPolicy", in: source)
        for key in [
            "\"permissionLevel\": permissionLevel",
            "\"autonomyDefault\": autonomyDefault",
            "\"developerMode\": developerMode",
            "\"requireBackupBeforeWrite\": requireBackups",
            "\"outsideWorkspaceDefault\": outsideDefault",
        ] {
            #expect(body.contains(key), "saveTrustPolicy no longer emits \(key) — update this suite's fixture body")
        }
        #expect(body.contains("postTrustWrite(body: body)"),
                "every trust write must go through the one chokepoint")

        let actions = try AppSourceScraping.appSource("NativeClient+TrustPolicyActions.swift")
        let accessBody = try AppSourceScraping.functionBody(named: "saveAgentAccessMode", in: actions)
        #expect(accessBody.contains("\"permissionLevel\": \"full_mac_os\""),
                "the Agent-access writer must keep converging on the permissionLevel key")
        #expect(accessBody.contains("postTrustWrite(body: body)"))
    }
}

// MARK: - decode helper

extension TrustPolicy {
    /// Decode a TrustPolicy from a plain JSON object literal — the shape the
    /// trust chokepoint returns after a write. Test-local, so the suite can
    /// build read-back states without touching disk.
    fileprivate static func decodedFromJSONObject(_ object: [String: Any]) -> TrustPolicy {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONDecoder.nativeAgent.decode(TrustPolicy.self, from: data)
    }
}
