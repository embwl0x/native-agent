import Testing
import Foundation
import Darwin
@testable import PersistenceCore

// MARK: - CheckedFixedSizeSecretFile — the never-repair invariant
//
// LEDGER: core.persistence.CheckedFixedSizeSecretFile.loadOrCreate
//         core.persistence.CheckedFixedSizeSecretFile.replace
//
// Before this file the type had ZERO tests anywhere in the repo, and it is the
// storage under BOTH local authority secrets: the 32-byte tool-manifest
// signing key (TrustCenter/SwiftNativeManifestSigner.swift:143) and the 32-byte
// iOS pairing secret (NativeAgentApp/PairingSecretManager.swift:27).
//
// THE SILENT FAILURE. Its own header states the one invariant it exists for:
// "missing state may bootstrap once, while existing invalid state is
// unavailable and is never repaired or replaced." If that regresses to
// repair-by-regenerate, a truncated/0644/symlinked key file is silently
// replaced with fresh entropy — every previously signed tool manifest fails
// verification and every paired iOS device silently de-pairs, and the app
// presents the whole thing as a clean first-run bootstrap. Nothing throws,
// nothing logs.
//
// THE TOOTH is the generator call COUNT, not just the thrown error. A future
// "self-healing" branch would still throw *something* on some paths; what it
// cannot do without being caught here is call `generate` on a path where
// existing bytes are present. Every damaged-state case asserts generate ran
// ZERO times AND the on-disk bytes are byte-identical afterward.
@Suite("CheckedFixedSizeSecretFile authority invariants")
struct CheckedFixedSizeSecretFileTests {

    private static let byteCount = 32

    // MARK: loadOrCreate

    /// (a) Missing target: bootstrap exactly once — byteCount bytes, mode 0600,
    /// regular file, and the returned bytes equal what landed on disk.
    @Test func loadOrCreate_missingTargetBootstrapsExactlyOnce() throws {
        let dir = try makeSecretDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("secret.bin")
        let counter = CallCounter()
        let seed = Data((0..<Self.byteCount).map { UInt8($0) })

        let created = try CheckedFixedSizeSecretFile.loadOrCreate(
            at: url,
            byteCount: Self.byteCount
        ) {
            counter.bump()
            return seed
        }

        #expect(counter.count == 1)
        #expect(created.count == Self.byteCount)
        #expect(created == seed)
        #expect(fileMode(url) == 0o600)
        #expect(isRegularFile(url))
        let onDisk = try Data(contentsOf: url)
        #expect(onDisk == seed)

        // A SECOND load must read, never re-generate: the bootstrap-once half
        // of the invariant. A regression that re-rolls entropy on every launch
        // invalidates every signature already published.
        let reloaded = try CheckedFixedSizeSecretFile.loadOrCreate(
            at: url,
            byteCount: Self.byteCount
        ) {
            counter.bump()
            return Data(repeating: 0xFF, count: Self.byteCount)
        }
        #expect(counter.count == 1)
        #expect(reloaded == seed)
    }

    /// (b)-(e) Every damaged-existing-state shape: throws Unavailable, calls the
    /// generator ZERO times, and leaves the target byte-identical. Table-driven
    /// so a new damage shape is one line, not a new test.
    @Test func loadOrCreate_damagedStateIsUnavailableAndNeverRepaired() throws {
        for damage in DamageShape.allCases {
            let dir = try makeSecretDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("secret.bin")
            let before = try damage.seed(at: url, byteCount: Self.byteCount)
            let counter = CallCounter()

            #expect(throws: CheckedFixedSizeSecretFile.Unavailable.self, "damage: \(damage)") {
                _ = try CheckedFixedSizeSecretFile.loadOrCreate(
                    at: url,
                    byteCount: Self.byteCount
                ) {
                    counter.bump()
                    return Data(repeating: 0xAB, count: Self.byteCount)
                }
            }

            // THE TOOTH: repair-by-regenerate would have to run the generator.
            #expect(counter.count == 0, "damage: \(damage) — generator must not run over existing state")
            #expect(damage.snapshot(at: url) == before, "damage: \(damage) — existing state must be preserved byte-for-byte")
        }
    }

    /// A non-positive byteCount is refused before anything touches the disk —
    /// otherwise a mis-wired caller silently "bootstraps" a zero-byte secret.
    @Test func loadOrCreate_nonPositiveByteCountIsRefusedWithoutCreatingAnything() throws {
        let dir = try makeSecretDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("secret.bin")
        let counter = CallCounter()

        #expect(throws: CheckedFixedSizeSecretFile.Unavailable.self) {
            _ = try CheckedFixedSizeSecretFile.loadOrCreate(at: url, byteCount: 0) {
                counter.bump()
                return Data()
            }
        }
        #expect(counter.count == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// A generator that returns the wrong length must never reach the disk.
    /// This is the short-read-key guard: fewer than byteCount bytes of entropy
    /// accepted as valid authority is indistinguishable from a healthy key.
    @Test func loadOrCreate_wrongLengthGeneratorOutputNeverLands() throws {
        let dir = try makeSecretDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("secret.bin")

        #expect(throws: CheckedFixedSizeSecretFile.Unavailable.self) {
            _ = try CheckedFixedSizeSecretFile.loadOrCreate(at: url, byteCount: Self.byteCount) {
                Data(repeating: 0x01, count: Self.byteCount - 1)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: replace

    /// Rotation over a VALID secret: returns the new bytes, the old bytes are
    /// gone, the file is still a regular 0600 file, and a canonical read-back
    /// (loadOrCreate over the rotated file) returns exactly the new bytes with
    /// the generator untouched — i.e. the swap really committed.
    @Test func replace_rotatesValidSecretAndCommitsNewBytes() throws {
        let dir = try makeSecretDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("secret.bin")
        let original = Data(repeating: 0x11, count: Self.byteCount)
        try writeSecret(original, at: url, mode: 0o600)
        let replacement = Data(repeating: 0x22, count: Self.byteCount)

        let rotated = try CheckedFixedSizeSecretFile.replace(
            at: url,
            byteCount: Self.byteCount
        ) { replacement }

        #expect(rotated == replacement)
        #expect(rotated != original)
        #expect(fileMode(url) == 0o600)
        #expect(isRegularFile(url))
        let onDisk = try Data(contentsOf: url)
        #expect(onDisk == replacement)

        // No rotation temporary may survive: `.secret.bin.rotate.<uuid>` files
        // accumulating in the secret directory would be a lifecycle leak in the
        // one directory that must stay legible.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".rotate.") }
        #expect(leftovers.isEmpty, "rotation temporaries leaked: \(leftovers)")

        let readBack = CallCounter()
        let canonical = try CheckedFixedSizeSecretFile.loadOrCreate(
            at: url,
            byteCount: Self.byteCount
        ) {
            readBack.bump()
            return Data(repeating: 0x33, count: Self.byteCount)
        }
        #expect(readBack.count == 0)
        #expect(canonical == replacement)
    }

    /// Rotation over DAMAGED state must fail closed and preserve the damaged
    /// bytes. This is the half a user reaches by mashing "Regenerate pairing
    /// secret" on a broken file: repairing it there would hand back a secret
    /// the paired device never agreed to, and report success.
    @Test func replace_damagedStateIsNeverRepairedByRotation() throws {
        for damage in DamageShape.allCases {
            let dir = try makeSecretDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("secret.bin")
            let before = try damage.seed(at: url, byteCount: Self.byteCount)
            let counter = CallCounter()

            #expect(throws: CheckedFixedSizeSecretFile.Unavailable.self, "damage: \(damage)") {
                _ = try CheckedFixedSizeSecretFile.replace(
                    at: url,
                    byteCount: Self.byteCount
                ) {
                    counter.bump()
                    return Data(repeating: 0xCD, count: Self.byteCount)
                }
            }
            #expect(counter.count == 0, "damage: \(damage) — rotation must validate BEFORE generating")
            #expect(damage.snapshot(at: url) == before, "damage: \(damage) — damaged state must survive a rotation attempt")
        }
    }

    /// Rotation over a MISSING target is not a bootstrap. `replace` is the
    /// user-facing "regenerate" control; if it silently created state it would
    /// paper over a deleted authority file instead of surfacing it.
    @Test func replace_missingTargetIsUnavailableNotABootstrap() throws {
        let dir = try makeSecretDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("secret.bin")
        let counter = CallCounter()

        #expect(throws: CheckedFixedSizeSecretFile.Unavailable.self) {
            _ = try CheckedFixedSizeSecretFile.replace(at: url, byteCount: Self.byteCount) {
                counter.bump()
                return Data(repeating: 0xEE, count: Self.byteCount)
            }
        }
        #expect(counter.count == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// A generator that throws during rotation leaves the ORIGINAL secret
    /// active and untouched — the rollback window the header promises.
    @Test func replace_generatorFailureLeavesOriginalSecretActive() throws {
        let dir = try makeSecretDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("secret.bin")
        let original = Data(repeating: 0x44, count: Self.byteCount)
        try writeSecret(original, at: url, mode: 0o600)

        struct GeneratorFailure: Error {}
        #expect(throws: CheckedFixedSizeSecretFile.Unavailable.self) {
            _ = try CheckedFixedSizeSecretFile.replace(at: url, byteCount: Self.byteCount) {
                throw GeneratorFailure()
            }
        }
        let onDisk = try Data(contentsOf: url)
        #expect(onDisk == original)
        #expect(fileMode(url) == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".rotate.") }
        #expect(leftovers.isEmpty, "failed rotation leaked temporaries: \(leftovers)")
    }

    // MARK: - Damage shapes

    private enum DamageShape: CaseIterable, CustomStringConvertible {
        case wrongByteCount
        case looseMode
        case symlink
        case directory

        var description: String {
            switch self {
            case .wrongByteCount: return "wrong-byte-count"
            case .looseMode: return "0644-mode"
            case .symlink: return "symlink"
            case .directory: return "directory"
            }
        }

        /// Seed the damage and return an opaque snapshot of the on-disk state
        /// to compare against after the call.
        func seed(at url: URL, byteCount: Int) throws -> String {
            switch self {
            case .wrongByteCount:
                try writeSecret(Data(repeating: 0x55, count: byteCount - 1), at: url, mode: 0o600)
            case .looseMode:
                try writeSecret(Data(repeating: 0x66, count: byteCount), at: url, mode: 0o644)
            case .symlink:
                let target = url.deletingLastPathComponent().appendingPathComponent("elsewhere.bin")
                try writeSecret(Data(repeating: 0x77, count: byteCount), at: target, mode: 0o600)
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            case .directory:
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            return snapshot(at: url)
        }

        func snapshot(at url: URL) -> String {
            switch self {
            case .symlink:
                let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "<gone>"
                let target = URL(fileURLWithPath: destination)
                let bytes = (try? Data(contentsOf: target))?.base64EncodedString() ?? "<gone>"
                return "symlink->\(destination)|\(bytes)"
            case .directory:
                var info = stat()
                let isDirectory = lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
                let children = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? ["<gone>"]
                return "dir=\(isDirectory)|\(children.sorted().joined(separator: ","))"
            case .wrongByteCount, .looseMode:
                let bytes = (try? Data(contentsOf: url))?.base64EncodedString() ?? "<gone>"
                return "mode=\(String(fileMode(url), radix: 8))|\(bytes)"
            }
        }
    }
}

// MARK: - Local helpers

/// Non-Sendable, single-threaded counter: every call here is synchronous, so a
/// plain box is honest and keeps the tooth readable.
private final class CallCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

private func makeSecretDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("checked-secret-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeSecret(_ data: Data, at url: URL, mode: mode_t) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
    #expect(chmod(url.path, mode) == 0)
}

private func fileMode(_ url: URL) -> mode_t {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return 0 }
    return info.st_mode & 0o7777
}

private func isRegularFile(_ url: URL) -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return false }
    return (info.st_mode & S_IFMT) == S_IFREG
}
