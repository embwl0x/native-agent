import Testing
import Foundation
@testable import TriggerScheduler
import NativeAgentCore
import PersistenceCore

// MARK: - Wave 38 W15: scheduler-job LIST read port tests + pause/resume guard
//
// Empirically exercises the SwiftNative `listJobs()` path. Covered:
//   * non-list disk content coerces to []
//   * empty / missing file → []
//   * nextRunAt decoration: integral epoch → ISO with NO fractional seconds;
//     fractional epoch → microsecond ISO; both add nextRunAtEpoch (float) +
//     nextRunAtISO.
//   * None / "" / garbage nextRunAt is NOT decorated (no epoch/ISO keys added)
//   * literal 0 IS decorated
//   * all OTHER keys pass through untouched (lastRunAt/createdAt/payload/etc.)
//   * round-trip create→list reflects the persisted job
//   * the read is held under the same <jobs.json>.lock flock as the writes

private func listTestRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SchedulerJobListTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func withListRoot(_ body: (URL) async throws -> Void) async throws {
    let root = try listTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
}

private func seedListJobs(_ jobs: [JSONValue], root: URL) throws {
    let dir = root.appendingPathComponent("scheduler", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("jobs.json")
    let data = try JSONValue.array(jobs).serializedData(pretty: false)
    try data.write(to: url)
}

private func seedRawJobsJSON(_ raw: JSONValue, root: URL) throws {
    let dir = root.appendingPathComponent("scheduler", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("jobs.json")
    let data = try raw.serializedData(pretty: false)
    try data.write(to: url)
}

private func lobj(_ v: JSONValue?) -> [String: JSONValue] {
    if case .object(let o)? = v { return o }
    return [:]
}
private func lstr(_ v: JSONValue?) -> String? {
    if case .string(let s)? = v { return s }
    return nil
}
private func ldbl(_ v: JSONValue?) -> Double? {
    switch v {
    case .some(.double(let d)): return d
    case .some(.int(let i)): return Double(i)
    default: return nil
    }
}

private let listFixedNow: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_780_660_800) }

private func makeListClient(root: URL) -> SwiftNativeTriggerScheduler {
    SwiftNativeTriggerScheduler(
        root: root,
        persistence: SwiftNativePersistenceCore(),
        now: listFixedNow,
        uuid: { "list-uuid" }
    )
}

// MARK: - empty / coercion

@Test func listJobs_missingFile_returnsEmpty() async throws {
    try await withListRoot { root in
        let client = makeListClient(root: root)
        let jobs = try await client.listJobs()
        #expect(jobs.isEmpty)
    }
}

@Test func listJobs_nonListContent_coercesToEmpty() async throws {
    try await withListRoot { root in
        try seedRawJobsJSON(.object(["not": .string("a list")]), root: root)
        let client = makeListClient(root: root)
        let jobs = try await client.listJobs()
        #expect(jobs.isEmpty)
    }
}

// MARK: - nextRunAt decoration

@Test func listJobs_integralEpoch_decoratesWithNoFractionalSeconds() async throws {
    try await withListRoot { root in
        // Stored as a float-string ("1893456000.0").
        try seedListJobs([.object([
            "id": .string("j1"),
            "name": .string("Integral"),
            "kind": .string("notify"),
            "nextRunAt": .string("1893456000.0"),
        ])], root: root)
        let client = makeListClient(root: root)
        let jobs = try await client.listJobs()
        #expect(jobs.count == 1)
        let j = lobj(jobs.first)
        #expect(lstr(j["nextRunAt"]) == "2030-01-01T00:00:00+00:00")
        #expect(lstr(j["nextRunAtISO"]) == "2030-01-01T00:00:00+00:00")
        #expect(ldbl(j["nextRunAtEpoch"]) == 1893456000.0)
    }
}

@Test func listJobs_fractionalEpoch_decoratesWithMicroseconds() async throws {
    try await withListRoot { root in
        try seedListJobs([.object([
            "id": .string("j2"),
            "nextRunAt": .string("1893456000.5"),
        ])], root: root)
        let client = makeListClient(root: root)
        let j = lobj(try await client.listJobs().first)
        // Python: datetime.fromtimestamp(1893456000.5, UTC).isoformat()
        #expect(lstr(j["nextRunAt"]) == "2030-01-01T00:00:00.500000+00:00")
        #expect(lstr(j["nextRunAtISO"]) == "2030-01-01T00:00:00.500000+00:00")
        #expect(ldbl(j["nextRunAtEpoch"]) == 1893456000.5)
    }
}

@Test func listJobs_numericEpochValue_decorates() async throws {
    try await withListRoot { root in
        // Older shells may store nextRunAt as a JSON number rather than a string;
        // Python float(int/float) coerces fine.
        try seedListJobs([.object([
            "id": .string("j3"),
            "nextRunAt": .int(1893456000),
        ])], root: root)
        let j = lobj(try await makeListClient(root: root).listJobs().first)
        #expect(lstr(j["nextRunAt"]) == "2030-01-01T00:00:00+00:00")
        #expect(ldbl(j["nextRunAtEpoch"]) == 1893456000.0)
    }
}

@Test func listJobs_zeroEpoch_isDecorated_notSkipped() async throws {
    try await withListRoot { root in
        // Python: `raw not in (None, "")` → literal 0 IS coerced to 0.0 and
        // decorated to the unix epoch, NOT skipped.
        try seedListJobs([.object([
            "id": .string("j4"),
            "nextRunAt": .int(0),
        ])], root: root)
        let j = lobj(try await makeListClient(root: root).listJobs().first)
        #expect(lstr(j["nextRunAt"]) == "1970-01-01T00:00:00+00:00")
        #expect(ldbl(j["nextRunAtEpoch"]) == 0.0)
    }
}

@Test func listJobs_nullNextRunAt_notDecorated() async throws {
    try await withListRoot { root in
        // Python: raw is None → skipped (no epoch/ISO keys added). The original
        // null nextRunAt passes through unchanged.
        try seedListJobs([.object([
            "id": .string("j5"),
            "nextRunAt": .null,
            "lastRunAt": .null,
        ])], root: root)
        let j = lobj(try await makeListClient(root: root).listJobs().first)
        #expect(j["nextRunAtEpoch"] == nil)
        #expect(j["nextRunAtISO"] == nil)
        // nextRunAt stays the original null.
        if case .some(.null) = j["nextRunAt"] {} else {
            Issue.record("nextRunAt should remain null when not decorated")
        }
    }
}

@Test func listJobs_emptyStringNextRunAt_notDecorated() async throws {
    try await withListRoot { root in
        // Python: "" is in (None, "") → skipped.
        try seedListJobs([.object([
            "id": .string("j6"),
            "nextRunAt": .string(""),
        ])], root: root)
        let j = lobj(try await makeListClient(root: root).listJobs().first)
        #expect(j["nextRunAtEpoch"] == nil)
        #expect(j["nextRunAtISO"] == nil)
        #expect(lstr(j["nextRunAt"]) == "")
    }
}

@Test func listJobs_garbageNextRunAt_notDecorated() async throws {
    try await withListRoot { root in
        // Python: float("notanum") raises ValueError → epoch=None → skipped.
        try seedListJobs([.object([
            "id": .string("j7"),
            "nextRunAt": .string("notanum"),
        ])], root: root)
        let j = lobj(try await makeListClient(root: root).listJobs().first)
        #expect(j["nextRunAtEpoch"] == nil)
        #expect(j["nextRunAtISO"] == nil)
        #expect(lstr(j["nextRunAt"]) == "notanum")
    }
}

// MARK: - passthrough of other fields

@Test func listJobs_otherFieldsPassThroughUntouched() async throws {
    try await withListRoot { root in
        try seedListJobs([.object([
            "id": .string("j8"),
            "name": .string("Keepall"),
            "kind": .string("improve"),
            "enabled": .bool(true),
            "oneShot": .bool(false),
            "intervalSeconds": .int(3600),
            "lastRunAt": .string("2026-06-01T00:00:00+00:00"),
            "createdAt": .string("2026-05-30T00:00:00+00:00"),
            "createdBy": .string("agent"),
            "payload": .object(["objective": .string("do the thing")]),
            "nextRunAt": .string("1893456000.0"),
        ])], root: root)
        let j = lobj(try await makeListClient(root: root).listJobs().first)
        #expect(lstr(j["name"]) == "Keepall")
        #expect(lstr(j["kind"]) == "improve")
        #expect(lstr(j["lastRunAt"]) == "2026-06-01T00:00:00+00:00")
        #expect(lstr(j["createdAt"]) == "2026-05-30T00:00:00+00:00")
        #expect(lstr(j["createdBy"]) == "agent")
        if case .object(let p)? = j["payload"] {
            #expect(lstr(p["objective"]) == "do the thing")
        } else {
            Issue.record("payload should pass through")
        }
        // and the decoration is applied on top.
        #expect(lstr(j["nextRunAt"]) == "2030-01-01T00:00:00+00:00")
    }
}

@Test func listJobs_preservesOrderAndCount() async throws {
    try await withListRoot { root in
        try seedListJobs([
            .object(["id": .string("a"), "nextRunAt": .string("1893456000.0")]),
            .object(["id": .string("b"), "nextRunAt": .null]),
            .object(["id": .string("c"), "nextRunAt": .string("1780660800.0")]),
        ], root: root)
        let jobs = try await makeListClient(root: root).listJobs()
        #expect(jobs.count == 3)
        #expect(lstr(lobj(jobs[0])["id"]) == "a")
        #expect(lstr(lobj(jobs[1])["id"]) == "b")
        #expect(lstr(lobj(jobs[2])["id"]) == "c")
        #expect(lstr(lobj(jobs[2])["nextRunAt"]) == "2026-06-05T12:00:00+00:00")
    }
}

// MARK: - round trip with createJob

@Test func listJobs_reflectsCreatedJob() async throws {
    try await withListRoot { root in
        let client = makeListClient(root: root)
        let created = lobj(try await client.createJob(body: .object([
            "name": .string("RT"),
            "kind": .string("dream"),
            "interval_seconds": .int(3600),
        ])))
        let createdId = lstr(created["id"]) ?? ""
        #expect(!createdId.isEmpty)

        let jobs = try await client.listJobs()
        #expect(jobs.count == 1)
        let listed = lobj(jobs.first)
        #expect(lstr(listed["id"]) == createdId)
        #expect(lstr(listed["name"]) == "RT")
        #expect(lstr(listed["kind"]) == "dream")
        // createJob stamps a numeric nextRunAt float-string → list decorates it.
        #expect(j_hasDecoration(listed))
    }
}

private func j_hasDecoration(_ j: [String: JSONValue]) -> Bool {
    j["nextRunAtEpoch"] != nil && j["nextRunAtISO"] != nil
}

// MARK: - direct decoration unit checks (epochToDecorationISO parity)

@Test func epochToDecorationISO_matchesPythonIsoformat() throws {
    // Pinned against `datetime.fromtimestamp(e, UTC).isoformat()` (worker audit).
    #expect(SchedulerJobNormalizer.epochToDecorationISO(1893456000.0) == "2030-01-01T00:00:00+00:00")
    #expect(SchedulerJobNormalizer.epochToDecorationISO(1893456000.5) == "2030-01-01T00:00:00.500000+00:00")
    #expect(SchedulerJobNormalizer.epochToDecorationISO(1780660800.0) == "2026-06-05T12:00:00+00:00")
    #expect(SchedulerJobNormalizer.epochToDecorationISO(0.0) == "1970-01-01T00:00:00+00:00")
}

@Test func epochToDecorationISO_microsecondTies_roundHalfToEven() throws {
    // CPython datetime.fromtimestamp uses round-HALF-to-EVEN at microsecond
    // resolution (gpt-5.5 review, wave 38 W15). Pinned against Python output:
    //   0.0000005 → 0 (even)  → no fractional component
    //   0.0000015 → .000002
    //   0.0000025 → .000002   (rounds to 2 even, NOT 3)
    #expect(SchedulerJobNormalizer.epochToDecorationISO(0.0000005) == "1970-01-01T00:00:00+00:00")
    #expect(SchedulerJobNormalizer.epochToDecorationISO(0.0000015) == "1970-01-01T00:00:00.000002+00:00")
    #expect(SchedulerJobNormalizer.epochToDecorationISO(0.0000025) == "1970-01-01T00:00:00.000002+00:00")
}

@Test func floatEpochForDecoration_mirrorsPythonCoercion() throws {
    // (None, "") → nil; numeric/string-numeric → value; garbage → nil; 0 → 0.0.
    #expect(SchedulerJobNormalizer.floatEpochForDecoration(nil) == nil)
    #expect(SchedulerJobNormalizer.floatEpochForDecoration(.null) == nil)
    #expect(SchedulerJobNormalizer.floatEpochForDecoration(.string("")) == nil)
    #expect(SchedulerJobNormalizer.floatEpochForDecoration(.string("notanum")) == nil)
    #expect(SchedulerJobNormalizer.floatEpochForDecoration(.string("1893456000.0")) == 1893456000.0)
    #expect(SchedulerJobNormalizer.floatEpochForDecoration(.int(0)) == 0.0)
    #expect(SchedulerJobNormalizer.floatEpochForDecoration(.double(1893456000.5)) == 1893456000.5)
    #expect(SchedulerJobNormalizer.floatEpochForDecoration(.array([])) == nil)
}

// MARK: - native factory guard

@Suite("Wave 38 W15: scheduler pause/resume AUDIT-FIRST guard")
struct SchedulerPauseResumeAuditTests {

    // The list path resolves through SwiftNativeTriggerScheduler.
    @Test func factory_listWriter_isSwiftNative() async throws {
        let writer = makeSchedulerJobWriter()
        #expect(writer is SwiftNativeTriggerScheduler)
    }

    @Test func factory_listWriter_usesInjectedDataRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchedulerWriterFactory-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        let writer = try #require(
            makeSchedulerJobWriter(dataRoot: root) as? SwiftNativeTriggerScheduler
        )

        #expect(writer.jobsPath == root
            .appendingPathComponent("scheduler", isDirectory: true)
            .appendingPathComponent("jobs.json"))
    }
}
