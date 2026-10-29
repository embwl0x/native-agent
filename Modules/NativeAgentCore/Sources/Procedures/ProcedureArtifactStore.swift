import NativeAgentCore
import Foundation
import NativeAgentShared
import PersistenceCore
import Darwin
// Blueprint: | `ProcedureArtifactStore.swift` | ProcedureArtifactStore immutable artifact installation, discovery, revalidation and status; explicit backup/export/sync decisions and privacy-map coverage |

/// Immutable procedure artifacts, canonical invocation receipts and exact activations.
public actor ProcedureArtifactStore {
    // Owns persisted procedure schemas, including exact activations. Local backup,
    // production export and phone sync exclude this store; off-disk backup includes
    // it without lock sidecars. PrivacyMap lists living_fabric/procedures.
    package let root: URL
    package let clock: @Sendable () -> Date
    public init(
        dataRoot: URL,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.root = dataRoot.appendingPathComponent("living_fabric/procedures", isDirectory: true)
        self.clock = clock
    }

    @discardableResult
    public func install(_ artifact: DeclarativeProcedureArtifact) async throws -> URL {
        guard Self.valid(artifact), !artifact.requiresLegacyRevalidation else {
            throw ProcedureArtifactStoreError.invalidArtifact
        }
        let path = artifactPath(artifact.id)
        let value = try JSONValue.parse(JSONEncoder().encode(artifact))
        try await SwiftNativePersistenceCore.withFileLock(path) {
            if FileManager.default.fileExists(atPath: path.path) {
                // Immutability is semantic, not dependent on a particular
                // PersistenceCore JSON whitespace/ordering implementation.
                guard let decoded = try? await load(artifact.id), decoded == artifact else {
                    throw ProcedureArtifactStoreError.immutableConflict
                }
                return
            }
            try await SwiftNativePersistenceCore.writeJSON(value, to: path)
        }
        // Retention runs off this actor after installation. Reference admission
        // shares the invocation ledger lock with a sweep's eligibility/deletion.
        await requestRetentionSweep()
        return path
    }

    public func load(_ artifactID: String) async throws -> DeclarativeProcedureArtifact {
        guard ProcedureTrajectoryExtractor.isOpaqueIdentity(artifactID) else { throw ProcedureArtifactStoreError.artifactNotFound }
        let path = artifactPath(artifactID)
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw ProcedureArtifactStoreError.artifactNotFound
        }
        guard let data = Self.checkedRegularFile(path, maximumBytes: 2 * 1_024 * 1_024),
              let artifact = try? JSONDecoder().decode(DeclarativeProcedureArtifact.self, from: data),
              Self.valid(artifact), artifact.id == artifactID else {
            throw ProcedureArtifactStoreError.corruptArtifact
        }
        return artifact
    }

    /// Recompile the original reviewed evidence and compare every field before
    /// binding v1 bytes to a full digest. IDs and activation pointers stay intact;
    /// migrating either would require a new exact activation approval.
    public func revalidateLegacyArtifact(
        _ artifactID: String,
        candidate: ProcedureCandidate
    ) async throws {
        let artifact = try await load(artifactID)
        guard artifact.requiresLegacyRevalidation,
              try DeclarativeProcedureCompiler.compile(candidate).withLegacyIdentity() == artifact else {
            throw ProcedureArtifactStoreError.invalidArtifact
        }
        let receipt = try legacyRevalidationReceipt(artifact)
        let path = legacyRevalidationPath(artifactID)
        try await SwiftNativePersistenceCore.withFileLock(path) {
            if FileManager.default.fileExists(atPath: path.path) {
                guard await legacyRevalidationMatches(artifact) else {
                    throw ProcedureArtifactStoreError.immutableConflict
                }
                return
            }
            try await SwiftNativePersistenceCore.writeJSON(receipt, to: path)
        }
    }

    func loadForInvocation(_ artifactID: String) async throws -> DeclarativeProcedureArtifact {
        let artifact = try await load(artifactID)
        if artifact.requiresLegacyRevalidation && !legacyRevalidationMatches(artifact) {
            throw ProcedureArtifactStoreError.legacyArtifactRequiresRevalidation
        }
        return artifact
    }

    internal nonisolated func legacyRevalidationMatches(_ artifact: DeclarativeProcedureArtifact) -> Bool {
        let path = legacyRevalidationPath(artifact.id)
        guard let data = Self.checkedRegularFile(path, maximumBytes: 64 * 1_024),
              let receipt = try? JSONValue.parse(data),
              let expected = try? legacyRevalidationReceipt(artifact) else { return false }
        return receipt == expected
    }

    private nonisolated func legacyRevalidationPath(_ artifactID: String) -> URL {
        root.appendingPathComponent("legacy_revalidations", isDirectory: true)
            .appendingPathComponent("\(artifactID).json")
    }

    private nonisolated func legacyRevalidationReceipt(_ artifact: DeclarativeProcedureArtifact) throws -> JSONValue {
        .object([
            "schema": .string("declarative-procedure-revalidation.v1"),
            "artifactID": .string(artifact.id),
            "canonicalIdentity": .string(try artifact.canonicalIdentity()),
        ])
    }

    /// Checked bounded discovery for callers that already have an explicit
    /// procedure request. The store remains the artifact owner: callers do not
    /// walk its directory, ignore corrupt rows, or guess from filenames. A
    /// damaged installed artifact fails the whole read closed rather than
    /// silently selecting a different procedure.
    public func loadInstalledArtifacts(
        domain: String? = nil
    ) async throws -> [DeclarativeProcedureArtifact] {
        if let domain, !Self.token(domain, maximum: 64) {
            throw ProcedureArtifactStoreError.invalidArtifact
        }
        let artifactsDirectory = root.appendingPathComponent("artifacts", isDirectory: true)
        guard FileManager.default.fileExists(atPath: artifactsDirectory.path) else { return [] }
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: artifactsDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw ProcedureArtifactStoreError.corruptArtifact
        }
        guard urls.count <= Self.maxInstalledArtifacts else {
            // An over-ceiling store heals by its sweep, never fail-closed forever.
            await requestRetentionSweep()
            throw ProcedureArtifactStoreError.artifactCapacityExceeded
        }
        var artifacts: [DeclarativeProcedureArtifact] = []
        artifacts.reserveCapacity(urls.count)
        for url in urls {
            guard let artifact = try? await load(url.deletingPathExtension().lastPathComponent) else {
                throw ProcedureArtifactStoreError.corruptArtifact
            }
            if domain == nil || artifact.domain == domain {
                artifacts.append(artifact)
            }
        }
        return artifacts
    }

    public func statusSnapshot() async -> ProcedureArtifactStatusSnapshot {
        var unreadable: [String] = []
        let artifactURLs = Self.statusListing(
            root.appendingPathComponent("artifacts", isDirectory: true), unreadable: &unreadable
        ).prefix(1_024)
        var validArtifacts = 0
        var corruptArtifacts = 0
        for url in artifactURLs {
            guard (try? await load(url.deletingPathExtension().lastPathComponent)) != nil else {
                corruptArtifacts += 1
                continue
            }
            validArtifacts += 1
        }

        let invocationPath = root.appendingPathComponent("invocations.jsonl")
        // The operator status receipt must distinguish a genuinely empty
        // invocation ledger from a bounded read that skipped malformed JSONL.
        // `tailJSONL` intentionally hides malformed physical rows for normal
        // consumers, but status is the explicit integrity-facing surface.
        var invocationRead: SwiftNativePersistenceCore.JSONLTailReadReceipt?
        do {
            invocationRead = try await SwiftNativePersistenceCore.tailJSONLReadReceipt(
                invocationPath,
                limit: 10_000,
                maxBytes: 8 * 1_024 * 1_024
            )
        } catch {
            unreadable.append("invocations.jsonl: \(error.localizedDescription)")
        }
        let rows = invocationRead?.rows ?? []
        var corruptInvocations = invocationRead?.malformedJSONRowCount ?? 0
        let receipts = rows.compactMap { value -> ProcedureInvocationReceipt? in
            guard let receipt = Self.invocationReceipt(value) else {
                corruptInvocations += 1
                return nil
            }
            return receipt
        }
        let activation = await exactActivationStatusSnapshot()
        return ProcedureArtifactStatusSnapshot(
            artifactCount: validArtifacts,
            corruptArtifactCount: corruptArtifacts,
            corruptInvocationCount: corruptInvocations,
            invocationCount: receipts.count,
            manualInvocationCount: receipts.filter { !$0.automaticSelection }.count,
            automaticInvocationCount: receipts.filter(\.automaticSelection).count,
            verifiedInvocationCount: receipts.filter(\.verified).count,
            lastInvocationStatus: receipts.last?.executorStatus,
            activationArtifactCount: activation.activationArtifactCount,
            corruptActivationArtifactCount: activation.corruptActivationArtifactCount,
            activeAutomaticProcedureCount: activation.activeAutomaticProcedureCount,
            automaticSelectionEnabled: activation.activeAutomaticProcedureCount > 0,
            payloadFree: true,
            unreadable: unreadable + activation.unreadable
        )
    }

    /// A directory that does not exist is an observed empty one; any other
    /// listing failure is a source the snapshot did not inspect.
    static func statusListing(_ directory: URL, unreadable: inout [String]) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            unreadable.append("\(directory.lastPathComponent)/: \(error.localizedDescription)")
            return []
        }
    }

    /// Checked bounded evidence read for the existing procedure owner. This is
    /// used only after a Workshop terminal event or by explicit operator/eval
    /// commands; it is never consulted on the ordinary chat hot path.
    public func loadInvocationReceipts(
        artifactID: String? = nil
    ) async throws -> [ProcedureInvocationReceipt] {
        if let artifactID, !ProcedureTrajectoryExtractor.isOpaqueIdentity(artifactID) {
            throw ProcedureArtifactStoreError.corruptInvocationLedger
        }
        let path = root.appendingPathComponent("invocations.jsonl")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        guard let size = try FileManager.default.attributesOfItem(
            atPath: path.path
        )[.size] as? NSNumber else {
            throw ToolFailureError("Procedure invocation ledger has no readable byte count", effects: .none, owner: path.path)
        }
        guard size.int64Value <= 8 * 1_024 * 1_024 else {
            throw ToolFailureError("Procedure invocation ledger exceeds 8 MiB (\(size.int64Value) bytes)", effects: .none, owner: path.path)
        }
        let (rows, report) = try await SwiftNativePersistenceCore.readJSONLReporting(path)
        guard report.isClean, report.physicalLineCount <= 10_000 else {
            throw ToolFailureError("Procedure invocation ledger contains \(report.malformedLineCount) malformed JSON rows across \(report.physicalLineCount) physical lines (limit 10,000)", effects: .none, owner: path.path)
        }
        return try rows.enumerated().compactMap { index, row in
            guard let receipt = Self.invocationReceipt(row) else {
                throw ToolFailureError("Procedure invocation ledger record \(index + 1) is not a valid invocation receipt", effects: .none, owner: path.path)
            }
            return artifactID == nil || receipt.artifactID == artifactID ? receipt : nil
        }
    }

    internal func artifactPath(_ id: String) -> URL {
        root.appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("\(id).json")
    }

}
