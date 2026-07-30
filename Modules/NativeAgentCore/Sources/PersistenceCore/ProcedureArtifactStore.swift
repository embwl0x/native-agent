import Foundation

public enum ProcedureArtifactStoreError: String, Error, Sendable, Equatable {
    case invalidArtifact = "invalid_artifact"
    case immutableConflict = "immutable_conflict"
    case artifactNotFound = "artifact_not_found"
    case corruptArtifact = "corrupt_artifact"
    /// The installed-artifact directory crossed the hard discovery ceiling —
    /// NOT a corrupt row. Added 2026-07-21 (audit): the ceiling guard used to
    /// throw `corruptArtifact`, mislabeling capacity as damage. Existing raw
    /// values are untouched (wire-compatible).
    case artifactCapacityExceeded = "artifact_capacity_exceeded"
    case corruptInvocationLedger = "corrupt_invocation_ledger"
    case invocationNotEligible = "invocation_not_eligible"
    case invalidInputReference = "invalid_input_reference"
    case invalidExecutionResult = "invalid_execution_result"
}

/// Closed, payload-free result vocabulary from a canonical domain executor.
/// Arbitrary executor prose must never be persisted into the invocation ledger.
public enum ProcedureCanonicalExecutionStatus: String, Codable, Sendable, Equatable {
    case verifiedSuccess = "verified_success"
    case verifiedFailure = "verified_failure"
    case cancelled
    case abstained
    case unverified
}

public struct ProcedureCanonicalExecutionResult: Sendable, Equatable {
    public let status: ProcedureCanonicalExecutionStatus
    public let authorityRechecked: Bool
    public let canonicalEvidenceMatched: Bool
    public let verified: Bool

    public init(
        status: ProcedureCanonicalExecutionStatus,
        authorityRechecked: Bool,
        canonicalEvidenceMatched: Bool,
        verified: Bool
    ) {
        self.status = status
        self.authorityRechecked = authorityRechecked
        self.canonicalEvidenceMatched = canonicalEvidenceMatched
        self.verified = verified
    }
}

/// Domain executors remain the only action owners. This seam never receives
/// parameter values: it passes an opaque canonical-store reference and one
/// already-admitted transition rule. The executor must refetch input, recheck
/// TrustCenter/approval, and return exact verification.
public protocol ProcedureCanonicalExecuting: Sendable {
    func executeProcedureRule(
        artifact: DeclarativeProcedureArtifact,
        rule: ProcedureTransitionRule,
        opaqueInputReference: String,
        invocationID: String
    ) async throws -> ProcedureCanonicalExecutionResult
}

public struct ProcedureInvocationReceipt: Codable, Sendable, Equatable {
    public static let schema = "declarative-procedure-invocation.v1"
    public let schema: String
    public let invocationID: String
    public let artifactID: String
    public let opaqueInputReference: String
    public let requestedAt: String
    public let dryRunStatus: ProcedureDryRunStatus
    public let dryRunReason: ProcedureDryRunReason
    public let executorStatus: ProcedureCanonicalExecutionStatus?
    public let authorityRechecked: Bool
    public let canonicalEvidenceMatched: Bool
    public let verified: Bool
    public let fallback: ProcedureFallbackRoute
    public let dispatched: Bool
    public let payloadFree: Bool
    public let permissionAuthority: Bool
    public let automaticSelection: Bool
    /// Present only when an exact typed activation admitted the invocation.
    /// Older/manual rows decode with nil and retain their original meaning.
    public let activationID: String?
    public let procedureID: String?
    public let selectionMode: String?

    public init(
        schema: String,
        invocationID: String,
        artifactID: String,
        opaqueInputReference: String,
        requestedAt: String,
        dryRunStatus: ProcedureDryRunStatus,
        dryRunReason: ProcedureDryRunReason,
        executorStatus: ProcedureCanonicalExecutionStatus?,
        authorityRechecked: Bool,
        canonicalEvidenceMatched: Bool,
        verified: Bool,
        fallback: ProcedureFallbackRoute,
        dispatched: Bool,
        payloadFree: Bool,
        permissionAuthority: Bool,
        automaticSelection: Bool,
        activationID: String? = nil,
        procedureID: String? = nil,
        selectionMode: String? = nil
    ) {
        self.schema = schema
        self.invocationID = invocationID
        self.artifactID = artifactID
        self.opaqueInputReference = opaqueInputReference
        self.requestedAt = requestedAt
        self.dryRunStatus = dryRunStatus
        self.dryRunReason = dryRunReason
        self.executorStatus = executorStatus
        self.authorityRechecked = authorityRechecked
        self.canonicalEvidenceMatched = canonicalEvidenceMatched
        self.verified = verified
        self.fallback = fallback
        self.dispatched = dispatched
        self.payloadFree = payloadFree
        self.permissionAuthority = permissionAuthority
        self.automaticSelection = automaticSelection
        self.activationID = activationID
        self.procedureID = procedureID
        self.selectionMode = selectionMode
    }
}

/// Bounded, payload-free operator projection. It reports whether an approved
/// native procedure actually exists and whether it has ever been invoked;
/// candidate prose, input values, Workshop IDs, and outputs are excluded.
public struct ProcedureArtifactStatusSnapshot: Sendable, Equatable {
    public let artifactCount: Int
    public let corruptArtifactCount: Int
    public let corruptInvocationCount: Int
    public let invocationCount: Int
    public let manualInvocationCount: Int
    public let automaticInvocationCount: Int
    public let verifiedInvocationCount: Int
    public let lastInvocationStatus: ProcedureCanonicalExecutionStatus?
    public let activationArtifactCount: Int
    public let corruptActivationArtifactCount: Int
    public let activeAutomaticProcedureCount: Int
    public let automaticSelectionEnabled: Bool
    public let payloadFree: Bool
}

/// Injected-root immutable artifact owner plus a manual-only canonical
/// invocation bridge for the initial low-risk Workshop production scope. It
/// has no automatic selection API and cannot execute an external-send,
/// confirm-required, or GitHub-oracle artifact.
public actor ProcedureArtifactStore {
    package let root: URL
    package let persistence: any PersistenceCoreProtocol
    package let clock: @Sendable () -> Date

    public init(
        dataRoot: URL,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.root = dataRoot.appendingPathComponent("living_fabric/procedures", isDirectory: true)
        self.persistence = persistence
        self.clock = clock
    }

    /// Installed-artifact retention knobs (audit 2026-07-21). Without a GC the
    /// artifacts directory grew monotonically until `loadInstalledArtifacts`
    /// fail-closed PERMANENTLY at `maxInstalledArtifacts` — and the guard
    /// mislabeled that as `corruptArtifact`. The sweep below keeps the store
    /// well below the ceiling.
    static let maxInstalledArtifacts = 1_024
    /// Post-sweep target — comfortably below the fail-closed ceiling.
    static let artifactRetentionTarget = 768
    /// An artifact no active pointer references becomes sweep-eligible after
    /// this age (file mtime).
    static let artifactRetentionAge: TimeInterval = 30 * 24 * 60 * 60

    @discardableResult
    public func install(_ artifact: DeclarativeProcedureArtifact) async throws -> URL {
        guard Self.valid(artifact) else { throw ProcedureArtifactStoreError.invalidArtifact }
        let path = artifactPath(artifact.id)
        let value = try JSONValue.parse(JSONEncoder().encode(artifact))
        try await persistence.withFileLock(path) {
            if FileManager.default.fileExists(atPath: path.path) {
                // Immutability is semantic, not dependent on a particular
                // PersistenceCore JSON whitespace/ordering implementation.
                guard let existing = try? Data(contentsOf: path),
                      existing.count <= 2 * 1_024 * 1_024,
                      let decoded = try? JSONDecoder().decode(
                          DeclarativeProcedureArtifact.self,
                          from: existing
                      ),
                      Self.valid(decoded), decoded == artifact else {
                    throw ProcedureArtifactStoreError.immutableConflict
                }
                return
            }
            try await persistence.writeJSON(value, to: path)
        }
        // Best-effort GC after the install lands: retention must never fail
        // the install that triggered it.
        _ = sweepUnreferencedArtifacts()
        return path
    }

    public func load(_ artifactID: String) async throws -> DeclarativeProcedureArtifact {
        guard Self.digest(artifactID) else { throw ProcedureArtifactStoreError.artifactNotFound }
        let path = artifactPath(artifactID)
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw ProcedureArtifactStoreError.artifactNotFound
        }
        guard let data = try? Data(contentsOf: path), data.count <= 2 * 1_024 * 1_024,
              let artifact = try? JSONDecoder().decode(DeclarativeProcedureArtifact.self, from: data),
              Self.valid(artifact), artifact.id == artifactID else {
            throw ProcedureArtifactStoreError.corruptArtifact
        }
        return artifact
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
        // Best-effort GC BEFORE the ceiling check so an over-ceiling store
        // self-heals instead of fail-closing forever (audit 2026-07-21).
        _ = sweepUnreferencedArtifacts()
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
            throw ProcedureArtifactStoreError.artifactCapacityExceeded
        }
        var artifacts: [DeclarativeProcedureArtifact] = []
        artifacts.reserveCapacity(urls.count)
        for url in urls {
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let data = try? Data(contentsOf: url),
                  data.count <= 2 * 1_024 * 1_024,
                  let artifact = try? JSONDecoder().decode(
                    DeclarativeProcedureArtifact.self,
                    from: data
                  ), Self.valid(artifact),
                  url.deletingPathExtension().lastPathComponent == artifact.id else {
                throw ProcedureArtifactStoreError.corruptArtifact
            }
            if domain == nil || artifact.domain == domain {
                artifacts.append(artifact)
            }
        }
        return artifacts
    }

    public func statusSnapshot() async -> ProcedureArtifactStatusSnapshot {
        let artifactsDirectory = root.appendingPathComponent("artifacts", isDirectory: true)
        let artifactURLs = ((try? FileManager.default.contentsOfDirectory(
            at: artifactsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension == "json" }.prefix(1_024)
        var validArtifacts = 0
        var corruptArtifacts = 0
        for url in artifactURLs {
            guard let data = try? Data(contentsOf: url), data.count <= 2 * 1_024 * 1_024,
                  let artifact = try? JSONDecoder().decode(
                    DeclarativeProcedureArtifact.self,
                    from: data
                  ), Self.valid(artifact) else {
                corruptArtifacts += 1
                continue
            }
            validArtifacts += 1
        }

        let invocationPath = root.appendingPathComponent("invocations.jsonl")
        let rows = (try? await persistence.tailJSONL(
            invocationPath,
            limit: 10_000,
            maxBytes: 8 * 1_024 * 1_024
        )) ?? []
        var corruptInvocations = 0
        let receipts = rows.compactMap { value -> ProcedureInvocationReceipt? in
            guard let data = try? value.serialize(pretty: false).data(using: .utf8),
                  let receipt = try? JSONDecoder().decode(
                    ProcedureInvocationReceipt.self,
                    from: data
                  ), receipt.schema == ProcedureInvocationReceipt.schema,
                  Self.digest(receipt.invocationID), Self.digest(receipt.artifactID),
                  Self.digest(receipt.opaqueInputReference),
                  Self.validTimestamp(receipt.requestedAt),
                  receipt.payloadFree, !receipt.permissionAuthority,
                  Self.validSelectionReceipt(receipt),
                  Self.validExecutionReceipt(receipt) else {
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
            payloadFree: true
        )
    }

    /// Checked bounded evidence read for the existing procedure owner. This is
    /// used only after a Workshop terminal event or by explicit operator/eval
    /// commands; it is never consulted on the ordinary chat hot path.
    public func loadInvocationReceipts(
        artifactID: String? = nil
    ) async throws -> [ProcedureInvocationReceipt] {
        if let artifactID, !Self.digest(artifactID) {
            throw ProcedureArtifactStoreError.corruptInvocationLedger
        }
        let path = root.appendingPathComponent("invocations.jsonl")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        guard let size = (try? FileManager.default.attributesOfItem(
            atPath: path.path
        )[.size]) as? NSNumber, size.intValue <= 8 * 1_024 * 1_024 else {
            throw ProcedureArtifactStoreError.corruptInvocationLedger
        }
        let rows = try await persistence.readJSONL(path)
        guard rows.count <= 10_000 else {
            throw ProcedureArtifactStoreError.corruptInvocationLedger
        }
        return try rows.compactMap { row in
            guard let data = try? row.serializedData(pretty: false),
                  let receipt = try? JSONDecoder().decode(
                    ProcedureInvocationReceipt.self,
                    from: data
                  ), receipt.schema == ProcedureInvocationReceipt.schema,
                  Self.digest(receipt.invocationID), Self.digest(receipt.artifactID),
                  Self.digest(receipt.opaqueInputReference),
                  Self.validTimestamp(receipt.requestedAt),
                  receipt.payloadFree, !receipt.permissionAuthority,
                  Self.validSelectionReceipt(receipt),
                  Self.validExecutionReceipt(receipt) else {
                throw ProcedureArtifactStoreError.corruptInvocationLedger
            }
            return artifactID == nil || receipt.artifactID == artifactID ? receipt : nil
        }
    }

    @discardableResult
    public func invokeManual(
        artifactID: String,
        opaqueInputReference: String,
        context: ProcedureDryRunContext,
        executor: any ProcedureCanonicalExecuting
    ) async throws -> ProcedureInvocationReceipt {
        try await invoke(
            artifactID: artifactID,
            opaqueInputReference: opaqueInputReference,
            context: context,
            selection: .manual,
            executor: executor
        )
    }

    /// Admission for an exact typed operation after a separate immutable local
    /// activation. The active pointer and implementation identity are reread
    /// here, inside the procedure owner, immediately before canonical dispatch.
    @discardableResult
    public func invokeAutomaticExact(
        procedureID: String,
        implementationIdentity: String,
        expectedArtifactID: String,
        opaqueInputReference: String,
        context: ProcedureDryRunContext,
        executor: any ProcedureCanonicalExecuting
    ) async throws -> ProcedureInvocationReceipt {
        let pointerPath = exactActivationPointerPath(procedureID)
        // Admission and canonical consequence share the pointer lock. A
        // rollback may wait for an already-admitted exact operation, but once
        // deactivateExact returns no new automatic effect can cross this gate.
        return try await persistence.withFileLock(pointerPath) {
            let active = try await loadActiveExactProcedure(
                procedureID: procedureID,
                implementationIdentity: implementationIdentity
            )
            guard active.artifact.id == expectedArtifactID else {
                throw ProcedureExactActivationError.activationBindingMismatch
            }
            return try await invoke(
                artifactID: expectedArtifactID,
                opaqueInputReference: opaqueInputReference,
                context: context,
                selection: .automaticExact(active.manifest),
                executor: executor
            )
        }
    }

    private enum InvocationSelection: Sendable {
        case manual
        case automaticExact(ProcedureExactActivationManifest)

        var automatic: Bool {
            if case .automaticExact = self { return true }
            return false
        }

        var activationID: String? {
            if case .automaticExact(let manifest) = self { return manifest.id }
            return nil
        }

        var procedureID: String? {
            if case .automaticExact(let manifest) = self {
                return manifest.proposal.procedureID
            }
            return nil
        }

        var mode: String? { automatic ? "exact_typed" : nil }
    }

    private func invoke(
        artifactID: String,
        opaqueInputReference: String,
        context: ProcedureDryRunContext,
        selection: InvocationSelection,
        executor: any ProcedureCanonicalExecuting
    ) async throws -> ProcedureInvocationReceipt {
        guard Self.digest(opaqueInputReference) else {
            throw ProcedureArtifactStoreError.invalidInputReference
        }
        let artifact = try await load(artifactID)
        guard context.invocationMode == .manual,
              artifact.domain == "workshop_execution",
              artifact.authorityClass == "low_risk",
              artifact.manualInvocationEligible,
              !artifact.automaticSelectionEligible,
              !artifact.safety.externalSendsEligible,
              !artifact.safety.permissionAuthority else {
            throw ProcedureArtifactStoreError.invocationNotEligible
        }
        let dry = ProcedureReplayEngine.dryRun(artifact, context: context)
        let requestedAt = Self.iso8601(clock())
        // Stable across retries and store instances. A crash after dispatch but
        // before receipt persistence must replay the same domain idempotency key.
        let invocationID = CausalTransitionEvidence.opaqueIdentity(
            "\(artifactID)|\(opaqueInputReference)|\(context.nextRuleIndex)"
        )
        let invocationPath = root.appendingPathComponent("invocations.jsonl")
        return try await persistence.withFileLock(invocationPath) {
            if let existing = try await Self.existingReceipt(
                invocationID: invocationID,
                artifactID: artifact.id,
                inputReference: opaqueInputReference,
                expectedFallback: artifact.deterministicFallback,
                path: invocationPath,
                persistence: persistence
            ) {
                return existing
            }
            var execution: ProcedureCanonicalExecutionResult?
            if (dry.status == .wouldAdvance || dry.status == .wouldComplete),
               let rule = dry.proposedRule {
                execution = try await executor.executeProcedureRule(
                    artifact: artifact,
                    rule: rule,
                    opaqueInputReference: opaqueInputReference,
                    invocationID: invocationID
                )
            }
            let accepted: Bool
            if let execution {
                let exactVerification = execution.authorityRechecked
                    && execution.canonicalEvidenceMatched
                    && execution.verified
                switch execution.status {
                case .verifiedSuccess, .verifiedFailure, .cancelled:
                    guard exactVerification else {
                        throw ProcedureArtifactStoreError.invalidExecutionResult
                    }
                    accepted = true
                case .abstained, .unverified:
                    guard !execution.verified else {
                        throw ProcedureArtifactStoreError.invalidExecutionResult
                    }
                    accepted = false
                }
            } else {
                accepted = false
            }
            let receipt = ProcedureInvocationReceipt(
                schema: ProcedureInvocationReceipt.schema,
                invocationID: invocationID,
                artifactID: artifact.id,
                opaqueInputReference: opaqueInputReference,
                requestedAt: requestedAt,
                dryRunStatus: dry.status,
                dryRunReason: dry.reason,
                executorStatus: execution?.status,
                authorityRechecked: execution?.authorityRechecked ?? false,
                canonicalEvidenceMatched: execution?.canonicalEvidenceMatched ?? false,
                verified: accepted,
                fallback: dry.fallback,
                dispatched: execution != nil,
                payloadFree: true,
                permissionAuthority: false,
                automaticSelection: selection.automatic,
                activationID: selection.activationID,
                procedureID: selection.procedureID,
                selectionMode: selection.mode
            )
            try await appendJSONLCapped(
                try JSONValue.parse(JSONEncoder().encode(receipt)),
                to: invocationPath,
                using: persistence,
                maxLines: 10_000,
                logLabel: "ProcedureArtifactStore",
                takeLock: false,
                trimWhenBytesExceed: 8 * 1_024 * 1_024
            )
            return receipt
        }
    }

    /// Best-effort installed-artifact GC (audit 2026-07-21). Removes DECODABLE,
    /// VALID artifacts that neither an active pointer references NOR a recent
    /// invocation receipt names, once they are older than `artifactRetentionAge`;
    /// if the store is still above `artifactRetentionTarget`, the oldest such
    /// unreferenced artifacts go next.
    /// Never deletes a file it cannot decode (fail-closed damage evidence
    /// stays put), never deletes a pointer-referenced artifact, and aborts
    /// entirely if any active pointer is undecodable (its artifactID is then
    /// unknowable, so nothing is provably safe to delete). Never throws — a GC
    /// failure must not break install or discovery. Returns the removal count.
    ///
    /// Round-3 audit (F3-M2): manual-invocable artifacts are loaded by
    /// `invoke()`/`invokeManual()` by artifactID with NO active pointer — the
    /// active/ directory only tracks exact automatic activations. Keying the
    /// referenced set on pointers alone therefore counted an in-active-use
    /// manual artifact as unreferenced and deleted it once its file mtime aged
    /// out (load/invoke never touch mtime). Fix: also treat any artifact whose
    /// invocation ledger carries a receipt younger than `artifactRetentionAge`
    /// as referenced. Genuinely-abandoned manual artifacts (no recent receipt)
    /// stay collectable. The ledger read is fail-safe: an unreadable, oversized,
    /// or undecodable ledger aborts the sweep, exactly like an undecodable
    /// pointer — a recent receipt we cannot parse might name an artifact we are
    /// about to delete.
    @discardableResult
    public func sweepUnreferencedArtifacts(now: Date = Date()) -> Int {
        let fm = FileManager.default
        let artifactsDirectory = root.appendingPathComponent("artifacts", isDirectory: true)
        guard let urls = try? fm.contentsOfDirectory(
            at: artifactsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter({ $0.pathExtension == "json" }) else { return 0 }

        let cutoff = now.addingTimeInterval(-Self.artifactRetentionAge)

        // Referenced set: artifactIDs named by the active pointers. An
        // undecodable pointer aborts the sweep (fail-safe).
        var referenced = Set<String>()
        let activeDirectory = root.appendingPathComponent("active", isDirectory: true)
        if let pointerURLs = try? fm.contentsOfDirectory(
            at: activeDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) {
            for url in pointerURLs where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let pointer = try? JSONDecoder().decode(
                          ProcedureExactActivationPointer.self, from: data
                      ),
                      pointer.validates else { return 0 }
                referenced.insert(pointer.artifactID)
            }
        }

        // Recency-referenced set (F3-M2): manual invocations leave no pointer,
        // so any artifact with an invocation receipt younger than the retention
        // age is treated as in active use. Read synchronously and fail-safe —
        // an unreadable or undecodable ledger aborts the sweep (a recent
        // receipt we cannot parse might name an artifact we are about to
        // delete). An OVERSIZED ledger does NOT abort (gpt-5.5 review, round
        // 3: abort-on-size made GC permanently nonfunctional once the file
        // crossed the cap): the ledger is append-only, so the newest receipts
        // — the only ones that can beat `cutoff` — live at the END. Read the
        // newest 8 MiB tail, drop the partial first line, and decode the rest.
        // An in-retention receipt buried under >8 MiB of newer traffic loses
        // only its recency protection (pointer + mtime retention still apply);
        // that narrow edge is strictly better than GC-off-forever.
        let invocationPath = root.appendingPathComponent("invocations.jsonl")
        if fm.fileExists(atPath: invocationPath.path) {
            let tailCap = 8 * 1_024 * 1_024
            guard let size = (try? fm.attributesOfItem(
                atPath: invocationPath.path
            )[.size]) as? NSNumber,
                  var data = try? Self.readNewestTail(
                      of: invocationPath, fileSize: size.intValue, maxBytes: tailCap
                  ) else { return 0 }
            if size.intValue > tailCap,
               let firstNewline = data.firstIndex(of: UInt8(ascii: "\n")) {
                // Tail starts mid-line: drop the partial first record.
                data = data[data.index(after: firstNewline)...]
            }
            let decoder = JSONDecoder()
            for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                guard let receipt = try? decoder.decode(
                    ProcedureInvocationReceipt.self, from: Data(line)
                ) else { return 0 }
                if let requested = Self.parsedTimestamp(receipt.requestedAt),
                   requested >= cutoff {
                    referenced.insert(receipt.artifactID)
                }
            }
        }

        struct Candidate {
            let url: URL
            let modified: Date
        }
        var candidates: [Candidate] = []
        for url in urls {
            let id = url.deletingPathExtension().lastPathComponent
            guard !referenced.contains(id),
                  let values = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
                  ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let data = try? Data(contentsOf: url),
                  data.count <= 2 * 1_024 * 1_024,
                  let artifact = try? JSONDecoder().decode(
                      DeclarativeProcedureArtifact.self, from: data
                  ),
                  Self.valid(artifact),
                  artifact.id == id else { continue }
            candidates.append(Candidate(
                url: url, modified: values.contentModificationDate ?? now
            ))
        }
        candidates.sort { $0.modified < $1.modified }
        var removed = 0
        var remaining = urls.count
        for candidate in candidates {
            // Oldest-first: once a candidate is neither aged out nor needed
            // for the target, no later (newer) candidate is either.
            guard candidate.modified < cutoff || remaining > Self.artifactRetentionTarget else { break }
            try? fm.removeItem(at: candidate.url)
            removed += 1
            remaining -= 1
        }
        if removed > 0 {
            NSLog("ProcedureArtifactStore: retention sweep removed %d unreferenced artifact(s)", removed)
        }
        return removed
    }

    private func artifactPath(_ id: String) -> URL {
        root.appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("\(id).json")
    }

    private static func valid(_ value: DeclarativeProcedureArtifact) -> Bool {
        let expectedDomain: (
            oracle: ProcedureCanonicalOracle,
            fallback: ProcedureFallbackRoute,
            capability: String
        )? = switch value.domain {
        case "github_command": (.githubCommandReducer, .githubCanonicalReducer, "github_connector")
        case "workshop_execution": (
            .workshopRecordAndTimeline,
            .ordinaryWorkshopPlannerExecutor,
            "workshop_execution"
        )
        default: nil
        }
        guard let expectedDomain else { return false }
        let allowedEffects = Set(value.inputContract.allowedExternalEffectClasses)
        let expectedPreconditions = Set([
            "authority_class_matches",
            "canonical_executor_available",
            "domain_state_matches",
            "input_schema_matches",
        ])
        let expectedRechecks: [ProcedureSafetyRecheckPoint] = [
            .beforeInvocation, .beforeEveryAction, .afterEveryCheckpoint,
        ]
        let validAuthority = value.authorityClass == "low_risk"
            || value.authorityClass == "confirm_required"
        let validApprovalOwner = value.authorityClass == "confirm_required"
            ? value.safety.canonicalApprovalOwner == "approval_inbox"
            : value.safety.canonicalApprovalOwner == nil
        let validRules = value.transitionTable.enumerated().allSatisfy { index, rule in
            index == rule.sequence
                && token(rule.onTransitionKind, maximum: 64)
                && token(rule.beforeState, maximum: 64, optional: true)
                && token(rule.afterState, maximum: 64, optional: true)
                && token(rule.actionKind, maximum: 64, optional: true)
                && token(rule.requiredEvidenceKind, maximum: 64, optional: true)
                && token(rule.expectedNextEvidence, maximum: 64, optional: true)
                && token(rule.checkpointClass, maximum: 64, optional: true)
                && token(rule.verificationClass, maximum: 64, optional: true)
                && allowedEffects.contains(rule.externalEffectClass)
                && token(rule.externalEffectClass, maximum: 64)
                && rule.externalEffectClass != "external_send"
                && rule.externalEffectClass != "unknown"
                && (rule.terminalClass == nil || index == value.transitionTable.count - 1)
        }
        let terminalCount = value.transitionTable.filter { $0.terminalClass != nil }.count
        let expectedAbandonConditions = Set(ProcedureCandidateCompiler.deterministicAbandonConditions)
        return value.schema == DeclarativeProcedureArtifact.schema
            && digest(value.id)
            && compilerIdentityMatches(value)
            && digest(value.procedureShapeIdentity)
            && !value.sourceTrajectoryIdentities.isEmpty
            && value.sourceTrajectoryIdentities.count <= 64
            && value.sourceTrajectoryIdentities.allSatisfy(digest)
            && Set(value.sourceTrajectoryIdentities).count == value.sourceTrajectoryIdentities.count
            && value.sourceTrajectoryIdentities == value.sourceTrajectoryIdentities.sorted()
            && value.interpretation == "trusted_declarative_transition_table_v1"
            && token(value.domain, maximum: 64)
            && token(value.inputContract.taskFamily, maximum: 128)
            && token(value.inputContract.inputClass, maximum: 128)
            && token(value.inputContract.parameterSchemaClass, maximum: 128)
            && !value.inputContract.acceptedParameterSchemaIdentities.isEmpty
            && value.inputContract.acceptedParameterSchemaIdentities.count <= 64
            && value.inputContract.acceptedParameterSchemaIdentities.allSatisfy(digest)
            && Set(value.inputContract.acceptedParameterSchemaIdentities).count
                == value.inputContract.acceptedParameterSchemaIdentities.count
            && value.inputContract.acceptedParameterSchemaIdentities
                == value.inputContract.acceptedParameterSchemaIdentities.sorted()
            && !allowedEffects.isEmpty
            && allowedEffects.count == value.inputContract.allowedExternalEffectClasses.count
            && allowedEffects.allSatisfy { token($0, maximum: 64) }
            && value.inputContract.allowedExternalEffectClasses
                == value.inputContract.allowedExternalEffectClasses.sorted()
            && !allowedEffects.contains("external_send")
            && !allowedEffects.contains("unknown")
            && validAuthority
            && validApprovalOwner
            && value.canonicalOracle == expectedDomain.oracle
            && value.deterministicFallback == expectedDomain.fallback
            && value.safety.trustCenterCapability == expectedDomain.capability
            && Set(value.safety.requiredPreconditions) == expectedPreconditions
            && value.safety.requiredPreconditions.count == expectedPreconditions.count
            && value.safety.recheckPoints == expectedRechecks
            && digest(value.reviewerDecision.reviewerIdentity)
            && digest(value.reviewerDecision.approvalReceiptIdentity)
            && digest(value.reviewerDecision.candidateEvidenceDigest)
            && value.reviewerDecision.candidateShapeIdentity == value.procedureShapeIdentity
            && value.reviewerDecision.verdict == .approve
            && validTimestamp(value.reviewerDecision.decidedAt)
            && (!value.canaryEligible || value.reviewerDecision.scope == .manualAndCanary)
            && value.manualInvocationEligible
            && !value.automaticSelectionEligible
            && !value.generatedExecutableCode
            && !value.safety.externalSendsEligible
            && !value.safety.permissionAuthority
            && !value.safety.automaticActivationAllowed
            && Set(value.deterministicAbandonConditions) == expectedAbandonConditions
            && value.deterministicAbandonConditions.count == expectedAbandonConditions.count
            && (3...ProcedureTrajectoryExtractor.maximumSteps).contains(value.transitionTable.count)
            && validRules
            && terminalCount == 1
            && !value.inputContract.allowedExternalEffectClasses.contains("external_send")
            && value.rollbackDeclaration == "delete_artifact_restore_fallback_no_data_migration"
    }

    /// Verify the content-addressed identity emitted by
    /// `DeclarativeProcedureCompiler`. This prevents a decoded artifact from
    /// retaining an approved-looking ID while changing its domain, authority,
    /// action, transition, effect, or accepted input schema.
    private static func compilerIdentityMatches(_ value: DeclarativeProcedureArtifact) -> Bool {
        let fingerprint = [
            value.procedureShapeIdentity,
            value.domain,
            value.inputContract.taskFamily,
            value.inputContract.inputClass,
            value.authorityClass,
            value.inputContract.acceptedParameterSchemaIdentities.joined(separator: ","),
            value.transitionTable.map {
                "\($0.sequence)|\($0.beforeState ?? "nil")|\($0.onTransitionKind)|"
                    + "\($0.actionKind ?? "nil")|\($0.requiredEvidenceKind ?? "nil")|"
                    + "\($0.externalEffectClass)|\($0.afterState ?? "nil")|"
                    + "\($0.terminalClass?.rawValue ?? "nil")"
            }.joined(separator: ">"),
            value.reviewerDecision.reviewerIdentity,
            value.reviewerDecision.decidedAt,
        ].joined(separator: "||")
        return value.id == CausalTransitionEvidence.opaqueIdentity(fingerprint)
    }

    private static func digest(_ raw: String) -> Bool {
        raw.count == 64 && raw.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func token(_ raw: String, maximum: Int) -> Bool {
        token(Optional(raw), maximum: maximum, optional: false)
    }

    private static func token(_ raw: String?, maximum: Int, optional: Bool) -> Bool {
        guard let raw else { return optional }
        guard !raw.isEmpty, raw.count <= maximum else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._:"))
        return raw.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Newest-`maxBytes` tail of an append-only file (whole file when it fits).
    /// Throws on any I/O failure — the GC caller treats that as fail-safe abort.
    private static func readNewestTail(
        of url: URL, fileSize: Int, maxBytes: Int
    ) throws -> Data {
        if fileSize <= maxBytes {
            return try Data(contentsOf: url)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(fileSize - maxBytes))
        return try handle.read(upToCount: maxBytes) ?? Data()
    }

    private static func validTimestamp(_ raw: String) -> Bool {
        parsedTimestamp(raw) != nil
    }

    private static func parsedTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func existingReceipt(
        invocationID: String,
        artifactID: String,
        inputReference: String,
        expectedFallback: ProcedureFallbackRoute,
        path: URL,
        persistence: any PersistenceCoreProtocol
    ) async throws -> ProcedureInvocationReceipt? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size]) as? NSNumber,
              size.intValue <= 8 * 1_024 * 1_024 else {
            throw ProcedureArtifactStoreError.corruptInvocationLedger
        }
        let rows: [JSONValue]
        do { rows = try await persistence.readJSONL(path) }
        catch { throw ProcedureArtifactStoreError.corruptInvocationLedger }
        guard rows.count <= 10_000 else {
            throw ProcedureArtifactStoreError.corruptInvocationLedger
        }
        for row in rows.reversed() {
            guard let data = try? row.serializedData(pretty: false),
                  let receipt = try? JSONDecoder().decode(ProcedureInvocationReceipt.self, from: data) else {
                throw ProcedureArtifactStoreError.corruptInvocationLedger
            }
            guard receipt.schema == ProcedureInvocationReceipt.schema,
                  digest(receipt.invocationID), digest(receipt.artifactID), digest(receipt.opaqueInputReference),
                  validTimestamp(receipt.requestedAt),
                  receipt.payloadFree, !receipt.permissionAuthority,
                  validSelectionReceipt(receipt),
                  validExecutionReceipt(receipt) else {
                throw ProcedureArtifactStoreError.corruptInvocationLedger
            }
            // Eligibility-only attempts are audit rows, not durable action
            // claims. They must not block a later exact retry after TrustCenter
            // or a canonical approval becomes available.
            if receipt.invocationID == invocationID, receipt.dispatched {
                guard receipt.artifactID == artifactID,
                      receipt.opaqueInputReference == inputReference,
                      receipt.fallback == expectedFallback else {
                    throw ProcedureArtifactStoreError.corruptInvocationLedger
                }
                return receipt
            }
        }
        return nil
    }

    private static func validExecutionReceipt(_ receipt: ProcedureInvocationReceipt) -> Bool {
        guard receipt.dispatched == (receipt.executorStatus != nil) else { return false }
        guard receipt.dispatched else {
            return !receipt.authorityRechecked
                && !receipt.canonicalEvidenceMatched
                && !receipt.verified
        }
        switch receipt.executorStatus {
        case .verifiedSuccess?, .verifiedFailure?, .cancelled?:
            return receipt.authorityRechecked
                && receipt.canonicalEvidenceMatched
                && receipt.verified
        case .abstained?, .unverified?:
            return !receipt.verified
        case nil:
            return false
        }
    }

    private static func validSelectionReceipt(_ receipt: ProcedureInvocationReceipt) -> Bool {
        if receipt.automaticSelection {
            guard let activationID = receipt.activationID,
                  let procedureID = receipt.procedureID,
                  receipt.selectionMode == "exact_typed",
                  digest(activationID),
                  token(procedureID, maximum: 80) else { return false }
            return true
        }
        return receipt.activationID == nil
            && receipt.procedureID == nil
            && receipt.selectionMode == nil
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
