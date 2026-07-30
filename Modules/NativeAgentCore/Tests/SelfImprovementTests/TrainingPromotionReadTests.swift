import Testing
import Foundation
@testable import SelfImprovement
import NativeAgentCore
import PersistenceCore

// MARK: - wave 31 W09: training/promotion/evals read-side parity tests
//
// Seeds a temp data root mirroring the daemon's on-disk layout
// (<root>/training_journal/{drill_runs,proposals,promotion_candidates,
// promotion_stages}/ and <root>/evals/runs.json), then asserts each
// SwiftNativeSelfImprovement read method reproduces the daemon's projection
// shape + ordering.

private struct TempRoot {
    let root: URL

    static func make() throws -> TempRoot {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tp-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return TempRoot(root: root)
    }

    func journalDir(_ sub: String) throws -> URL {
        let d = root
            .appendingPathComponent("training_journal", isDirectory: true)
            .appendingPathComponent(sub, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Seed `<root>/trust/policy.json` with the given raw JSON (wave 32 W05 gates).
    func writeTrustPolicy(_ json: String) throws {
        let dir = root.appendingPathComponent("trust", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent("policy.json"), atomically: true, encoding: .utf8)
    }

    func write(_ url: URL, _ json: String) throws {
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func actor(_ t: TempRoot) -> SwiftNativeSelfImprovement {
    SwiftNativeSelfImprovement(dataRoot: t.root)
}

private func asArray(_ v: JSONValue) -> [JSONValue] {
    if case .array(let a) = v { return a }
    return []
}

private func obj(_ v: JSONValue) -> [String: JSONValue] {
    if case .object(let o) = v { return o }
    return [:]
}

private func str(_ v: JSONValue?) -> String? {
    if case .string(let s)? = v { return s }
    return nil
}

@Suite("Training/Promotion/Evals read-side")
struct TrainingPromotionReadTests {

    @Test("training/runs: projects 5 fields, newest-name-first")
    func trainingRuns() async throws {
        let t = try TempRoot.make()
        defer { t.cleanup() }
        let dir = try t.journalDir("drill_runs")
        // Two graded runs + one non-graded file that must be ignored.
        try t.write(dir.appendingPathComponent("2026-05-01-aaa-graded.json"), """
        {"run_id":"aaa","suite_name":"core","graded_at":"2026-05-01","total_score":8,"max_score":10,"extra":"drop-me"}
        """)
        try t.write(dir.appendingPathComponent("2026-05-02-bbb-graded.json"), """
        {"run_id":"bbb","suite_name":"core","graded_at":"2026-05-02","total_score":9,"max_score":10}
        """)
        try t.write(dir.appendingPathComponent("notes.json"), #"{"run_id":"ignored"}"#)

        let result = asArray(await actor(t).listTrainingRunsLocal())
        #expect(result.count == 2)
        // reverse=True on file name → bbb (2026-05-02) first.
        #expect(str(obj(result[0])["run_id"]) == "bbb")
        #expect(str(obj(result[1])["run_id"]) == "aaa")
        // Only the 5 projected keys, no `extra`.
        #expect(Set(obj(result[1]).keys) == ["run_id", "suite_name", "graded_at", "total_score", "max_score"])
    }

    @Test("training/runs/<id>: returns FULL unprojected dict (not the 5-field list shape)")
    func trainingRunDetail() async throws {
        let t = try TempRoot.make()
        defer { t.cleanup() }
        let dir = try t.journalDir("drill_runs")
        // The detail route returns the WHOLE graded-run record, including fields
        // list_runs drops (`extra`, `proposals`, etc.). File name is
        // `<run_id>-graded.json`.
        try t.write(dir.appendingPathComponent("aaa-graded.json"), """
        {"run_id":"aaa","suite_name":"core","graded_at":"2026-05-01","total_score":8,"max_score":10,"extra":"kept","proposals":[{"id":"p1"}]}
        """)
        let result = await actor(t).getTrainingRunLocal(runId: "aaa")
        let o = obj(result ?? .null)
        #expect(str(o["run_id"]) == "aaa")
        // Detail keeps fields the list projection drops.
        #expect(str(o["extra"]) == "kept")
        #expect(o["proposals"] != nil)
        // Full pass-through: more than the 5 projected keys.
        #expect(o.keys.count == 7)
    }

    @Test("training/runs/<id>: absent file returns nil (→ daemon 404)")
    func trainingRunDetailMissing() async throws {
        let t = try TempRoot.make()
        defer { t.cleanup() }
        _ = try t.journalDir("drill_runs")   // dir exists, file does not
        let result = await actor(t).getTrainingRunLocal(runId: "nope")
        #expect(result == nil)
    }

    @Test("training/runs/<id>: present-but-malformed file returns {} not nil (matches _read_json default)")
    func trainingRunDetailMalformed() async throws {
        let t = try TempRoot.make()
        defer { t.cleanup() }
        let dir = try t.journalDir("drill_runs")
        // f.exists() is TRUE but the JSON is broken → daemon `_read_json(f, {})`
        // returns {} (default on parse failure), NOT a 404. So the Swift port
        // must return .object([:]) (a non-nil empty object), distinguishing it
        // from the absent-file 404 case above.
        try t.write(dir.appendingPathComponent("bad-graded.json"), "{not valid json")
        let result = await actor(t).getTrainingRunLocal(runId: "bad")
        #expect(result != nil)
        #expect(obj(result ?? .null).isEmpty)
    }

    @Test("training/proposals: full dict pass-through, forward name order")
    func trainingProposals() async throws {
        let t = try TempRoot.make()
        defer { t.cleanup() }
        let dir = try t.journalDir("proposals")
        try t.write(dir.appendingPathComponent("p2.json"), """
        {"proposal_id":"p2","run_id":"r2","target_doc":"SOUL.md","change_type":"append","current":"a","proposed":"b","rationale":"x","expected_drift_addressed":"d","status":"pending","created_at":"2026-05-02","rejection_reason":null,"approved_at":null}
        """)
        try t.write(dir.appendingPathComponent("p1.json"), """
        {"proposal_id":"p1","status":"approved","target_doc":"VOICE.md"}
        """)
        let result = asArray(await actor(t).listTrainingProposalsLocal())
        #expect(result.count == 2)
        // forward name order → p1 first.
        #expect(str(obj(result[0])["proposal_id"]) == "p1")
        #expect(str(obj(result[1])["proposal_id"]) == "p2")
        // Pass-through preserves the daemon key `rejection_reason` (NOT re-keyed
        // to the UI's optimistic `reject_reason`).
        #expect(obj(result[1])["rejection_reason"] != nil)
    }

    @Test("promotion/candidates: dataclass field set, newest-name-first")
    func promotionCandidates() async throws {
        let t = try TempRoot.make()
        defer { t.cleanup() }
        let dir = try t.journalDir("promotion_candidates")
        try t.write(dir.appendingPathComponent("c1.json"), """
        {"candidate_id":"c1","source":"manual","tier":"B","patches":[],"status":"done","created_at":"2026-05-01","secret_extra":"drop"}
        """)
        try t.write(dir.appendingPathComponent("c2.json"), #"{"candidate_id":"c2","source":"training_b1","tier":"A","patches":[],"status":"running","created_at":"2026-05-02"}"#)
        let result = asArray(await actor(t).listPromotionCandidatesLocal())
        #expect(result.count == 2)
        // reverse=True on file name → c2 first.
        #expect(str(obj(result[0])["candidate_id"]) == "c2")
        // Only dataclass fields; extras dropped; missing optionals null-filled.
        let c1 = obj(result[1])
        #expect(c1["secret_extra"] == nil)
        #expect(c1["finished_at"] == .null)
        #expect(c1["merged_commit_sha"] == .null)
        #expect(c1.keys.count == 14)
    }

    @Test("promotion/pending: only status==pending, dataclass fields")
    func promotionPending() async throws {
        let t = try TempRoot.make()
        defer { t.cleanup() }
        let dir = try t.journalDir("promotion_stages")
        try t.write(dir.appendingPathComponent("s1.json"), """
        {"candidate_id":"s1","tier":"B","harness":{},"delta":{},"staged_at":"2026-05-01","worktree_path":"/w","branch_name":"b","status":"pending"}
        """)
        try t.write(dir.appendingPathComponent("s2.json"), #"{"candidate_id":"s2","tier":"B","harness":{},"delta":{},"staged_at":"2026-05-02","worktree_path":"/w","branch_name":"b","status":"approved"}"#)
        let result = asArray(await actor(t).listPromotionPendingLocal())
        #expect(result.count == 1)
        #expect(str(obj(result[0])["candidate_id"]) == "s1")
        #expect(obj(result[0]).keys.count == 10)
        #expect(obj(result[0])["resolved_at"] == .null)
    }

    @Test("evals/runs: createdAt DESC, [] when not array")
    func evals() async throws {
        let t = try TempRoot.make()
        defer { t.cleanup() }
        let evalsDir = t.root.appendingPathComponent("evals", isDirectory: true)
        try FileManager.default.createDirectory(at: evalsDir, withIntermediateDirectories: true)
        try t.write(evalsDir.appendingPathComponent("runs.json"), """
        [{"id":"e1","createdAt":"2026-05-01"},{"id":"e2","createdAt":"2026-05-03"},{"id":"e3","createdAt":"2026-05-02"}]
        """)
        let result = asArray(await actor(t).listEvalsLocal())
        #expect(result.count == 3)
        // sorted by createdAt DESC.
        #expect(str(obj(result[0])["id"]) == "e2")
        #expect(str(obj(result[1])["id"]) == "e3")
        #expect(str(obj(result[2])["id"]) == "e1")
    }

    @Test("evals/runs: non-string + falsy createdAt coercion matches str(x or '')")
    func evalsKeyCoercion() async throws {
        let t = try TempRoot.make()
        defer { t.cleanup() }
        let evalsDir = t.root.appendingPathComponent("evals", isDirectory: true)
        try FileManager.default.createDirectory(at: evalsDir, withIntermediateDirectories: true)
        // e_num createdAt=123 → key "123"; e_str createdAt="99" → key "99";
        // e_zero createdAt=0 → falsy → key ""; e_missing → key "".
        // DESC string sort of keys: "99" > "123" > "" (e_zero before e_missing
        // by original-order tiebreak).
        try t.write(evalsDir.appendingPathComponent("runs.json"), """
        [{"id":"e_zero","createdAt":0},{"id":"e_num","createdAt":123},{"id":"e_str","createdAt":"99"},{"id":"e_missing"}]
        """)
        let result = asArray(await actor(t).listEvalsLocal())
        #expect(result.map { str(obj($0)["id"]) } == ["e_str", "e_num", "e_zero", "e_missing"])
    }

    @Test("pythonStrOr falsy/truthy parity")
    func pythonStrOrParity() {
        #expect(SwiftNativeSelfImprovement.pythonStrOr(nil) == "")
        #expect(SwiftNativeSelfImprovement.pythonStrOr(.null) == "")
        #expect(SwiftNativeSelfImprovement.pythonStrOr(.string("")) == "")
        #expect(SwiftNativeSelfImprovement.pythonStrOr(.string("2026-05-01")) == "2026-05-01")
        #expect(SwiftNativeSelfImprovement.pythonStrOr(.int(0)) == "")
        #expect(SwiftNativeSelfImprovement.pythonStrOr(.int(123)) == "123")
        #expect(SwiftNativeSelfImprovement.pythonStrOr(.bool(false)) == "")
        #expect(SwiftNativeSelfImprovement.pythonStrOr(.bool(true)) == "True")
        #expect(SwiftNativeSelfImprovement.pythonStrOr(.array([])) == "")
    }

    @Test("missing dirs/files return empty arrays (no throw)")
    func emptyWhenAbsent() async throws {
        let t = try TempRoot.make()
        defer { t.cleanup() }
        let a = actor(t)
        #expect(asArray(await a.listTrainingRunsLocal()).isEmpty)
        #expect(asArray(await a.listTrainingProposalsLocal()).isEmpty)
        #expect(asArray(await a.listPromotionCandidatesLocal()).isEmpty)
        #expect(asArray(await a.listPromotionPendingLocal()).isEmpty)
        #expect(asArray(await a.listEvalsLocal()).isEmpty)
    }

    // MARK: - wave 32 W05: trust-gate parity (_training_allowed / _promotion_allowed)

    @Test("gates DEFAULT-ALLOW when policy.json absent (default-merge true)")
    func gatesAllowOnAbsentPolicy() async throws {
        // The daemon's trust_policy() merges over default_trust_policy(), which
        // sets trainingPolicy.autonomous_training=true and promotionPolicy.enabled
        // =true. A fresh install with no policy.json is therefore ALLOWED.
        let t = try TempRoot.make()
        defer { t.cleanup() }
        let a = actor(t)
        #expect(await a.trainingAllowed() == true)
        #expect(await a.promotionAllowed() == true)
    }

    @Test("gates ALLOW when saved policy omits the leaf key (default leaf survives)")
    func gatesAllowWhenLeafOmitted() async throws {
        // Saved trainingPolicy/promotionPolicy dicts present but WITHOUT the gated
        // leaf → the per-leaf default-merge keeps the default True.
        let t = try TempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy("""
        {"trainingPolicy":{"dream_scheduler":true},"promotionPolicy":{"run_smoke_in_harness":true}}
        """)
        let a = actor(t)
        #expect(await a.trainingAllowed() == true)
        #expect(await a.promotionAllowed() == true)
    }

    @Test("gates CLOSE when leaf explicitly false (saved overrides default)")
    func gatesCloseOnExplicitFalse() async throws {
        let t = try TempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy("""
        {"trainingPolicy":{"autonomous_training":false},"promotionPolicy":{"enabled":false}}
        """)
        let a = actor(t)
        #expect(await a.trainingAllowed() == false)
        #expect(await a.promotionAllowed() == false)
    }

    @Test("developerMode=true reopens both gates even when leaves are false")
    func developerModeOverride() async throws {
        let t = try TempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy("""
        {"developerMode":true,"trainingPolicy":{"autonomous_training":false},"promotionPolicy":{"enabled":false}}
        """)
        let a = actor(t)
        #expect(await a.trainingAllowed() == true)
        #expect(await a.promotionAllowed() == true)
    }

    @Test("falsy developerMode does NOT reopen a closed leaf gate")
    func falsyDeveloperModeNoOverride() async throws {
        // bool(developerMode) must be falsy for false/0/""/missing — none reopen.
        let t = try TempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy("""
        {"developerMode":false,"trainingPolicy":{"autonomous_training":false},"promotionPolicy":{"enabled":false}}
        """)
        let a = actor(t)
        #expect(await a.trainingAllowed() == false)
        #expect(await a.promotionAllowed() == false)
    }

    @Test("non-object saved outer key FAILS CLOSED (daemon would 500; gate must not open)")
    func nonObjectOuterFailsClosed() async throws {
        // The daemon's merge OVERWRITES the default dict with the non-dict value
        // (deep-merge needs both sides to be dicts), then calls `.get()` on a
        // non-dict → AttributeError → HTTP 500. A security gate must never silently
        // open on a malformed trust file, so the Swift mirror fails CLOSED (deny).
        // developerMode is absent here, so neither gate can be reopened.
        let t = try TempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy(#"{"trainingPolicy":"oops","promotionPolicy":42}"#)
        let a = actor(t)
        #expect(await a.trainingAllowed() == false)
        #expect(await a.promotionAllowed() == false)
    }

    @Test("developerMode short-circuits before a non-object outer (matches daemon `or`)")
    func developerModeShortCircuitsNonObjectOuter() async throws {
        // Python `bool(developerMode) or bool(<crashing .get>)` short-circuits on a
        // truthy developerMode and never evaluates the crashing branch → allowed.
        let t = try TempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy(#"{"developerMode":true,"trainingPolicy":"oops","promotionPolicy":42}"#)
        let a = actor(t)
        #expect(await a.trainingAllowed() == true)
        #expect(await a.promotionAllowed() == true)
    }

    @Test("non-object policy.json fails open to default-true (matches isinstance guard)")
    func nonObjectPolicyFile() async throws {
        // Daemon: `if not isinstance(saved, dict): saved = {}` → empty → defaults.
        let t = try TempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy("[1, 2, 3]")
        let a = actor(t)
        #expect(await a.trainingAllowed() == true)
        #expect(await a.promotionAllowed() == true)
    }

    @Test("Full-Mac (full_mac_os) preserves developerMode=true; override ALLOW")
    func fullMacOsPreservesDeveloperMode() async throws {
        let t = try TempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy("""
        {"developerMode":true,"permissionLevel":"full_mac_os","trainingPolicy":{"autonomous_training":false},"promotionPolicy":{"enabled":false}}
        """)
        let a = actor(t)
        #expect(await a.trainingAllowed() == true)
        #expect(await a.promotionAllowed() == true)
    }

    @Test("Full-Mac (wide_open_receipts + outside=allow) preserves developerMode=true; ALLOW")
    func fullMacWideOpenAllowPreservesDeveloperMode() async throws {
        let t = try TempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy("""
        {"developerMode":true,"permissionLevel":"wide_open_receipts","filePolicy":{"outsideWorkspaceDefault":"allow"},"trainingPolicy":{"autonomous_training":false},"promotionPolicy":{"enabled":false}}
        """)
        let a = actor(t)
        #expect(await a.trainingAllowed() == true)
        #expect(await a.promotionAllowed() == true)
    }

    @Test("wide_open_receipts with outside=deny is NOT Full-Mac; developerMode survives → ALLOW")
    func wideOpenDenyIsNotFullMac() async throws {
        let t = try TempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy("""
        {"developerMode":true,"permissionLevel":"wide_open_receipts","filePolicy":{"outsideWorkspaceDefault":"deny"},"trainingPolicy":{"autonomous_training":false},"promotionPolicy":{"enabled":false}}
        """)
        let a = actor(t)
        #expect(await a.trainingAllowed() == true)
        #expect(await a.promotionAllowed() == true)
    }

    @Test("malformed filePolicy does not suppress explicit developerMode override")
    func malformedFilePolicyDoesNotSuppressDeveloperMode() async throws {
        let t = try TempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy("""
        {"developerMode":true,"permissionLevel":"wide_open_receipts","filePolicy":[["outsideWorkspaceDefault","allow"]],"trainingPolicy":{"autonomous_training":false},"promotionPolicy":{"enabled":false}}
        """)
        let a = actor(t)
        #expect(await a.trainingAllowed() == true)
        #expect(await a.promotionAllowed() == true)
    }

    @Test("balanced permission level: developerMode reopens both gates")
    func balancedDeveloperModeSurvives() async throws {
        let t = try TempRoot.make()
        defer { t.cleanup() }
        try t.writeTrustPolicy("""
        {"developerMode":true,"permissionLevel":"balanced","trainingPolicy":{"autonomous_training":false},"promotionPolicy":{"enabled":false}}
        """)
        let a = actor(t)
        #expect(await a.trainingAllowed() == true)
        #expect(await a.promotionAllowed() == true)
    }

    @Test("pythonBool truthiness parity")
    func pythonBoolParity() {
        #expect(SwiftNativeSelfImprovement.pythonBool(nil) == false)
        #expect(SwiftNativeSelfImprovement.pythonBool(.null) == false)
        #expect(SwiftNativeSelfImprovement.pythonBool(.bool(false)) == false)
        #expect(SwiftNativeSelfImprovement.pythonBool(.bool(true)) == true)
        #expect(SwiftNativeSelfImprovement.pythonBool(.int(0)) == false)
        #expect(SwiftNativeSelfImprovement.pythonBool(.int(1)) == true)
        #expect(SwiftNativeSelfImprovement.pythonBool(.double(0)) == false)
        #expect(SwiftNativeSelfImprovement.pythonBool(.double(0.5)) == true)
        #expect(SwiftNativeSelfImprovement.pythonBool(.string("")) == false)
        #expect(SwiftNativeSelfImprovement.pythonBool(.string("x")) == true)
        #expect(SwiftNativeSelfImprovement.pythonBool(.array([])) == false)
        #expect(SwiftNativeSelfImprovement.pythonBool(.array([.int(1)])) == true)
        #expect(SwiftNativeSelfImprovement.pythonBool(.object([:])) == false)
        #expect(SwiftNativeSelfImprovement.pythonBool(.object(["a": .int(1)])) == true)
    }
}
