import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Ledger row `store.admitMotorConsequence` (docs/evals/ledger.json,
// fence core.substrate.field) — the DURABLE replay guard in front of the
// busiest admission path in the fence (218 of 256 live field nodes are
// motor_action) had no test in any module.
//
// It returns a bare Bool, so both failure directions are silent:
//   - wrongly `true`  → the same motor consequence re-enters resident
//                       physiology after every relaunch;
//   - wrongly `false` → motor events silently never reach cognition at all.
//
// These pin the ENVELOPE the guard promises, not its hash strings:
//   1. identity + dedup: same action, same semantics → admitted exactly once;
//   2. contradiction arbitration: a differing projection is admitted only on a
//      STRICTLY newer canonical owner timestamp (ambiguous → refused);
//   3. cap eviction is OLDEST-FIRST — after overflow the most recent key is
//      still guarded, and the evicted one is the oldest.
@Suite("MotorConsequenceAdmission")
struct MotorConsequenceAdmissionTests {

    /// Pinned explicitly (never a shared/default root): the PersistenceCore
    /// harness backstop makes a bare `swift test` hermetic, and this makes it
    /// hermetic regardless of the harness.
    private func tempDataRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-motoradmit-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func model(
        domain: String = "workshop",
        identity: String = "action-1",
        phase: MotorActionPhase = .running,
        domainState: String = "running",
        verification: MotorVerificationState = .pending,
        updatedAt: String? = "2026-08-23T10:00:00Z"
    ) -> MotorActionReadModel {
        MotorActionReadModel(
            domain: domain,
            actionIdentity: identity,
            phase: phase,
            domainState: domainState,
            verification: verification,
            expectedNextEvidence: nil,
            updatedAt: updatedAt
        )
    }

    @Test("an identical motor consequence is admitted exactly once, per (domain, action)")
    func dedupesOnSemanticFingerprintAndSeparatesIdentities() async throws {
        let root = try tempDataRoot("dedupe")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CognitiveSQLiteStore(dataRoot: root)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let first = model()
        #expect(try await store.admitMotorConsequence(first, at: now) == true)
        // Replay of the very same projection — the whole point of the durable guard.
        #expect(try await store.admitMotorConsequence(first, at: now.addingTimeInterval(1)) == false)
        #expect(try await store.admitMotorConsequence(first, at: now.addingTimeInterval(600)) == false)

        // Same action identity under a DIFFERENT domain owner is a different
        // action: a shared action id must not shadow another domain's event.
        #expect(try await store.admitMotorConsequence(
            model(domain: "browser"), at: now.addingTimeInterval(2)) == true)
        // …and a different action id in the same domain is likewise separate.
        #expect(try await store.admitMotorConsequence(
            model(identity: "action-2"), at: now.addingTimeInterval(3)) == true)
    }

    @Test("a contradicting projection needs a STRICTLY newer owner timestamp")
    func contradictionRequiresStrictlyNewerOwnerTimestamp() async throws {
        let root = try tempDataRoot("contradiction")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CognitiveSQLiteStore(dataRoot: root)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(try await store.admitMotorConsequence(
            model(phase: .running, domainState: "running", updatedAt: "2026-08-23T10:00:00Z"),
            at: now) == true)

        // Contradiction at the SAME owner instant is ambiguous → refused.
        #expect(try await store.admitMotorConsequence(
            model(phase: .succeeded, domainState: "succeeded", verification: .satisfied,
                  updatedAt: "2026-08-23T10:00:00Z"),
            at: now.addingTimeInterval(1)) == false)

        // Contradiction stamped EARLIER than the admitted one → refused.
        #expect(try await store.admitMotorConsequence(
            model(phase: .failed, domainState: "failed", verification: .failed,
                  updatedAt: "2026-08-23T09:00:00Z"),
            at: now.addingTimeInterval(2)) == false)

        // No owner timestamp at all → cannot be shown newer → refused.
        #expect(try await store.admitMotorConsequence(
            model(phase: .failed, domainState: "failed", verification: .failed, updatedAt: nil),
            at: now.addingTimeInterval(3)) == false)

        // Strictly newer (fractional-seconds ISO8601 is a real owner format) → admitted.
        #expect(try await store.admitMotorConsequence(
            model(phase: .succeeded, domainState: "succeeded", verification: .satisfied,
                  updatedAt: "2026-08-23T10:00:00.500Z"),
            at: now.addingTimeInterval(4)) == true)

        // And that later correction is now itself the guarded state.
        #expect(try await store.admitMotorConsequence(
            model(phase: .succeeded, domainState: "succeeded", verification: .satisfied,
                  updatedAt: "2026-08-23T10:00:00.500Z"),
            at: now.addingTimeInterval(5)) == false)
    }

    // The cap eviction is the silent-starvation edge: if it evicted a LIVE key
    // the same consequence would be re-admitted as new on the next relaunch.
    // Mirrors CognitiveSQLiteStore.maximumMotorConsequenceAdmissions (private);
    // if that constant moves, this fails loudly rather than drifting vacuous.
    private static let admissionCap = 4_096

    @Test("cap overflow evicts the OLDEST admission and never the newest")
    func capEvictionIsOldestFirst() async throws {
        let root = try tempDataRoot("cap")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CognitiveSQLiteStore(dataRoot: root)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let cap = Self.admissionCap
        for index in 0..<cap {
            #expect(try await store.admitMotorConsequence(
                model(identity: "action-\(index)"),
                at: base.addingTimeInterval(Double(index))) == true)
        }

        // Exactly at the cap, nothing has been evicted yet: the oldest key is
        // still guarded (a false here would mean eviction fires early).
        #expect(try await store.admitMotorConsequence(
            model(identity: "action-0"), at: base.addingTimeInterval(Double(cap))) == false)

        // One past the cap.
        #expect(try await store.admitMotorConsequence(
            model(identity: "action-overflow"),
            at: base.addingTimeInterval(Double(cap + 1))) == true)

        // The newest keys must still be guarded — evicting a live id is the
        // failure that silently re-admits a motor consequence forever.
        #expect(try await store.admitMotorConsequence(
            model(identity: "action-overflow"),
            at: base.addingTimeInterval(Double(cap + 2))) == false)
        #expect(try await store.admitMotorConsequence(
            model(identity: "action-\(cap - 1)"),
            at: base.addingTimeInterval(Double(cap + 3))) == false)

        // …and the OLDEST one is the one that made room: it is admissible again.
        #expect(try await store.admitMotorConsequence(
            model(identity: "action-0"),
            at: base.addingTimeInterval(Double(cap + 4))) == true)
    }
}
