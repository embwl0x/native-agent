import BackgroundLoops
import ChatOrchestration
import CognitiveSubstrate
import Foundation
import KnowledgeGraph
import NativeAgentCore
import PersistenceCore

// MARK: - HER HOUR, wired — personality-depth item 9
//
// `StudioWanderLane` (BackgroundLoops) holds the law. This file holds the
// organs: the installation read, the material composition, the one call, the
// receipts and the trace. Modelled line-for-line on
// NativeCognitionRuntime+StudioEncounters.swift, which is modelled on
// NativeCognitionRuntime+PressureDream.swift — three lanes, one shape, one seam.
//
// ── NO NEW TIMER, NO NEW BUDGET (NORTHSTAR clause 4) ────────────────────────
// Called from `rescheduleResidualRepairDeadline`, which already runs on every
// somatic signal, every deadline fire and every wake re-anchor, and already
// holds a fresh residual reading. No loop id, no scheduler job, no watchdog. The
// background-cognition gate runs FIRST inside the task, so low power, thermal
// pressure and a conserve/sleep loop budget defer it exactly as they defer the
// dream.
//
// ── KILL SWITCH: THE LANE IS NOT INSTALLED ──────────────────────────────────
// `StudioWanderState.shared.installation(for:)` is consulted before any state is
// read. Off means `considerStudioWander` returns having touched nothing: no
// state file, no material read, no receipt, no trace. There is no
// "wander_skipped" record, because a lane that is not installed cannot skip.
//
// ── CLAUSE 6: PUSH, NEVER PROMPT ────────────────────────────────────────────
// Nothing this lane produces enters her next prompt. The hour is a turn of its
// own; what survives it is what SHE wrote (a journal entry, by her own tool
// call) plus one line of trace and a receipt. Nothing auto-appends.
//
// ── HONEST ENCOUNTERS ONLY (Agent, binding) ─────────────────────────────────
// The call runs with the ordinary tool loop at `read_only` file access, so the
// browser/vision organs and the local file readers are hers to use and the write
// tools are not. Nothing in this file fetches an artifact FOR her: if she cannot
// actually receive the work, the encounter did not happen, and the outcome is
// `no_artifact` — which never journals, because only she can journal.

/// Process-wide holder for the lane's non-durable state.
///
/// It lives here rather than as stored properties on `NativeCognitionRuntime`
/// for one reason that matters: an uninstalled lane must add NOTHING to the
/// runtime, and a nil entry in this actor is a lane that does not exist.
actor StudioWanderState {
    static let shared = StudioWanderState()

    private var installations: [String: StudioWanderLane.Installation] = [:]
    private var inFlight: Set<String> = []
    /// The most recent instant a turn was observed in flight, per data root.
    /// The residual reschedule fires on every signal and every deadline, so this
    /// is a real observation of when she was last being spoken to — not a poll,
    /// and not a stored copy of anything the turn engine owns.
    private var lastTurnActivityAt: [String: Date] = [:]
    /// Loaded-once-per-process mirror of the durable refractory stamp. The
    /// double optional distinguishes "not loaded yet" from "loaded, and she has
    /// never had one".
    private var lastWander: [String: Date?] = [:]
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

    func noteTurnActivity(for dataRoot: URL, at: Date) {
        lastTurnActivityAt[dataRoot.standardizedFileURL.path] = at
    }

    /// The FIRST reading after launch seeds the quiet clock rather than
    /// answering "quiet since forever". Nothing was being watched before the
    /// process existed, and a launch that lands mid-conversation must not read
    /// as half an hour of silence. She waits out one honest quiet window first.
    func turnActivityOrSeed(for dataRoot: URL, at: Date) -> Date {
        let key = dataRoot.standardizedFileURL.path
        if let known = lastTurnActivityAt[key] { return known }
        lastTurnActivityAt[key] = at
        return at
    }

    /// The durable refractory stamp, read from disk ONCE per process and kept
    /// here afterwards. The residual reschedule fires on every somatic signal;
    /// re-reading a JSON file that changes at most once a day on each of them
    /// would be the "faster machine" shape clause 4 rules out.
    func lastWanderAt(
        for dataRoot: URL,
        load: @Sendable () async throws -> Date?
    ) async throws -> Date? {
        let key = dataRoot.standardizedFileURL.path
        if let known = lastWander[key] { return known }
        let loaded = try await load()
        // A never-wandered install has no stamp; remember the ANSWER, not just
        // a value, so the miss is not re-read on every signal either.
        lastWander[key] = .some(loaded)
        return loaded
    }

    func noteWanderEnded(for dataRoot: URL, at: Date) {
        lastWander[dataRoot.standardizedFileURL.path] = .some(at)
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

    /// Change-only receipt suppression, the same discipline the dream and
    /// encounter lanes use: "she is not due to wander" is true on nearly every
    /// signal and must never be the loudest thing in the ledger.
    func shouldRecord(_ key: String, for dataRoot: URL) -> Bool {
        let root = dataRoot.standardizedFileURL.path
        guard lastOutcome[root] != key else { return false }
        lastOutcome[root] = key
        return true
    }

    func forceRecordNext(for dataRoot: URL) {
        lastOutcome[dataRoot.standardizedFileURL.path] = nil
    }
}

extension NativeCognitionRuntime {

    /// Called from the residual-repair reschedule, beside `considerPressureDream`
    /// and `considerStudioEncounter`.
    func considerStudioWander(_ opportunity: OrganismResidualRepairOpportunity) {
        guard !isFlushedForTermination else { return }
        let root = dataRoot
        let turnInFlight = liveTurnInFlight
        // The dream's own decision, from the reading the dream lane just used.
        // `.fire` is due now; `.turnInFlight` is due and waiting for the turn to
        // settle. Both outrank an hour of her own, so both refuse here — by
        // returning, never by ranking.
        let dreamDecision = OrganismIdentityDreamTrigger.decide(
            opportunity: opportunity,
            turnInFlight: turnInFlight
        )
        let dreamIsDue = dreamDecision == .fire || dreamDecision == .turnInFlight
        let at = now()
        Task { [weak self] in
            guard await Self.studioWanderIsInstalled(dataRoot: root) else { return }
            if turnInFlight {
                await StudioWanderState.shared.noteTurnActivity(for: root, at: at)
            }
            let lastWander: Date?
            do {
                lastWander = try await StudioWanderState.shared.lastWanderAt(for: root) {
                    try await StudioWanderLane.loadState(dataRoot: root).lastWanderAt
                }
            } catch {
                await self?.recordStudioWanderPersistenceFailure(error)
                return
            }
            let decision = await StudioWanderLane.decide(
                now: at,
                turnInFlight: turnInFlight,
                dreamIsDue: dreamIsDue,
                lastTurnActivityAt: StudioWanderState.shared
                    .turnActivityOrSeed(for: root, at: at),
                lastWanderAt: lastWander,
                inQuietHours: Self.studioWanderInQuietHours(dataRoot: root, at: at)
            )
            guard decision == .wander else { return }
            guard await StudioWanderState.shared.claim(root) else { return }
            await self?.runStudioWander(at: at)
            await StudioWanderState.shared.release(root)
        }
    }

    /// Installation, resolved once per data root and cached. Public-safe builds
    /// before onboarding cannot install it at all; the switch defaults OFF
    /// everywhere else.
    static func studioWanderIsInstalled(dataRoot: URL) async -> Bool {
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
                    .object(forKey: "cognitiveSubstrateEnabled") as? Bool ?? false
            )
    }

    /// The user's own sleep window, read from the same preference file the turn
    /// clock reads. No second source of truth for when the house is asleep.
    static func studioWanderInQuietHours(dataRoot: URL, at: Date) -> Bool {
        guard let window = TurnQuietHoursWindow.read(dataRoot: dataRoot) else { return false }
        return window.contains(hour: Calendar.current.component(.hour, from: at))
    }

    private func runStudioWander(at: Date) async {
        let root = dataRoot

        // The same throttle every other background cognition lane respects.
        // `reflection` in the reason marks this as expensive work, so a
        // `conserve` budget defers it rather than letting it through. A deferral
        // does NOT consume her hour: the refractory advances only when the hour
        // actually happened.
        switch await backgroundCognitionGate(reason: "studio_wander:reflection") {
        case .skipped:
            return
        case .allowed:
            break
        }

        // Re-read against the current instant: the gate above took real time and
        // a dream may have become due while it did. Her hour never preempts.
        let fresh = await organismKernel.residualRepairOpportunity()
        let dreamDecision = OrganismIdentityDreamTrigger.decide(
            opportunity: fresh,
            turnInFlight: liveTurnInFlight
        )
        guard dreamDecision != .fire, dreamDecision != .turnInFlight else { return }

        let (material, sourceFailures) = await composeStudioWanderMaterial()
        // 2026-09-06: a source that could not be READ used to look exactly like
        // a source that was empty, and the decline below consumed her 24 h
        // refractory on the strength of it. A failed read is a failed run: it
        // is recorded, the refractory is left alone (`beginHour` has not run
        // yet), and the lane asks again on its ordinary cadence.
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
        await StudioWanderState.shared.noteWanderEnded(for: root, at: admittedAt)
        guard await studioWanderStillEligible() else { return }
        // Nothing of her own in reach. The hour still happened and it is still
        // hers — she simply had nothing to look at, which is a decline. It
        // consumes the refractory precisely so the lane does not re-ask every
        // thirty minutes for the rest of the day.
        guard !material.isEmpty else {
            await finishStudioWander(
                outcome: .declined,
                line: "Nothing of mine was in reach; I let the hour go.",
                journalEntryID: nil,
                providerCalls: 0,
                at: admittedAt
            )
            return
        }

        // TOOL BODY FOR THE HOUR: the ordinary app tools, narrowed to an
        // explicit allowlist, then witnessed.
        //
        // The narrowing is not decoration. `runEphemeralToolTurn` inherits the
        // WHOLE catalog, and `fileAccess: read_only` stops file writes and
        // shells but stops none of the things that reach the world: `act`/`go`
        // move User's screen, `mail_send`/`messages_send`/`slack_post_message`/
        // `agentmail_send` speak as him, `claude_message`/`codex_message`/
        // `invoke_codex` wake other agents, `commit_memory` rewrites what she
        // knows, the `desk_*` mutations edit his board, `workshop_submit` starts
        // work. An unattended hour of her own must be able to LOOK and to WRITE
        // IN HER OWN JOURNAL, and nothing else.
        //
        // `enforceAppAutonomy: false` matches every other client the app builds:
        // the shared ChatOrchestration membrane resolves autonomy once, after
        // SecurityCenter has authenticated the origin.
        let witness = StudioWanderToolWitness(
            inner: StudioWanderToolAllowlist(
                inner: makeNativeAgentAppToolDispatchClient(
                    enforceAppAutonomy: false,
                    dataRoot: root
                )
            ),
            shouldContinue: { [weak self] in await self?.studioWanderStillEligible() ?? false }
        )
        let response: ChatOrchestration.ChatResponse
        do {
            let client = makeNativeAgentAppChatOrchestrationClient(
                tools: witness,
                dataRoot: root
            )
            response = try await client.runEphemeralToolTurn(
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
        } catch {
            // Admission remains durable: a provider failure can occur after
            // a journal write and must not silently replay the hour.
            await substrate.recordReceipt(
                kind: "studio.wander_failed",
                payload: .object(["error": .string(String(describing: error))])
            )
            return
        }

        // WHAT SHE ACTUALLY DID, read from the tools she actually CALLED —
        // never from what the reply claims. "I looked at it" is an assertion; a
        // dispatch is evidence, and this whole lane exists because the
        // difference matters.
        let seen = await witness.report()
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
            providerCalls: response.providerCallCount ?? 0,
            at: admittedAt
        )
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
        providerCalls: Int,
        at: Date
    ) async {
        // LAST GATE BEFORE ANYTHING IS WRITTEN. The hour takes real time, and
        // the switch — or the Subconscious master above it — can be turned off
        // while it runs. A lane that is no longer installed must leave nothing
        // behind: no refractory stamp, no trace line, no receipt. Both switches
        // invalidate the cached installation, so this re-resolves rather than
        // reading a stale `.installed`.
        guard await Self.studioWanderIsInstalled(dataRoot: dataRoot) else { return }
        let entry = StudioWanderLane.TraceEntry(
            at: StudioClock.nowISO(at),
            outcome: outcome,
            line: line,
            journalEntryID: journalEntryID
        )
        do { try await StudioWanderLane.recordEndedHour(dataRoot: dataRoot, entry: entry, at: at) }
        catch { await recordStudioWanderPersistenceFailure(error); return }
        await StudioWanderState.shared.noteWanderEnded(for: dataRoot, at: at)
        // Change-only, keyed on outcome + whether an entry landed. A run of
        // identical declines is one receipt; a choice after declines is news.
        let key = "\(outcome.rawValue)|\(journalEntryID ?? "")"
        guard await StudioWanderState.shared.shouldRecord(key, for: dataRoot) else { return }
        var payload: [String: JSONValue] = [
            "outcome": .string(outcome.rawValue),
            "line": .string(String(line.prefix(240))),
            "providerCalls": .int(Int64(providerCalls)),
            "attempt": .int(Int64(await StudioWanderState.shared.attemptCount())),
            // Said out loud so no reader has to infer it.
            "autoJournaled": .bool(false),
            "trace": .string(StudioWanderLane.statePath(dataRoot: dataRoot).path),
        ]
        if let journalEntryID { payload["journalEntryId"] = .string(journalEntryID) }
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
        let fresh = await organismKernel.residualRepairOpportunity()
        let activity = await StudioWanderState.shared.turnActivityOrSeed(for: dataRoot, at: now())
        let installed = Self.studioWanderInstallationNow(dataRoot: dataRoot).isInstalled
        let busy = liveTurnInFlight
        let dream = OrganismIdentityDreamTrigger.decide(opportunity: fresh, turnInFlight: busy)
        return !Task.isCancelled && !isFlushedForTermination && installed
            && StudioWanderLane.decide(
                now: now(), turnInFlight: busy, dreamIsDue: dream == .fire || dream == .turnInFlight,
                lastTurnActivityAt: activity, lastWanderAt: nil,
                inQuietHours: Self.studioWanderInQuietHours(dataRoot: dataRoot, at: now())
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
    /// 2026-09-06: it also reports WHICH sources failed. Every read here was a
    /// bare `try?`, so a store that could not be opened produced exactly the
    /// same empty material as a genuinely empty one — and the runner filed that
    /// as "nothing of mine was in reach", a successful decline that consumed
    /// the 24 h refractory. A read failure is not a decline.
    private func composeStudioWanderMaterial() async -> (
        material: StudioWanderLane.Material, sourceFailures: [String]
    ) {
        let store = SwiftNativeStudioStore(dataRoot: dataRoot)
        var sourceFailures: [String] = []
        let seeds = await substrate.thoughtSeedSnapshot()
        let curiosity = seeds
            .filter { $0.kind == .openQuestion || $0.kind == .anomaly }
            .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
            .map(\.text)

        var invitations: [StudioEncounterCandidate]
        do {
            invitations = try await store.namedEncounterIntake()
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

        let material = StudioWanderLane.Material(
            curiosity: curiosity,
            // An invitation she cannot open is a tease. A consult User filed is
            // named by its id, and `studio_consult_read` is the only way to see
            // the artifact refs inside it — so the line carries the id, and the
            // prompt names the tool. Without this she was being shown one-line
            // summaries of works and asked to judge them, which is the
            // description-only encounter her own rule forbids.
            invitations: invitations.map { candidate in
                guard candidate.source == .named else { return candidate.invitationLine }
                return "\(candidate.invitationLine) "
                    + "[studio_consult_read consult_id: \(candidate.originID)]"
            },
            recentJournalTitles: Array(recentTitles)
        )
        return (material, sourceFailures)
    }

    /// Her hour has its own routing row: model and reasoning effort are chosen in
    /// Providers beside `dream` and `cognition_reflection`, because whose model
    /// she thinks with when nobody is watching is a real choice and not an
    /// inherited default.
    static let studioWanderSurface = "studio_wander"

    /// Her closing line, bounded. Never rewritten, never summarized — the last
    /// non-empty line of what she said, which is what the prompt asked her for.
    static func studioWanderLine(_ output: String) -> String {
        let line = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("#") }
        guard let line, !line.isEmpty else { return "The hour passed without a word." }
        return String(line.prefix(240))
    }
}

/// WHAT SHE ACTUALLY DID, witnessed at the dispatch seam.
///
/// The wander lane must distinguish three endings that a reply text cannot be
/// trusted to distinguish: she chose and met the work, she reached for it and
/// could not receive it, and she declined. All three are legitimate, and the
/// difference between the first two is her hardest veto ("honest encounters
/// only"), so it is decided by DISPATCHES, not by prose.
///
/// This wrapper adds no policy of its own: every call passes straight through
/// to the same gated chain a chat turn uses, and refusals stay refusals. It only
/// remembers what went by.
actor StudioWanderToolWitness: ToolDispatchClient {
    struct Report: Sendable, Equatable {
        var attemptedArtifact: Bool
        var obtainedArtifact: Bool
        var journalEntryID: String?
    }

    /// REACHING for a work. Navigation counts here: opening the page IS the
    /// attempt, and an attempt that never becomes a delivery is exactly the
    /// `no_artifact` ending.
    ///
    /// `screen` is absent on purpose. Glancing at whatever happens to be in
    /// front of her is not reaching for anything.
    static let artifactOrgans: Set<String> = deliveringOrgans.union([
        "browser.open_url", "browser_open_url",
        // Opening the consult User left on the table IS reaching for the work it
        // names. Whether it DELIVERS depends on what the envelope carries — see
        // `consultDelivered`.
        "studio_consult_read",
    ])

    /// RECEIVING one. Only these can prove she actually met the work: the page's
    /// text, its links, a picture of it, the document itself, the file itself,
    /// the window itself. Deliberately narrower than the turn's allowlist — a
    /// tool added tomorrow does not silently start counting as an encounter.
    ///
    /// Both spellings for the browser family, for the same reason the allowlist
    /// carries both: this witness sees the name the model emitted.
    static let deliveringOrgans: Set<String> = [
        "browser.read_text", "browser_read_text",
        "browser.read_links", "browser_read_links",
        "browser.screenshot", "browser_screenshot",
        "read", "read_file", "file_excerpt", "mac_view", "mac_look",
    ]

    private let inner: any ToolDispatchClient
    private let shouldContinue: @Sendable () async -> Bool
    private var attempted = false
    private var obtained = false
    private var journalEntryID: String?

    init(inner: any ToolDispatchClient, shouldContinue: @escaping @Sendable () async -> Bool = { true }) {
        self.inner = inner
        self.shouldContinue = shouldContinue
    }

    func report() -> Report {
        Report(
            attemptedArtifact: attempted,
            obtainedArtifact: obtained,
            journalEntryID: journalEntryID
        )
    }

    nonisolated func dispatch(
        tool: String,
        input: [String: JSONValue],
        surface: String
    ) async throws -> JSONValue {
        guard await shouldContinue(), !Task.isCancelled else { throw CancellationError() }
        if Self.artifactOrgans.contains(tool) { await noteArtifactAttempt() }
        do {
            let result = try await inner.dispatch(tool: tool, input: input, surface: surface)
            if Self.delivered(tool: tool, result: result) { await noteArtifactObtained() }
            if tool == "studio_journal", let id = Self.journalEntryID(in: result) {
                await noteJournalEntry(id)
            }
            return result
        } catch {
            // A refused or failed organ is exactly the `no_artifact` evidence
            // this witness exists to keep. Rethrow: she must see the failure.
            throw error
        }
    }

    nonisolated func listAvailableTools() async throws -> [String] {
        try await inner.listAvailableTools()
    }

    nonisolated func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas()
    }

    private func noteArtifactAttempt() { attempted = true }
    private func noteArtifactObtained() { obtained = true }
    private func noteJournalEntry(_ id: String) { journalEntryID = id }

    /// DID THIS CALL PUT THE WORK IN FRONT OF HER?
    ///
    /// Three rules, because three organs answer the question differently:
    ///
    ///   * A reading organ (`read`, `read_file`, `browser.read_text`, …) that
    ///     returned a real result delivered.
    ///   * `browser.open_url` delivers ONLY when it was asked to CAPTURE —
    ///     `sourceReceipt`/`screenshotReceipt` on the browser run receipt. A
    ///     bare navigation opened a window and returned; nothing came back to
    ///     her, so the page is not yet a work she has met.
    ///   * `studio_consult_read` discovers references, not artifact content.
    ///     Only a subsequent read or capture witnesses an encounter.
    static func delivered(tool: String, result: JSONValue) -> Bool {
        guard succeeded(result) else { return false }
        if tool == "browser.open_url" || tool == "browser_open_url" {
            return carriesCapture(result)
        }
        if tool == "studio_consult_read" { return false }
        return deliveringOrgans.contains(tool)
    }

    /// A browser run that actually brought something back. The run receipt
    /// carries `sourceReceipt` / `screenshotReceipt` as an object when the call
    /// asked to capture, and `.null` when it did not
    /// (Browser+OperationStore.swift).
    static func carriesCapture(_ result: JSONValue) -> Bool {
        for key in ["sourceReceipt", "screenshotReceipt", "source_receipt", "screenshot_receipt"] {
            if case .object? = deepValue(result, key) { return true }
        }
        return false
    }

    /// Read a key from the payload or from one level of nesting (`consult`,
    /// `output`, `run`), which is how these executors wrap their bodies.
    static func deepValue(_ result: JSONValue, _ key: String) -> JSONValue? {
        guard case .object(let object) = result else { return nil }
        if let direct = object[key] { return direct }
        for wrapper in ["consult", "output", "run", "receipt"] {
            if case .object(let nested)? = object[wrapper], let found = nested[key] {
                return found
            }
        }
        return nil
    }

    /// DID THIS ACTUALLY RETURN ANYTHING?
    ///
    /// Read from the real terminal payload. The browser organs return a native
    /// action receipt — `{"status": "completed" | "dry_run", "dryRun": Bool, …}`
    /// (NativeClient+NativeActions `appendNativeActionReceipt`) — so a dry run
    /// reports success in the ordinary sense while having read nothing at all.
    /// Counting that as an encounter is precisely the dishonesty her veto is
    /// about, so `dry_run` and `dryRun: true` are both non-deliveries, as are
    /// refusals and errors.
    static func succeeded(_ result: JSONValue) -> Bool {
        guard case .object(let object) = result else { return true }
        if case .bool(true)? = object["dryRun"] { return false }
        guard case .string(let status)? = object["status"] else { return true }
        return !["refused", "error", "failed", "dry_run"].contains(status)
    }

    static func journalEntryID(in result: JSONValue) -> String? {
        guard case .object(let object) = result else { return nil }
        for key in ["entry_id", "id"] {
            if case .string(let value)? = object[key], !value.isEmpty { return value }
        }
        if case .object(let entry)? = object["entry"],
           case .string(let value)? = entry["id"], !value.isEmpty {
            return value
        }
        return nil
    }
}

extension NativeCognitionRuntime {
    /// Called by the Settings toggle. Installation is resolved once per data
    /// root and cached, so flipping the switch has to drop that cache — turning
    /// the lane OFF must uninstall it now, not at the next relaunch.
    static func reloadStudioWanderInstallation(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        await StudioWanderState.shared.invalidateInstallation(for: dataRoot)
    }
}

/// WHAT SHE MAY REACH IN AN HOUR OF HER OWN — the admission list, enforced at
/// the dispatch seam and at the advertised catalog.
///
/// ── WHY AN ALLOWLIST AND NOT A DENY LIST ────────────────────────────────────
/// `runEphemeralToolTurn` inherits the whole catalog, and `fileAccess:
/// "read_only"` gates the FILESYSTEM, not the world: it blocks `write_file` and
/// the shells and leaves `act`, `go`, `mail_send`, `messages_send`,
/// `slack_post_message`, `agentmail_send`, `claude_message`, `codex_message`,
/// `invoke_codex`, `agent_swarm`, `commit_memory`, `workshop_submit`, the
/// `desk_*` mutations and every external MCP tool fully reachable. A deny list
/// over that surface fails OPEN the moment somebody adds a tool — which is the
/// one direction an unattended, unwitnessed lane must never fail. So this is an
/// allowlist: anything not named here is neither advertised nor dispatchable,
/// and a tool shipped tomorrow is unavailable to her hour until someone
/// deliberately decides otherwise.
///
/// ── WHAT AN HOUR IS FOR ─────────────────────────────────────────────────────
/// Look, and write in her own journal. That is the whole capability. She cannot
/// speak as User, cannot touch his board, cannot wake another agent, cannot move
/// what is on his screen, and cannot change what she knows — none of which she
/// needs in order to sit with a work and say what she thinks of it.
///
/// ── THE REFUSAL IS SPOKEN ───────────────────────────────────────────────────
/// A blocked tool throws with a sentence she can read, naming what she may use
/// instead. Silence would leave her guessing at her own edges, and an hour spent
/// guessing is not an hour spent looking.
struct StudioWanderToolAllowlist: ToolDispatchClient {
    let inner: any ToolDispatchClient

    static let admitted: Set<String> = [
        // ── Perception. Every one of these is documented read-only; none of
        //    them activates, raises, opens, presses or types.
        "screen",
        // `read` is the document organ — "It presses nothing, types nothing and
        // opens nothing." Without it there is no way to receive a PDF or a long
        // article at all, and an hour that cannot receive a work cannot hold an
        // honest encounter. ADDED beyond the named list for that reason.
        "read",
        "mac_view", "mac_look",
        // ── The artifact, when it is a local file.
        "read_file", "file_excerpt",
        // ── The artifact, when it is remote. These are the app's REAL browser
        //    tools (AppChatToolDispatcher `canonicalBrowserToolName`), and they
        //    are the READ half only: open a page, take its text, its links, or a
        //    picture of it. `web_fetch`/`web_search` do not exist in this
        //    build's catalog and are deliberately not named here.
        //
        //    THE DELIBERATE EXCEPTION (coordinator's call, 2026-09-02):
        //    `browser.open_url` navigates the VISIBLE browser, which is the one
        //    thing in this list that changes something a person could see. It is
        //    admitted anyway, because it is how she looks at a work: there is no
        //    headless fetch organ in this build, so refusing navigation would
        //    not make her hour safer — it would make a remote encounter
        //    impossible and quietly reduce her studio to whatever is already on
        //    the local disk. Navigating to a page she chose is looking at
        //    something; it sends nothing, submits nothing and speaks to nobody.
        //
        //    `browser.navigate` is NOT admitted even though it shares an
        //    executor: one public alias for the one thing she may do keeps the
        //    admitted set legible.
        //
        //    Every `browser.chrome_*` tool is excluded — click, fill, type,
        //    keypress, select, set_checked, double_click, scroll, wait — because
        //    those drive a real browser session as the user. She may LOOK at a
        //    page in her own hour; she may not use one.
        //
        //    Both spellings: this wrapper sits OUTSIDE the app dispatcher, so it
        //    sees whatever the model emitted, and the dotted names ship with
        //    documented provider-safe underscore aliases.
        "browser.status", "browser_status",
        "browser.open_url", "browser_open_url",
        "browser.read_text", "browser_read_text",
        "browser.read_links", "browser_read_links",
        "browser.screenshot", "browser_screenshot",
        // ── Her studio. `studio_journal` is the ONLY write in the whole list,
        //    and it is hers: nothing else may call it during the hour, and
        //    nothing calls it for her.
        //
        //    `studio_consult` is NOT here: it FILES a consult envelope
        //    (`fileConsult`, a real write into data/studio/consults/), and an
        //    unattended hour has no business minting consults. What she needs is
        //    the read half — the invitations she is shown are consults User left
        //    on the table, and she must be able to open one and see its actual
        //    artifact refs rather than judging it from a one-line summary.
        //
        //    `studio_canon_resolve` is deliberately absent — the canon seat
        //    requires a live chat turn and would refuse a background lane
        //    anyway; leaving it out means the refusal never has to be relied on.
        "studio_journal", "studio_recall", "studio_consult_read",
        // ── Her own memory and context, read-only.
        "recall_memory", "search_kg", "context_expand",
        "list_skills", "read_skill",
        // ── Orientation.
        "time_now", "inner_state",
        // Discovery is read-only; dispatch filters its answer to this same set.
        "tool_catalog", "list_tools",
        // Mechanical plumbing, not a capability: `read` returns a bounded
        // summary plus a `result_handle` for anything long, and its own schema
        // says to page with this rather than re-running. Without it a long
        // document is half-received, which is the exact dishonesty the honest-
        // encounter rule exists to prevent. ADDED beyond the named list.
        "tool_result_page",
    ]

    /// Discovery tools that ENUMERATE the catalog. They stay available — she
    /// needs to know what she has — but their answer is scrubbed to the
    /// admitted set on the way out.
    static let catalogTools: Set<String> = ["tool_catalog", "list_tools"]

    func dispatch(
        tool: String,
        input: [String: JSONValue],
        surface: String
    ) async throws -> JSONValue {
        guard Self.admitted.contains(tool) else {
            throw AutonomyGateError.toolDenied(reason: Self.refusal(tool))
        }
        let result = try await inner.dispatch(tool: tool, input: input, surface: surface)
        guard Self.catalogTools.contains(tool) else { return result }
        // The catalog answers from the WHOLE app surface — `browser_tools`,
        // `organism_tools`, `notification_tools`, `tool_groups`, the capability
        // rows — none of which this wrapper filtered, because none of it went
        // through `listAvailableToolSchemas`. Unscrubbed it would hand her a
        // menu of `browser.navigate`, every `chrome_*`, the notification tools
        // and the rest, all of which `dispatch` will then refuse. Advertising
        // what she cannot have is the "ignored is worse than absent" failure in
        // its most literal form, so the menu is trimmed to what is real.
        return Self.scrubCatalog(result)
    }

    /// Structural, not key-by-key: any array of tool names is filtered, any row
    /// carrying a `name` is filtered, and any group that empties out is dropped.
    /// A catalog key added tomorrow is scrubbed by the same rule rather than
    /// leaking until someone remembers to name it here.
    static func scrubCatalog(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            var out: [String: JSONValue] = [:]
            for (key, child) in object {
                // A row object naming a non-admitted tool is dropped whole by
                // the array case below; recurse for everything else.
                out[key] = scrubCatalog(child)
            }
            return .object(out)
        case .array(let items):
            var kept: [JSONValue] = []
            for item in items {
                switch item {
                case .string(let name):
                    // Only filter things that look like tool names. A prose
                    // array (descriptions, reasons) has no admitted member and
                    // must not be silently emptied — so a wholly non-tool array
                    // is left alone by the guard after this loop.
                    if admitted.contains(name) { kept.append(item) }
                case .object(let row):
                    if case .string(let name)? = row["name"], !admitted.contains(name) {
                        continue
                    }
                    kept.append(scrubCatalog(item))
                default:
                    kept.append(scrubCatalog(item))
                }
            }
            // A string array that mentioned no tool at all is prose, not a tool
            // list; return it untouched rather than blanking it.
            let strings = items.compactMap { item -> String? in
                if case .string(let name) = item { return name } else { return nil }
            }
            if !strings.isEmpty, strings.count == items.count,
               !strings.contains(where: { admitted.contains($0) || looksLikeToolName($0) }) {
                return value
            }
            return .array(kept)
        default:
            return value
        }
    }

    /// A conservative shape test, used only to tell "a list of tools that
    /// happens to contain none of mine" from "a sentence". Tool names in this
    /// app are lowercase identifiers, optionally dotted or `mcp__`-prefixed.
    static func looksLikeToolName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64, !value.contains(" ") else { return false }
        return value.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" || $0 == "." }
    }

    /// The advertised half. Filtering here is what keeps the blocked tools out
    /// of the request entirely: `runEphemeralToolTurn` derives its
    /// `turnActiveTools` from this walk, so an unadmitted tool is never put in
    /// front of her as an option she has to decline.
    func listAvailableTools() async throws -> [String] {
        try await inner.listAvailableTools().filter { Self.admitted.contains($0) }
    }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas().filter { Self.admitted.contains($0.name) }
    }

    static func refusal(_ tool: String) -> String {
        "'\(tool)' is not available in your own hour. This time is for looking and, if you "
        + "want to, writing in your journal — it cannot reach anyone, move anything on "
        + "User's screen, or change what you know. You have: "
        + admitted.sorted().joined(separator: ", ")
        + ". Nothing was done."
    }
}
