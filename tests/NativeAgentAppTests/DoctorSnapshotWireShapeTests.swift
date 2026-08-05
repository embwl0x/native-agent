// A1/FIX-1a wire-shape pin.
//
// getHealthCard is now a SECOND producer of <dataRoot>/doctor/latest.json, and
// that file has two other readers (SelfHealingHook's healthy→fail detector and
// the heartbeat's doctor section). If the two producers ever disagree on the
// wire shape, those readers silently mis-parse. This test runs BOTH producers
// over the same check results and compares the bytes.
//
// Lives in its own file because naming DoctorChecks.CheckResult requires
// `import DoctorChecks`, which collides with the app's own `DoctorCheck` model
// struct in any file that also uses it.

import Foundation
import Testing
import BackgroundLoops
import DoctorChecks
@testable import NativeAgentApp

private struct StubDoctorChecks: DoctorChecksProtocol {
    let results: [CheckResult]
    func runAll(repair: Bool, checkLLM: Bool) async throws -> [CheckResult] { results }
    func runCheck(id: String, repair: Bool) async throws -> CheckResult? {
        results.first { $0.id == id }
    }
}

@Suite("A1 doctor snapshot wire shape")
struct DoctorSnapshotWireShapeTests {
    @Test("getHealthCard and DoctorAutoRunLoop write the identical snapshot")
    func bothProducersAgreeOnTheWireShape() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-wire-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let loopDir = root.appendingPathComponent("loop/doctor", isDirectory: true)
        let cardPath = root.appendingPathComponent("card/doctor/latest.json")

        let results = [
            CheckResult(id: "storage", title: "Storage", status: "ok", detail: "core-ok"),
            CheckResult(
                id: "chat_messages", title: "Chat Message Logs", status: "warn",
                detail: "core-warn", repair: "fix me"
            ),
        ]

        let loop = DoctorAutoRunLoop(
            interval: 600,
            doctorChecks: StubDoctorChecks(results: results),
            storage: { loopDir }
        )
        let outcome = await loop.tickOutcome()
        guard case .completed = outcome else {
            Issue.record("DoctorAutoRunLoop tick did not complete: \(outcome)")
            return
        }

        _ = await NativeClient.makeHealthCard(
            now: ISO8601DateFormatter().string(from: Date()),
            cachePath: cardPath,
            liveChecks: [],
            runCoreChecks: { results }
        )

        let loopObj = try normalized(loopDir.appendingPathComponent("latest.json"))
        let cardObj = try normalized(cardPath)
        // runAt differs by construction (two different instants); everything
        // else — key set, check array, per-check keys and values — must match.
        #expect(NSDictionary(dictionary: loopObj) == NSDictionary(dictionary: cardObj))
    }

    /// Parses the snapshot and replaces the timestamp with a fixed sentinel.
    private func normalized(_ path: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: path)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["runAt"] is String)
        obj["runAt"] = "<stamp>"
        #expect(Set(obj.keys) == ["checks", "runAt"])
        return obj
    }
}
