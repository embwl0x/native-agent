import Testing
import Foundation
import Darwin
@testable import PersistenceCore

// MARK: - The audit-append lane (appendAuditLine / appendAuditLineRaw)
//
// LEDGER: core.persistence.appendAuditLine
//         core.persistence.appendAuditLineRaw
//
// Both had ZERO tests. They are the only two append primitives in the fence
// that deliberately do NOT tighten the target to 0600, and `appendAuditLineRaw`
// is the sole writer behind the blocked-Mac-control receipt feed
// (MacControl+Client.swift:1229 → data/mac_control_audit.jsonl; the ledger row
// says :1276, which is that call site at a later revision — the allowlist test
// below is what actually holds the caller set, so the line number never rots).
//
// THREE silent failures this suite converts into contracts:
//  1. PERMISSION. The loose 0644 posture is DELIBERATE (the daemon-era audit
//     files are shared-readable). A "consistency" refactor that routes these
//     through `appendJSONL` would silently tighten every audit file to 0600 and
//     break the readers — or, read the other way, someone could route a real
//     secret through here and never notice it is world-readable. Pinned in both
//     directions, with `appendJSONL` as the contrast that proves the two paths
//     really differ.
//  2. BYTE-EXACTNESS. `appendAuditLineRaw` exists precisely so a line produced
//     by `serializeOrderedObjectPython` is NOT re-sorted. If it ever re-encodes,
//     the Swift rows stop being byte-equivalent to the Python daemon's rows and
//     nothing anywhere compares them.
//  3. EMBEDDED NEWLINE. It appends a caller-supplied string verbatim with no
//     validation, so one `\n` in a payload splits a single audit row into two
//     physical lines, one of them unparseable. Today that is silent corruption
//     attributed to whichever writer appended next. This suite pins it as a
//     KNOWN, measured contract — the reader's own malformed-line accounting
//     sees it — so the day someone adds validation, this test tells them which
//     behaviour they changed.
@Suite("audit append lane")
struct AuditLineAppendTests {

    // MARK: Permission posture

    /// A fresh file created through `appendAuditLine` carries the umask-derived
    /// mode, NOT 0600. The expected mode is measured from a sibling file created
    /// with the same 0o666 request rather than hardcoded, so the assertion holds
    /// under any umask instead of encoding the CI machine's.
    @Test func appendAuditLine_createsUmaskDerivedModeNotZero600() async throws {
        let dir = try makeAuditDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let core = SwiftNativePersistenceCore()
        let umaskDerived = try umaskDerivedMode(in: dir)

        let auditPath = dir.appendingPathComponent("audit.jsonl")
        try await core.appendAuditLine(.object(["event": .string("blocked")]), to: auditPath)

        #expect(fileMode(auditPath) == umaskDerived)

        // THE CONTRAST that makes this non-vacuous: the ordinary append path on
        // an identical fresh file DOES tighten to 0600. If a refactor merged the
        // two, this pair stops disagreeing and the suite goes red.
        let tightPath = dir.appendingPathComponent("tight.jsonl")
        try await core.appendJSONL(.object(["event": .string("blocked")]), to: tightPath)
        #expect(fileMode(tightPath) == 0o600)
        #expect(fileMode(auditPath) != fileMode(tightPath))
    }

    /// An EXISTING 0644 audit file keeps its mode across an append. This is the
    /// half that a shared reader (another uid, the daemon-era tooling) depends
    /// on; silently tightening it makes the reader go quiet, not loud.
    @Test func appendAuditLine_leavesExistingLooseModeUntouched() async throws {
        let dir = try makeAuditDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let core = SwiftNativePersistenceCore()
        let path = dir.appendingPathComponent("audit.jsonl")
        try Data("{\"seed\":1}\n".utf8).write(to: path)
        #expect(chmod(path.path, 0o644) == 0)

        try await core.appendAuditLine(.object(["event": .string("second")]), to: path)
        #expect(fileMode(path) == 0o644)

        try await core.appendAuditLineRaw("{\"event\": \"third\"}", to: path)
        #expect(fileMode(path) == 0o644)

        let rows = try await core.readJSONL(path)
        #expect(rows.count == 3)
    }

    // MARK: Byte-exactness

    /// A line produced by `serializeOrderedObjectPython` must reach the file
    /// byte-identically — insertion order preserved, no re-encode, exactly one
    /// trailing newline added. That is the entire reason this entry point
    /// exists; if it ever routed through `serialize`, the keys would come back
    /// sorted and the Swift rows would stop matching the daemon's byte-for-byte.
    @Test func appendAuditLineRaw_appendsTheLineByteIdentically() async throws {
        let dir = try makeAuditDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let core = SwiftNativePersistenceCore()
        let path = dir.appendingPathComponent("mac_control_audit.jsonl")

        // Deliberately NOT alphabetical: "verb" before "allowed" before "at".
        let ordered: [(String, JSONValue)] = [
            ("verb", .string("click")),
            ("allowed", .bool(false)),
            ("at", .string("2026-08-23T00:00:00Z")),
            ("reason", .string("policy: \"blocked\"")),
        ]
        let line = try JSONValue.serializeOrderedObjectPython(ordered)
        try await core.appendAuditLineRaw(line, to: path)

        let raw = try String(contentsOf: path, encoding: .utf8)
        #expect(raw == line + "\n")

        // Order preservation stated as a property, not just an equality: the
        // first key on disk is the first key the caller wrote, which a sorting
        // re-encode could not produce.
        let firstKeyOnDisk = raw
            .drop(while: { $0 != "\"" })
            .dropFirst()
            .prefix(while: { $0 != "\"" })
        #expect(String(firstKeyOnDisk) == "verb")
        #expect(String(firstKeyOnDisk) != ordered.map(\.0).sorted().first)

        // And it stays parseable as one row.
        let rows = try await core.readJSONL(path)
        #expect(rows.count == 1)
    }

    /// KNOWN CONTRACT (not an endorsement): an embedded newline in the
    /// caller-supplied string splits one logical audit row into exactly two
    /// physical lines, and the reader's own accounting counts the broken half as
    /// malformed. Pinned so the corruption is measured rather than discovered
    /// later in a feed and blamed on the next writer.
    ///
    /// WHEN VALIDATION LANDS: flip this to expect a throw (or an escaped single
    /// line) and drop the malformed-count assertion. The failure of this test is
    /// the signal that the contract moved — which is the whole point.
    @Test func appendAuditLineRaw_embeddedNewlineSplitsExactlyOneRowIntoTwo() async throws {
        let dir = try makeAuditDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let core = SwiftNativePersistenceCore()
        let path = dir.appendingPathComponent("mac_control_audit.jsonl")

        try await core.appendAuditLineRaw("{\"event\": \"clean\"}", to: path)
        // A payload the caller believes is one row.
        try await core.appendAuditLineRaw("{\"note\": \"line-one\nline-two\"}", to: path)

        let raw = try String(contentsOf: path, encoding: .utf8)
        let physicalLines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(physicalLines.count == 3, "one clean row + the split row's two halves")

        let (rows, report) = try await core.readJSONLReporting(path)
        // The clean row survives; the split row yields ONE unparseable half and
        // one half that is not the row the caller wrote.
        #expect(report.malformedLineCount >= 1)
        #expect(rows.count < physicalLines.count)
        #expect(report.physicalLineCount == 3)
    }

    /// The audit lane is append-only: a second append never rewrites the first
    /// row's bytes. Cheap, but it is the property every receipt feed assumes and
    /// nothing else in the fence states for this entry point.
    @Test func appendAuditLine_isAppendOnlyAcrossCalls() async throws {
        let dir = try makeAuditDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let core = SwiftNativePersistenceCore()
        let path = dir.appendingPathComponent("audit.jsonl")

        try await core.appendAuditLine(.object(["n": .int(1)]), to: path)
        let afterFirst = try Data(contentsOf: path)
        try await core.appendAuditLine(.object(["n": .int(2)]), to: path)
        let afterSecond = try Data(contentsOf: path)

        #expect(afterSecond.count > afterFirst.count)
        #expect(afterSecond.prefix(afterFirst.count) == afterFirst)
    }

    // MARK: Who may reach for the loose-permission primitive

    /// SOURCE-CONFORMANCE GUARD. These two entry points are non-durable AND
    /// permission-loosening; `appendAuditLine` currently has no caller at all,
    /// which makes it exactly the primitive the next security writer reaches for
    /// by name. Rather than freeze the caller count at zero (which would go red
    /// the day someone wires it legitimately), this pins the ALLOWLIST: a new
    /// call site outside it is a deliberate decision that has to edit this test.
    ///
    /// Scope is the Core module tree, which is what `#filePath` can reach
    /// hermetically; the app-target callers are the app fence's business.
    @Test func auditAppendEntryPoints_haveOnlyAllowlistedCallers() throws {
        let moduleRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PersistenceCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // NativeAgentCore
        let sources = moduleRoot.appendingPathComponent("Sources", isDirectory: true)

        // relative path -> the entry points it is allowed to call.
        let allowlist: [String: Set<String>] = [
            "PersistenceCore/PersistenceCore.swift": ["appendAuditLine", "appendAuditLineRaw"],
            "MacControl/MacControl+Client.swift": ["appendAuditLineRaw"],
        ]

        var offenders: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let relative = url.path.replacingOccurrences(of: sources.path + "/", with: "")
            let permitted = allowlist[relative] ?? []
            for entryPoint in ["appendAuditLineRaw", "appendAuditLine"] {
                // `appendAuditLine(` does not match `appendAuditLineRaw(`.
                guard text.contains("\(entryPoint)(") else { continue }
                if !permitted.contains(entryPoint) {
                    offenders.append("\(relative) calls \(entryPoint)")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            New caller(s) of the deliberately non-durable, non-0600 audit append \
            lane: \(offenders.joined(separator: "; ")). If this is intended, add \
            the file to the allowlist in this test — and check that the feed it \
            writes really tolerates a lost tail line and a world-readable mode.
            """
        )
    }
}

// MARK: - Local helpers

private func makeAuditDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("audit-append-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// The mode a 0o666-requested create actually lands with under this process's
/// umask — measured, never assumed, and never by mutating the process umask
/// (which would race every other test in the same process).
private func umaskDerivedMode(in dir: URL) throws -> mode_t {
    let probe = dir.appendingPathComponent("umask-probe-\(UUID().uuidString)")
    let fd = Darwin.open(probe.path, O_CREAT | O_WRONLY | O_EXCL, 0o666)
    guard fd >= 0 else {
        throw NSError(domain: "AuditLineAppendTests", code: Int(errno))
    }
    Darwin.close(fd)
    defer { try? FileManager.default.removeItem(at: probe) }
    return fileMode(probe)
}

private func fileMode(_ url: URL) -> mode_t {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return 0 }
    return info.st_mode & 0o7777
}
