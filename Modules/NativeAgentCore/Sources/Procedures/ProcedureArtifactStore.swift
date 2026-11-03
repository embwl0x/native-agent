import NativeAgentCore
import Foundation
import NativeAgentShared
import PersistenceCore
import Darwin
// Blueprint: | `ProcedureArtifactStore.swift` | ProcedureArtifactStore immutable current-schema artifact installation and discovery with shared reference-locked capacity admission; status, backup/export/sync decisions and privacy-map coverage |

/// Immutable procedure artifacts, canonical invocation receipts and exact activations.
public actor ProcedureArtifactStore {
    // Owns persisted procedure schemas, including exact activations. Local backup,
    // production export and phone sync exclude this store; off-disk backup includes
    // it without lock sidecars. PrivacyMap lists living_fabric/procedures.
    package let root: URL
    package let clock: @Sendable () -> Date
    /// Admission and discovery share this ceiling; retention cannot remove
    /// protected references to make room for an accepted installation.
    static let maxInstalledArtifacts = 1_024
    public init(
        dataRoot: URL,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.root = dataRoot.appendingPathComponent("living_fabric/procedures", isDirectory: true)
        self.clock = clock
    }

    @discardableResult
    public func install(_ artifact: DeclarativeProcedureArtifact) async throws -> URL {
        guard Self.valid(artifact) else {
            throw ProcedureArtifactStoreError.invalidArtifact
        }
        let path = artifactPath(artifact.id)
        let value = try JSONValue.parse(JSONEncoder().encode(artifact))
        // The root's reference lock serializes count-and-write across store
        // instances and excludes retention, in its ledger -> artifact order.
        try await SwiftNativePersistenceCore.withFileLock(root.appendingPathComponent("invocations.jsonl")) {
            try await SwiftNativePersistenceCore.withFileLock(path) {
                let urls = try Self.installedArtifactURLs(in: self.root)
                guard urls.count <= Self.maxInstalledArtifacts else {
                    throw ProcedureArtifactStoreError.artifactCapacityExceeded
                }
                if urls.contains(path) {
                    // Immutability is semantic, not dependent on a particular
                    // PersistenceCore JSON whitespace/ordering implementation.
                    guard try await self.load(artifact.id) == artifact else {
                        throw ProcedureArtifactStoreError.immutableConflict
                    }
                    return
                }
                guard urls.count < Self.maxInstalledArtifacts else {
                    throw ProcedureArtifactStoreError.artifactCapacityExceeded
                }
                try await SwiftNativePersistenceCore.writeJSON(value, to: path)
            }
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

    func loadForInvocation(_ artifactID: String) async throws -> DeclarativeProcedureArtifact {
        try await load(artifactID)
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
        let urls = try Self.installedArtifactURLs(in: root)
        guard urls.count <= Self.maxInstalledArtifacts else {
            // A sweep can free unreferenced capacity; protected artifacts stay
            // protected even when the inventory is already over the ceiling.
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

    /// Missing is an observed empty directory; unreadable is never capacity.
    private static func installedArtifactURLs(in root: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("artifacts", isDirectory: true),
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            throw ProcedureArtifactStoreError.corruptArtifact
        }
    }

    public func statusSnapshot() async -> ProcedureArtifactStatusSnapshot {
        var unreadable: [String] = []
        let artifactURLs = Self.statusListing(
            root.appendingPathComponent("artifacts", isDirectory: true), unreadable: &unreadable
        ).prefix(Self.maxInstalledArtifacts)
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
