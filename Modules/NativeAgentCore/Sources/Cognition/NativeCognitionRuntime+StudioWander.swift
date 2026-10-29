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
// Blueprint: | `NativeCognitionRuntime+StudioWander.swift` | `NativeCognitionRuntime`: retained hour flight, checked admission and terminal settlement; installation, material composition and editable studio-intake invitations |

// MARK: - Her hour
//
// `StudioWanderLane` holds the law. This file holds the
// organs: the installation read, the material composition, the one call, the
// receipts and the trace.
//
// ── NO NEW TIMER, NO NEW BUDGET (NORTHSTAR clause 4) ────────────────────────
// Called from `rescheduleResidualRepairDeadline`, which already runs on every
// somatic signal, every deadline fire and every wake re-anchor, and already
// holds a fresh residual reading. No loop id, no scheduler job, no watchdog. The
// installation, conversation quiet and durable refractory decide admission.
//
// ── KILL SWITCH: THE LANE IS NOT INSTALLED ──────────────────────────────────
// `StudioWanderState.shared.installation(for:)` is consulted before any state is
// read. Off means `considerStudioWander` returns having touched nothing: no
// state file, no material read, no receipt, no trace. There is no
// "wander_skipped" record, because a lane that is not installed cannot skip.
// An already-admitted hour still settles after either switch is turned off.
//
// ── CLAUSE 6: PUSH, NEVER PROMPT ────────────────────────────────────────────
// Nothing this lane produces enters her next prompt. The hour is a turn of its
// own; what survives it is what SHE wrote (a journal entry, by her own tool
// call) plus one line of trace and a receipt. Nothing auto-appends.
//
// ── HONEST ENCOUNTERS ONLY ────────────────────────────────────────────────
// The call runs with the ordinary tool loop at `read_only` file access, so the
// browser/vision organs and the local file readers are hers to use and the write
// tools are not. Nothing in this file fetches an artifact FOR her: if she cannot
// actually receive the work, the encounter did not happen, and the outcome is
// `no_artifact` — which never journals, because only she can journal.

/// Process-wide holder for the lane's non-durable state.
///
/// Installation and per-root claims live here; the runtime retains the actual
/// flight so sleep can cancel work and join its settlement.
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

    /// The Settings toggle re-resolves installation without a relaunch: turning
    /// it off must UNINSTALL the lane, not leave a cached `.installed` behind.
    func invalidateInstallation(for dataRoot: URL) {
        installations[dataRoot.standardizedFileURL.path] = nil
    }

    /// Single-flight claim. One hour at a time, per data root.
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

    /// Change-only receipt suppression: "she is not due to wander" is true on nearly every
    /// signal and must never be the loudest thing in the ledger.
    func shouldRecord(_ key: String, for dataRoot: URL) -> Bool {
        let root = dataRoot.standardizedFileURL.path
        guard lastOutcome[root] != key else { return false }
        lastOutcome[root] = key
        return true
    }

}

extension NativeCognitionRuntime {

    /// Called from the residual-repair reschedule.
    func considerStudioWander() {
        guard !isFlushedForTermination, studioWanderTask == nil else { return }
        studioWanderTask = Task { [weak self] in
            await self?.runStudioWanderIfDue()
            await self?.studioWanderFlightEnded()
        }
    }

    private func studioWanderFlightEnded() { studioWanderTask = nil }

    private func runStudioWanderIfDue() async {
        let root = dataRoot
        let turnInFlight = liveTurnInFlight
        let at = now()
        guard !Task.isCancelled, !isFlushedForTermination,
              await Self.studioWanderIsInstalled(dataRoot: root) else { return }
        let lastWander: Date?
        do {
            lastWander = try await StudioWanderLane.loadState(dataRoot: root).lastWanderAt
        } catch {
            await recordStudioWanderPersistenceFailure(error)
            return
        }
        let decision = await StudioWanderLane.decide(
            now: at,
            turnInFlight: turnInFlight,
            lastTurnActivityAt: ChatTurnSteering.shared.turnActivityOrSeed(for: root, at: at),
            lastWanderAt: lastWander
        )
        guard decision == .wander, !Task.isCancelled, !isFlushedForTermination else { return }
        guard await StudioWanderState.shared.claim(root) else { return }
        await runStudioWander(at: at)
        await settle { await StudioWanderState.shared.release(root) }
    }

    /// Installation, resolved once per data root and cached. Public-safe builds
    /// before onboarding cannot install it at all; the switch defaults OFF
    /// everywhere else.
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
                // The Subconscious master's own key. Spelled out because the
                // runtime keeps it private; the Settings row this switch sits
                // beside reads the same literal through @AppStorage.
                subconsciousEnabled: UserDefaults.standard
                    .object(forKey: "cognitiveSubstrateEnabled") == nil
                    || UserDefaults.standard.bool(forKey: "cognitiveSubstrateEnabled")
            )
    }

    private func runStudioWander(at: Date) async {
        guard await studioWanderStillEligible() else { return }
        let root = dataRoot

        let (material, sourceFailures, offeredCares, careGeneration) = await composeStudioWanderMaterial()
        // Report source failures; if no material remains, leave the refractory unconsumed.
        if !sourceFailures.isEmpty {
            await substrate.recordReceipt(kind: "studio.wander_source_unavailable", payload: .object([
                "failures": .array(sourceFailures.map { .string($0) }),
                "materialEmpty": .bool(material.isEmpty),
            ]))
            if material.isEmpty { return }
        }
        guard await studioWanderStillEligible() else { return }
        // Persist admission before tools can run. Provider failure may follow
        // tool effects, so it is not permission to replay an unknown outcome.
        let admittedAt = now()
        do { try await StudioWanderLane.beginHour(dataRoot: root, at: admittedAt) }
        catch { await recordStudioWanderPersistenceFailure(error); return }
        guard await studioWanderStillEligible() else {
            await settle {
                await self.finishStudioWander(outcome: .stopped,
                    line: "The hour ended before exploration began.", journalEntryID: nil,
                    providerCalls: 0, at: admittedAt)
            }
            return
        }
        // Her hour's witness admits only looking and her own journal, and records encounters.
        //
        // The narrowing is not decoration. `runEphemeralToolTurn` inherits the
        // WHOLE catalog, and `fileAccess: read_only` stops file writes and
        // shells but stops none of the things that reach the world: `act`/`go`
        // move User's screen, `mail_send`/`messages_send`
        // speak as him, `claude_message`/`codex_message`/
        // `invoke_codex` wake other agents, `commit_memory` rewrites what she
        // knows, the `desk_*` mutations edit his board, `workshop_submit` starts
        // work. An unattended hour of her own must be able to LOOK and to WRITE
        // IN HER OWN JOURNAL, and nothing else.
        //
        // `enforceAppAutonomy: false` matches every other client the app builds:
        // the shared ChatOrchestration membrane resolves autonomy once, after
        // SecurityCenter has authenticated the origin.
        // A test-root runtime gets its own bodiless engine.
        let engine = host.studioWanderClient(dataRoot: root, usesLiveAppBody: usesLiveAppBody)
        let witness = StudioWanderToolWitness(
            inner: engine.toolDispatchClient(),
            shouldContinue: { [weak self] in await self?.studioWanderStillEligible() ?? false }
        )
        let response: ChatTurnRuntime.ChatResponse
        do {
            let client = engine.chatClient(tools: witness)
            response = try await LLMCallContext.$purpose.withValue("studio_wander") {
            try await client.runEphemeralToolTurn(
                message: StudioWanderLane.prompt(material),
                // Reads and her own studio lane; no shell, no writes. The
                // browser/vision organs and the local file readers are what an
                // honest encounter is made of, and they are all reads.
                fileAccess: "read_only",
                surface: Self.studioWanderSurface,
                providerAdmission: { [weak self] in
                    guard await self?.studioWanderStillEligible() == true else { throw CancellationError() }
                }
            )
            }
        } catch {
            // Admission remains durable: a provider failure can occur after
            // a journal write and must not silently replay the hour.
            let eligible = await studioWanderStillEligible()
            let stopped = Task.isCancelled || error is CancellationError || !eligible
            let failure = String(describing: error)
            await settle {
                let seen = await witness.report()
                await self.finishStudioWander(outcome: stopped ? .stopped : .failed,
                    line: stopped ? "The hour stopped; what I already did is kept."
                        : "The hour failed; what I already did is kept.",
                    journalEntryID: seen.journalEntryID, providerCalls: nil, at: admittedAt,
                    failure: failure, encounter: seen)
            }
            return
        }

        await settle {
            await self.settleStudioWander(response, seen: await witness.report(),
                admittedAt: admittedAt, offeredCares: offeredCares, careGeneration: careGeneration)
        }
    }

    private func settleStudioWander(_ response: ChatTurnRuntime.ChatResponse,
                                   seen: StudioWanderToolWitness.Report, admittedAt: Date,
                                   offeredCares: [UUID], careGeneration: UInt64) async {
        let root = dataRoot

        // WHAT SHE ACTUALLY DID, read from the tools she actually CALLED —
        // never from what the reply claims. "I looked at it" is an assertion; a
        // dispatch is evidence, and this whole lane exists because the
        // difference matters.
        let line = Self.studioWanderLine(response.output)
        let outcome: StudioWanderLane.Outcome
        if seen.obtainedArtifact {
            outcome = .chose
        } else if seen.attemptedArtifact {
            // She reached for the work and could not receive it. Her veto: the
            // encounter did not happen. Note that this branch cannot coexist
            // with a journal entry — `studio_journal` is hers alone to call and
            // she was told not to write about a work she did not meet — but if
            // one somehow exists it is HER entry and it is reported, not erased.
            outcome = .noArtifact
        } else {
            outcome = .declined
        }
        let journalEntryID = seen.journalEntryID
        await finishStudioWander(
            outcome: outcome,
            line: line,
            journalEntryID: journalEntryID,
            providerCalls: response.providerCallCount,
            at: admittedAt,
            encounter: seen
        )
        // Preserve questions from real encounters even if the switch changes after admission.
        if outcome == .chose, let question = Self.studioWanderQuestion(response.output) {
            var topic: String?
            if let journalEntryID,
               let entry = try? await SwiftNativeStudioStore(dataRoot: root).readJournal()
                .first(where: { $0.id == journalEntryID }) {
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
            }
        }
    }

    /// Her `still wondering:` line, if she wrote one.
    static func studioWanderQuestion(_ output: String) -> String? {
        output.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces) }
            .last { $0.lowercased().hasPrefix("still wondering:") }
            .map { String($0.dropFirst("still wondering:".count)).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : String($0.prefix(240)) }
    }

    /// The question and the offered care it carries on, when her line names
    /// one by its key ("still wondering: [w2] …"). Which care it belongs to is
    /// hers to say; with no key it is a care of its own.
    static func studioWanderContinuing(_ question: String, offered: [UUID]) -> (question: String, care: UUID?) {
        guard question.hasPrefix("[w"), let close = question.firstIndex(of: "]"),
              let number = Int(question[question.index(question.startIndex, offsetBy: 2)..<close]),
              number > 0,
              offered.indices.contains(number - 1) else { return (question, nil) }
        let rest = question[question.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return (rest.isEmpty ? question : rest, offered[number - 1])
    }

    /// Advance the refractory, write the one-line trace, and record the receipt.
    ///
    /// The refractory advances on EVERY ended hour, decline included: the hour
    /// was hers and she spent it. Nothing here counts, scores, or compares
    /// outcomes across days.
    private func finishStudioWander(
        outcome: StudioWanderLane.Outcome,
        line: String,
        journalEntryID: String?,
        providerCalls: Int?,
        at: Date,
        failure: String? = nil,
        encounter: StudioWanderToolWitness.Report? = nil
    ) async {
        // Admission already happened. Switches and Stop end work, never this
        // terminal record or its witnessed journal entry.
        let entry = StudioWanderLane.TraceEntry(
            at: NativeTimestampFormat.sixDigitUTCOffset(at),
            outcome: outcome,
            line: line,
            journalEntryID: journalEntryID
        )
        do { try await StudioWanderLane.recordEndedHour(dataRoot: dataRoot, entry: entry, at: at) }
        catch { await recordStudioWanderPersistenceFailure(error); return }
        // Each admitted hour owns a terminal receipt, even when two ended alike.
        var payload: [String: JSONValue] = [
            "outcome": .string(outcome.rawValue),
            "line": .string(String(line.prefix(240))),
            "providerCalls": providerCalls.map { .int(Int64($0)) } ?? .null,
            "attempt": .int(Int64(await StudioWanderState.shared.attemptCount())),
            // Said out loud so no reader has to infer it.
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
    }

    private func recordStudioWanderPersistenceFailure(_ error: Error) async {
        guard await StudioWanderState.shared.shouldRecord("state_unavailable", for: dataRoot) else { return }
        await substrate.recordReceipt(kind: "studio.wander_state_unavailable", payload: .object([
            "error": .string(String(describing: error)), "saved": .bool(false),
        ]))
    }

    /// Revalidate after preparation and again at each tool boundary. The
    /// current run's refractory is already reserved, not a reason to reject
    /// its continuation. Foreground activity ends this hour's tool access.
    private func studioWanderStillEligible() async -> Bool {
        let activity = await ChatTurnSteering.shared.turnActivityOrSeed(for: dataRoot, at: now())
        let installed = Self.studioWanderInstallationNow(dataRoot: dataRoot).isInstalled
        let busy = liveTurnInFlight
        return !Task.isCancelled && !isFlushedForTermination && installed
            && StudioWanderLane.decide(
                now: now(), turnInFlight: busy,
                lastTurnActivityAt: activity, lastWanderAt: nil
            ) == .wander
    }

    /// HER OWN MATERIAL, and nothing invented.
    ///
    /// Four live sources, every one of them already hers: the questions her own
    /// substrate left open, the consults User filed that the journal never
    /// answered, the works the graph holds with nothing written about them, and
    /// the titles she has been writing about lately. A source that cannot be
    /// read contributes NOTHING — an empty field is a correct answer.
    ///
    /// Report unreadable sources separately from genuinely empty material.
    private func composeStudioWanderMaterial() async -> (
        material: StudioWanderLane.Material, sourceFailures: [String], offeredCares: [UUID], careGeneration: UInt64
    ) {
        let store = SwiftNativeStudioStore(dataRoot: dataRoot)
        var sourceFailures: [String] = []
        // Her own open cares, most pressing first.
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
            journal = try await store.readJournal()
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
            // An invitation she cannot open is a tease. A consult User filed is
            // named by its id, and `studio_consult_read` is the only way to see
            // the artifact refs inside it — so the line carries the id, and the
            // prompt names the tool. Without this she was being shown one-line
            // summaries of works and asked to judge them, which is the
            // description-only encounter her own rule forbids.
            invitations: invitationLines,
            recentJournalTitles: Array(recentTitles),
            cares: cares.enumerated().map { "[w\($0.offset + 1)] \($0.element.about) — \($0.element.open ?? "")" }
        )
        return (material, sourceFailures, cares.map(\.id), careGeneration)
    }

    /// Her hour has its own routing row: model and reasoning effort are chosen in
    /// Providers beside `dream` and `cognition_reflection`, because whose model
    /// she thinks with when nobody is watching is a real choice and not an
    /// inherited default.
    public static let studioWanderSurface = "studio_wander"

    /// Her closing line, bounded. Never rewritten, never summarized — the last
    /// non-empty line of what she said, which is what the prompt asked her for.
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
    /// Called by the Settings toggle. Installation is resolved once per data
    /// root and cached, so flipping the switch has to drop that cache — turning
    /// the lane OFF must uninstall it now, not at the next relaunch.
    public static func reloadStudioWanderInstallation(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        await StudioWanderState.shared.invalidateInstallation(for: dataRoot)
    }
}
