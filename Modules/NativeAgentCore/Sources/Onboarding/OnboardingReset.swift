import Foundation
import NativeAgentShared
import MemoryV2
import Observation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
// Blueprint: | `OnboardingReset.swift` | Durable reset intent, exact-byte backups and recovery; backups precede completion evidence removal |
extension SwiftNativeOnboardingClient {
    struct OnboardingResetTargetIntent: Codable, Sendable {
        let role: String
        let contentBase64: String
        let sha256: String
        let backupFileName: String
    }
    /// Original bytes in the manifest can reconstruct backups after source removal.
    struct OnboardingResetTransactionManifest: Codable, Sendable {
        let schemaVersion: Int
        let transactionID: String
        let createdAt: String
        let backupStamp: String
        let personaRoot: String
        let dataRoot: String
        let completionManifestSHA256: String?
        let sentinelSHA256: String?
        let targets: [OnboardingResetTargetIntent]
    }
    static let pendingResetTransactionRelativePath = "onboarding/pending-reset.json"
    var resetTransactionManifestPath: URL {
        dataRoot.appendingPathComponent(Self.pendingResetTransactionRelativePath)
    }
    /// Record exact bytes and marker hashes; publish and verify backups before removing matching sources.
    /// Clear completion evidence next and reset intent last; restarts resume the same intent.
    public func resetOnboarding(confirm: Bool) async throws -> OnboardingResetResult {
        if !confirm {
            return OnboardingResetResult(ok: false, error: "confirmation_required")
        }
        return try await SwiftNativePersistenceCore.withFileLock(transactionManifestPath) {
            let manifest: OnboardingResetTransactionManifest
            if let pending = try Self.loadResetTransactionIfPresent(
                at: resetTransactionManifestPath,
                personaRoot: personaRoot,
                dataRoot: dataRoot
            ) {
                manifest = pending
            } else {
                manifest = try await prepareResetTransactionLocked()
            }
            return try await commitPreparedResetTransaction(
                manifest
            )
        }
    }
    func reconcilePendingResetLocked() async throws {
        guard let pending = try Self.loadResetTransactionIfPresent(
            at: resetTransactionManifestPath,
            personaRoot: personaRoot,
            dataRoot: dataRoot
        ) else { return }
        _ = try await commitPreparedResetTransaction(pending)
    }
    private func prepareResetTransactionLocked() async throws -> OnboardingResetTransactionManifest {
        try ensureDirectoryExists(personaRoot)
        let transactionID = UUID().uuidString.lowercased()
        let backupStamp = Self.utcStamp()
        var targets: [OnboardingResetTargetIntent] = []
        for definition in Self.resetTargetDefinitions {
            let source = personaRoot.appendingPathComponent(definition.fileName)
            let intent: OnboardingResetTargetIntent? = try await SwiftNativePersistenceCore.withFileLock(source) {
                guard FileManager.default.fileExists(atPath: source.path) else { return nil }
                let data: Data
                do {
                    data = try Data(contentsOf: source)
                } catch {
                    throw OnboardingError.ioFailure(
                        "read \(definition.fileName) for reset failed: \(error.localizedDescription)"
                    )
                }
                return OnboardingResetTargetIntent(
                    role: definition.role,
                    contentBase64: data.base64EncodedString(),
                    sha256: Self.sha256(data),
                    backupFileName: Self.resetBackupFileName(
                        sourceFileName: definition.fileName,
                        backupStamp: backupStamp,
                        transactionID: transactionID
                    )
                )
            }
            if let intent { targets.append(intent) }
        }
        let sentinel = dataRoot.appendingPathComponent(".onboarded")
        let sentinelSHA256 = try await SwiftNativePersistenceCore.withFileLock(sentinel) {
            try Self.fileHashIfPresent(sentinel, label: ".onboarded")
        }
        // Read directly under the caller's completion-manifest lock to avoid nesting the same flock.
        let completionManifestSHA256 = try Self.fileHashIfPresent(
            transactionManifestPath,
            label: "pending onboarding completion"
        )
        let manifest = OnboardingResetTransactionManifest(
            schemaVersion: 1,
            transactionID: transactionID,
            createdAt: NativeTimestampFormat.fractionalZulu(Date()),
            backupStamp: backupStamp,
            personaRoot: Self.canonicalPath(personaRoot),
            dataRoot: Self.canonicalPath(dataRoot),
            completionManifestSHA256: completionManifestSHA256,
            sentinelSHA256: sentinelSHA256,
            targets: targets
        )
        try Self.writeTransaction(manifest, to: resetTransactionManifestPath, encodingContext: "onboarding reset transaction")
        return manifest
    }
    private func commitPreparedResetTransaction(
        _ manifest: OnboardingResetTransactionManifest
    ) async throws -> OnboardingResetResult {
        for target in manifest.targets {
            let backup = personaRoot.appendingPathComponent(target.backupFileName)
            try await SwiftNativePersistenceCore.withFileLock(backup) {
                try Self.ensureResetBackup(target, at: backup)
            }
        }
        for target in manifest.targets {
            guard let definition = Self.resetTargetDefinitions.first(where: { $0.role == target.role }) else {
                throw OnboardingError.ioFailure("reset transaction contains unknown role '\(target.role)'")
            }
            let source = personaRoot.appendingPathComponent(definition.fileName)
            try await SwiftNativePersistenceCore.withFileLock(source) {
                try Self.ensureResetFileRemoved(
                    expectedSHA256: target.sha256, at: source, label: source.lastPathComponent
                )
            }
        }
        // Re-verify backups after deletion; clear completion intent before its sentinel to prevent replay.
        for target in manifest.targets {
            let backup = personaRoot.appendingPathComponent(target.backupFileName)
            try await SwiftNativePersistenceCore.withFileLock(backup) {
                try Self.ensureResetBackup(target, at: backup)
            }
        }
        try Self.ensureResetFileRemoved(
            expectedSHA256: manifest.completionManifestSHA256,
            at: transactionManifestPath,
            label: "pending onboarding completion"
        )
        let sentinel = dataRoot.appendingPathComponent(".onboarded")
        let expectedSentinelSHA256 = manifest.sentinelSHA256
        try await SwiftNativePersistenceCore.withFileLock(sentinel) {
            try Self.ensureResetFileRemoved(
                expectedSHA256: expectedSentinelSHA256,
                at: sentinel,
                label: ".onboarded"
            )
        }
        do {
            try FileManager.default.removeItem(at: resetTransactionManifestPath)
            try SwiftNativePersistenceCore.syncDirectory(resetTransactionManifestPath.deletingLastPathComponent())
        } catch {
            throw OnboardingError.ioFailure(
                "clear onboarding reset transaction failed: \(error.localizedDescription)"
            )
        }
        return OnboardingResetResult(
            ok: true,
            backedUp: manifest.targets.map {
                personaRoot.appendingPathComponent($0.backupFileName).path
            }
        )
    }
    static var resetTargetDefinitions: [(role: String, fileName: String)] {
        [
            ("soul", "SOUL.md"),
            ("voice", "VOICE.md"),
            ("user", "USER.md"),
            ("growth", "GROWTH.md"),
            ("agents", "AGENTS.md"),
        ]
    }
    static func resetBackupFileName(
        sourceFileName: String,
        backupStamp: String,
        transactionID: String
    ) -> String {
        "\(sourceFileName).pre-reset-\(backupStamp)-\(transactionID).bak"
    }
    static func loadResetTransactionIfPresent(
        at path: URL,
        personaRoot: URL,
        dataRoot: URL
    ) throws -> OnboardingResetTransactionManifest? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw OnboardingError.ioFailure(
                "read onboarding reset transaction failed: \(error.localizedDescription)"
            )
        }
        let manifest: OnboardingResetTransactionManifest
        do {
            manifest = try JSONDecoder().decode(OnboardingResetTransactionManifest.self, from: data)
        } catch {
            throw OnboardingError.ioFailure(
                "onboarding reset transaction is malformed; preserving it for recovery"
            )
        }
        guard manifest.schemaVersion == 1,
              manifest.personaRoot == canonicalPath(personaRoot),
              manifest.dataRoot == canonicalPath(dataRoot),
              !manifest.transactionID.isEmpty,
              !manifest.backupStamp.isEmpty else {
            throw OnboardingError.ioFailure(
                "onboarding reset transaction belongs to a different root or schema"
            )
        }
        let definitions = Dictionary(uniqueKeysWithValues: resetTargetDefinitions.map { ($0.role, $0.fileName) })
        let roles = manifest.targets.map(\.role)
        guard Set(roles).count == roles.count,
              roles.allSatisfy({ definitions[$0] != nil }) else {
            throw OnboardingError.ioFailure("onboarding reset transaction target set is invalid")
        }
        for target in manifest.targets {
            guard let fileName = definitions[target.role] else {
                throw OnboardingError.ioFailure("onboarding reset transaction target role is invalid")
            }
            let expectedBackup = resetBackupFileName(
                sourceFileName: fileName,
                backupStamp: manifest.backupStamp,
                transactionID: manifest.transactionID
            )
            guard target.backupFileName == expectedBackup,
                  URL(fileURLWithPath: target.backupFileName).lastPathComponent == target.backupFileName,
                  let content = Data(base64Encoded: target.contentBase64),
                  sha256(content) == target.sha256 else {
                throw OnboardingError.ioFailure(
                    "onboarding reset transaction evidence is invalid for '\(target.role)'"
                )
            }
        }
        for markerHash in [manifest.completionManifestSHA256, manifest.sentinelSHA256].compactMap({ $0 }) {
            guard markerHash.count == 64,
                  markerHash.unicodeScalars.allSatisfy({ scalar in
                      switch scalar.value {
                      case 0x30...0x39, 0x61...0x66: return true
                      default: return false
                      }
                  }) else {
                throw OnboardingError.ioFailure("onboarding reset marker evidence is invalid")
            }
        }
        return manifest
    }
    static func fileHashIfPresent(_ path: URL, label: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        do {
            return sha256(try Data(contentsOf: path))
        } catch {
            throw OnboardingError.ioFailure("read \(label) during reset failed: \(error.localizedDescription)")
        }
    }
    private static func resetContent(_ intent: OnboardingResetTargetIntent) throws -> Data {
        guard let data = Data(base64Encoded: intent.contentBase64), sha256(data) == intent.sha256 else {
            throw OnboardingError.ioFailure("reset evidence hash mismatch for '\(intent.role)'")
        }
        return data
    }
    static func ensureResetBackup(
        _ intent: OnboardingResetTargetIntent,
        at backup: URL
    ) throws {
        let intended = try resetContent(intent)
        if FileManager.default.fileExists(atPath: backup.path) {
            let existing: Data
            do {
                existing = try Data(contentsOf: backup)
            } catch {
                throw OnboardingError.ioFailure(
                    "read reset backup \(backup.lastPathComponent) failed: \(error.localizedDescription)"
                )
            }
            guard sha256(existing) == intent.sha256 else {
                throw OnboardingError.ioFailure(
                    "reset backup \(backup.lastPathComponent) changed outside the pending transaction"
                )
            }
            try SwiftNativePersistenceCore.syncDirectory(backup.deletingLastPathComponent())
            return
        }
        try atomicWriteData(intended, to: backup)
        let persisted = try Data(contentsOf: backup)
        guard sha256(persisted) == intent.sha256 else {
            throw OnboardingError.ioFailure(
                "reset backup \(backup.lastPathComponent) failed post-write verification"
            )
        }
    }
    static func ensureResetFileRemoved(
        expectedSHA256: String?,
        at path: URL,
        label: String
    ) throws {
        guard FileManager.default.fileExists(atPath: path.path) else {
            try SwiftNativePersistenceCore.syncDirectory(path.deletingLastPathComponent())
            return
        }
        guard let expectedSHA256 else {
            throw OnboardingError.ioFailure("\(label) appeared outside the pending reset transaction")
        }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw OnboardingError.ioFailure("read \(label) before reset removal failed")
        }
        guard sha256(data) == expectedSHA256 else {
            throw OnboardingError.ioFailure("\(label) changed outside the pending reset transaction")
        }
        do {
            try FileManager.default.removeItem(at: path)
            try SwiftNativePersistenceCore.syncDirectory(path.deletingLastPathComponent())
        } catch {
            throw OnboardingError.ioFailure(
                "remove \(label) during reset failed: \(error.localizedDescription)"
            )
        }
        guard !FileManager.default.fileExists(atPath: path.path) else {
            throw OnboardingError.ioFailure("\(label) remained after reset removal")
        }
    }
}
