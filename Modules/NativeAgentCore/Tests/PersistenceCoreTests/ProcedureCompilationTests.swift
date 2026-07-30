import Foundation
import Testing
@testable import PersistenceCore

@Suite("Meaningful procedural compilation")
struct ProcedureCompilationTests {
    @Test("zero-provider compiled executions cannot poison discovery evidence")
    func compiledEvidenceIsPartitionedFromDiscovery() throws {
        let baselineRows = (0..<12).flatMap {
            procedureEvidence(instance: $0, day: 1 + $0 / 4, schemaVariant: $0 % 2)
        }
        let compiledRows = (100..<105).flatMap {
            procedureEvidence(
                instance: $0,
                day: 5,
                schemaVariant: $0 % 2,
                providerCalls: 0,
                removableProviderCalls: 0
            )
        }
        let baseline = ProcedureTrajectoryExtractor.extract(baselineRows).trajectories
        let combined = ProcedureTrajectoryExtractor.extract(baselineRows + compiledRows).trajectories
        #expect(combined.filter(ProcedureCandidateCompiler
            .isPostCompilationExecutionEvidence).count == 5)

        let baselineCandidate = try #require(
            ProcedureCandidateCompiler.evaluate(trajectories: baseline).first
        )
        let combinedCandidate = try #require(
            ProcedureCandidateCompiler.evaluate(trajectories: combined).first
        )
        #expect(combinedCandidate.trajectoryCount == baselineCandidate.trajectoryCount)
        #expect(combinedCandidate.reviewBindingDigest == baselineCandidate.reviewBindingDigest)
        #expect(combinedCandidate.measurableRemovableProviderCalls
            == baselineCandidate.measurableRemovableProviderCalls)
    }

    @Test("extracts only bounded ordered opaque multi-step trajectories")
    func strictExtraction() throws {
        let good = procedureEvidence(instance: 1, day: 1, schemaVariant: 0)
        let report = ProcedureTrajectoryExtractor.extract(good)
        let trajectory = try #require(report.trajectories.first)
        #expect(report.trajectories.count == 1)
        #expect(trajectory.id.count == 64)
        #expect(trajectory.steps.count == 4)
        #expect(trajectory.steps.filter { $0.actionKind != nil || $0.evidenceKind != nil }.count >= 2)
        #expect(trajectory.terminalClass == .verifiedSuccess)
        #expect(trajectory.providerCallCount == 1)
        #expect(trajectory.toolCallCount == 1)
        #expect(trajectory.providerCostMicros == 20)
        #expect(trajectory.toolCostMicros == 5)
        #expect(trajectory.removableOrchestrationProviderCallCount == 1)

        let encoded = String(decoding: try JSONEncoder().encode(trajectory), as: UTF8.self)
        #expect(!encoded.contains("private-value"))
        #expect(!encoded.contains("/Users/"))

        let legacy = CausalTransitionEvidence(
            domain: "workshop_execution",
            operationId: opaque("legacy-op"),
            occurredAt: timestamp(day: 1, second: 0),
            itemIdentity: opaque("legacy-item"),
            kind: "step_completed",
            beforeState: "running",
            afterState: "running",
            expectedNextEvidence: nil,
            outcome: "state_unchanged"
        )
        let legacyReport = ProcedureTrajectoryExtractor.extract([legacy])
        #expect(legacyReport.rowsWithoutTrajectoryIdentity == 1)
        #expect(legacyReport.trajectories.isEmpty)
    }

    @Test("rejects generated short, overlong, unverified, and authority-divergent evidence")
    func generatedExtractionFaults() {
        let short = Array(procedureEvidence(instance: 10, day: 1, schemaVariant: 0).prefix(2))
        let unverified = procedureEvidence(
            instance: 11,
            day: 1,
            schemaVariant: 0,
            terminalVerification: "unverified"
        )
        let authorityDivergent = procedureEvidence(
            instance: 12,
            day: 1,
            schemaVariant: 0,
            authorityDivergenceAt: 2
        )
        let overlong = longProcedureEvidence(instance: 13, day: 1, count: 17)
        let generated = procedureEvidence(
            instance: 14,
            day: 1,
            schemaVariant: 0,
            evidenceClass: .generatedMechanism
        )

        let reports = [
            ProcedureTrajectoryExtractor.extract(short),
            ProcedureTrajectoryExtractor.extract(unverified),
            ProcedureTrajectoryExtractor.extract(authorityDivergent),
            ProcedureTrajectoryExtractor.extract(overlong),
            ProcedureTrajectoryExtractor.extract(generated),
        ]
        #expect(reports.allSatisfy { $0.trajectories.isEmpty })
        #expect(reports[0].rejections.first?.reasons.contains(.tooFewTransitions) == true)
        #expect(reports[1].rejections.first?.reasons.contains(.invalidTerminal) == true)
        #expect(reports[2].rejections.first?.reasons.contains(.missingMetadata) == true)
        #expect(reports[3].rejections.first?.reasons.contains(.tooManyTransitions) == true)
        #expect(reports[4].rejections.first?.reasons.contains(.nonProductionEvidence) == true)
    }

    @Test("strict admission yields a reviewed low-risk Workshop canary but no activation")
    func conservativeWorkshopAdmission() throws {
        let rows = (0..<12).flatMap { index in
            procedureEvidence(
                instance: index,
                day: 1 + index / 4,
                schemaVariant: index % 2
            )
        }
        let trajectories = ProcedureTrajectoryExtractor.extract(rows).trajectories
        #expect(trajectories.count == 12)
        let shape = try #require(trajectories.first?.procedureShapeIdentity)
        let unreviewed = try #require(ProcedureCandidateCompiler.evaluate(
            trajectories: trajectories
        ).first)
        let review = ProcedureReviewerDecision(
            candidateShapeIdentity: shape,
            verdict: .approve,
            scope: .manualAndCanary,
            reviewerIdentity: opaque("reviewer"),
            approvalReceiptIdentity: opaque("approval-receipt"),
            candidateEvidenceDigest: unreviewed.reviewBindingDigest,
            decidedAt: timestamp(day: 4, second: 0)
        )
        let candidate = try #require(ProcedureCandidateCompiler.evaluate(
            trajectories: trajectories,
            reviewerDecisions: [review]
        ).first)

        #expect(candidate.productRole == .workshopFirstProduct)
        #expect(candidate.trajectoryCount == 12)
        #expect(candidate.distinctInputInstanceCount == 12)
        #expect(candidate.parameterSchemaVariationCount == 2)
        #expect(candidate.distinctDayCount == 3)
        #expect(candidate.verifiedSuccessRate == 1)
        #expect(candidate.approvalCheckpointDivergenceCount == 0)
        #expect(candidate.timeSeparatedHoldoutPassed)
        #expect(candidate.measurableRemovableProviderCalls == 12)
        #expect(candidate.manualInvocationEligible)
        #expect(candidate.canaryEligible)
        #expect(!candidate.automaticSelectionEligible)

        let artifact = try DeclarativeProcedureCompiler.compile(candidate)
        #expect(artifact.schema == DeclarativeProcedureArtifact.schema)
        #expect(artifact.transitionTable.count == 4)
        #expect(artifact.canonicalOracle == .workshopRecordAndTimeline)
        #expect(artifact.safety.recheckPoints == [
            .beforeInvocation, .beforeEveryAction, .afterEveryCheckpoint,
        ])
        #expect(!artifact.safety.externalSendsEligible)
        #expect(!artifact.safety.permissionAuthority)
        #expect(!artifact.safety.automaticActivationAllowed)
        #expect(!artifact.automaticSelectionEligible)
        #expect(!artifact.generatedExecutableCode)
        #expect(artifact.rollbackDeclaration == "delete_artifact_restore_fallback_no_data_migration")
        #expect(artifact.deterministicFallback == .ordinaryWorkshopPlannerExecutor)
    }

    @Test("historical and generated replay use exact tables and fall back on faults")
    func exactReplayAndGeneratedFault() throws {
        let (artifact, trajectories) = try eligibleArtifact()
        let historical = ProcedureReplayEngine.replay(
            artifact,
            against: trajectories[0],
            mode: .historicalExact
        )
        #expect(historical.status == .matched)
        #expect(historical.reason == .exactMatch)
        #expect(historical.matchedStepCount == 4)

        let faultRows = procedureEvidence(
            instance: 99,
            day: 3,
            schemaVariant: 0,
            faultActionAt: 2
        )
        let fault = try #require(ProcedureTrajectoryExtractor.extract(faultRows).trajectories.first)
        let generated = ProcedureReplayEngine.replay(
            artifact,
            against: fault,
            mode: .generatedFault
        )
        #expect(generated.status == .fallback)
        #expect(generated.reason == .canonicalEvidenceMismatch)
        #expect(generated.fallback == .ordinaryWorkshopPlannerExecutor)
    }

    @Test("current-state dry replay abstains on novel input and never dispatches")
    func dryReplayNovelInputAndTrust() throws {
        let (artifact, _) = try eligibleArtifact()
        let base = dryContext(artifact: artifact)
        let exact = ProcedureReplayEngine.dryRun(artifact, context: base)
        #expect(exact.status == .wouldAdvance)
        #expect(exact.reason == .exactDryRun)
        #expect(!exact.dispatchedAction)

        let novel = ProcedureReplayEngine.dryRun(
            artifact,
            context: dryContext(artifact: artifact, schemaIdentity: opaque("novel-schema"))
        )
        #expect(novel.status == .abstained)
        #expect(novel.reason == .novelInput)
        #expect(!novel.dispatchedAction)

        let denied = ProcedureReplayEngine.dryRun(
            artifact,
            context: dryContext(artifact: artifact, trustCenterAllowed: false)
        )
        #expect(denied.status == .fallback)
        #expect(denied.reason == .trustCenterDenied)

        var failedPreconditions = requiredPreconditions(artifact)
        failedPreconditions["canonical_executor_available"] = false
        let precondition = ProcedureReplayEngine.dryRun(
            artifact,
            context: dryContext(artifact: artifact, preconditions: failedPreconditions)
        )
        #expect(precondition.status == .fallback)
        #expect(precondition.reason == .preconditionFailed)
    }

    @Test("cancellation and authority divergence fail before any action")
    func cancellationAndAuthorityDivergence() throws {
        let cancelledRows = procedureEvidence(
            instance: 70,
            day: 1,
            schemaVariant: 0,
            terminal: .cancelled
        )
        let cancelledTrajectory = try #require(
            ProcedureTrajectoryExtractor.extract(cancelledRows).trajectories.first
        )
        #expect(cancelledTrajectory.terminalClass == .cancelled)
        #expect(cancelledTrajectory.cancellationObserved)

        let (artifact, _) = try eligibleArtifact()
        let cancelled = ProcedureReplayEngine.dryRun(
            artifact,
            context: dryContext(artifact: artifact, cancellationRequested: true)
        )
        #expect(cancelled.status == .cancelled)
        #expect(cancelled.reason == .cancellationRequested)
        #expect(!cancelled.dispatchedAction)

        let authority = ProcedureReplayEngine.dryRun(
            artifact,
            context: dryContext(artifact: artifact, authorityClass: "confirm_required")
        )
        #expect(authority.status == .fallback)
        #expect(authority.reason == .authorityDiverged)
        #expect(!authority.dispatchedAction)
    }

    @Test("external sends, missing savings, and absent review remain ineligible")
    func ineligibleCandidates() throws {
        let externalRows = (0..<2).flatMap {
            procedureEvidence(
                instance: 200 + $0,
                day: 1 + $0,
                schemaVariant: 0,
                externalEffect: "external_send",
                removableProviderCalls: nil
            )
        }
        let trajectories = ProcedureTrajectoryExtractor.extract(externalRows).trajectories
        let candidate = try #require(ProcedureCandidateCompiler.evaluate(
            trajectories: trajectories
        ).first)
        #expect(!candidate.manualInvocationEligible)
        #expect(candidate.manualBlockingReasons.contains(.externalSendIneligible))
        #expect(candidate.manualBlockingReasons.contains(.providerSavingsUnproven))
        #expect(candidate.manualBlockingReasons.contains(.reviewerDecisionMissing))
        #expect(throws: ProcedureCompilationError.candidateNotEligible) {
            try DeclarativeProcedureCompiler.compile(candidate)
        }
    }

    @Test("hash-shaped caller assertion cannot substitute for approval-bound review")
    func forgedReviewBindingIsRejected() throws {
        let rows = (0..<12).flatMap {
            procedureEvidence(instance: 500 + $0, day: 1 + $0 / 4, schemaVariant: $0 % 2)
        }
        let trajectories = ProcedureTrajectoryExtractor.extract(rows).trajectories
        let shape = try #require(trajectories.first?.procedureShapeIdentity)
        let forged = ProcedureReviewerDecision(
            candidateShapeIdentity: shape,
            verdict: .approve,
            scope: .manualAndCanary,
            reviewerIdentity: opaque("claimed-reviewer"),
            approvalReceiptIdentity: opaque("claimed-approval"),
            candidateEvidenceDigest: opaque("wrong-evidence"),
            decidedAt: timestamp(day: 4, second: 0)
        )
        let candidate = try #require(ProcedureCandidateCompiler.evaluate(
            trajectories: trajectories,
            reviewerDecisions: [forged]
        ).first)
        #expect(!candidate.manualInvocationEligible)
        #expect(candidate.manualBlockingReasons.contains(.reviewerDecisionMissing))
        #expect(throws: ProcedureCompilationError.candidateNotEligible) {
            try DeclarativeProcedureCompiler.compile(candidate)
        }
    }

    @Test("review approval is invalidated when source facts change under the same trajectory ids")
    func reviewBindsCompleteTrajectoryEvidence() throws {
        let originalRows = (0..<12).flatMap {
            procedureEvidence(instance: 700 + $0, day: 1 + $0 / 4, schemaVariant: $0 % 2)
        }
        let original = ProcedureTrajectoryExtractor.extract(originalRows).trajectories
        let unreviewed = try #require(ProcedureCandidateCompiler.evaluate(
            trajectories: original
        ).first)
        let review = ProcedureReviewerDecision(
            candidateShapeIdentity: unreviewed.id,
            verdict: .approve,
            scope: .manualAndCanary,
            reviewerIdentity: opaque("evidence-reviewer"),
            approvalReceiptIdentity: opaque("evidence-approval"),
            candidateEvidenceDigest: unreviewed.reviewBindingDigest,
            decidedAt: timestamp(day: 4, second: 0)
        )

        // Same opaque trajectory IDs, shapes, counts, outcomes, and days; only
        // the claimed removable provider-call fact changed after approval.
        let changedRows = (0..<12).flatMap {
            procedureEvidence(
                instance: 700 + $0,
                day: 1 + $0 / 4,
                schemaVariant: $0 % 2,
                removableProviderCalls: 2
            )
        }
        let changed = ProcedureTrajectoryExtractor.extract(changedRows).trajectories
        let candidate = try #require(ProcedureCandidateCompiler.evaluate(
            trajectories: changed,
            reviewerDecisions: [review]
        ).first)
        #expect(candidate.reviewBindingDigest != unreviewed.reviewBindingDigest)
        #expect(candidate.manualBlockingReasons.contains(.reviewerDecisionMissing))
        #expect(!candidate.manualInvocationEligible)
    }

    @Test("immutable store invokes only manual exact dry-run through canonical executor")
    func manualArtifactInvocation() async throws {
        let (artifact, _) = try eligibleArtifact()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("procedure-artifact-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_783_915_200)
        let store = ProcedureArtifactStore(dataRoot: root, clock: { now })
        _ = try await store.install(artifact)
        #expect(try await store.load(artifact.id) == artifact)
        let executor = RecordingProcedureExecutor()
        let receipt = try await store.invokeManual(
            artifactID: artifact.id,
            opaqueInputReference: opaque("canonical-input"),
            context: dryContext(artifact: artifact),
            executor: executor
        )
        #expect(receipt.dispatched)
        #expect(receipt.verified)
        #expect(!receipt.permissionAuthority)
        #expect(!receipt.automaticSelection)
        #expect(await executor.count() == 1)

        // The same artifact/input/rule is one durable invocation even across a
        // new store actor. It must not dispatch the canonical owner twice.
        let retryStore = ProcedureArtifactStore(dataRoot: root, clock: { now.addingTimeInterval(30) })
        _ = try await retryStore.install(artifact)
        let replayed = try await retryStore.invokeManual(
            artifactID: artifact.id,
            opaqueInputReference: opaque("canonical-input"),
            context: dryContext(artifact: artifact),
            executor: executor
        )
        #expect(replayed == receipt)
        #expect(await executor.count() == 1)

        async let concurrentA = store.invokeManual(
            artifactID: artifact.id,
            opaqueInputReference: opaque("concurrent-input"),
            context: dryContext(artifact: artifact),
            executor: executor
        )
        async let concurrentB = retryStore.invokeManual(
            artifactID: artifact.id,
            opaqueInputReference: opaque("concurrent-input"),
            context: dryContext(artifact: artifact),
            executor: executor
        )
        let firstConcurrent = try await concurrentA
        let secondConcurrent = try await concurrentB
        #expect(firstConcurrent == secondConcurrent)
        #expect(await executor.count() == 2)

        let denied = try await store.invokeManual(
            artifactID: artifact.id,
            opaqueInputReference: opaque("denied-input"),
            context: dryContext(artifact: artifact, trustCenterAllowed: false),
            executor: executor
        )
        #expect(!denied.dispatched)
        #expect(!denied.verified)
        #expect(await executor.count() == 2)
        // A non-dispatched eligibility attempt is audit evidence, not a
        // durable action result. Once the canonical authority is available,
        // the exact invocation may dispatch once and then deduplicate.
        let admittedAfterDenial = try await store.invokeManual(
            artifactID: artifact.id,
            opaqueInputReference: opaque("denied-input"),
            context: dryContext(artifact: artifact, trustCenterAllowed: true),
            executor: executor
        )
        #expect(admittedAfterDenial.dispatched)
        #expect(admittedAfterDenial.verified)
        #expect(await executor.count() == 3)
        let admittedReplay = try await store.invokeManual(
            artifactID: artifact.id,
            opaqueInputReference: opaque("denied-input"),
            context: dryContext(artifact: artifact, trustCenterAllowed: true),
            executor: executor
        )
        #expect(admittedReplay == admittedAfterDenial)
        #expect(await executor.count() == 3)
        let raw = try String(
            contentsOf: root.appendingPathComponent("living_fabric/procedures/invocations.jsonl"),
            encoding: .utf8
        )
        #expect(!raw.contains("private-value"))
        #expect(!raw.contains("/Users/"))
        let status = await store.statusSnapshot()
        #expect(status.artifactCount == 1)
        #expect(status.corruptArtifactCount == 0)
        #expect(status.corruptInvocationCount == 0)
        #expect(status.invocationCount >= 4)
        #expect(status.verifiedInvocationCount >= 3)
        #expect(!status.automaticSelectionEnabled)
        #expect(status.payloadFree)
    }

    @Test("artifact discovery is bounded, domain-filtered, and fails closed on damage")
    func checkedArtifactDiscovery() async throws {
        let (artifact, _) = try eligibleArtifact()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("procedure-discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProcedureArtifactStore(dataRoot: root)
        _ = try await store.install(artifact)

        #expect(try await store.loadInstalledArtifacts() == [artifact])
        #expect(try await store.loadInstalledArtifacts(domain: artifact.domain) == [artifact])
        #expect(try await store.loadInstalledArtifacts(domain: "different_domain").isEmpty)
        await #expect(throws: ProcedureArtifactStoreError.invalidArtifact) {
            _ = try await store.loadInstalledArtifacts(domain: "../invalid")
        }

        let corruptPath = root.appendingPathComponent(
            "living_fabric/procedures/artifacts/\(opaque("damaged-artifact")).json"
        )
        try Data("not-json".utf8).write(to: corruptPath)
        await #expect(throws: ProcedureArtifactStoreError.corruptArtifact) {
            _ = try await store.loadInstalledArtifacts()
        }
    }

    @Test("retention sweep removes only aged, unreferenced, decodable artifacts")
    func retentionSweepScope() async throws {
        let (artifact, _) = try eligibleArtifact()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("procedure-retention-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProcedureArtifactStore(dataRoot: root)
        let path = try await store.install(artifact)

        // A recent unreferenced artifact is never swept.
        #expect(await store.sweepUnreferencedArtifacts() == 0)

        // Backdate past the retention age: now sweep-eligible. This artifact was
        // never invoked, so it is genuinely abandoned (no pointer, no recent
        // invocation receipt) — collection is correct. The recency-protection
        // case is covered by `retentionSweepProtectsRecentlyInvoked` (F3-M2).
        let aged = Date().addingTimeInterval(-ProcedureArtifactStore.artifactRetentionAge - 3600)
        try FileManager.default.setAttributes(
            [.modificationDate: aged], ofItemAtPath: path.path
        )
        #expect(await store.sweepUnreferencedArtifacts() == 1)
        #expect(try await store.loadInstalledArtifacts().isEmpty)
        await #expect(throws: ProcedureArtifactStoreError.artifactNotFound) {
            _ = try await store.load(artifact.id)
        }

        // An undecodable file is fail-closed damage evidence, NOT GC fodder:
        // it survives the sweep even when aged, and discovery still throws.
        let corruptPath = root.appendingPathComponent(
            "living_fabric/procedures/artifacts/\(opaque("damaged-aged")).json"
        )
        try Data("not-json".utf8).write(to: corruptPath)
        try FileManager.default.setAttributes(
            [.modificationDate: aged], ofItemAtPath: corruptPath.path
        )
        #expect(await store.sweepUnreferencedArtifacts() == 0)
        #expect(FileManager.default.fileExists(atPath: corruptPath.path))
    }

    @Test("retention sweep keeps an artifact with a recent invocation receipt (F3-M2)")
    func retentionSweepProtectsRecentlyInvoked() async throws {
        let (artifact, _) = try eligibleArtifact()

        // A manual-invocable artifact in active use leaves invocation receipts
        // but NO active pointer (pointers track exact automatic activations
        // only). A recent receipt must keep it out of the sweep even once its
        // file mtime ages past retention — load/invoke never touch mtime.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("procedure-retention-recent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProcedureArtifactStore(dataRoot: root) // real-clock receipts
        let path = try await store.install(artifact)
        _ = try await store.invokeManual(
            artifactID: artifact.id,
            opaqueInputReference: opaque("recent-input"),
            context: dryContext(artifact: artifact),
            executor: RecordingProcedureExecutor()
        )
        let aged = Date().addingTimeInterval(-ProcedureArtifactStore.artifactRetentionAge - 3600)
        try FileManager.default.setAttributes(
            [.modificationDate: aged], ofItemAtPath: path.path
        )
        #expect(await store.sweepUnreferencedArtifacts() == 0)
        #expect(try await store.loadInstalledArtifacts() == [artifact])

        // Symmetry: an artifact whose only receipt is itself older than the
        // retention age is genuinely abandoned and still collects. A past clock
        // makes the persisted receipt's requestedAt stale.
        let staleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("procedure-retention-stale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staleRoot) }
        let stalePast = Date().addingTimeInterval(-ProcedureArtifactStore.artifactRetentionAge - 7200)
        let staleStore = ProcedureArtifactStore(dataRoot: staleRoot, clock: { stalePast })
        let stalePath = try await staleStore.install(artifact)
        _ = try await staleStore.invokeManual(
            artifactID: artifact.id,
            opaqueInputReference: opaque("stale-input"),
            context: dryContext(artifact: artifact),
            executor: RecordingProcedureExecutor()
        )
        try FileManager.default.setAttributes(
            [.modificationDate: aged], ofItemAtPath: stalePath.path
        )
        #expect(await staleStore.sweepUnreferencedArtifacts() == 1)
        #expect(try await staleStore.loadInstalledArtifacts().isEmpty)
    }

    @Test("retention sweep stays functional with an oversized invocation ledger (gpt-5.5 round-3 review)")
    func retentionSweepSurvivesOversizedLedger() async throws {
        // Abort-on-size would make GC permanently nonfunctional once the
        // ledger crossed 8 MiB. The sweep must instead read the newest tail:
        // a recent receipt near the END of an oversized ledger still protects
        // its artifact, and the sweep still DELETES a receipt-less aged one.
        let (artifact, _) = try eligibleArtifact()
        let aged = Date().addingTimeInterval(-ProcedureArtifactStore.artifactRetentionAge - 3600)

        func inflateLedger(at root: URL) throws {
            // Inflate past the 8 MiB tail cap by repeating the real (decodable)
            // receipt line — append-only newest-at-end shape, so the tail read
            // must drop a partial first line and decode the rest.
            let ledger = root.appendingPathComponent(
                "living_fabric/procedures/invocations.jsonl"
            )
            let line = try Data(contentsOf: ledger)
            var inflated = Data()
            while inflated.count <= 9 * 1_024 * 1_024 { inflated.append(line) }
            try inflated.write(to: ledger)
        }

        // Store A — oversized ledger whose receipts are all STALE (past clock):
        // an abort-on-size would return 0; the tail read must still DELETE the
        // aged artifact. This is the "GC stays functional" half.
        let staleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("procedure-oversize-stale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staleRoot) }
        let stalePast = Date().addingTimeInterval(-ProcedureArtifactStore.artifactRetentionAge - 7200)
        let staleStore = ProcedureArtifactStore(dataRoot: staleRoot, clock: { stalePast })
        let stalePath = try await staleStore.install(artifact)
        _ = try await staleStore.invokeManual(
            artifactID: artifact.id,
            opaqueInputReference: opaque("oversize-stale-input"),
            context: dryContext(artifact: artifact),
            executor: RecordingProcedureExecutor()
        )
        try inflateLedger(at: staleRoot)
        try FileManager.default.setAttributes(
            [.modificationDate: aged], ofItemAtPath: stalePath.path
        )
        #expect(await staleStore.sweepUnreferencedArtifacts() == 1)
        #expect(try await staleStore.loadInstalledArtifacts().isEmpty)

        // Store B — oversized ledger whose newest receipts are RECENT: the
        // tail read must still protect the artifact (sweep runs, deletes 0).
        // Together with Store A this distinguishes tail-read from abort.
        let recentRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("procedure-oversize-recent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: recentRoot) }
        let recentStore = ProcedureArtifactStore(dataRoot: recentRoot)
        let recentPath = try await recentStore.install(artifact)
        _ = try await recentStore.invokeManual(
            artifactID: artifact.id,
            opaqueInputReference: opaque("oversize-recent-input"),
            context: dryContext(artifact: artifact),
            executor: RecordingProcedureExecutor()
        )
        try inflateLedger(at: recentRoot)
        try FileManager.default.setAttributes(
            [.modificationDate: aged], ofItemAtPath: recentPath.path
        )
        #expect(await recentStore.sweepUnreferencedArtifacts() == 0)
        #expect(try await recentStore.loadInstalledArtifacts() == [artifact])
    }

    @Test("retention sweep never removes a pointer-referenced artifact")
    func retentionSweepKeepsPointerReferenced() async throws {
        let (artifact, _) = try eligibleArtifact()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("procedure-retention-ptr-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProcedureArtifactStore(dataRoot: root)
        let path = try await store.install(artifact)
        let aged = Date().addingTimeInterval(-ProcedureArtifactStore.artifactRetentionAge - 3600)
        try FileManager.default.setAttributes(
            [.modificationDate: aged], ofItemAtPath: path.path
        )

        // An active pointer naming the artifact protects it from the sweep,
        // however old the file is.
        let activeDir = root.appendingPathComponent("living_fabric/procedures/active", isDirectory: true)
        try FileManager.default.createDirectory(at: activeDir, withIntermediateDirectories: true)
        let pointer: [String: Any] = [
            "schema": "procedure-exact-activation-pointer.v1",
            "activationID": opaque("activation"),
            "artifactID": artifact.id,
            "procedureID": "proc-retention-test",
            "implementationIdentity": opaque("implementation"),
            "proposalDigest": opaque("proposal"),
        ]
        try JSONSerialization.data(withJSONObject: pointer)
            .write(to: activeDir.appendingPathComponent("proc-retention-test.json"))
        #expect(await store.sweepUnreferencedArtifacts() == 0)
        #expect(try await store.loadInstalledArtifacts() == [artifact])

        // An UNDECODABLE pointer aborts the whole sweep (fail-safe): with its
        // referenced artifactID unknowable, nothing is provably safe to delete.
        try Data("not-json".utf8).write(
            to: activeDir.appendingPathComponent("proc-broken.json")
        )
        #expect(await store.sweepUnreferencedArtifacts() == 0)
        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    @Test("artifact ceiling throws the honest capacity error, not corruptArtifact")
    func capacityCeilingIsHonestAndSelfHeals() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("procedure-capacity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProcedureArtifactStore(dataRoot: root)
        let artifactsDir = root.appendingPathComponent("living_fabric/procedures/artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
        // Ceiling + 1 undecodable rows: the sweep cannot touch them, so the
        // guard must still trip — with the capacity label, not corruptArtifact.
        for i in 0...ProcedureArtifactStore.maxInstalledArtifacts {
            let name = String(format: "%064x", i + 1)
            try Data("x".utf8).write(to: artifactsDir.appendingPathComponent("\(name).json"))
        }
        await #expect(throws: ProcedureArtifactStoreError.artifactCapacityExceeded) {
            _ = try await store.loadInstalledArtifacts()
        }
    }

    @Test("operator status excludes decodable but semantically corrupt invocation claims")
    func statusRejectsCorruptInvocationClaims() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("procedure-status-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent(
            "living_fabric/procedures/invocations.jsonl"
        )
        let corrupt = ProcedureInvocationReceipt(
            schema: ProcedureInvocationReceipt.schema,
            invocationID: opaque("corrupt-invocation"),
            artifactID: opaque("corrupt-artifact"),
            opaqueInputReference: opaque("corrupt-input"),
            requestedAt: timestamp(day: 1, second: 0),
            dryRunStatus: .wouldAdvance,
            dryRunReason: .exactDryRun,
            executorStatus: .unverified,
            authorityRechecked: true,
            canonicalEvidenceMatched: true,
            verified: true,
            fallback: .ordinaryWorkshopPlannerExecutor,
            dispatched: true,
            payloadFree: true,
            permissionAuthority: false,
            automaticSelection: false
        )
        try await SwiftNativePersistenceCore().appendJSONL(
            try JSONValue.parse(JSONEncoder().encode(corrupt)),
            to: path
        )

        let status = await ProcedureArtifactStore(dataRoot: root).statusSnapshot()
        #expect(status.invocationCount == 0)
        #expect(status.verifiedInvocationCount == 0)
        #expect(status.corruptInvocationCount == 1)
        #expect(status.lastInvocationStatus == nil)
    }

    @Test("artifact store rejects domain-oracle drift before invocation")
    func artifactSemanticBinding() async throws {
        let (artifact, _) = try eligibleArtifact()
        let encoded = try JSONEncoder().encode(artifact)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["canonicalOracle"] = ProcedureCanonicalOracle.githubCommandReducer.rawValue
        let drifted = try JSONDecoder().decode(
            DeclarativeProcedureArtifact.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("procedure-artifact-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProcedureArtifactStore(dataRoot: root)
        await #expect(throws: ProcedureArtifactStoreError.invalidArtifact) {
            _ = try await store.install(drifted)
        }
    }

    @Test("executor cannot claim a verified status without exact authority evidence")
    func invalidExecutorResultFailsClosed() async throws {
        let (artifact, _) = try eligibleArtifact()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("procedure-artifact-result-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProcedureArtifactStore(dataRoot: root)
        _ = try await store.install(artifact)
        await #expect(throws: ProcedureArtifactStoreError.invalidExecutionResult) {
            _ = try await store.invokeManual(
                artifactID: artifact.id,
                opaqueInputReference: opaque("invalid-result-input"),
                context: dryContext(artifact: artifact),
                executor: InvalidProcedureExecutor()
            )
        }
    }

    @Test("exact activation is immutable, typed, fail-closed, and pointer-rollbackable")
    func exactActivationLifecycle() async throws {
        let (artifact, _) = try eligibleArtifact()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("procedure-exact-active-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_783_915_200)
        let store = ProcedureArtifactStore(dataRoot: root, clock: { now })
        _ = try await store.install(artifact)
        let invocationIDs = (0..<12).map { opaque("qualified-invocation-\($0)") }
        let trajectoryIDs = (0..<12).map { opaque("qualified-trajectory-\($0)") }
        let proposal = ProcedureExactActivationProposal(
            artifactID: artifact.id,
            procedureShapeIdentity: artifact.procedureShapeIdentity,
            procedureID: "local_file_copy_v1",
            implementationIdentity: opaque("native-copy-implementation-v1"),
            qualifyingInvocationIDs: invocationIDs,
            qualifyingTrajectoryIDs: trajectoryIDs,
            verifiedExecutionCount: 12,
            distinctInputCount: 12,
            zeroProviderExecutionCount: 12,
            sourceEvidenceTrajectoryCount: artifact.sourceTrajectoryIdentities.count,
            p95ExecutionLatencyMilliseconds: 420,
            evaluatedAt: timestamp(day: 4, second: 0)
        )
        #expect(proposal.validates)
        let reusedQualificationForUnknownProcedure = ProcedureExactActivationProposal(
            artifactID: artifact.id,
            procedureShapeIdentity: artifact.procedureShapeIdentity,
            procedureID: "different_procedure_v1",
            implementationIdentity: opaque("different-implementation"),
            qualifyingInvocationIDs: invocationIDs,
            qualifyingTrajectoryIDs: trajectoryIDs,
            verifiedExecutionCount: 12,
            distinctInputCount: 12,
            zeroProviderExecutionCount: 12,
            sourceEvidenceTrajectoryCount: artifact.sourceTrajectoryIdentities.count,
            p95ExecutionLatencyMilliseconds: 420,
            qualificationProtocolIdentity: proposal.qualificationProtocolIdentity,
            evaluatedAt: timestamp(day: 4, second: 0)
        )
        #expect(!reusedQualificationForUnknownProcedure.validates)
        let decision = ProcedureExactActivationReviewerDecision(
            proposalDigest: proposal.bindingDigest,
            verdict: .approve,
            reviewerIdentity: opaque("exact-reviewer"),
            approvalReceiptIdentity: opaque("exact-approval"),
            decidedAt: timestamp(day: 4, second: 1)
        )
        let manifest = try await store.installAndActivateExact(
            proposal: proposal,
            reviewerDecision: decision
        )
        #expect(manifest.validates)
        let replayStore = ProcedureArtifactStore(
            dataRoot: root,
            clock: { now.addingTimeInterval(120) }
        )
        let replayedManifest = try await replayStore.installAndActivateExact(
            proposal: proposal,
            reviewerDecision: decision
        )
        #expect(replayedManifest == manifest)
        #expect(await replayStore.statusSnapshot().activationArtifactCount == 1)
        let active = try await store.loadActiveExactProcedure(
            procedureID: proposal.procedureID,
            implementationIdentity: proposal.implementationIdentity
        )
        #expect(active.manifest == manifest)
        #expect(active.artifact == artifact)
        await #expect(throws: ProcedureExactActivationError.activationBindingMismatch) {
            _ = try await store.loadActiveExactProcedure(
                procedureID: proposal.procedureID,
                implementationIdentity: opaque("changed-implementation")
            )
        }

        let executor = RecordingProcedureExecutor()
        let receipt = try await store.invokeAutomaticExact(
            procedureID: proposal.procedureID,
            implementationIdentity: proposal.implementationIdentity,
            expectedArtifactID: artifact.id,
            opaqueInputReference: opaque("automatic-input"),
            context: dryContext(artifact: artifact),
            executor: executor
        )
        #expect(receipt.verified)
        #expect(receipt.automaticSelection)
        #expect(receipt.activationID == manifest.id)
        #expect(receipt.procedureID == proposal.procedureID)
        #expect(receipt.selectionMode == "exact_typed")
        let status = await store.statusSnapshot()
        #expect(status.activationArtifactCount == 1)
        #expect(status.corruptActivationArtifactCount == 0)
        #expect(status.activeAutomaticProcedureCount == 1)
        #expect(status.automaticSelectionEnabled)
        #expect(status.corruptInvocationCount == 0)

        try await store.deactivateExact(
            procedureID: proposal.procedureID,
            expectedActivationID: manifest.id
        )
        await #expect(throws: ProcedureExactActivationError.activationNotFound) {
            _ = try await store.loadActiveExactProcedure(
                procedureID: proposal.procedureID,
                implementationIdentity: proposal.implementationIdentity
            )
        }
        #expect(try await store.load(artifact.id) == artifact)
        let rolledBack = await store.statusSnapshot()
        #expect(!rolledBack.automaticSelectionEnabled)
        #expect(rolledBack.activeAutomaticProcedureCount == 0)
        #expect(rolledBack.activationArtifactCount == 1)

        let pointer = root.appendingPathComponent(
            "living_fabric/procedures/active/\(proposal.procedureID).json"
        )
        try Data("not-json".utf8).write(to: pointer, options: .atomic)
        await #expect(throws: ProcedureExactActivationError.activationCorrupt) {
            _ = try await store.loadActiveExactProcedure(
                procedureID: proposal.procedureID,
                implementationIdentity: proposal.implementationIdentity
            )
        }
    }

    @Test("exact rollback waits for admitted consequence and closes later admission")
    func exactActivationRollbackBoundary() async throws {
        let (artifact, _) = try eligibleArtifact()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("procedure-exact-rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProcedureArtifactStore(dataRoot: root)
        _ = try await store.install(artifact)
        let proposal = ProcedureExactActivationProposal(
            artifactID: artifact.id,
            procedureShapeIdentity: artifact.procedureShapeIdentity,
            procedureID: "local_file_copy_v1",
            implementationIdentity: opaque("native-copy-rollback-v1"),
            qualifyingInvocationIDs: (0..<12).map { opaque("rollback-invocation-\($0)") },
            qualifyingTrajectoryIDs: (0..<12).map { opaque("rollback-trajectory-\($0)") },
            verifiedExecutionCount: 12,
            distinctInputCount: 12,
            zeroProviderExecutionCount: 12,
            sourceEvidenceTrajectoryCount: artifact.sourceTrajectoryIdentities.count,
            p95ExecutionLatencyMilliseconds: 420,
            evaluatedAt: timestamp(day: 4, second: 0)
        )
        let decision = ProcedureExactActivationReviewerDecision(
            proposalDigest: proposal.bindingDigest,
            verdict: .approve,
            reviewerIdentity: opaque("rollback-reviewer"),
            approvalReceiptIdentity: opaque("rollback-approval"),
            decidedAt: timestamp(day: 4, second: 1)
        )
        let manifest = try await store.installAndActivateExact(
            proposal: proposal,
            reviewerDecision: decision
        )

        let executor = BlockingProcedureExecutor()
        let admitted = Task {
            try await store.invokeAutomaticExact(
                procedureID: proposal.procedureID,
                implementationIdentity: proposal.implementationIdentity,
                expectedArtifactID: artifact.id,
                opaqueInputReference: opaque("rollback-admitted-input"),
                context: dryContext(artifact: artifact),
                executor: executor
            )
        }
        await executor.waitUntilStarted()

        let rollbackFinished = CompletionProbe()
        let rollback = Task {
            try await store.deactivateExact(
                procedureID: proposal.procedureID,
                expectedActivationID: manifest.id
            )
            await rollbackFinished.mark()
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!(await rollbackFinished.value))

        await executor.release()
        #expect(try await admitted.value.verified)
        try await rollback.value
        #expect(await rollbackFinished.value)
        await #expect(throws: ProcedureExactActivationError.activationNotFound) {
            _ = try await store.invokeAutomaticExact(
                procedureID: proposal.procedureID,
                implementationIdentity: proposal.implementationIdentity,
                expectedArtifactID: artifact.id,
                opaqueInputReference: opaque("rollback-late-input"),
                context: dryContext(artifact: artifact),
                executor: RecordingProcedureExecutor()
            )
        }
    }
}

private actor RecordingProcedureExecutor: ProcedureCanonicalExecuting {
    private var calls = 0
    func executeProcedureRule(
        artifact _: DeclarativeProcedureArtifact,
        rule _: ProcedureTransitionRule,
        opaqueInputReference _: String,
        invocationID _: String
    ) async throws -> ProcedureCanonicalExecutionResult {
        calls += 1
        return ProcedureCanonicalExecutionResult(
            status: .verifiedSuccess,
            authorityRechecked: true,
            canonicalEvidenceMatched: true,
            verified: true
        )
    }
    func count() -> Int { calls }
}

private actor BlockingProcedureExecutor: ProcedureCanonicalExecuting {
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func executeProcedureRule(
        artifact _: DeclarativeProcedureArtifact,
        rule _: ProcedureTransitionRule,
        opaqueInputReference _: String,
        invocationID _: String
    ) async throws -> ProcedureCanonicalExecutionResult {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return ProcedureCanonicalExecutionResult(
            status: .verifiedSuccess,
            authorityRechecked: true,
            canonicalEvidenceMatched: true,
            verified: true
        )
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor CompletionProbe {
    private(set) var value = false
    func mark() { value = true }
}

private struct InvalidProcedureExecutor: ProcedureCanonicalExecuting {
    func executeProcedureRule(
        artifact _: DeclarativeProcedureArtifact,
        rule _: ProcedureTransitionRule,
        opaqueInputReference _: String,
        invocationID _: String
    ) async throws -> ProcedureCanonicalExecutionResult {
        ProcedureCanonicalExecutionResult(
            status: .verifiedSuccess,
            authorityRechecked: false,
            canonicalEvidenceMatched: false,
            verified: false
        )
    }
}

private func eligibleArtifact() throws -> (DeclarativeProcedureArtifact, [ProcedureTrajectory]) {
    let rows = (0..<12).flatMap {
        procedureEvidence(instance: $0, day: 1 + $0 / 4, schemaVariant: $0 % 2)
    }
    let trajectories = ProcedureTrajectoryExtractor.extract(rows).trajectories
    let shape = try #require(trajectories.first?.procedureShapeIdentity)
    let unreviewed = try #require(ProcedureCandidateCompiler.evaluate(
        trajectories: trajectories
    ).first)
    let review = ProcedureReviewerDecision(
        candidateShapeIdentity: shape,
        verdict: .approve,
        scope: .manualAndCanary,
        reviewerIdentity: opaque("reviewer"),
        approvalReceiptIdentity: opaque("approval-receipt"),
        candidateEvidenceDigest: unreviewed.reviewBindingDigest,
        decidedAt: timestamp(day: 4, second: 0)
    )
    let candidate = try #require(ProcedureCandidateCompiler.evaluate(
        trajectories: trajectories,
        reviewerDecisions: [review]
    ).first)
    return (try DeclarativeProcedureCompiler.compile(candidate), trajectories)
}

private func procedureEvidence(
    instance: Int,
    day: Int,
    schemaVariant: Int,
    terminal: ProcedureTerminalClass = .verifiedSuccess,
    terminalVerification: String = "verified",
    authorityDivergenceAt: Int? = nil,
    faultActionAt: Int? = nil,
    externalEffect: String = "local_read",
    providerCalls: Int? = 1,
    removableProviderCalls: Int? = 1,
    evidenceClass: CausalInterventionAssignment.EvidenceClass? = nil
) -> [CausalTransitionEvidence] {
    let instanceIdentity = opaque("instance-\(instance)")
    let shapeIdentity = opaque("workshop-shape")
    let schemaIdentity = opaque("schema-\(schemaVariant)")
    let kinds = ["enqueued", "started", "step_completed", terminal.rawValue]
    let before: [String?] = [nil, "queued", "running", "verifying"]
    let after = ["queued", "running", "verifying", terminal == .cancelled ? "cancelled" : "completed"]
    return (0..<4).map { index in
        let isTerminal = index == 3
        let action: String? = {
            if faultActionAt == index { return "tool:list_dir" }
            switch index {
            case 0: return "queue_admission"
            case 1: return "execute_plan"
            case 2: return "tool:read_file"
            case 3 where terminal == .cancelled: return "cancel"
            default: return nil
            }
        }()
        return CausalTransitionEvidence(
            domain: "workshop_execution",
            operationId: opaque("operation-\(instance)-\(index)"),
            occurredAt: timestamp(day: day, second: index),
            itemIdentity: instanceIdentity,
            kind: kinds[index],
            beforeState: before[index],
            afterState: after[index],
            expectedNextEvidence: isTerminal ? nil : "next_evidence",
            outcome: "state_changed",
            trajectoryID: instanceIdentity,
            parentOperationID: index == 0 ? nil : opaque("operation-\(instance)-\(index - 1)"),
            sequenceNumber: index,
            motorPhase: isTerminal ? (terminal == .cancelled ? "cancelled" : "succeeded") : "running",
            verificationClass: isTerminal
                ? (terminal == .cancelled ? "not_applicable" : terminalVerification)
                : "observed",
            authorityClass: authorityDivergenceAt == index ? "confirm_required" : "low_risk",
            deadlineClass: nil,
            terminalClass: isTerminal ? terminal.rawValue : nil,
            completenessClass: isTerminal ? "complete" : "observed",
            taskFamily: "workshop.routine",
            inputClass: "typed_document",
            inputInstanceIdentity: instanceIdentity,
            parameterSchemaClass: "typed_step_arguments_v1",
            parameterSchemaIdentity: schemaIdentity,
            procedureShapeIdentity: shapeIdentity,
            actionKind: action,
            evidenceKind: isTerminal ? "domain_verification" : "canonical_receipt",
            checkpointClass: index == 0 ? "trust_center_admission" : nil,
            retryClass: nil,
            retryCount: isTerminal ? 0 : nil,
            cancellationClass: isTerminal && terminal == .cancelled
                ? "canonical_user_cancellation" : nil,
            externalEffectClass: index == 2 ? externalEffect : "local_control",
            latencyMilliseconds: isTerminal ? 3_000 : nil,
            providerCallCount: isTerminal ? providerCalls : nil,
            toolCallCount: index == 2 ? 1 : nil,
            providerCostMicros: isTerminal ? 20 : nil,
            toolCostMicros: isTerminal ? 5 : nil,
            removableOrchestrationProviderCallCount: isTerminal
                ? removableProviderCalls : nil,
            interventionAssignment: evidenceClass.map { evidenceClass in
                CausalInterventionAssignment(
                    assignmentID: opaque("procedure-lab-\(instance)"),
                    intervention: "procedure_compilation_probe",
                    evidenceClass: evidenceClass
                )
            }
        )
    }
}

private func longProcedureEvidence(instance: Int, day: Int, count: Int) -> [CausalTransitionEvidence] {
    let instanceIdentity = opaque("long-\(instance)")
    return (0..<count).map { index in
        let terminal = index == count - 1
        return CausalTransitionEvidence(
            domain: "workshop_execution",
            operationId: opaque("long-op-\(instance)-\(index)"),
            occurredAt: timestamp(day: day, second: index),
            itemIdentity: instanceIdentity,
            kind: terminal ? "completed" : "step_completed",
            beforeState: index == 0 ? nil : "s\(index)",
            afterState: terminal ? "completed" : "s\(index + 1)",
            expectedNextEvidence: terminal ? nil : "next",
            outcome: "state_changed",
            trajectoryID: instanceIdentity,
            sequenceNumber: index,
            motorPhase: terminal ? "succeeded" : "running",
            verificationClass: terminal ? "verified" : "observed",
            authorityClass: "low_risk",
            terminalClass: terminal ? "verified_success" : nil,
            completenessClass: terminal ? "complete" : "observed",
            taskFamily: "workshop.routine",
            inputClass: "typed_document",
            inputInstanceIdentity: instanceIdentity,
            parameterSchemaClass: "typed_step_arguments_v1",
            parameterSchemaIdentity: opaque("long-schema"),
            procedureShapeIdentity: opaque("long-shape"),
            actionKind: terminal ? nil : "tool:read_file",
            evidenceKind: "canonical_receipt",
            externalEffectClass: terminal ? "local_control" : "local_read",
            removableOrchestrationProviderCallCount: terminal ? 1 : nil
        )
    }
}

private func dryContext(
    artifact: DeclarativeProcedureArtifact,
    schemaIdentity: String? = nil,
    authorityClass: String? = nil,
    trustCenterAllowed: Bool = true,
    preconditions: [String: Bool]? = nil,
    cancellationRequested: Bool = false
) -> ProcedureDryRunContext {
    ProcedureDryRunContext(
        invocationMode: .manual,
        taskFamily: artifact.inputContract.taskFamily,
        inputClass: artifact.inputContract.inputClass,
        parameterSchemaIdentity: schemaIdentity
            ?? artifact.inputContract.acceptedParameterSchemaIdentities[0],
        authorityClass: authorityClass ?? artifact.authorityClass,
        requestedExternalEffectClass: "local_control",
        currentState: artifact.transitionTable[0].beforeState,
        nextRuleIndex: 0,
        trustCenterAllowed: trustCenterAllowed,
        preconditionResults: preconditions ?? requiredPreconditions(artifact),
        canonicalApprovalOwnerRechecked: true,
        cancellationRequested: cancellationRequested
    )
}

private func requiredPreconditions(
    _ artifact: DeclarativeProcedureArtifact
) -> [String: Bool] {
    Dictionary(uniqueKeysWithValues: artifact.safety.requiredPreconditions.map { ($0, true) })
}

private func opaque(_ raw: String) -> String {
    CausalTransitionEvidence.opaqueIdentity(raw)
}

private func timestamp(day: Int, second: Int) -> String {
    String(format: "2026-07-%02dT12:00:%02dZ", day, second)
}
