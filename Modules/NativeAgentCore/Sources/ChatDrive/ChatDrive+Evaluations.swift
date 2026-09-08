import Foundation
import NativeAgentCore
import NativeAgentEvaluation
import Context
import MemoryV2
import PersistenceCore

extension ChatDriveMain {
    static func runMemoryEval(dataRootPath: String, queryMode: String) async throws {
        let dataRoot = URL(fileURLWithPath: dataRootPath).standardizedFileURL
        let embeddingMock = ProcessInfo.processInfo.environment["NATIVE_AGENT_EMBEDDING_MOCK"] == "1"
        if embeddingMock,
           ProcessInfo.processInfo.environment["NATIVEAGENT_RELEASE_GATE"] == "1" {
            throw NSError(domain: "ChatDriveMemoryEval", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                    "memory-eval refuses NATIVE_AGENT_EMBEDDING_MOCK=1 in release-gate mode",
            ])
        }
        let loadedProbeSet = try MemoryProbeSet.loadForEvaluation(dataRoot: dataRoot)
        let probeSet = probeSetForEval(loadedProbeSet, queryMode: queryMode)
        guard !probeSet.probes.isEmpty else {
            throw MemoryProbeRunner.ProbeRunnerError.emptyProbeSet
        }
        let embedder: any EmbeddingProvider
        if embeddingMock {
            embedder = MockEmbeddingProvider(dimensions: 384)
        } else if let coreML = try? CoreMLEmbeddingProvider.bundled(extrasRoot: dataRoot) {
            embedder = coreML
        } else {
            let out: JSONValue = .object([
                "dataRoot": .string(dataRoot.path),
                "embeddingMock": .bool(false),
                "queryMode": .string(normalizedEvalQueryMode(queryMode)),
                "total": .int(0),
                "frozenCopy": .bool(false),
                "liveStoreMutated": .bool(false),
                "verdict": .object([
                    "status": .string("unavailable"),
                    "reason": .string(
                        "CoreML embedding provider is unavailable; memory-eval did not execute probes"
                    ),
                    "probesExecuted": .int(0),
                ]),
            ])
            print((try? out.serialize(pretty: true)) ?? "\(out)")
            throw NSError(domain: "ChatDriveMemoryEval", code: 3, userInfo: [
                NSLocalizedDescriptionKey:
                    "memory-eval cannot score without the CoreML embedding provider",
            ])
        }
        // Never open the caller's store: even a "read" open of the SQLite pool
        // rewrites WAL/SHM sidecars and runs migrations, mutating a root this
        // evaluation promises to leave byte-identical (liveStoreMutated=false
        // must be a fact, not a claim). Freeze by byte-copying the memory
        // directory into a private temp root and open ONLY the copy.
        let frozenRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-memory-eval-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: frozenRoot) }
        try FileManager.default.createDirectory(at: frozenRoot, withIntermediateDirectories: true)
        let sourceMemoryDirectory = dataRoot.appendingPathComponent("memory", isDirectory: true)
        if FileManager.default.fileExists(atPath: sourceMemoryDirectory.path) {
            try FileManager.default.copyItem(
                at: sourceMemoryDirectory,
                to: frozenRoot.appendingPathComponent("memory", isDirectory: true)
            )
        }
        let storage = try MemoryStorage(dataRoot: frozenRoot)
        let started = Date()
        let queryBatch: MemoryEmbeddingBatch
        do {
            queryBatch = try await MemoryProbeRunner.embedQuestionsWithEpoch(
                probeSet.probes,
                embedder: embedder
            )
        } catch {
            let out: JSONValue = .object([
                "dataRoot": .string(dataRoot.path),
                "modelId": .string(embedder.modelId),
                "embeddingMock": .bool(embeddingMock),
                "queryMode": .string(normalizedEvalQueryMode(queryMode)),
                "total": .int(0),
                "frozenCopy": .bool(true),
                "liveStoreMutated": .bool(false),
                "verdict": .object([
                    "status": .string("failed"),
                    "reason": .string("embedding batch failed: \(error)"),
                    "probesExecuted": .int(0),
                ]),
            ])
            print((try? out.serialize(pretty: true)) ?? "\(out)")
            throw error
        }
        let score = try await MemoryProbeRunner.evaluate(
            storage: storage,
            probes: probeSet.probes,
            vectors: queryBatch.vectors,
            topK: probeSet.topK,
            embeddingEpoch: queryBatch.epoch
        )
        let contextScore = try await runFrozenContextMemoryEvaluation(
            storage: storage,
            probeSet: probeSet,
            queryBatch: queryBatch
        )
        let epochState = try await storage.embeddingEpochState()
        let disclosure = frozenDisclosureEvaluation()
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        let missValues: [JSONValue] = score.misses.map { miss in
            .object([
                "probeId": .string(miss.probeId),
                "question": .string(miss.question),
                "topSummaries": .array(miss.topSummaries.map { .string($0) }),
            ])
        }
        let out: JSONValue = .object([
            "dataRoot": .string(dataRoot.path),
            "modelId": .string(embedder.modelId),
            "embeddingMock": .bool(embeddingMock),
            "version": .int(Int64(probeSet.version)),
            "topK": .int(Int64(probeSet.topK)),
            "queryMode": .string(normalizedEvalQueryMode(queryMode)),
            "total": .int(Int64(score.total)),
            "hits": .int(Int64(score.hits)),
            "fraction": .double(score.fraction),
            "summary": .string(score.summary),
            "verdict": .object([
                "status": .string("scored"),
                "summary": .string(score.summary),
                "probesExecuted": .int(Int64(score.total)),
                "allConfiguredProbesExecuted": .bool(score.total == probeSet.probes.count),
            ]),
            "hitProbeIds": .array(score.hitProbeIds.map { .string($0) }),
            "misses": .array(missValues),
            "frozenCopy": .bool(true),
            "liveStoreMutated": .bool(false),
            "embeddingEpoch": .object([
                "protected": .bool(epochState.protected),
                "active": epochState.activeEpoch.map(JSONValue.string) ?? .null,
                "query": .string(queryBatch.epoch.rawValue),
                "matches": .bool(epochState.activeEpoch == nil || epochState.activeEpoch == queryBatch.epoch.rawValue),
            ]),
            "contextSelector": contextScore,
            "disclosure": disclosure,
            "rankingChangeEligible": .bool(false),
            "rankingDecision": .string(
                "baseline-only: no semantic/temporal/rank-fusion candidate is activated by this evaluation"
            ),
            "durationMs": .int(Int64(elapsedMs)),
        ])
        print((try? out.serialize(pretty: true)) ?? "\(out)")
    }

    static func runFrozenContextMemoryEvaluation(
        storage: MemoryStorage,
        probeSet: MemoryProbeSet,
        queryBatch: MemoryEmbeddingBatch
    ) async throws -> JSONValue {
        let memories = try await storage.listMemories(persona: nil, status: "active", limit: nil)
            .filter { MemoryLifecycle.isRecallEligible($0.lifecycle) }
        var sources: [ContextStoredSource] = []
        var atoms: [ContextStoredAtom] = []
        var recordByAtom: [ContextAtomID: StoredMemory] = [:]
        for memory in memories {
            guard let vector = memory.embedding,
                  memory.embeddingEpoch == nil || memory.embeddingEpoch == queryBatch.epoch.rawValue,
                  let disclosure = MemoryRecordDisclosurePolicy.classify(
                      personaID: memory.personaId,
                      status: memory.status,
                      lifecycle: memory.lifecycle,
                      tags: memoryTags(memory.metadata),
                      metadata: memory.metadata
                  ) else { continue }
            let sourceID = ContextSourceID(rawValue: "memory-eval-source:\(memory.id)")
            let atomID = ContextAtomID(rawValue: "memory-eval-atom:\(memory.id)")
            let privacy: ContextPrivacy
            switch disclosure.privacy {
            case .localPrivate: privacy = .localPrivate
            case .trustedRemote: privacy = .trustedRemote
            case .publicSafe: privacy = .publicSafe
            }
            let surfaces = Set(disclosure.permittedSurfaces.map(ContextSurface.init(rawValue:)))
            let pinned: Bool = {
                guard case .object(let object)? = memory.metadata,
                      case .bool(true)? = object["pinned"] else { return false }
                return true
            }()
            let authority: ContextAuthority = pinned ? .canonical : .inferred
            let updatedAt = MemoryRecallScoring.parseTimestamp(memory.updatedAt) ?? Date(timeIntervalSince1970: 0)
            let sourceHash = ContextStableID.digest(parts: [
                memory.id, memory.content, memory.updatedAt, queryBatch.epoch.rawValue,
            ])
            let descriptor = ContextSourceDescriptor(
                id: sourceID,
                owner: "nativeagent.memory-eval",
                kind: .memory,
                canonicalLocator: "memory-v2/records/\(memory.id)",
                authority: authority,
                privacy: privacy,
                permittedSurfaces: surfaces,
                injectionPolicy: .adaptive
            )
            let draft = ContextAtomDraft(
                id: atomID,
                sourceID: sourceID,
                kind: .memory,
                headingPath: [],
                sourceRange: ContextSourceRange(utf8Start: 0, utf8End: memory.content.utf8.count),
                sourceHash: sourceHash,
                body: memory.content,
                authority: authority,
                confidence: memory.confidence,
                freshness: ContextFreshness(updatedAt: updatedAt),
                privacy: privacy,
                permittedSurfaces: surfaces,
                injectionPolicy: .adaptive,
                contentRole: .memory,
                entities: [ContextEntity(kind: "memory_record", id: memory.id, label: memory.id)],
                triggers: memoryTags(memory.metadata),
                activation: 0,
                recentUsefulness: 0,
                decayState: 1,
                embedding: ContextEmbedding(
                    modelFingerprint: queryBatch.epoch.rawValue,
                    values: vector
                )
            )
            sources.append(ContextStoredSource(
                descriptor: descriptor,
                sourceHash: sourceHash,
                health: .healthy,
                lastError: nil,
                validFromGeneration: 1,
                validToGeneration: nil
            ))
            atoms.append(ContextStoredAtom(
                versionKey: "\(atomID.rawValue)@1",
                draft: draft,
                validFromGeneration: 1,
                validToGeneration: nil
            ))
            recordByAtom[atomID] = memory
        }
        let generation = ContextStoredGeneration(
            generation: ContextGenerationRecord(
                id: 1,
                parentID: nil,
                createdAt: Date(timeIntervalSince1970: 0),
                reason: "frozen memory evaluation",
                sourceFingerprint: ContextStableID.digest(parts: sources.map(\.sourceHash).sorted()),
                atomCount: atoms.count,
                sourceCount: sources.count
            ),
            sources: sources,
            atoms: atoms,
            relationships: []
        )
        let selector = ContextSelector()
        var hits = 0
        var hitIDs: [String] = []
        var misses: [JSONValue] = []
        for (index, probe) in probeSet.probes.enumerated() {
            let need = NeedSignal(
                message: probe.question,
                surface: .chat,
                origin: .localAuthenticated,
                authorization: ContextSelectionAuthorization(
                    allowedOrigins: [.localAuthenticated],
                    allowedPrivacy: [.localPrivate, .trustedRemote, .publicSafe],
                    allowedSourceIDs: Set(sources.map(\.descriptor.id))
                ),
                queryEmbedding: queryBatch.vectors[index],
                queryEmbeddingModelFingerprint: queryBatch.epoch.rawValue,
                availableGenerationID: 1,
                characterBudget: 6_000,
                now: Date(timeIntervalSince1970: 60),
                cacheState: .hit
            )
            let packet = try selector.select(need, from: generation)
            let selected = packet.selectedItems.compactMap { recordByAtom[$0.pointer.atomID] }
            let matched = packet.selectedItems.contains { item in
                guard let memory = recordByAtom[item.pointer.atomID] else { return false }
                if let expectedID = probe.expectMemoryId, memory.id == expectedID,
                   item.representation == .body, !item.text.isEmpty { return true }
                return probe.expectAnySubstring.contains { expected in
                    !expected.isEmpty && item.text.range(
                        of: expected,
                        options: [.caseInsensitive]
                    ) != nil
                }
            }
            if matched {
                hits += 1
                hitIDs.append(probe.id)
            } else {
                misses.append(.object([
                    "probeId": .string(probe.id),
                    "selected": .array(selected.prefix(5).map { .string($0.id) }),
                    "rankingEvidence": .array(packet.receipt.candidateScores
                        .sorted { $0.features.total > $1.features.total }
                        .compactMap { candidate -> JSONValue? in
                            guard let memory = recordByAtom[candidate.atomID] else { return nil }
                            return .object([
                                "recordID": .string(memory.id),
                                "expected": .bool(memory.id == probe.expectMemoryId),
                                "semantic": .double(candidate.features.semanticCosine),
                                "overlap": .double(candidate.features.tokenOverlap),
                                "coverage": .double(candidate.features.messageCoverage),
                                "total": .double(candidate.features.total),
                            ])
                        }),
                ]))
            }
        }
        return .object([
            "productionSelector": .bool(true),
            "productionAssembly": .bool(false),
            "scope": .string("memory-only component; full app assembly is covered by the app context integration eval"),
            "renderedEvidence": .bool(true),
            "total": .int(Int64(probeSet.probes.count)),
            "hits": .int(Int64(hits)),
            "summary": .string("\(hits)/\(probeSet.probes.count)"),
            "hitProbeIds": .array(hitIDs.map(JSONValue.string)),
            "misses": .array(misses),
            "candidateAtoms": .int(Int64(atoms.count)),
        ])
    }

    static func frozenDisclosureEvaluation() -> JSONValue {
        func decision(tags: [String], surface: String, persona: String) -> Bool {
            MemoryRecordDisclosurePolicy.classify(
                personaID: "CustomAgent",
                status: "active",
                lifecycle: MemoryLifecycle.confirmed,
                tags: tags,
                metadata: nil
            )?.permits(surface: surface, personaID: persona) == true
        }
        let checks: [(String, Bool)] = [
            ("private_chat", decision(tags: [], surface: "chat", persona: "CustomAgent")),
            // Telegram is User's authenticated personal surface (2026-07-20);
            // slack is the prompt-injectable no-human surface the local_private
            // fence actually protects against.
            ("private_telegram", decision(tags: [], surface: "telegram", persona: "CustomAgent")),
            ("private_slack_denied", !decision(tags: [], surface: "slack", persona: "CustomAgent")),
            ("public_telegram", decision(tags: ["privacy:public_safe"], surface: "telegram", persona: "CustomAgent")),
            ("persona_mismatch_denied", !decision(tags: [], surface: "chat", persona: "Other")),
            ("workshop_alias", decision(tags: [], surface: "workshop", persona: "CustomAgent")),
            ("claude_bridge_alias", decision(tags: [], surface: "claude-bridge", persona: "CustomAgent")),
        ]
        return .object([
            "passed": .bool(checks.allSatisfy(\.1)),
            "checks": .object(Dictionary(uniqueKeysWithValues: checks.map { ($0.0, .bool($0.1)) })),
        ])
    }

    static func memoryTags(_ metadata: JSONValue?) -> [String] {
        guard case .object(let object)? = metadata,
              case .array(let values)? = object["tags"] else { return [] }
        return values.compactMap {
            guard case .string(let value) = $0 else { return nil }
            return value
        }
    }

    static func runPhysiologySoakReport(dataRootPath: String) async throws {
        let dataRoot = URL(fileURLWithPath: dataRootPath, isDirectory: true).standardizedFileURL
        let loaded = await InstalledPhysiologySoakStore(dataRoot: dataRoot).loadReportWithEvidenceSource()
        let output = PhysiologySoakReportOutput(
            evidenceSourceState: loaded.evidenceSourceState,
            retainedDayFileCount: loaded.retainedDayFileCount,
            unreadableDayFileCount: loaded.unreadableDayFileCount,
            report: loaded.report
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(output), as: UTF8.self))
    }

    /// CLI envelope for the real store load: keep the analyzer report intact,
    /// while saying whether zero records came from a readable empty directory
    /// or from an absent/unreadable evidence source.
    private struct PhysiologySoakReportOutput: Encodable {
        let schema = "chat-drive-physiology-soak-report.v1"
        let evidenceSourceState: InstalledPhysiologySoakEvidenceSourceState
        let retainedDayFileCount: Int
        let unreadableDayFileCount: Int
        let report: InstalledPhysiologySoakReport
    }

    /// Read-only evidence report for the Living Fabric pilot. This is builder
    /// instrumentation, not another runtime owner: it reads bounded persisted
    /// traces through the existing projections, writes nothing, creates no
    /// training corpus, and grants no control or learning approval.
    static func runLivingFabricEval(dataRootPath: String) async throws {
        let dataRoot = URL(fileURLWithPath: dataRootPath).standardizedFileURL
        let evaluatedAt = Date()
        let persistence = SwiftNativePersistenceCore()
        let traceDirectory = dataRoot.appendingPathComponent("turn_traces", isDirectory: true)
        let traceDirectoryRead = livingFabricDirectoryRead(traceDirectory)
        let traceURLs = traceDirectoryRead.urls
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // Turn trace retention is already bounded by the app. Keep this CLI
        // defensive as well so a malformed/custom root cannot turn a review
        // command into an unbounded memory load. The receipt is part of the
        // report: an empty or imperfect input window must not look like an
        // authoritative zero-recommendation result.
        let maximumTraceFiles = 21
        let perFileRowLimit = 20_000
        let perFileByteLimit = 16 * 1_024 * 1_024
        let maximumTraceEvents = 100_000
        let selectedTraceURLs = Array(traceURLs.suffix(maximumTraceFiles))
        var traceEvents: [TurnTraceEvent] = []
        traceEvents.reserveCapacity(min(50_000, traceURLs.count * 2_000))
        var physicalTraceRowsScanned = 0
        var malformedJSONTraceRows = 0
        var rejectedTraceEventRows = 0
        var byteWindowTruncatedFileCount = 0
        var globallyDiscardedTraceEventCount = 0
        var traceSourceState = traceDirectoryRead.state
        var traceFilesRead = 0
        for url in selectedTraceURLs {
            do {
                let receipt = try await persistence.tailJSONLReadReceipt(
                    url,
                    limit: perFileRowLimit,
                    maxBytes: perFileByteLimit
                )
                traceFilesRead += 1
                physicalTraceRowsScanned += receipt.physicalRowsScanned
                malformedJSONTraceRows += receipt.malformedJSONRowCount
                if receipt.truncatedToByteWindow {
                    byteWindowTruncatedFileCount += 1
                }
                let decoded = receipt.rows.compactMap(TurnTraceEvent.init(jsonRow:))
                rejectedTraceEventRows += receipt.rows.count - decoded.count
                traceEvents.append(contentsOf: decoded)
                if traceEvents.count > maximumTraceEvents {
                    let discarded = traceEvents.count - maximumTraceEvents
                    traceEvents.removeFirst(discarded)
                    globallyDiscardedTraceEventCount += discarded
                }
            } catch {
                traceSourceState = .sourceUnreadable
                continue
            }
        }

        let operationalEvidence = try await collectOperationalProcedureEvidence(
            dataRoot: dataRoot,
            persistence: persistence,
            tolerateUnreadableSources: true
        )
        let transitions = operationalEvidence.transitions
        let authoritativeOutcomes = operationalEvidence.authoritativeOutcomes

        let transitionDates = transitions.compactMap { parseLivingFabricDate($0.occurredAt) }
        let transitionDomainCounts = Dictionary(grouping: transitions, by: \.domain)
            .mapValues(\.count)
        let procedureExtraction = ProcedureTrajectoryExtractor.extract(transitions)
        let procedureCandidates = ProcedureCandidateCompiler.evaluate(
            trajectories: procedureExtraction.trajectories
        )
        let procedureRoot = dataRoot
            .appendingPathComponent("living_fabric", isDirectory: true)
            .appendingPathComponent("procedures", isDirectory: true)
        let procedureSourceRead = livingFabricDirectoryRead(procedureRoot)
        let procedureArtifacts = await ProcedureArtifactStore(dataRoot: dataRoot).statusSnapshot()
        let outcomeReport = CausalTerminalOutcomeClassifier.classify(
            transitions: transitions,
            authoritative: authoritativeOutcomes
        )
        let holdout = AdaptiveCausalTimeHoldoutPolicy.split(transitions)
        let drift = AdaptiveCausalDriftEvaluator.evaluate(
            training: holdout.training,
            holdout: holdout.holdout
        )
        let transitionSchemaVersion = "causal-transition-evidence.v2"
        let privacyArtifactURL = dataRoot
            .appendingPathComponent("living_fabric", isDirectory: true)
            .appendingPathComponent("review", isDirectory: true)
            .appendingPathComponent("privacy-classification.json")
        let privacyLoad: (artifact: AdaptiveCausalPrivacyReviewArtifact?, status: String) = {
            do {
                return (try AdaptiveCausalPrivacyReviewLoader.load(
                    from: privacyArtifactURL,
                    requiredDomains: Set(transitions.map(\.domain)),
                    transitionSchemaVersion: transitionSchemaVersion
                ), "valid")
            } catch let error as AdaptiveCausalArtifactError {
                return (nil, error.rawValue)
            } catch {
                return (nil, "malformed")
            }
        }()
        let shadowRoot = dataRoot
            .appendingPathComponent("living_fabric", isDirectory: true)
            .appendingPathComponent("shadow", isDirectory: true)
        let rollbackLoad: (artifact: AdaptiveCausalRollbackManifest?, status: String) = {
            do {
                return (try AdaptiveCausalRollbackManifestLoader.load(
                    from: shadowRoot.appendingPathComponent("rollback-manifest.json"),
                    modelArtifactDirectory: shadowRoot.appendingPathComponent("models", isDirectory: true)
                ), "valid")
            } catch let error as AdaptiveCausalArtifactError {
                return (nil, error.rawValue)
            } catch {
                return (nil, "malformed")
            }
        }()
        func artifactSourceState(_ status: String) -> LivingFabricEvidenceSourceState {
            switch status {
            case "valid": return .read
            case AdaptiveCausalArtifactError.missing.rawValue: return .sourceAbsent
            default: return .sourceUnreadable
            }
        }
        let gate = AdaptiveCausalLearningGate.evaluate(AdaptiveCausalLearningEvidence(
            firstTransitionAt: transitionDates.min(),
            lastTransitionAt: transitionDates.max(),
            evaluatedAt: evaluatedAt,
            transitionCount: transitions.count,
            outcomeCompleteCount: outcomeReport.outcomeCompleteTransitionCount,
            invalidTransitionTimestampCount: holdout.invalidTimestampCount,
            // These names classify this bounded projection, not the underlying
            // raw stores. Approval/drift/rollback remain explicit blockers.
            transitionSchemaVersion: transitionSchemaVersion,
            // These can become non-nil/true only through strict read-only
            // validation of explicit offline artifacts. The evaluator never
            // creates or repairs either artifact.
            privacyClassificationVersion: privacyLoad.artifact?.classificationVersion,
            holdoutDays: holdout.elapsedHoldoutDays,
            driftDetectionReady: drift.detectorReady,
            distributionDriftWithinLimit: drift.withinLimit,
            rollbackArtifactReady: rollbackLoad.artifact != nil,
            personalTraceLearningApproved: false,
            purpose: .personalShadowEvaluation,
            holdoutTransitionCount: holdout.holdout.count,
            controlledProductionTransitionCount: transitions.count {
                $0.evidenceClass == .controlledProduction
            }
        ))

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let readinessValue: JSONValue = .object([
            "readyForShadowTraining": .bool(gate.readyForShadowTraining),
            "blockers": .array(gate.blockers.map { .string($0.rawValue) }),
            "observationDays": .double(gate.observationDays),
            "observationDaysRemaining": .double(gate.observationDaysRemaining),
            "transitionCount": .int(Int64(gate.transitionCount)),
            "transitionDomains": .object(transitionDomainCounts.mapValues { .int(Int64($0)) }),
            "transitionsRemaining": .int(Int64(gate.transitionsRemaining)),
            "outcomeCompleteCount": .int(Int64(gate.outcomeCompleteCount)),
            "outcomeCoverage": .double(gate.outcomeCoverage),
            "outcomeClassification": .string("terminal_trajectory.v1"),
            "terminalTrajectoryCount": .int(Int64(outcomeReport.terminalTrajectoryCount)),
            "incompleteTrajectoryCount": .int(Int64(outcomeReport.incompleteTrajectoryCount)),
            "terminalKinds": .object(Dictionary(
                uniqueKeysWithValues: outcomeReport.terminalKindCounts.map {
                    ($0.key.rawValue, JSONValue.int(Int64($0.value)))
                }
            )),
            "privacyReviewLoaded": .bool(privacyLoad.artifact != nil),
            "privacyReviewStatus": .string(privacyLoad.status),
            "privacyClassificationVersion": privacyLoad.artifact.map { .string($0.classificationVersion) } ?? .null,
            "holdoutCutoffAt": holdout.cutoffAt.map { .string(formatter.string(from: $0)) } ?? .null,
            "holdoutTrainingCount": .int(Int64(holdout.training.count)),
            "holdoutEvaluationCount": .int(Int64(holdout.holdout.count)),
            "sampleSufficiencyUsed": .bool(gate.sampleSufficiencyUsed),
            "readinessPurpose": .string(gate.purpose.rawValue),
            "controlledProductionTransitionCount": .int(
                Int64(gate.controlledProductionTransitionCount)
            ),
            "holdoutInvalidTimestampCount": .int(Int64(holdout.invalidTimestampCount)),
            "holdoutDays": .int(Int64(holdout.elapsedHoldoutDays)),
            "holdoutDaysRemaining": .int(Int64(gate.holdoutDaysRemaining)),
            "lastEvidenceAgeDays": gate.lastEvidenceAgeDays.map(JSONValue.double) ?? .null,
            "driftSchema": .string(drift.schema),
            "driftStatus": .string(drift.status.rawValue),
            "driftJensenShannon": drift.jensenShannonDivergence.map(JSONValue.double) ?? .null,
            "driftMaximumAllowed": .double(drift.maximumAllowedDivergence),
            "rollbackManifestLoaded": .bool(rollbackLoad.artifact != nil),
            "rollbackManifestStatus": .string(rollbackLoad.status),
            "rollbackModelVersion": rollbackLoad.artifact.map { .string($0.modelVersion) } ?? .null,
            "controlAuthority": .bool(false),
            "personalTraceLearningApproved": .bool(false),
        ])
        let procedureValue: JSONValue = .object([
            "schema": .string("compiled.procedure.evidence.v1"),
            "acceptedTrajectories": .int(Int64(procedureExtraction.trajectories.count)),
            "rejectedTrajectories": .int(Int64(procedureExtraction.rejections.count)),
            "rowsWithoutTrajectoryIdentity": .int(Int64(
                procedureExtraction.rowsWithoutTrajectoryIdentity
            )),
            "rejectionReasons": .object(Dictionary(
                grouping: procedureExtraction.rejections.flatMap(\.reasons),
                by: \.rawValue
            ).mapValues { .int(Int64($0.count)) }),
            "candidates": .array(procedureCandidates.map { candidate in
                .object([
                    "shapeIdentity": .string(candidate.id),
                    "productRole": .string(candidate.productRole.rawValue),
                    "trajectories": .int(Int64(candidate.trajectoryCount)),
                    "verifiedSuccesses": .int(Int64(candidate.verifiedSuccessCount)),
                    "verifiedSuccessRate": .double(candidate.verifiedSuccessRate),
                    "manualEligible": .bool(candidate.manualInvocationEligible),
                    "canaryEligible": .bool(candidate.canaryEligible),
                    "automaticSelectionEligible": .bool(false),
                    "manualBlockers": .array(candidate.manualBlockingReasons.map {
                        .string($0.rawValue)
                    }),
                    "canaryBlockers": .array(candidate.canaryBlockingReasons.map {
                        .string($0.rawValue)
                    }),
                ])
            }),
            "installedArtifacts": .int(Int64(procedureArtifacts.artifactCount)),
            "corruptArtifacts": .int(Int64(procedureArtifacts.corruptArtifactCount)),
            "invocations": .int(Int64(procedureArtifacts.invocationCount)),
            "manualInvocations": .int(Int64(procedureArtifacts.manualInvocationCount)),
            "automaticInvocations": .int(Int64(procedureArtifacts.automaticInvocationCount)),
            "verifiedInvocations": .int(Int64(procedureArtifacts.verifiedInvocationCount)),
            "activationArtifacts": .int(Int64(procedureArtifacts.activationArtifactCount)),
            "activeAutomaticProcedures": .int(
                Int64(procedureArtifacts.activeAutomaticProcedureCount)
            ),
            "automaticSelectionEnabled": .bool(
                procedureArtifacts.automaticSelectionEnabled
            ),
            "generatedEvidenceCanQualify": .bool(false),
            "payloadFree": .bool(true),
        ])
        let evidenceSourcesValue: JSONValue = .object([
            "turnTraces": .object([
                "source": .string("turn_traces/*.jsonl"),
                "state": .string(traceSourceState.rawValue),
                "filesDiscovered": .int(Int64(traceURLs.count)),
                "filesRead": .int(Int64(traceFilesRead)),
            ]),
            "githubCommand": .object([
                "source": .string("workshop/github_command/{ops.jsonl,ops_base.json}"),
                "state": .string(operationalEvidence.githubCommandSourceState.rawValue),
                "transitionsRead": .int(Int64(transitions.count)),
            ]),
            "workshopExecutions": .object([
                "source": .string("workshop/executions/*/{execution.json,timeline.jsonl}"),
                "state": .string(operationalEvidence.workshopExecutionSourceState.rawValue),
                "executionDirectoriesRead": .int(
                    Int64(operationalEvidence.workshopExecutionDirectoriesRead)
                ),
                "timelineState": .string(operationalEvidence.workshopTimelineSourceState.rawValue),
                "timelineFilesRead": .int(Int64(operationalEvidence.workshopTimelineFilesRead)),
            ]),
            "procedureArtifacts": .object([
                "source": .string("living_fabric/procedures/"),
                "state": .string(procedureSourceRead.state.rawValue),
                "artifactsRead": .int(Int64(procedureArtifacts.artifactCount)),
                "invocationsRead": .int(Int64(procedureArtifacts.invocationCount)),
            ]),
            "privacyClassification": .object([
                "source": .string("living_fabric/review/privacy-classification.json"),
                "state": .string(artifactSourceState(privacyLoad.status).rawValue),
                "validationStatus": .string(privacyLoad.status),
            ]),
            "rollbackManifest": .object([
                "source": .string("living_fabric/shadow/{rollback-manifest.json,models/}"),
                "state": .string(artifactSourceState(rollbackLoad.status).rawValue),
                "validationStatus": .string(rollbackLoad.status),
            ]),
        ])
        let out: JSONValue = .object([
            "schema": .string("living-fabric-evidence.v1"),
            "generatedAt": .string(formatter.string(from: evaluatedAt)),
            // The actual selected window is evidence too. It makes the 21-file
            // and 100k-event safety bounds visible to operators, and separates
            // malformed input from an honest no-recommendations finding.
            "traceWindow": .object([
                "schema": .string("living-fabric.trace-window.v1"),
                "inputStatus": .string(
                    traceSourceState == .sourceUnreadable ? "source unreadable"
                        : (traceURLs.isEmpty ? "no trace files found" : "trace files evaluated")
                ),
                "filesDiscovered": .int(Int64(traceURLs.count)),
                "filesScanned": .int(Int64(selectedTraceURLs.count)),
                "filesOmittedBy21DayWindow": .int(
                    Int64(max(0, traceURLs.count - selectedTraceURLs.count))
                ),
                "physicalRowsScanned": .int(Int64(physicalTraceRowsScanned)),
                "malformedJSONRows": .int(Int64(malformedJSONTraceRows)),
                "rejectedEventRows": .int(Int64(rejectedTraceEventRows)),
                "eventsRetained": .int(Int64(traceEvents.count)),
                "eventsDiscardedByGlobalCap": .int(Int64(globallyDiscardedTraceEventCount)),
                "filesTruncatedByByteWindow": .int(Int64(byteWindowTruncatedFileCount)),
                "perFileRowLimit": .int(Int64(perFileRowLimit)),
                "perFileByteLimit": .int(Int64(perFileByteLimit)),
                "globalEventLimit": .int(Int64(maximumTraceEvents)),
            ]),
            "evidenceSources": evidenceSourcesValue,
            "wave6": readinessValue,
            "procedureCompilation": procedureValue,
        ])
        print((try? out.serialize(pretty: true)) ?? "\(out)")
    }

    static func probeSetForEval(_ probeSet: MemoryProbeSet, queryMode: String) -> MemoryProbeSet {
        let mode = normalizedEvalQueryMode(queryMode)
        guard mode == "compact" else { return probeSet }
        return MemoryProbeSet(
            version: probeSet.version,
            topK: probeSet.topK,
            probes: probeSet.probes.map { probe in
                MemoryProbe(
                    id: probe.id,
                    question: compactMemoryEvalQuery(probe.question),
                    expectMemoryId: probe.expectMemoryId,
                    expectAnySubstring: probe.expectAnySubstring
                )
            }
        )
    }

    static func normalizedEvalQueryMode(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered == "compact" ? "compact" : "natural"
    }

    static func compactMemoryEvalQuery(_ question: String) -> String {
        let stopwords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "can", "did", "do", "does",
            "for", "from", "how", "in", "is", "it", "kind", "of", "on", "or",
            "should", "the", "to", "want", "what", "when", "where", "which", "who",
            "why", "with"
        ]
        let tokens = question
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopwords.contains($0) }
        let compact = Array(tokens.prefix(12)).joined(separator: " ")
        return compact.isEmpty ? question : compact
    }
}
