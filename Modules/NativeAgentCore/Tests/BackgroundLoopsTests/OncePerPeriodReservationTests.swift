import Testing
import Foundation
@testable import BackgroundLoops

@Suite("OncePerPeriodReservation")
struct OncePerPeriodReservationTests {

    private func tempMarker() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("once_per_period_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("marker")
    }

    @Test("key form: first call reserves and stamps the key")
    func keyFormReservesFirst() async throws {
        let marker = tempMarker()
        defer { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }

        let r = await reserveOncePerPeriod(key: "week-1", at: marker)
        guard case .reserved = r else { Issue.record("expected reserved, got \(r)"); return }
        let stored = try String(contentsOf: marker, encoding: .utf8)
        #expect(stored == "week-1")
    }

    @Test("key form: same key in the same period is alreadyReserved")
    func keyFormSkipsSamePeriod() async throws {
        let marker = tempMarker()
        defer { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }

        _ = await reserveOncePerPeriod(key: "week-1", at: marker)
        let second = await reserveOncePerPeriod(key: "week-1", at: marker)
        guard case .alreadyReserved = second else {
            Issue.record("expected alreadyReserved, got \(second)"); return
        }
    }

    @Test("key form: a new period key reserves again")
    func keyFormReservesNextPeriod() async throws {
        let marker = tempMarker()
        defer { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }

        _ = await reserveOncePerPeriod(key: "week-1", at: marker)
        let next = await reserveOncePerPeriod(key: "week-2", at: marker)
        guard case .reserved = next else { Issue.record("expected reserved, got \(next)"); return }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "week-2")
    }

    @Test("rollback restores the prior stamp so the next tick retries")
    func rollbackRestoresPrior() async throws {
        let marker = tempMarker()
        defer { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }

        // Seed a prior stamp for period 1.
        _ = await reserveOncePerPeriod(key: "week-1", at: marker)
        // Reserve period 2, then roll back (simulating a failed pass).
        let r = await reserveOncePerPeriod(key: "week-2", at: marker)
        guard case .reserved(_, let rollback) = r else { Issue.record("expected reserved"); return }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "week-2")
        await rollback()
        // Prior "week-1" restored ⇒ period 2 is eligible again next tick.
        #expect(try String(contentsOf: marker, encoding: .utf8) == "week-1")
    }

    @Test("rollback is a compare-and-restore: a newer claim is never clobbered")
    func rollbackDoesNotClobberNewerClaim() async throws {
        let marker = tempMarker()
        defer { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }

        _ = await reserveOncePerPeriod(key: "week-1", at: marker)
        let r = await reserveOncePerPeriod(key: "week-2", at: marker)
        guard case .reserved(let stamp, let rollback) = r else {
            Issue.record("expected reserved"); return
        }
        #expect(stamp == "week-2")
        // A concurrent driver re-claims the marker between our reservation and
        // our failure (e.g. a forced run). The rollback must leave ITS stamp.
        try "week-2-forced".write(to: marker, atomically: true, encoding: .utf8)
        await rollback()
        #expect(try String(contentsOf: marker, encoding: .utf8) == "week-2-forced")
    }

    @Test("rollback after the marker vanished externally restores nothing")
    func rollbackAfterExternalRemovalIsNoOp() async throws {
        let marker = tempMarker()
        defer { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }

        _ = await reserveOncePerPeriod(key: "week-1", at: marker)
        let r = await reserveOncePerPeriod(key: "week-2", at: marker)
        guard case .reserved(_, let rollback) = r else { Issue.record("expected reserved"); return }
        try FileManager.default.removeItem(at: marker)
        await rollback()
        // Absent stays absent — resurrecting the prior would be stale state.
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("rollback removes the marker when there was no prior")
    func rollbackRemovesWhenNoPrior() async throws {
        let marker = tempMarker()
        defer { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }

        let r = await reserveOncePerPeriod(key: "week-1", at: marker)
        guard case .reserved(_, let rollback) = r else { Issue.record("expected reserved"); return }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        await rollback()
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("isFresh true skips without stamping")
    func isFreshTrueSkips() async throws {
        let marker = tempMarker()
        defer { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }

        let r = await reserveOncePerPeriod(at: marker, stamp: "new") { _ in true }
        guard case .alreadyReserved = r else { Issue.record("expected alreadyReserved"); return }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("a throwing isFresh surfaces as .failed and does not stamp")
    func throwingIsFreshFails() async throws {
        let marker = tempMarker()
        defer { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }

        struct Boom: Error {}
        let r = await reserveOncePerPeriod(at: marker, stamp: "new") { _ in throw Boom() }
        guard case .failed = r else { Issue.record("expected failed, got \(r)"); return }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("isFresh may consume a lock-scoped side effect (manual-run forcing)")
    func isFreshSideEffectForcesRun() async throws {
        let marker = tempMarker()
        defer { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }
        let force = marker.deletingLastPathComponent().appendingPathComponent("force")

        // Seed a fresh stamp so time-based freshness would normally skip.
        try "fresh".data(using: .utf8)!.write(to: marker)
        try Data().write(to: force)

        let r = await reserveOncePerPeriod(at: marker, stamp: "forced") { _ in
            if FileManager.default.fileExists(atPath: force.path) {
                try FileManager.default.removeItem(at: force)
                return false   // force a run despite freshness
            }
            return true
        }
        guard case .reserved = r else { Issue.record("expected reserved, got \(r)"); return }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "forced")
        #expect(!FileManager.default.fileExists(atPath: force.path))   // consumed
    }
}
