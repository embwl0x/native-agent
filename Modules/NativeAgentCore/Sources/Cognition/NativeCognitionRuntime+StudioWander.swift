import BackgroundLoops
import ChatTurnRuntime
import CognitiveSubstrate
import Foundation
import NativeAgentShared
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Studio
import PersonaEngine
import ChatTurnContracts
import ChatToolParsing
import ToolRegistry
// Blueprint: | `NativeCognitionRuntime+StudioWander.swift` | `NativeCognitionRuntime`. |

// MARK: - The wander hour
// StudioWanderLane owns admission; this runtime composes sources, runs the turn and records settlement.
// Use the existing residual deadline without another timer, budget or watchdog.
// Resolve installation before any read; disabled hours leave no state, receipt or trace, while admitted hours still settle.
// The hour adds nothing to later prompts except what the agent explicitly writes.
// Permit only real artifact encounters and the agent's own journal; unavailable work cannot count as an encounter.

/// Keep installation and per-root claims process-wide; retain flights in the runtime so sleep can join settlement.
actor StudioWanderState {
    static let shared = StudioWanderState()

    private var installations: [String: StudioWanderLane.Installation] = [:]
    private var inFlight: Set<String> = []
    private var lastOutcome: [String: String] = [:]
    private var attempts: UInt64 = 0

    func installation(
        for dataRoot: URL,
        resolve: @Sendable () -> StudioWanderLane.Installation
    ) -> StudioWanderLane.Installation {
        let key = dataRoot.standardizedFileURL.path
        if let cached = installations[key] { return cached }
        let resolved = resolve()
        installations[key] = resolved
        return resolved
    }

    /// Invalidate installation on Settings changes so disabling takes effect without relaunch.
    func invalidateInstallation(for dataRoot: URL) {
        installations[dataRoot.standardizedFileURL.path] = nil
    }

    /// Allow one hour per data root at a time.
    func claim(_ dataRoot: URL) -> Bool {
        let key = dataRoot.standardizedFileURL.path
        guard !inFlight.contains(key) else { return false }
        inFlight.insert(key)
        attempts &+= 1
        return true
    }

    func release(_ dataRoot: URL) {
        inFlight.remove(dataRoot.standardizedFileURL.path)
    }

    func attemptCount() -> UInt64 { attempts }

    /// Suppress unchanged not-due receipts so routine signals cannot dominate the ledger.
    func shouldRecord(_ key: String, for dataRoot: URL) -> Bool {
        let root = dataRoot.standardizedFileURL.path
        guard lastOutcome[root] != key else { return false }
        lastOutcome[root] = key
        return true
    }

}

extension NativeCognitionRuntime {

    func considerStudioWander(runNow: Bool = false, reply: MindClockReply? = nil) {
        guard Self.studioWanderInstallationNow(dataRoot: dataRoot).isInstalled else {
            sourceWakes.wanderNextAt = nil
            if let reply { reply(.off("the hour is not installed")) } else { beat(.wander, .off("the hour is not installed")) }
            return
        }
        if !runNow, let next = sourceWakes.wanderNextAt, next > now() { return }
        guard !isFlushedForTermination, studioWanderTask == nil else {
            reply?(.init("held", "The wander hour is running or the runtime is stopping.")); return
        }
        studioWanderTask = Task { [weak self] in
            guard let self else { reply?(.init("unavailable", "The runtime was released.")); return }
            let result = await self.runStudioWanderIfDue(satisfyWait: runNow)
            if let reply { reply(result) } else { await self.beat(.wander, result) }
            await self.studioWanderFlightEnded()
        }
    }

    private func studioWanderFlightEnded() async {
        studioWanderTask = nil
        if let next = sourceWakes.wanderNextAt, next > now() {
            await rescheduleResidualRepairDeadline()
        }
    }

    private func runStudioWanderIfDue(satisfyWait: Bool = false) async -> MindClockResult {
        sourceWakes.wanderNextAt = nil
        let root = dataRoot
        let turnInFlight = liveTurnInFlight
        let at = now()
        guard !Task.isCancelled, !isFlushedForTermination else { return .init("stopped", "The runtime is stopping.") }
        guard await Self.studioWanderIsInstalled(dataRoot: root) else { return .off("the hour is not installed") }
        let lastWander: Date?
        do {
            lastWander = try await StudioWanderLane.loadState(dataRoot: root).lastWanderAt
        } catch {
            await recordStudioWanderPersistenceFailure(error)
            return .init("unavailable", "The wander hour state could not be read: " + error.localizedDescription)
        }
        let lastActivity = await ChatTurnSteering.shared.turnActivityOrSeed(for: root, at: at)
        sourceWakes.wanderNextAt = StudioWanderLane.nextEligibility(
            now: at, lastTurnActivityAt: lastActivity, lastWanderAt: lastWander)
        let decision = StudioWanderLane.decide(
            now: at,
            turnInFlight: turnInFlight,
            lastTurnActivityAt: lastActivity,
            lastWanderAt: lastWander,
            satisfyWait: satisfyWait
        )
        guard decision == .wander else { return .waiting(decision.rawValue) }
        guard !Task.isCancelled, !isFlushedForTermination else { return .init("stopped", "The runtime is stopping.") }
        guard await StudioWanderState.shared.claim(root) else { return .waiting("The hour is already claimed.") }
        let result = await runStudioWander(at: at, satisfyWait: satisfyWait)
        await settle { await StudioWanderState.shared.release(root) }
        do {
            let state = try await StudioWanderLane.loadState(dataRoot: root)
            let activity = await ChatTurnSteering.shared.turnActivityOrSeed(for: root, at: now())
            sourceWakes.wanderNextAt = StudioWanderLane.nextEligibility(
                now: now(), lastTurnActivityAt: activity, lastWanderAt: state.lastWanderAt)
        } catch {
            sourceWakes.wanderNextAt = nil
            await recordStudioWanderPersistenceFailure(error)
        }
        return result
    }

    /// Resolve installation per root; public pre-onboarding builds cannot admit hours.
    public static func studioWanderIsInstalled(dataRoot: URL) async -> Bool {
        await StudioWanderState.shared.installation(for: dataRoot) {
            studioWanderInstallationNow(dataRoot: dataRoot)
        }.isInstalled
    }

    static func studioWanderInstallationNow(dataRoot: URL) -> StudioWanderLane.Installation {
            StudioWanderLane.resolveInstallation(
                enabled: UserDefaults.standard
                    .object(forKey: StudioWanderLane.enabledDefaultsKey) as? Bool,
                forcedNeutral: NativeAgentPublicSafety.shouldForceNeutralOrganism(
                    dataRoot: dataRoot
                ),
                // Match the private master preference's literal because Settings and runtime must read the same choice.
                subconsciousEnabled: UserDefaults.standard
                    .object(forKey: "cognitiveSubstrateEnabled") == nil
                    || UserDefaults.standard.bool(forKey: "cognitiveSubstrateEnabled")
            )
    }

    private func runStudioWander(at: Date, satisfyWait: Bool = false) async -> MindClockResult {
        let quietSatisfiedThrough: Date? = satisfyWait ? at : nil
        guard await studioWanderStillEligible(quietSatisfiedThrough: quietSatisfiedThrough) else { return .waiting(
            "The wander hour no longer passes live admission.") }
        let root = dataRoot

        let (material, sourceFailures, offeredCares, careGeneration) = await composeStudioWanderMaterial()
        // Report unreadable sources; no remaining material leaves refractory unconsumed.
        if !sourceFailures.isEmpty {
            await substrate.recordReceipt(kind: "studio.wander_source_unavailable", payload: .object([
                "failures": .array(sourceFailures.map { .string($0) }),
                "materialEmpty": .bool(material.isEmpty),
            ]))
            if material.isEmpty { return .init("unavailable", sourceFailures.joined(separator: "; ")) }
        }
        guard await studioWanderStillEligible(quietSatisfiedThrough: quietSatisfiedThrough) else { return .waiting(
            "The wander hour no longer passes live admission.") }
        // Persist admission before tools run; later provider failure cannot authorize replay of unknown effects.
        let admittedAt = now()
        do { try await StudioWanderLane.beginHour(dataRoot: root, at: admittedAt, satisfyWait: satisfyWait) }
        catch { await recordStudioWanderPersistenceFailure(error); return .init("unavailable", error.localizedDescription) }
        guard await studioWanderStillEligible(quietSatisfiedThrough: quietSatisfiedThrough) else {
            return await settle {
                await self.finishStudioWander(outcome: .stopped,
                    line: "The hour ended before exploration began.", journalEntryID: nil,
                    providerCalls: 0, at: admittedAt)
            }
        }
        // The full tool catalog includes external effects that read-only file access does not gate.
        // Narrow dispatch to looking and the agent's own journal; authenticate origin before shared autonomy admission.
        // Alternate-root runtimes use their own bodiless engine.
        let engine = host.studioWanderClient(dataRoot: root, usesLiveAppBody: usesLiveAppBody)
        let witness = StudioWanderToolWitness(
            inner: engine.toolDispatchClient(),
            shouldContinue: { [weak self] in await self?.studioWanderStillEligible(quietSatisfiedThrough: quietSatisfiedThrough) ?? false }
        )
        let response: ChatTurnRuntime.ChatResponse
        do {
            let client = engine.chatClient(tools: witness)
            let turn = Turn().with(\.envelope, TurnEnvelope.native("studio_wander", surface: Self.studioWanderSurface))
            response = try await client.runEphemeralToolTurn(
                message: StudioWanderLane.prompt(material),
                // Allow browser, vision and local reads without shells or external writes.
                fileAccess: "read_only",
                surface: Self.studioWanderSurface,
                providerAdmission: { [weak self] in
                    guard await self?.studioWanderStillEligible(quietSatisfiedThrough: quietSatisfiedThrough) == true else { throw CancellationError() }
                },
                purpose: "studio_wander",
                turn: turn, work: ChatTurnWork()
            )
        } catch {
            // Keep admission durable because provider failure may follow a committed journal write.
            let eligible = await studioWanderStillEligible(quietSatisfiedThrough: quietSatisfiedThrough)
            let stopped = Task.isCancelled || error is CancellationError || !eligible
            let failure = String(describing: error)
            return await settle {
                let seen = await witness.report()
                return await self.finishStudioWander(outcome: stopped ? .stopped : .failed,
                    line: stopped ? "The hour stopped; what I already did is kept."
                        : "The hour failed; what I already did is kept.",
                    journalEntryID: seen.journalEntryID, providerCalls: nil, at: admittedAt,
                    failure: failure, encounter: seen)
            }
        }

        return await settle {
            await self.settleStudioWander(response, seen: await witness.report(),
                admittedAt: admittedAt, offeredCares: offeredCares, careGeneration: careGeneration)
        }
    }

    private func settleStudioWander(_ response: ChatTurnRuntime.ChatResponse,
                                   seen: StudioWanderToolWitness.Report, admittedAt: Date,
                                   offeredCares: [UUID], careGeneration: UInt64) async -> MindClockResult {
        let root = dataRoot

        // Witness dispatched tools rather than trusting the reply's claim of an encounter.
        let line = Self.studioWanderLine(response.output)
        let outcome: StudioWanderLane.Outcome
        if seen.obtainedArtifact {
            outcome = .chose
        } else if seen.attemptedArtifact {
            // Failure to receive the work is no_artifact; report any agent-authored journal entry without erasing it.
            outcome = .noArtifact
        } else {
            outcome = .declined
        }
        let journalEntryID = seen.journalEntryID
        let result = await finishStudioWander(
            outcome: outcome,
            line: line,
            journalEntryID: journalEntryID,
            providerCalls: response.providerCallCount,
            at: admittedAt,
            encounter: seen
        )
        // Preserve real-encounter questions even when the switch changes after admission.
        if outcome == .chose, let question = Self.studioWanderQuestion(response.output) {
            var topic: String?
            if let journalEntryID,
               let entry = try? await SwiftNativeStudioStore(dataRoot: root).readJournal()
                .entries.first(where: { $0.id == journalEntryID }) {
                topic = entry.work.title
            }
            let (asked, continuing) = Self.studioWanderContinuing(question, offered: offeredCares)
            do {
                let saved = try await substrate.noteHourWondering(
                    asked, topic: topic, continuing: continuing, generation: careGeneration,
                    source: journalEntryID.map { "studio:" + $0 }
                        ?? "studio_wander:\(NativeTimestampFormat.sixDigitUTCOffset(admittedAt))")
                if !saved { throw CognitiveCareNotSaved(detail: "the hour's care generation is no longer current") }
            } catch {
                await recordStudioWanderPersistenceFailure(error)
                return .init("failed", "The hour ended as \(outcome.rawValue), but its wondering was not saved: \(error.localizedDescription)",
                    fields: result.fields)
            }
        }
        return result
    }

    static func studioWanderQuestion(_ output: String) -> String? {
        output.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces) }
            .last { $0.lowercased().hasPrefix("still wondering:") }
            .map { String($0.dropFirst("still wondering:".count)).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : String($0.prefix(240)) }
    }

    /// Let an explicit question key select the continued care; no key creates an independent care.
    static func studioWanderContinuing(_ question: String, offered: [UUID]) -> (question: String, care: UUID?) {
        guard question.hasPrefix("[w"), let close = question.firstIndex(of: "]"),
              let number = Int(question[question.index(question.startIndex, offsetBy: 2)..<close]),
              number > 0,
              offered.indices.contains(number - 1) else { return (question, nil) }
        let rest = question[question.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return (rest.isEmpty ? question : rest, offered[number - 1])
    }

    /// Every admitted hour advances refractory, including a decline; trace and receipt record spending without scoring outcomes.
    private func finishStudioWander(
        outcome: StudioWanderLane.Outcome,
        line: String,
        journalEntryID: String?,
        providerCalls: Int?,
        at: Date,
        failure: String? = nil,
        encounter: StudioWanderToolWitness.Report? = nil
    ) async -> MindClockResult {
        // Switches and Stop end admitted work, never its terminal record or witnessed journal entry.
        let entry = StudioWanderLane.TraceEntry(
            at: NativeTimestampFormat.sixDigitUTCOffset(at),
            outcome: outcome,
            line: line,
            journalEntryID: journalEntryID
        )
        do { try await StudioWanderLane.recordEndedHour(dataRoot: dataRoot, entry: entry, at: at) }
        catch { await recordStudioWanderPersistenceFailure(error); return .init("failed",
            "The hour ended as \(outcome.rawValue), but its terminal trace was not saved: \(error.localizedDescription)") }
        // Every admitted hour owns a terminal receipt, including repeated outcomes.
        var payload: [String: JSONValue] = [
            "outcome": .string(outcome.rawValue),
            "line": .string(String(line.prefix(240))),
            "providerCalls": providerCalls.map { .int(Int64($0)) } ?? .null,
            "attempt": .int(Int64(await StudioWanderState.shared.attemptCount())),
            "autoJournaled": .bool(false),
            "trace": .string(StudioWanderLane.statePath(dataRoot: dataRoot).path),
        ]
        if let journalEntryID { payload["journalEntryId"] = .string(journalEntryID) }
        if let failure { payload["error"] = .string(String(failure.prefix(240))) }
        if let encounter {
            payload["attemptedArtifact"] = .bool(encounter.attemptedArtifact)
            payload["obtainedArtifact"] = .bool(encounter.obtainedArtifact)
        }
        await substrate.recordReceipt(kind: outcome.receiptKind, payload: .object(payload))
        publishRuntimeChange(reason: "studio:wander_\(outcome.rawValue)")
        // An hour that obtained its work produced an encounter; a decline or an unreceived work produced none.
        return .init(outcome.rawValue, failure ?? line, fields: payload, yield: outcome == .chose ? 1 : 0)
    }

    private func recordStudioWanderPersistenceFailure(_ error: Error) async {
        guard await StudioWanderState.shared.shouldRecord("state_unavailable", for: dataRoot) else { return }
        await substrate.recordReceipt(kind: "studio.wander_state_unavailable", payload: .object([
            "error": .string(String(describing: error)), "saved": .bool(false),
        ]))
    }

    /// Revalidate after preparation and at tool boundaries; current-run refractory does not reject continuation.
    /// Foreground activity ends unattended tool access.
    private func studioWanderStillEligible(quietSatisfiedThrough: Date? = nil) async -> Bool {
        let activity = await ChatTurnSteering.shared.turnActivityOrSeed(for: dataRoot, at: now())
        let installed = Self.studioWanderInstallationNow(dataRoot: dataRoot).isInstalled
        let busy = liveTurnInFlight
        return !Task.isCancelled && !isFlushedForTermination && installed
            && StudioWanderLane.decide(
                now: now(), turnInFlight: busy,
                lastTurnActivityAt: activity, lastWanderAt: nil,
                satisfyWait: quietSatisfiedThrough.map { activity <= $0 } ?? false
            ) == .wander
    }

    /// Compose only canonical open cares, consults, graph works and recent writing.
    /// Report unreadable sources separately from genuinely empty material.
    private func composeStudioWanderMaterial() async -> (
        material: StudioWanderLane.Material, sourceFailures: [String], offeredCares: [UUID], careGeneration: UInt64
    ) {
        let store = SwiftNativeStudioStore(dataRoot: dataRoot)
        var sourceFailures: [String] = []
        let (cares, careGeneration) = await substrate.caresForHour()

        var invitations: [StudioEncounterCandidate]
        do {
            let host = self.host, root = dataRoot
            invitations = try await store.namedEncounterIntake { input in
                try await host.callReadPart(id: "studio-intake", input: input, actions: ["studio.intake.read"],
                    dataRoot: root, origin: "studio_wander:intake")
            }
        } catch {
            invitations = []
            sourceFailures.append("named encounter intake: \(error.localizedDescription)")
        }
        do {
            let journaled = try await store.journaledWorkIdentities()
            let indexer = try SwiftNativeKnowledgeGraphIndexer(
                memorySQLitePath: dataRoot
                    .appendingPathComponent("memory/memory.sqlite")
                    .standardizedFileURL
            )
            invitations.append(contentsOf: try await indexer.unjournaledWorkCandidates(
                journaledWorks: journaled
            ))
        } catch {
            sourceFailures.append("knowledge graph work candidates: \(error.localizedDescription)")
        }

        let journal: [StudioJournalEntry]
        do {
            let read = try await store.readJournal()
            journal = read.entries
            sourceFailures += read.holes.map { "studio journal: \($0)" }
        } catch {
            journal = []
            sourceFailures.append("studio journal: \(error.localizedDescription)")
        }
        let recentTitles = journal
            .suffix(StudioWanderLane.Material.bulletLimit)
            .reversed()
            .map(\.work.title)

        var invitationLines: [String] = []
        do {
            let packet: [JSONValue] = invitations.map { candidate in
                .object(["source": .string(candidate.source.rawValue), "id": .string(candidate.originID),
                    "title": candidate.title.map(JSONValue.string) ?? .null,
                    "creator": candidate.creator.map(JSONValue.string) ?? .null,
                    "reference": candidate.reference.map(JSONValue.string) ?? .null])
            }
            let result = try await host.callReadPart(id: "studio-intake", input: .object([
                "operation": .string("invitations"), "candidates": .array(packet),
                "unavailable_sources": .array(sourceFailures.map(JSONValue.string))]),
                actions: ["studio.intake.read"], dataRoot: dataRoot, origin: "studio_wander:invitations")
            invitationLines = try JSONDecoder().decode([String].self, from: result.serializedData(pretty: false))
        } catch { sourceFailures.append("studio invitations: \(error.localizedDescription)") }
        let material = StudioWanderLane.Material(
            // Include consult IDs and their read action so the agent can receive actual artifact references rather than judge summaries alone.
            invitations: invitationLines,
            recentJournalTitles: Array(recentTitles),
            cares: cares.enumerated().map { "[w\($0.offset + 1)] \($0.element.about) — \($0.element.open ?? "")" }
        )
        return (material, sourceFailures, cares.map(\.id), careGeneration)
    }

    /// Keep the hour's model and effort explicit in Providers because unattended thought needs its own saved routing choice.
    public static let studioWanderSurface = "studio_wander"

    /// Keep the agent's final nonempty line verbatim, bounded without rewriting or summarization.
    static func studioWanderLine(_ output: String) -> String {
        let line = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("#")
                && !$0.replacingOccurrences(of: "**", with: "").lowercased().hasPrefix("still wondering:") }
        guard let line, !line.isEmpty else { return "The hour passed without a word." }
        return String(line.prefix(240))
    }
}

extension NativeCognitionRuntime {
    /// Drop installation cache on Settings changes so disabling uninstalls the hour immediately.
    public static func reloadStudioWanderInstallation(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        await StudioWanderState.shared.invalidateInstallation(for: dataRoot)
    }
}
