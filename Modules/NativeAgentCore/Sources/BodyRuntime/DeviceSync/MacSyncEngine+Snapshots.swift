import Foundation
import PersistenceCore
import NativeAgentShared
import struct NativeAgentShared.MemoryRecord
import NativeAgentCore
import MindCore
import MacNerves
import DeskCore
import SenseCore
import ProviderRouting
import CommonCrypto
import CryptoKit
import AppKit
import AVFoundation
// Blueprint: | `MacSyncEngine+Snapshots.swift` | Revisioned payload/wire digests; host-owned Inspector and bounded chat projections. |

public typealias DeviceSyncSnapshotRows = any Encodable & Sendable

extension MacSyncEngine {
    nonisolated static let turnSummariesSnapshotFilename = "turn_summaries.json"
    nonisolated static let organismLivingStatusSnapshotFilename = "organism_living_status.json"
    private static var lastFaceBuild: (directory: URL, generation: UInt64, inputs: [String: PartFaceSnapshot], digest: SnapshotFileDigest)?

    public enum SnapshotWriteScope: Sendable {
        case standard
        case chatSessions
        case workActivity

        // Broader scopes retain an activity pass of their own.
        func including(_ other: Self?) -> Self {
            if self == .standard || other == .standard { return .standard }
            return self == .chatSessions || other == .chatSessions ? .chatSessions : .workActivity
        }
    }

    // MARK: - Snapshot writer
    // Raw policy fields must reach the phone even when the typed Mac model does not name them.

    public func writeSnapshots(
        forceHeavy: Bool = false,
        republish: Bool = false,
        includeMemories: Bool = false,
        includeChatTranscripts: Bool = false,
        scope: SnapshotWriteScope = .standard,
        repairFiles: Set<String> = []
    ) async {
        guard isActive, let snapshotDir else { return }
        if snapshotWriteInFlight {
            snapshotWriteQueuedScope = scope.including(snapshotWriteQueuedScope)
            snapshotWriteQueuedNeedsHeavy = snapshotWriteQueuedNeedsHeavy || forceHeavy
            snapshotWriteQueuedNeedsRepublish = snapshotWriteQueuedNeedsRepublish || republish
            snapshotWriteQueuedRepairs.formUnion(repairFiles)
            snapshotWriteQueuedNeedsMemories = snapshotWriteQueuedNeedsMemories || includeMemories
            snapshotWriteQueuedNeedsChatTranscripts =
                snapshotWriteQueuedNeedsChatTranscripts || includeChatTranscripts
            return
        }
        let lifecycleGeneration = snapshotLifecycleGeneration
        snapshotWriteInFlight = true
        defer {
            snapshotWriteInFlight = false
            if snapshotIntegrityReconcileQueued, isActive { requestSnapshotIntegrityPass() }
            if isActive, let queuedScope = snapshotWriteQueuedScope {
                snapshotWriteQueuedScope = nil
                let queuedForceHeavy = snapshotWriteQueuedNeedsHeavy
                let queuedRepublish = snapshotWriteQueuedNeedsRepublish
                let queuedRepairs = snapshotWriteQueuedRepairs
                let queuedIncludeMemories = snapshotWriteQueuedNeedsMemories
                let queuedIncludeChatTranscripts = snapshotWriteQueuedNeedsChatTranscripts
                snapshotWriteQueuedNeedsHeavy = false
                snapshotWriteQueuedNeedsRepublish = false
                snapshotWriteQueuedRepairs = []
                snapshotWriteQueuedNeedsMemories = false
                snapshotWriteQueuedNeedsChatTranscripts = false
                Task { @MainActor in
                    await self.writeSnapshots(
                        forceHeavy: queuedForceHeavy,
                        republish: queuedRepublish,
                        includeMemories: queuedIncludeMemories,
                        includeChatTranscripts: queuedIncludeChatTranscripts,
                        scope: queuedScope, repairFiles: queuedRepairs
                    )
                }
            }
        }

        // Admit the event burst before capture; merge heavier follow-up demand instead of rebuilding per observation.
        await Task.yield()
        guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
        let heavy = forceHeavy || snapshotWriteQueuedNeedsHeavy
        let repairs = repairFiles.union(snapshotWriteQueuedRepairs)
        if republish || snapshotWriteQueuedNeedsRepublish {
            snapshotFileDigests.removeAll()
            sync.bridge.invalidateMobileSnapshotPublication()
        }
        let memories = includeMemories || snapshotWriteQueuedNeedsMemories
        let transcripts = includeChatTranscripts || snapshotWriteQueuedNeedsChatTranscripts
        let mergedScope = scope.including(snapshotWriteQueuedScope)
        snapshotWriteQueuedScope = nil
        snapshotWriteQueuedNeedsHeavy = false
        snapshotWriteQueuedNeedsRepublish = false
        snapshotWriteQueuedRepairs = []
        snapshotWriteQueuedNeedsMemories = false
        snapshotWriteQueuedNeedsChatTranscripts = false
        await buildAndWriteSnapshots(
            forceHeavy: heavy, includeMemories: memories, includeChatTranscripts: transcripts, scope: mergedScope,
            snapshotDir: snapshotDir, lifecycleGeneration: lifecycleGeneration, repairFiles: repairs
        )
    }

    func encodeSnapshot<Value: Encodable & Sendable>(_ value: Value) async throws -> Data {
        try await MobileSnapshotBuilder.shared.encode(value)
    }

    /// Every scope adds the owner's current faces to the same publication and skip accounting as its other files.
    private func writeFaceSnapshots(
        in snapshotDir: URL, lifecycleGeneration: UInt64, readRevision: Double,
        changed: inout [String: Data], skipped: inout [String: String], attempted: inout Set<String>
    ) async -> [String: PartFaceSnapshot]? {
        guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return nil }
        do {
            let snapshots = try await sync.owner.pageFaces()
            if let built = Self.lastFaceBuild, built.directory == snapshotDir, built.generation == lifecycleGeneration,
               await MobileSnapshotBuilder.shared.build({ snapshots == built.inputs }),
               snapshotFileDigests["faces.json"] == built.digest, sync.bridge.lastPublishedMobileSnapshotStatus[.faces] != nil {
                guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return nil }
                attempted.insert("faces")
                return nil
            }
            let data = try await MobileSnapshotBuilder.shared.faces(snapshots, studio: MakeStudio(dataRoot: sync.dataRoot))
            await writeSnapshot(.built(data), to: "faces.json", in: snapshotDir,
                lifecycleGeneration: lifecycleGeneration, readRevision: readRevision,
                changed: &changed, skipped: &skipped, attempted: &attempted)
            return snapshots
        } catch {
            await writeSnapshot(.skipped("face encoding failed: \(error.localizedDescription)"), to: "faces.json", in: snapshotDir,
                lifecycleGeneration: lifecycleGeneration, readRevision: readRevision,
                changed: &changed, skipped: &skipped, attempted: &attempted)
            return nil
        }
    }

    private func buildAndWriteSnapshots(
        forceHeavy: Bool, includeMemories: Bool, includeChatTranscripts: Bool, scope: SnapshotWriteScope,
        snapshotDir: URL, lifecycleGeneration: UInt64, repairFiles: Set<String>
    ) async {
        if scope == .workActivity {
            await writeWorkActivitySnapshots(in: snapshotDir, lifecycleGeneration: lifecycleGeneration)
            return
        }
        requestWorkActivityPublication()
        let includeHeavySnapshots = forceHeavy
        let includeTranscriptSnapshots = forceHeavy || includeChatTranscripts
        if scope == .chatSessions, !forceHeavy, !includeMemories {
            await writeChatSessionSnapshots(
                includeTranscripts: includeChatTranscripts,
                snapshotDir: snapshotDir,
                lifecycleGeneration: lifecycleGeneration
            )
            return
        }

        let readRevision = Date().timeIntervalSince1970

        do {
            let api = try sync.owner
            let pass = MacSyncSnapshotPass(snapshotDir: snapshotDir, lifecycleGeneration: lifecycleGeneration,
                readRevision: readRevision)
            let reads = try await readSnapshotSources(pass, api: api, includeHeavySnapshots: includeHeavySnapshots,
                includeMemories: includeMemories, includeTranscriptSnapshots: includeTranscriptSnapshots)
            guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
            try await writeWorkSnapshots(reads, pass, api: api, repairFiles: repairFiles)
            try await writeRuntimeSnapshots(reads, pass, api: api, includeHeavySnapshots: includeHeavySnapshots,
                includeTranscriptSnapshots: includeTranscriptSnapshots, repairFiles: repairFiles)

            await commitSnapshots(pass.committedSnapshots, skipped: pass.skippedSnapshotGroups,
                attempted: pass.attemptedSnapshotGroups, in: snapshotDir,
                lifecycleGeneration: lifecycleGeneration, readRevision: readRevision)

        } catch {
            syncError = "Snapshot error: \(error.localizedDescription)"
        }
        await sync.retryRequestedResults()
    }

    /// Reads every source of a full pass concurrently; a failed read records its group and keeps the last good file.
    private func readSnapshotSources(
        _ pass: MacSyncSnapshotPass, api: NativeAgentEngine,
        includeHeavySnapshots: Bool, includeMemories: Bool, includeTranscriptSnapshots: Bool
    ) async throws -> MacSyncSnapshotReads {
        // Keep expensive inventory and readout projections out of the idle timer; explicit demand rebuilds them.
        async let sessionsTask = api.transcripts.list()
        async let healthTask = api.doctor.readHealth()
        async let memProposalsTask = api.pendingMemoryProposals()
        async let organismTask = self.organismLivingStatusSnapshot()
        async let overviewTask = api.workOverview()
        async let skillsTask: DeviceSyncSnapshotRows? = {
            guard includeHeavySnapshots else { return nil }
            return try await api.tools.refreshSkills()
        }()
        async let memoriesTask: [MemoryRecord]? = {
            guard includeHeavySnapshots || includeMemories else { return nil }
            let records = try await api.memory.activeMemories()
            let now = Date()
            return records.filter { record in
                MemoryRecordDisclosurePolicy.classify(record, at: now)?.permits(surface: "ios", personaID: nil) == true
                    && Self.memoryPhoneFields(record).allSatisfy { ContextSecretContentPolicy.redactedFragment($0) == $0 }
            }.map(MemoryRecord.init(phoneRow:))
        }()
        async let connectorsTask: [MobileConnectorSnapshot]? = {
            guard includeHeavySnapshots else { return nil }
            return try await api.connectors.mobileConnectors()
        }()
        async let toolCatalogTask: [MobileToolCatalogRecord]? = {
            guard includeHeavySnapshots else { return nil }
            return try await api.mobileToolCatalog()
        }()
        async let providersTask: (providers: DeviceSyncSnapshotRows, routing: ProviderRoutingSnapshot)? = {
            guard includeHeavySnapshots else { return nil }
            return try await api.providers.list()
        }()

        func recordFetchFailure(_ label: String, _ error: Error) { pass.recordFetchFailure(label, error) }
        func recordGroupSkip(_ label: String, _ reason: String) { pass.recordGroupSkip(label, reason) }

        var jobEvidence: [DeskExecutionEvidence]?
        var skills: DeviceSyncSnapshotRows?
        var memories: [MemoryRecord]?
        var connectors: [MobileConnectorSnapshot]?
        var toolCatalog: [MobileToolCatalogRecord]?
        var sessions: [ChatSession]?
        do { sessions = try await sessionsTask } catch {
            recordFetchFailure("sessions", error)
            recordGroupSkip("pinned_chat_sessions", "sessions unavailable: \(error.localizedDescription)")
            if includeTranscriptSnapshots {
                recordGroupSkip("chat_transcripts", "sessions unavailable: \(error.localizedDescription)")
            }
        }
        var health: RuntimeHealth?
        do { health = try await healthTask } catch { recordFetchFailure("health", error) }
        var memProposals: DeviceSyncSnapshotRows?
        do { memProposals = try await memProposalsTask } catch { recordFetchFailure("memory_proposals", error) }
        var organismLivingStatus = await organismTask
        // One Desk board supplies both attention and desk.json; notifications use the app's overview independently of phone sync.
        let (overview, deskItems, approvals, inbox, evidenceRows) = await overviewTask
        do { jobEvidence = try evidenceRows.get() } catch { recordFetchFailure("jobs", error) }
        if let deskItems, overview.unavailable.isEmpty {
            organismLivingStatus.needsUser = overview.needsYouCount > 0
            organismLivingStatus.needsAttention = (organismLivingStatus.needsAttention ?? false)
                || deskItems.contains { $0.status == .blocked }
        } else {
            // Replace an unreadable Desk projection with an unavailable marker so stale counters cannot appear current.
            nativeLog("[MacSyncEngine] overview read incomplete, publishing explicit status: \(overview.unavailable.joined(separator: "; "))")
        }
        organismLivingStatus = Self.organismLivingStatusAfterDeskRead(
            organismLivingStatus,
            deskReadSucceeded: deskItems != nil && overview.unavailable.isEmpty
        )
        var providers: (providers: DeviceSyncSnapshotRows, routing: ProviderRoutingSnapshot)?
        if includeHeavySnapshots {
            do { skills = try await skillsTask } catch { recordFetchFailure("skills_snapshot", error) }
        }
        if includeHeavySnapshots || includeMemories {
            do { memories = try await memoriesTask } catch { recordFetchFailure("memories", error) }
        }
        if includeHeavySnapshots {
            do { connectors = try await connectorsTask } catch { recordFetchFailure("connectors", error) }
            do { toolCatalog = try await toolCatalogTask } catch {
                recordFetchFailure("tools_snapshot", error)
            }
            // Provider catalog refresh is expensive, so publish only on demand.
            do { providers = try await providersTask } catch { recordFetchFailure("providers", error) }
        }
        return MacSyncSnapshotReads(sessions: sessions, health: health, memProposals: memProposals,
            organismLivingStatus: organismLivingStatus, overview: overview, deskItems: deskItems,
            approvals: approvals, inbox: inbox, jobEvidence: jobEvidence, skills: skills, memories: memories,
            connectors: connectors, toolCatalog: toolCatalog, providers: providers)
    }

    /// Work, Desk, authority and preference projections of a full pass.
    private func writeWorkSnapshots(
        _ reads: MacSyncSnapshotReads, _ pass: MacSyncSnapshotPass, api: NativeAgentEngine, repairFiles: Set<String>
    ) async throws {
        let snapshotDir = pass.snapshotDir
        let (overview, deskItems, jobEvidence) = (reads.overview, reads.deskItems, reads.jobEvidence)
        let (skills, toolCatalog, memories) = (reads.skills, reads.toolCatalog, reads.memories)
        let (approvals, inbox) = (reads.approvals, reads.inbox)
        func recordFetchFailure(_ label: String, _ error: Error) { pass.recordFetchFailure(label, error) }
        func recordGroupSkip(_ label: String, _ reason: String) { pass.recordGroupSkip(label, reason) }
        func writeData(_ data: Data, to filename: String) async {
            await publish(.built(data), to: filename)
        }
        func write<T: Encodable & Sendable>(_ value: T, to filename: String) async { await passWrite(value, to: filename, pass) }
        func publish(_ build: SnapshotGroupBuild, to filename: String) async { await passPublish(build, to: filename, pass) }

        await publish(await helpersSnapshotData(), to: "helpers_agents.json")
        do {
            let mobileOverview = try await MobileSnapshotBuilder.shared.state(
                overview, storedAt: snapshotDir.appendingPathComponent("work_overview.json"),
                rebuilding: repairFiles.contains("work_overview.json"), clock: MobileSnapshotBuilder.CapturedClock.self,
                retainingClocks: {
                    $0.capturedAt = $1.capturedAt
                }, stamp: { value, previous, now in
                    let changedAt: Date
                    if let previous {
                        guard let prior = NativeTimestampFormat.parseISO8601(previous.capturedAt) else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        changedAt = max(now, prior.addingTimeInterval(0.001))
                    } else { changedAt = now }
                    value.capturedAt = NativeTimestampFormat.fractionalZulu(changedAt)
                })
            await write(mobileOverview, to: "work_overview.json")
        } catch { recordFetchFailure("work_overview", error) }
        if let deskItems {
            do {
                let projection = try await MobileSnapshotBuilder.shared.desk(deskItems, evidence: jobEvidence)
                await writeData(projection.data, to: "desk.json")
                // Publish omissions explicitly; received row count cannot prove what the bounds dropped.
                await write(
                    MobileDeskProjectionReport(
                        totalRows: deskItems.count,
                        includedRows: projection.included
                    ),
                    to: "desk_bounds.json"
                )
                // Include full priority-item text so the phone can open needed work away from the Mac.
                let readingCopies = try await MobileSnapshotBuilder.shared
                    .deskReadingCopies(deskItems)
                await writeData(readingCopies.data, to: "desk_details.json")
            } catch {
                recordFetchFailure("desk", error)
            }
        }
        if let skills { await write(skills, to: "skills_snapshot.json") }
        if let toolCatalog { await write(toolCatalog, to: "tools_snapshot.json") }
        if let memories { await write(memories, to: "memories.json") }
        async let personalityFetch: PersonalityProfile? = {
            do { return try await api.persona.loadProfile() } catch {
                nativeLog("[MacSyncEngine] snapshot fetch failed for personality — keeping last good file: %@", "\(error)")
                return nil
            }
        }()
        async let approvalsData: SnapshotGroupBuild = self.nativeApprovalsSnapshotData(approvals)
        async let inboxData: SnapshotGroupBuild = self.nativeInboxSnapshotData(inbox)
        let (personalityProfile, approvalsRaw, inboxRaw) = await (
            personalityFetch,
            approvalsData,
            inboxData
        )
        do { await writeData(try await api.trust.snapshotData(), to: "trust_policy.json") }
        catch { recordFetchFailure("trust_policy", error) }
        do {
            await write(try await api.macIntegration.macIntegrationPermissionsSnapshot(), to: "mac_integration_permissions.json")
        } catch {
            recordFetchFailure("mac_integration_permissions", error)
        }
        await write(api.layout.availability, to: "ui_layout.json")
        let voiceName = VoicePreference.name()
        let nativeVoice = VoicePreference.nativeVoice(identifier: voiceName)
        await write(MobileVoicePreference(name: voiceName, quiet: VoicePreference.quiet(),
                    nativeIdentifier: nativeVoice?.identifier, nativeName: nativeVoice?.name, nativeLanguage: nativeVoice?.language),
                    to: "voice_preference.json")
        if let personalityProfile {
            await write(personalityProfile, to: "personality.json")
        } else {
            recordGroupSkip("personality", "native personality snapshot unavailable")
        }
        await publish(approvalsRaw, to: "approvals.json")
        await publish(inboxRaw, to: "inbox.json")
    }

    /// Inspector, run, chat, health, organism and routing projections of a full pass.
    private func writeRuntimeSnapshots(
        _ reads: MacSyncSnapshotReads, _ pass: MacSyncSnapshotPass, api: NativeAgentEngine,
        includeHeavySnapshots: Bool, includeTranscriptSnapshots: Bool, repairFiles: Set<String>
    ) async throws {
        let snapshotDir = pass.snapshotDir
        let (connectors, sessions, health) = (reads.connectors, reads.sessions, reads.health)
        let (organismLivingStatus, memProposals, providers) = (reads.organismLivingStatus, reads.memProposals, reads.providers)
        func recordFetchFailure(_ label: String, _ error: Error) { pass.recordFetchFailure(label, error) }
        func recordGroupSkip(_ label: String, _ reason: String) { pass.recordGroupSkip(label, reason) }
        func writeData(_ data: Data, to filename: String) async {
            await publish(.built(data), to: filename)
        }
        func write<T: Encodable & Sendable>(_ value: T, to filename: String) async { await passWrite(value, to: filename, pass) }
        func publish(_ build: SnapshotGroupBuild, to filename: String) async { await passPublish(build, to: filename, pass) }

        if includeHeavySnapshots {
            // Share Inspector's persisted projection so phone summaries cannot diverge.
            async let turnSummariesData: Data? = api.trace.summaryData()
            async let knowledgeGraphData: SnapshotGroupBuild = self.nativeKnowledgeGraphSnapshotData()
            async let runsFetch: [RunRecord]? = {
                let rows = try? await api.runs.refresh(dataRoot: api.dataRoot)
                if rows == nil {
                    nativeLog("[MacSyncEngine] runs ledger unreadable — keeping last good runs.json")
                }
                return rows
            }()
            let (turnSummariesRaw, knowledgeGraphRaw, runsAll) = await (
                turnSummariesData,
                knowledgeGraphData,
                runsFetch
            )
            await publish(
                turnSummariesRaw.map(SnapshotGroupBuild.built) ?? .skipped("turn traces unreadable or incomplete"),
                to: Self.turnSummariesSnapshotFilename)
            await publish(knowledgeGraphRaw, to: "knowledge_graph.json")
            if let runsAll {
                // Redact, then bound, synced prompt/output/error fields without changing the stored runs: CloudKit gets what the transcript projection gives.
                @Sendable func clip(_ raw: String?, _ cap: Int) -> String? {
                    guard let raw else { return nil }
                    let s = TurnSecretRedactor.redactText(raw)
                    guard s.count > cap else { return s }
                    return String(s.prefix(cap)) + "… [clipped for sync]"
                }
                let runsData = await MobileSnapshotBuilder.shared.build { () -> SnapshotGroupBuild in
                    let encoder = TurnSummaryComputer.makeEncoder()
                    let recent = runsAll
                        .sorted { $0.createdAt > $1.createdAt }
                        .prefix(50)
                        .map { run -> RunRecord in
                            var r = run
                            r.prompt = clip(r.prompt, 2_000)
                            r.output = clip(r.output, 4_000)
                            r.error = clip(r.error, 2_000)
                            return r
                        }
                    do {
                        let bounded = try EncodedPrefix.largestPrefix(
                            count: recent.count, maximumEncodedBytes: 6 * 1024 * 1024,
                            encode: { try encoder.encode(Array(recent.prefix($0))) }
                        )
                        guard recent.isEmpty || bounded.included > 0 else { return .skipped("Run snapshot exceeds 6 MiB") }
                        return .built(bounded.data)
                    } catch { return .skipped(error.localizedDescription) }
                }
                await publish(runsData, to: "runs.json")
            } else {
                recordGroupSkip("runs", "run ledger unavailable or unreadable")
            }
        }
        if let connectors { await write(connectors, to: "connectors.json") }
        // Failed session reads cannot blank dependent pinned chats or transcripts.
        if let sessions {
            await write(sessions, to: "sessions.json")
            let navigation = api.transcripts.navigation(for: sessions)
            await write(navigation, to: "pinned_chat_sessions.json")
            if includeTranscriptSnapshots {
                do {
                    let transcriptSessions = try transcriptSnapshotSessions(from: sessions, navigation: navigation)
                    let transcripts: [ChatTranscriptSnapshot] = transcriptSessions.isEmpty
                        ? []
                        : await chatTranscriptSnapshots(for: transcriptSessions, api: api)
                    await write(transcripts, to: "chat_transcripts.json")
                } catch {
                    recordGroupSkip("chat_transcripts", error.localizedDescription)
                }
            }
        }
        if let health {
            do {
                let mobileHealth = try await MobileSnapshotBuilder.shared.health(
                    health, storedAt: snapshotDir.appendingPathComponent("health.json"),
                    rebuilding: repairFiles.contains("health.json"))
                await writeData(mobileHealth, to: "health.json")
            } catch { recordFetchFailure("health", error) }
        }
        await publish(await telegramSnapshotData(in: snapshotDir, rebuilding: repairFiles.contains("telegram.json")), to: "telegram.json")
        do {
            let mobileOrganism = try await MobileSnapshotBuilder.shared.state(
                organismLivingStatus, storedAt: snapshotDir.appendingPathComponent(Self.organismLivingStatusSnapshotFilename),
                rebuilding: repairFiles.contains(Self.organismLivingStatusSnapshotFilename),
                clock: MobileSnapshotBuilder.GeneratedClock.self,
                retainingClocks: { $0.generatedAt = $1.generatedAt }, stamp: { value, previous, now in
                    value.generatedAt = previous.map { max(now, $0.generatedAt.addingTimeInterval(1)) } ?? now
                })
            await write(mobileOrganism, to: Self.organismLivingStatusSnapshotFilename)
        } catch { recordFetchFailure("organism_living_status", error) }
        if let memProposals { await write(memProposals, to: "memory_proposals.json") }
        await write([JSONValue](), to: "training_proposals.json")
        if let providers { await write(providers.providers, to: "providers.json") }

        // Publish canonical surface routing so both phone pickers use the Mac's model and effort under one revision.
        if includeHeavySnapshots {
            await publish(
                await self.modelPreferencesSnapshotData(providers?.routing),
                to: "model_preferences.json"
            )
        }
    }

    private func passWrite<T: Encodable & Sendable>(_ value: T, to filename: String, _ pass: MacSyncSnapshotPass) async {
        await writeSnapshot(value, to: filename, in: pass.snapshotDir,
            lifecycleGeneration: pass.lifecycleGeneration, readRevision: pass.readRevision,
            changed: &pass.committedSnapshots, skipped: &pass.skippedSnapshotGroups,
            attempted: &pass.attemptedSnapshotGroups)
    }

    private func passPublish(_ build: SnapshotGroupBuild, to filename: String, _ pass: MacSyncSnapshotPass) async {
        await writeSnapshot(build, to: filename, in: pass.snapshotDir,
            lifecycleGeneration: pass.lifecycleGeneration, readRevision: pass.readRevision,
            changed: &pass.committedSnapshots, skipped: &pass.skippedSnapshotGroups,
            attempted: &pass.attemptedSnapshotGroups)
    }

    /// One full snapshot pass: where it publishes, and the groups it attempted, skipped and changed.
    private final class MacSyncSnapshotPass {
        let snapshotDir: URL
        let lifecycleGeneration: UInt64
        let readRevision: Double
        var attemptedSnapshotGroups = Set<String>()
        var skippedSnapshotGroups: [String: String] = [:]
        var committedSnapshots: [String: Data] = [:]

        init(snapshotDir: URL, lifecycleGeneration: UInt64, readRevision: Double) {
            self.snapshotDir = snapshotDir
            self.lifecycleGeneration = lifecycleGeneration
            self.readRevision = readRevision
        }

        func recordFetchFailure(_ label: String, _ error: Error) {
            let reason = error.localizedDescription
            attemptedSnapshotGroups.insert(label)
            skippedSnapshotGroups[label] = reason
            nativeLog("[MacSyncEngine] snapshot fetch failed for %@ — keeping last good file: %@", label, "\(error)")
        }
        func recordGroupSkip(_ label: String, _ reason: String) {
            attemptedSnapshotGroups.insert(label)
            skippedSnapshotGroups[label] = reason
            nativeLog("[MacSyncEngine] snapshot group %@ SKIPPED — keeping last good file: %@", label, reason)
        }
    }

    /// What one full pass read, before any of it is written.
    private struct MacSyncSnapshotReads {
        let sessions: [ChatSession]?
        let health: RuntimeHealth?
        let memProposals: DeviceSyncSnapshotRows?
        let organismLivingStatus: OrganismLivingStatusFile
        let overview: WorkOverview
        let deskItems: [DeskItem]?
        let approvals: Result<[ApprovalRequest], Error>
        let inbox: Result<[InboxItemRecord], Error>
        let jobEvidence: [DeskExecutionEvidence]?
        let skills: DeviceSyncSnapshotRows?
        let memories: [MemoryRecord]?
        let connectors: [MobileConnectorSnapshot]?
        let toolCatalog: [MobileToolCatalogRecord]?
        let providers: (providers: DeviceSyncSnapshotRows, routing: ProviderRoutingSnapshot)?
    }

    /// Chat edges rebuild only the canonical index, pins and needed transcripts, avoiding unrelated projections.
    private func writeChatSessionSnapshots(
        includeTranscripts: Bool,
        snapshotDir: URL,
        lifecycleGeneration: UInt64
    ) async {
        let readRevision = Date().timeIntervalSince1970
        var changed: [String: Data] = [:]
        var skipped: [String: String] = [:]
        var attempted = Set<String>()
        func write<T: Encodable & Sendable>(_ value: T, filename: String) async {
            await writeSnapshot(value, to: filename, in: snapshotDir,
                lifecycleGeneration: lifecycleGeneration, readRevision: readRevision,
                changed: &changed, skipped: &skipped, attempted: &attempted)
        }
        do {
            let api = try sync.owner
            let sessions = try await api.transcripts.list()
            guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
            let navigation = api.transcripts.navigation(for: sessions)
            await write(sessions, filename: "sessions.json")
            await write(navigation, filename: "pinned_chat_sessions.json")
            if includeTranscripts {
                do {
                    let selected = try transcriptSnapshotSessions(from: sessions, navigation: navigation)
                    await write(await chatTranscriptSnapshots(for: selected, api: api), filename: "chat_transcripts.json")
                } catch {
                    attempted.insert("chat_transcripts")
                    skipped["chat_transcripts"] = "transcripts unavailable: \(error.localizedDescription)"
                }
            }
        } catch {
            attempted = ["sessions", "pinned_chat_sessions"]
            if includeTranscripts { attempted.insert("chat_transcripts") }
            for group in attempted { skipped[group] = "sessions unavailable: \(error.localizedDescription)" }
        }
        await commitSnapshots(changed, skipped: skipped, attempted: attempted, in: snapshotDir,
            lifecycleGeneration: lifecycleGeneration, readRevision: readRevision)
        await sync.retryRequestedResults()
    }

    func writeSnapshot<T: Encodable & Sendable>(
        _ value: T, to filename: String, in snapshotDir: URL,
        lifecycleGeneration: UInt64, readRevision: Double,
        changed: inout [String: Data], skipped: inout [String: String], attempted: inout Set<String>
    ) async {
        let build: SnapshotGroupBuild
        do { build = .built(try await encodeSnapshot(value)) }
        catch { build = .skipped("encoding failed: \(error.localizedDescription)") }
        await writeSnapshot(build, to: filename, in: snapshotDir,
            lifecycleGeneration: lifecycleGeneration, readRevision: readRevision,
            changed: &changed, skipped: &skipped, attempted: &attempted)
    }

    private func writeSnapshot(
        _ build: SnapshotGroupBuild, to filename: String, in snapshotDir: URL,
        lifecycleGeneration: UInt64, readRevision: Double,
        changed: inout [String: Data], skipped: inout [String: String], attempted: inout Set<String>
    ) async {
        guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
        let group = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        attempted.insert(group)
        switch build {
        case .skipped(let reason): skipped[group] = reason
        case .built(let data):
            switch await writeSnapshotData(data, to: filename, in: snapshotDir,
                lifecycleGeneration: lifecycleGeneration, readRevision: readRevision) {
            case .changed(let bytes): changed[filename] = bytes
            case .failed(let reason): skipped[group] = "write failed: \(reason)"
            case .unchanged: break
            }
        }
    }

    /// Every scope holds the snapshot writer through publication and staleness reconciliation.
    func commitSnapshots(
        _ changed: [String: Data], skipped: [String: String], attempted: Set<String>, in snapshotDir: URL,
        lifecycleGeneration: UInt64, readRevision: Double
    ) async {
        var committedSnapshots = changed
        var skippedSnapshotGroups = skipped
        var attemptedSnapshotGroups = attempted
        let faceInputs = await writeFaceSnapshots(in: snapshotDir, lifecycleGeneration: lifecycleGeneration, readRevision: readRevision,
            changed: &committedSnapshots, skipped: &skippedSnapshotGroups, attempted: &attemptedSnapshotGroups)
        guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
        let digests = snapshotFileDigests
        let prunedDigests = await MobileSnapshotBuilder.shared.build { Self.digestsPrunedToExistingFiles(digests, in: snapshotDir) }
        if prunedDigests.count != snapshotFileDigests.count {
            snapshotFileDigests = prunedDigests
            await saveSnapshotDigests()
        }
        if !committedSnapshots.isEmpty {
            let failed = await publishChangedSnapshots(
                committedSnapshots,
                in: snapshotDir,
                lifecycleGeneration: lifecycleGeneration
            )
            guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
            var publicationSkips = Self.publishFailureSkips(failed, changed: Set(committedSnapshots.keys))
            if let omissions = skippedSnapshotGroups["faces"], let failure = publicationSkips["faces"] {
                publicationSkips["faces"] = omissions + "; " + failure
            }
            skippedSnapshotGroups.merge(publicationSkips) { _, publish in publish }
        }
        if let faceInputs, skippedSnapshotGroups["faces"] == nil, !Task.isCancelled,
           lifecycleGeneration == snapshotLifecycleGeneration, isActive, let digest = snapshotFileDigests["faces.json"] {
            Self.lastFaceBuild = (snapshotDir, lifecycleGeneration, faceInputs, digest)
        }
        let currentSkips = skippedSnapshotGroups
        let currentAttempts = attemptedSnapshotGroups
        let unresolvedSnapshotGroups = await MobileSnapshotBuilder.shared.build {
            Self.updateSnapshotSkipState(
                currentSkips: currentSkips, attemptedGroups: currentAttempts,
                dataRoot: PersistenceCore.defaultDataRoot()
            )
        }
        guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
        if unresolvedSnapshotGroups.isEmpty {
            let questionsFailure = await sync.needsUser.failure
            guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
            syncError = questionsFailure.map { "Desk questions remain owed: " + $0 }
        } else {
            let messages = NAMobileSnapshotGroup.stalenessMessages(unresolvedSnapshotGroups)
            syncError = messages.keys.sorted().first.flatMap { messages[$0] }
                ?? "iPhone updates could not be prepared. The last received data is still available. Open Connection in Settings to check the Mac link."
        }
        committedSnapshots = [:]
        if let stalenessMarker = await MobileSnapshotBuilder.shared.build({
            Self.snapshotStalenessMarkerData(unresolvedGroups: unresolvedSnapshotGroups)
        }) {
            var markerAttempts = Set<String>()
            await writeSnapshot(.built(stalenessMarker), to: Self.snapshotStalenessFilename, in: snapshotDir,
                lifecycleGeneration: lifecycleGeneration, readRevision: readRevision,
                changed: &committedSnapshots, skipped: &skippedSnapshotGroups, attempted: &markerAttempts)
        }
        if !committedSnapshots.isEmpty {
            await publishChangedSnapshots(
                committedSnapshots,
                in: snapshotDir,
                lifecycleGeneration: lifecycleGeneration
            )
        }
    }

    /// Publish before checkpointing; failed groups must invalidate their digests for retry.
    @discardableResult
    func publishChangedSnapshots(
        _ committed: [String: Data],
        in snapshotDir: URL,
        lifecycleGeneration: UInt64
    ) async -> [NAMobileSnapshotGroup: DeviceSyncError] {
        let changedFilenames = Set(committed.keys)
        let groups = NAMobileSnapshotGroup.groups(containingAny: changedFilenames)
        let failures = await sync.bridge.publishMobileSnapshotStatus(
            groups: groups,
            snapshotDirectory: snapshotDir,
            committed: committed,
            shouldPublish: { self.snapshotLifecycleGeneration == lifecycleGeneration && self.isActive }
        ) ?? [:]
        guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return [:] }
        if !failures.isEmpty {
            let messages = NAMobileSnapshotGroup.stalenessMessages(Self.publishFailureSkips(failures, changed: changedFilenames))
            syncError = messages.keys.sorted().first.flatMap { messages[$0] }
            forgetSnapshotDigests(for: changedFilenames)
        }
        await saveSnapshotDigests()
        return failures
    }

    /// Mark only files this pass changed; unchanged phone copies must not acquire badges that cannot clear until a rewrite.
    nonisolated static func publishFailureSkips(_ failures: [NAMobileSnapshotGroup: DeviceSyncError],
                                                changed: Set<String>) -> [String: String] {
        var skips: [String: String] = [:]
        for (group, reason) in failures {
            for filename in group.filenames where changed.contains(filename) {
                let page = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
                skips[page] = "publish failed (\(group.rawValue)): \(reason.localizedDescription)"
                skips["_message.\(page)"] = NAMobileSnapshotGroup.stalePageMessage(page, recovery: reason.snapshotRecoveryMessage)
            }
        }
        return skips
    }

    private func transcriptSnapshotSessions(from sessions: [ChatSession], navigation: ChatSessionNavigation) throws -> [ChatSession] {
        let mobileSourceKey = try NativeAgentICloudBridgeConstants.mobileSourceKey
        var seen = Set<String>()
        var out: [ChatSession] = []
        func append(_ session: ChatSession?) {
            guard let session,
                  session.archived != true,
                  seen.insert(session.id).inserted else { return }
            out.append(session)
        }
        // The person's current conversation has first priority regardless of source.
        let currentID = navigation.anchor?.sessionId
        append(sessions.first { $0.id == currentID })
        // Retain one Mac main and one phone main; isMainAppSourceKey includes both.
        append(sessions.first(where: {
            $0.sourceKey?.trimmingCharacters(in: .whitespacesAndNewlines) == "app"
                && $0.archived != true
        }))
        append(sessions.first(where: {
            ($0.sourceKey?.trimmingCharacters(in: .whitespacesAndNewlines) == mobileSourceKey
                || (($0.source ?? "").lowercased() == "ios" && ($0.sourceKey ?? "").isEmpty))
                && $0.archived != true
        }))
        let remainingPins = navigation.rows.filter(\.isPinned).map(\.session).filter { !seen.contains($0.id) && $0.archived != true }
        let room = max(0, Self.transcriptSnapshotSessionCeiling - out.count)
        // Newest pins win both count and byte limits; omitted history remains explicitly unsynced.
        let selectedPins = Array(
            remainingPins
                .sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
                .prefix(room)
        )
        for session in selectedPins {
            append(session)
        }
        // Fill remaining transcript capacity with recent history; agent-bridge and bot chats require an anchor or pin.
        for session in sessions.sorted(by: { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }) {
            guard out.count < Self.transcriptSnapshotSessionCeiling else { break }
            guard !["agent-bridge", "bot"].contains((session.source ?? "").lowercased()) else { continue }
            append(session)
        }
        return out
    }

    /// Failed publication invalidates those digests so the next pass rewrites and republishes the files.
    private func forgetSnapshotDigests(for filenames: Set<String>) {
        guard !filenames.isEmpty else { return }
        for filename in filenames {
            snapshotFileDigests.removeValue(forKey: filename)
        }
    }

    /// Maximum transcript sessions per publication; encoded bytes are bounded separately.
    static let transcriptSnapshotSessionCeiling = 16
    public nonisolated static let transcriptSnapshotRowLimit = 80

    /// Raw chat_transcripts.json budget; the status codec also enforces 8 MiB raw and 800 KiB published limits.
    nonisolated static let chatTranscriptGroupByteBudget = 2 * 1024 * 1024

    private func chatTranscriptSnapshots(for sessions: [ChatSession], api: NativeAgentEngine) async -> [ChatTranscriptSnapshot] {
        var out: [ChatTranscriptSnapshot] = []
        let exchanges: Result<[OtherRoomExchange], Error>
        do { exchanges = .success(try await api.mobileOtherRoomExchanges()) }
        catch { exchanges = .failure(error) }
        var used = 2
        for session in sessions {
            var snapshot = ChatTranscriptSnapshot(sessionId: session.id, messages: [],
                transcriptGeneration: session.transcriptGeneration)
            do {
                snapshot = try await api.mobileChatMessages(sessionId: session.id, limit: Self.transcriptSnapshotRowLimit)
                snapshot.transcriptGeneration = session.transcriptGeneration
                snapshot.messages = await MobileSnapshotBuilder.shared.build { [messages = snapshot.messages] in
                    messages.map { row in
                        var copy = row
                        copy.content = Self.truncateTranscriptContent(row.content)
                        return copy
                    }
                }
                let since = snapshot.messages.first.flatMap { UserDisplayFormatters.parseISOTimestamp($0.createdAt) }
                snapshot.otherRooms = try exchanges.get().filter { event in
                    event.sessionID != session.id && since.map { event.at >= $0 } == true
                }
            } catch {
                snapshot.readError = error.localizedDescription
            }
            let encodedBytes = (try? await MobileSnapshotBuilder.shared.encode(snapshot))?.count
                ?? Self.chatTranscriptGroupByteBudget
            var candidates = out + [snapshot]
            var size = used + encodedBytes + (out.isEmpty ? 0 : 1)
            if size > Self.chatTranscriptGroupByteBudget {
                // Prefer conversation rows to optional image previews, including sessions already selected.
                candidates = await MobileSnapshotBuilder.shared.build { [candidates] in
                    candidates.map { $0.omittingAttachmentPreviews() }
                }
                size = (try? await MobileSnapshotBuilder.shared.encode(candidates))?.count
                    ?? (Self.chatTranscriptGroupByteBudget + 1)
            }
            guard size <= Self.chatTranscriptGroupByteBudget else { break }
            used = size
            out = candidates
        }
        // The final index read is required evidence for every transcript.
        do {
            let generationsAfter = try await api.transcripts.transcriptGenerations()
            out = out.filter { snapshot in
                guard let after = generationsAfter[snapshot.sessionId] else { return false }
                return after == snapshot.transcriptGeneration
            }
        } catch {
            out = out.map { snapshot in
                var unavailable = ChatTranscriptSnapshot(sessionId: snapshot.sessionId, messages: [], transcriptGeneration: nil)
                unavailable.readError = "Transcript generation is unavailable: \(error.localizedDescription)"
                return unavailable
            }
        }
        // Keep priority sessions within the compressed budget; omissions remain unsynced, never authoritative empty transcripts.
        let candidates = out
        return await MobileSnapshotBuilder.shared.build {
            let encoder = TurnSummaryComputer.makeEncoder()
            var out = candidates
            // Apply preview reduction against the compressed envelope budget before dropping sessions.
            do {
                _ = try NAMobileSnapshotStatusCodec.encode(
                    group: .chat, files: ["chat_transcripts.json": try MobileSnapshotBuilder.wireBytes(encoder.encode(out))])
                return out
            } catch DeviceSyncError.payloadTooLarge {
                out = out.map { $0.omittingAttachmentPreviews() }
            } catch {
                return out
            }
            while !out.isEmpty {
                do {
                    _ = try NAMobileSnapshotStatusCodec.encode(
                        group: .chat,
                        files: ["chat_transcripts.json": try MobileSnapshotBuilder.wireBytes(encoder.encode(out))]
                    )
                    break
                } catch DeviceSyncError.payloadTooLarge {
                    out.removeLast()
                } catch {
                    // Other codec failures remain publication errors; they cannot justify dropping history.
                    break
                }
            }
            return out
        }
    }

    private nonisolated static func truncateTranscriptContent(_ content: String, maxCharacters: Int = 6_000) -> String {
        guard content.count > maxCharacters else { return content }
        return String(content.prefix(maxCharacters)) + "\n[truncated for iPhone snapshot]"
    }

    private nonisolated static let revisionedSnapshotFiles: Set<String> = [
        "approvals.json", "inbox.json", "memories.json", "memory_proposals.json"
    ]

    nonisolated static func revisionedSnapshotData(_ data: Data, revision: Double) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["revision": revision,
            "value": JSONSerialization.jsonObject(with: data)], options: [.sortedKeys])
    }

    func writeSnapshotData(
        _ data: Data,
        to filename: String,
        in snapshotDir: URL,
        lifecycleGeneration expectedLifecycleGeneration: UInt64,
        readRevision: Double
    ) async -> SnapshotFileWriteResult {
        var data = data
        if let cap = Self.rowFileByteCaps[filename] {
            let bounded = await MobileSnapshotBuilder.shared.build { [data] in Self.newestRows(data, maxBytes: cap) }
            if bounded.dropped > 0 {
                nativeLog("[MacSyncEngine] %@ over %d bytes — kept the newest rows, dropped %d", filename, cap, bounded.dropped)
            }
            data = bounded.data
        }
        // One byte representation for every builder; no filename-specific payload filtering.
        do {
            data = try await MobileSnapshotBuilder.shared.build { [data] in
                try MobileSnapshotBuilder.wireBytes(data)
            }
        } catch { return .failed("Snapshot state could not be compared: \(error.localizedDescription)") }
        let digest = await MobileSnapshotBuilder.shared.build { [data] in MacSyncSnapshotIntegrity.digest(data) }
        guard expectedLifecycleGeneration == snapshotLifecycleGeneration, isActive else { return .unchanged }
        let url = snapshotDir.appendingPathComponent(filename)
        if snapshotFileDigests[filename]?.payload == digest { return .unchanged }
        if Self.revisionedSnapshotFiles.contains(filename) {
            do { data = try await MobileSnapshotBuilder.shared.build { [data] in try Self.revisionedSnapshotData(data, revision: readRevision) } }
            catch { return .failed(error.localizedDescription) }
        }
        let wireDigest = await MobileSnapshotBuilder.shared.build { [data] in MacSyncSnapshotIntegrity.digest(data) }
        do {
            let equal = try await VolumeIO.run { [data] in
                do { return try VolumeIO.contents(of: url) == data }
                catch { if Self.isNoSuchFileError(error) { return false }; throw error }
            }
            guard expectedLifecycleGeneration == snapshotLifecycleGeneration, isActive else { return .unchanged }
            if equal {
                // A lost digest can owe publication of these bytes without replacing the file.
                snapshotFileDigests[filename] = SnapshotFileDigest(payload: digest, wire: wireDigest)
                return .changed(data)
            }
        } catch {
            // These bytes are a derived copy; an unreadable comparison cannot block its canonical producer's replacement.
            nativeLog("[MacSyncEngine] Rebuilding unreadable snapshot %@: %@", filename, error.localizedDescription)
        }
        guard expectedLifecycleGeneration == snapshotLifecycleGeneration, isActive, !Task.isCancelled else { return .unchanged }
        // Await the coordinated write before recording its digest or admitting another snapshot pass.
        let writeResult = await VolumeIO.result { [data, url] in
            Self.coordinatedWriteReturningError(data: data, to: url)
        }
        let writeError: String?
        switch writeResult {
        case .success(let error): writeError = error
        case .failure(let error): writeError = "Snapshot commit is unverified: \(error.localizedDescription). Reconcile this file before publishing."
        }
        // Foundation writes cannot cancel after entry; invalidate captured-cache digests before admitting a restarted pass.
        guard expectedLifecycleGeneration == snapshotLifecycleGeneration,
              isActive else {
            snapshotFileDigests.removeValue(forKey: filename)
            await saveSnapshotDigests()
            return .unchanged
        }
        if let writeError {
            snapshotFileDigests.removeValue(forKey: filename)
            await saveSnapshotDigests()
            syncError = "Snapshot write failed for \(filename): \(writeError)"
            return .failed(writeError)
        }
        snapshotFileDigests[filename] = SnapshotFileDigest(payload: digest, wire: wireDigest)
        return .changed(data)
    }

    /// Bound each row file below the shared 800 KiB published/8 MiB raw envelope so one store cannot fail its siblings.
    nonisolated static let rowFileByteCaps: [String: Int] = [
        "sessions.json": 1_048_576,
        "memories.json": 1_048_576,
    ]

    /// Byte bounds prefer newest rows but preserve their source order.
    nonisolated static func newestRows(_ data: Data, maxBytes: Int) -> (data: Data, dropped: Int) {
        guard data.count > maxBytes,
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return (data, 0) }
        func stamp(_ row: Any) -> String {
            let object = row as? [String: Any]
            return object?["updatedAt"] as? String ?? object?["createdAt"] as? String ?? ""
        }
        let newestFirst = rows.indices.sorted { stamp(rows[$0]) > stamp(rows[$1]) }
        guard let bounded = try? EncodedPrefix.largestPrefix(
            count: max(0, rows.count - 1), maximumEncodedBytes: maxBytes,
            encode: { count in
                let kept = Set(newestFirst.prefix(count))
                return try JSONSerialization.data(withJSONObject: rows.indices.filter(kept.contains).map { rows[$0] },
                                                  options: [.sortedKeys])
            }
        ) else { return (data, 0) }
        return (bounded.data, rows.count - bounded.included)
    }

    nonisolated static func digestsPrunedToExistingFiles(_ digests: [String: SnapshotFileDigest], in dir: URL) -> [String: SnapshotFileDigest] {
        digests.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.key).path) }
    }

    private func nativeApprovalsSnapshotData(_ read: Result<[ApprovalRequest], Error>) async -> SnapshotGroupBuild {
        let approvals: [ApprovalRequest]
        do { approvals = try read.get() } catch {
            return .skipped("approval store unreadable: \(error.localizedDescription)")
        }
        do { return .built(try await MobileSnapshotBuilder.shared.encode(approvals)) } catch {
            return .skipped("approvals could not be encoded: \(error.localizedDescription)")
        }
    }

    private func nativeInboxSnapshotData(_ read: Result<[InboxItemRecord], Error>) async -> SnapshotGroupBuild {
        let items: [InboxItemRecord]
        do { items = try read.get() } catch {
            return .skipped("inbox unreadable: \(error.localizedDescription)")
        }
        return await buildInboxSnapshot(items)
    }

    func buildInboxSnapshot(_ items: [InboxItemRecord]) async -> SnapshotGroupBuild {
        do {
            let projection = try await MobileSnapshotBuilder.shared.inbox(items)
            if !items.isEmpty, projection.included == 0 {
                return .skipped("mobile inbox rows exceeded the bounded projection budget")
            }
            if projection.included < items.count {
                nativeLog(
                    "[MacSyncEngine] mobile inbox projection bounded rows=%d total=%d bytes=%d",
                    projection.included,
                    items.count,
                    projection.data.count
                )
            }
            return .built(projection.data)
        } catch {
            return .skipped("inbox could not be encoded: \(error.localizedDescription)")
        }
    }

    private func nativeKnowledgeGraphSnapshotData() async -> SnapshotGroupBuild {
        do {
            return .built(try await sync.owner.knowledgeGraphSnapshotData())
        } catch {
            nativeLog(
                "[MacSyncEngine] canonical knowledge graph unreadable — keeping last good snapshot: %@",
                String(describing: error)
            )
            return .skipped("knowledge graph unreadable: \(error.localizedDescription)")
        }
    }

    func organismLivingStatusSnapshot() async -> OrganismLivingStatusFile {
        guard let snapshot = await sync.cognition?.organismSnapshot() else { return Self.noMindLivingStatus() }
        return await MobileSnapshotBuilder.shared.build { Self.organismLivingStatusSnapshot(from: snapshot) }
    }

    /// No mind runs before setup has finished or after a reset closed it: the phone is told so, never shown a calm or stale body. The file is the
    /// same on every pass while no mind runs, so it publishes once.
    nonisolated static func noMindLivingStatus() -> OrganismLivingStatusFile {
        var status = OrganismLivingStatusFile(generatedAt: .distantPast, enabled: false, posture: "off", bodyLine: nil, behaviorLine: "off",
            needsUser: false, needsAttention: nil, signalCount: 0, lastSignalAt: nil,
            body: OrganismLivingBodyFile(macAwake: true, iPhoneReachable: false, providersHealthy: false, memoryHealthy: false, dreamHealthy: false,
                toolHandsAvailable: false, approvalChannelsOpen: false, notificationPathHealthy: nil, resourcePressure: "unknown"),
            counters: OrganismLivingCountersFile(fieldNodes: 0, pendingPredictions: 0, dreamRepairs: 0),
            availability: .unavailable)
        status.markUnavailable(reason: "mind_not_started")
        return status
    }

    nonisolated static func organismLivingStatusSnapshot(
        from snapshot: OrganismSnapshot
    ) -> OrganismLivingStatusFile {
        let posture = OrganismBehaviorPosture.from(snapshot: snapshot)
        let behaviorLine = posture?.summaryLine ?? "off"
        return OrganismLivingStatusFile(
            generatedAt: snapshot.generatedAt,
            enabled: snapshot.enabled,
            posture: posture?.posture ?? (snapshot.enabled ? "steady" : "off"),
            bodyLine: snapshot.projectedBodyLine,
            behaviorLine: behaviorLine,
            needsUser: false,
            needsAttention: LivingAttentionPolicy.organismNeedsAttention(snapshot),
            signalCount: snapshot.signalCount,
            lastSignalAt: snapshot.lastSignalAt,
            body: OrganismLivingBodyFile(
                macAwake: snapshot.bodySchema.macAwake,
                iPhoneReachable: snapshot.bodySchema.iPhoneReachable,
                providersHealthy: snapshot.bodySchema.providersHealthy,
                memoryHealthy: snapshot.bodySchema.memoryHealthy,
                dreamHealthy: snapshot.bodySchema.dreamHealthy,
                toolHandsAvailable: snapshot.bodySchema.toolHandsAvailable,
                approvalChannelsOpen: snapshot.bodySchema.approvalChannelsOpen,
                notificationPathHealthy: snapshot.bodySchema.notificationPathHealthy,
                resourcePressure: snapshot.bodySchema.resourcePressure.rawValue
            ),
            counters: OrganismLivingCountersFile(
                fieldNodes: snapshot.fieldSummary.nodeCount,
                pendingPredictions: snapshot.predictionSummary.pendingCount,
                dreamRepairs: snapshot.dreamRepairSummary.receiptCount
            ),
            availability: snapshot.enabled ? .live : .disabled
        )
    }

    /// Failed Desk reads replace complete mobile status so stale state cannot appear healthy; disabled organism snapshots stay disabled.
    nonisolated static func organismLivingStatusAfterDeskRead(
        _ status: OrganismLivingStatusFile,
        deskReadSucceeded: Bool
    ) -> OrganismLivingStatusFile {
        guard !deskReadSucceeded, status.enabled else { return status }
        var unavailable = status
        unavailable.markUnavailable(reason: "desk_status_unavailable")
        return unavailable
    }

    /// Publish checked per-surface routing preferences; omit empty surfaces the Mac cannot honor.
    private func modelPreferencesSnapshotData(_ routing: ProviderRoutingSnapshot?) async -> SnapshotGroupBuild {
        guard let routing else { return .skipped("model preferences unreadable: provider settings unavailable") }
        return await MobileSnapshotBuilder.shared.build {
            let out = iCloudBridge.providerSurfaceSelections(from: routing).mapValues { selection in
                var row = ["model": selection.model]
                if let provider = selection.providerID { row["providerId"] = provider }
                if let effort = selection.reasoningEffort { row["reasoningEffort"] = effort }
                if let tier = selection.serviceTier, !tier.isEmpty { row["serviceTier"] = tier }
                return row
            }
            let enc = JSONEncoder()
            enc.outputFormatting = .sortedKeys
            do { return .built(try Self.revisionedSnapshotData(enc.encode(out), revision: routing.revision)) } catch {
                return .skipped("model preferences could not be encoded: \(error.localizedDescription)")
            }
        }
    }
}

private extension MacSyncEngine {
    /// Inspect each source fragment before encoding; only fields the deployed phone record actually carries belong here.
    nonisolated static func memoryPhoneFields(_ record: MindCore.MemoryRecord) -> [String] {
        [record.id, record.layer, record.text, record.sourceRunId, record.status, record.createdAt, record.updatedAt].compactMap { $0 }
            + (record.tags ?? [])
    }
}

extension MemoryRecord {
    /// A reading copy of canonical memory values; missing values stay missing.
    init(phoneRow r: MindCore.MemoryRecord) {
        self.init(
            id: r.id, layer: r.layer, text: r.text, sourceRunId: r.sourceRunId,
            importance: r.importance, confidence: r.confidence, status: r.status, pinned: r.pinned, tags: r.tags,
            createdAt: r.createdAt, updatedAt: r.updatedAt
        )
    }
}
