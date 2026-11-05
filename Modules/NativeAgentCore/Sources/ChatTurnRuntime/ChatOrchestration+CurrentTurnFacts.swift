import AgentWorkspace
import AgentConversations
import Foundation
import Transcripts
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import MemoryV2
import ProviderRouting
import TrustCenter
import Context
import Experiences
import ChatToolRuntime
// Blueprint: | `ChatOrchestration+CurrentTurnFacts.swift` | `SwiftNativeTurnEngine`; Parallel read-only facts; consuming reads at composition |

extension SwiftNativeTurnEngine {
    /// Gather read-only facts before context exists so failed assembly consumes nothing; defer consuming reads until composition.
    typealias ReadOnlyTurnFacts = (
        clock: String, note: String?, directive: String?,
        voiceStep: String?, place: String?, glance: PreparedWorkspaceGlance?, contacts: JSONValue,
        elsewhere: AgentScreen.ElsewhereReading?, body: BodyFelt.Pending?, timings: [ContextStageName: Int64]
    )

    private nonisolated static func timedFact<T: Sendable>(_ read: @Sendable () async -> T) async -> (value: T, ms: Int64) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = await read()
        return (value, Int64((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000))
    }

    /// Independent facts gather beside history and context assembly; consuming reads wait for composition.
    func currentTurnFacts(
        clockNow: Date,
        quietHours: TurnQuietHoursWindow?,
        sessionID: String?,
        queryUserMessage: String,
        turn: Turn, work: ChatTurnWork
    ) async throws -> ReadOnlyTurnFacts {
        // Contacts depend on neither assembled context nor history taint, so read them beside the other facts.
        let dataRoot = remPinsDataRoot
        async let contacts = Self.timedFact { Self.currentTurnContacts(dataRoot: dataRoot, turn: turn) }
        // Every turn kind (the person's, the agent's own wakes, peers') builds its facts here, so each one feels what the agent's body did not predict.
        async let body = { () async -> BodyFelt.Pending? in
            guard let dataRoot else { return nil }
            return await BodyFelt.pending(dataRoot: dataRoot, now: clockNow)
        }()
        let notesStart = DispatchTime.now().uptimeNanoseconds
        let clock = Self.renderClockContext(now: clockNow, quietHours: quietHours)
        // Workspace glances belong in the dynamic segment and are withheld from helper sessions.
        let glanceRead = try remPinsDataRoot.flatMap { root in try sessionID.flatMap { try SessionConversation.checkedIsHelper($0, dataRoot: root) ? nil : (
            root, $0) } }
        async let glance = Self.timedFact { () async -> PreparedWorkspaceGlance? in
            guard let read = glanceRead else { return nil }
            return await ChatWorkspaceBinding.glance(turn: turn, invocation: work.invocation,
                dataRoot: read.0, scope: read.1, at: clockNow, message: queryUserMessage)
        }
        // Updates remain pending until requested delivery; directives are session-scoped so another conversation cannot consume them.
        let note = try remPinsDataRoot.flatMap { try ChatUpdateNote.pendingNote(dataRoot: $0) }
        let directive = try remPinsDataRoot.flatMap { root in
            try sessionID.flatMap { try ChatSessionDirective.pendingDirective(dataRoot: root, sessionID: $0) }
        }
        let voiceStep = try FirstConversationPersonaProgression.pendingVoiceDirective(
            dataRoot: remPinsDataRoot, sessionID: sessionID
        )
        let notesMs = Int64((DispatchTime.now().uptimeNanoseconds - notesStart) / 1_000_000)
        async let place = Self.timedFact { () async -> String? in
            guard ContextCorrectionScope.isReferentialFollowup(queryUserMessage), let read = glanceRead else { return nil }
            return await ChatWorkspaceBinding.currentPlace(dataRoot: read.0, scope: read.1)
        }
        async let elsewhere = Self.timedFact { () async -> AgentScreen.ElsewhereReading? in
            guard let read = glanceRead else { return nil }
            return await ChatWorkspaceBinding.readElsewhere(turn: turn, invocation: work.invocation,
                dataRoot: read.0, scope: read.1, at: clockNow, live: ChatTurnSteering.liveSessions(dataRoot: read.0))
        }
        let (readContacts, readPlace, readGlance, readElsewhere, readBody) = await (contacts, place, glance, elsewhere, body)
        return (clock, note, directive, voiceStep, readPlace.value, readGlance.value, readContacts.value,
            readElsewhere.value, readBody, [.factsClockNotes: notesMs, .factsContacts: readContacts.ms, .factsPlace: readPlace.ms,
                                  .factsGlance: readGlance.ms, .factsElsewhereRead: readElsewhere.ms])
    }

    /// Consume elsewhere words after history binds taint and announce workspace arrivals only on delivery.
    /// Compose dynamic facts before the runtime line so it names the route admitted for this context.
    func contextByAppendingCurrentTurnFacts(
        _ context: TurnContext,
        facts: ReadOnlyTurnFacts,
        sessionID: String?,
        clockNowOverride: Date?,
        trace: inout ContextStageTrace,
        turn: Turn, work: ChatTurnWork
    ) async throws -> TurnContext {
        for (stage, ms) in facts.timings { trace.setTiming(stage, milliseconds: ms) }
        // AgentScreen owns cross-door continuity; peer-steered turns omit the person's words and bridge activity.
        var elsewhere: String?
        var agentNow: AgentNowCursor?
        let elsewhereStart = DispatchTime.now().uptimeNanoseconds
        if let dataRoot = remPinsDataRoot, let sessionID, try !SessionConversation.checkedIsHelper(sessionID, dataRoot: dataRoot) {
            let origin = turn.origin
            let surface = [origin?.surface, turn.envelope?.surface].compactMap { $0 }
                .first { AgentScreen.door($0) != nil } ?? context.surface
            let taint = turn.peerSteering
            let lane = origin?.agent == "agent"
                ? turn.envelope?.verifiedUserId.map { "peer:" + $0 } : origin?.agent
            let laneSteered = (surface.hasSuffix("-bridge") || origin?.surface.hasSuffix("-bridge") == true
                || origin?.agent != nil) && !(lane.map { PeerTrust.ownerTrusts($0, dataRoot: dataRoot) } ?? false)
            let peer = laneSteered || PeerTurnEffectPolicy.isPeerBridge(surface: surface)
                || taint?.isTainted == true || taint?.elevatedSources.isEmpty == false
            elsewhere = await ChatWorkspaceBinding.elsewhere(turn: turn, invocation: work.invocation,
                dataRoot: dataRoot, scope: sessionID, surface: surface,
                peer: peer, at: clockNowOverride, reading: facts.elsewhere)
            if AgentScreen.door(surface) != nil {
                agentNow = AgentNowCursor(at: facts.elsewhere?.failed == true ? nil : clockNowOverride ?? Date(), peer: peer)
            }
        }
        trace.record(.factsElsewhere, since: elsewhereStart)
        let arrivalsStart = DispatchTime.now().uptimeNanoseconds
        let arrivals = try await ChatWorkspaceBinding.pending(turn: turn, invocation: work.invocation,
            dataRoot: remPinsDataRoot, scope: sessionID)
            .map { try $0.serialize(pretty: false) }
            .map { "Workspace arrivals (navigation notices, not requests):\n" + $0 }
        trace.record(.factsArrivals, since: arrivalsStart)
        let runtimeStart = DispatchTime.now().uptimeNanoseconds
        defer { trace.record(.factsRuntime, since: runtimeStart) }
        let all = [facts.clock, facts.note, facts.directive, elsewhere, facts.voiceStep, arrivals,
                   facts.place, facts.glance?.text, facts.body?.line].compactMap { $0 }
        var withFacts = all.reduce(context) { Self.contextByAppendingRuntimeContext($0, runtimeContext: $1) }
        withFacts.partsDelivery = facts.glance?.delivered
        withFacts.bodyFelt = facts.body
        withFacts.agentNow = agentNow
        // Organ ids only: the line itself carries organ notes and stays out of traces.
        trace.setCount("body.feltOrgans", facts.body?.organs.count ?? 0)
        if let body = facts.body { trace.setLabel("body.felt", body.organs.joined(separator: ",")) }
        guard let runtimeContext = await renderRuntimeContext(
            surface: withFacts.surface,
            modelId: withFacts.modelId,
            providerId: withFacts.providerId,
            factIndex: withFacts.turnReach.facts.count,
            contacts: facts.contacts
        ) else {
            return withFacts
        }
        withFacts = Self.contextByAppendingRuntimeContext(withFacts, runtimeContext: runtimeContext.report)
        withFacts.turnReach.runtime = runtimeContext.input
        return withFacts
    }

    func creditDeliveredMemories(_ context: TurnContext) {
        guard !context.usageCreditMemoryIDs.isEmpty, let memory else { return }
        let ids = context.usageCreditMemoryIDs
        Task { await memory.recordServedContextHits(ids: ids) }
    }

    /// Workspace arrivals the accepted context carried, by their exact ids. A
    /// refusal or cancellation before provider output leaves them to announce.
    func announceDeliveredArrivals(in context: TurnContext, sessionID: String?) async {
        guard let dataRoot = remPinsDataRoot, let sessionID else { return }
        await ChatWorkspaceBinding.announceDelivered(dataRoot: dataRoot, scope: sessionID, in: Self.deliveredInput(context))
    }

    static func deliveredInput(_ context: TurnContext) -> String {
        [context.systemPrompt, context.turnVolatileBlock].compactMap { $0 }.joined(separator: "\n\n")
    }

    /// Capture only pending instructions actually present in the prepared
    /// context. A refusal before provider output leaves the records pending.
    func pendingInstructionDelivery(in context: TurnContext, sessionID: String?) throws -> (@Sendable () throws -> Void)? {
        guard let dataRoot = remPinsDataRoot else { return nil }
        let input = Self.deliveredInput(context)
        let note = try ChatUpdateNote.pendingNote(dataRoot: dataRoot).flatMap { input.contains($0) ? $0 : nil }
        let directive = try sessionID.flatMap {
            try ChatSessionDirective.pendingDirective(dataRoot: dataRoot, sessionID: $0)
        }.flatMap { input.contains($0) ? $0 : nil }
        let voice = try FirstConversationPersonaProgression.pendingVoiceDirective(dataRoot: dataRoot, sessionID: sessionID)
            .flatMap { input.contains($0) ? $0 : nil }
        let body = context.bodyFelt.flatMap { input.contains($0.line) ? $0 : nil }
        guard note != nil || directive != nil || voice != nil || body != nil else { return nil }
        return {
            if let body { BodyFelt.markSaid(body, dataRoot: dataRoot) }
            guard note != nil || directive != nil || voice != nil else { return }
            do {
            if let note {
                try ChatUpdateNote.markDelivered(dataRoot: dataRoot, expectedNote: note)
            }
            if let directive, let sessionID {
                try ChatSessionDirective.markDelivered(dataRoot: dataRoot, sessionID: sessionID, expectedDirective: directive)
            }
            if let voice, let sessionID {
                try FirstConversationPersonaProgression.markVoiceDirectiveDelivered(
                    dataRoot: dataRoot, sessionID: sessionID, expectedDirective: voice)
            }
            RepairOwed.settle(dataRoot, operation: "turn.instructions.delivered:" + (sessionID ?? "update"), evidence: .init(source: "context",
                id: sessionID ?? "update_note"))
            } catch {
                let words = """
                    The provider accepted this turn's instructions, but their delivery stamp could not be saved: \(error.localizedDescription). \
                    Repair the instruction store before consuming them again.
                    """
                RepairOwed.owe(dataRoot, id: UUID().uuidString, kind: .run, operation: "turn.instructions.delivered:" + (sessionID ?? "update"),
                    owner: "context", words: words)
                throw ToolFailureError(words, effects: .occurred, owner: "context", code: "instruction_delivery_stamp_failed", recovery: .repair)
            }
        }
    }

    private func renderRuntimeContext(
        surface: String,
        modelId: String,
        providerId: String?,
        factIndex: Int,
        contacts: JSONValue
    ) async -> (report: String, input: JSONValue)? {
        let model = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        let normalizedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let surfaceName = normalizedSurface.isEmpty ? "chat" : normalizedSurface
        let provider = providerId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerName: String
        if let provider, !provider.isEmpty { providerName = provider }
        else { providerName = "unavailable (this turn has no admitted provider identity)" }
        // Only the app's own chat receives its window mode; unset leaves the prompt unchanged.
        let defaults = UserDefaults.standard
        let viewMode = surfaceName != "chat" ? nil
            : defaults.string(forKey: "nativeagent.viewMode")
        return (Self.renderRuntimeContext(surface: surfaceName, provider: providerName, model: model),
                .object(["view_mode": viewMode.map(JSONValue.string) ?? .null, "contacts": contacts,
                         "fact_index": .int(Int64(factIndex))]))
    }

    /// Read the canonical contact owner each turn so reachability and trust stay independent and current.
    private nonisolated static func currentTurnContacts(dataRoot: URL?, turn: Turn) -> JSONValue {
        guard let dataRoot else {
            return .object(["status": .string("unavailable"), "reason": .string("No contact data root was supplied.")])
        }
        do {
            return .object(["status": .string("available"),
                "rows": .array(try AgentPeerStore(dataRoot: dataRoot).contactSummaries(turn: turn).map(JSONValue.string))])
        } catch {
            // Storage diagnostics stay with their native owner, not in a part's input.
            return .object(["status": .string("unavailable"), "reason": .string("Contact storage could not be read.")])
        }
    }

    nonisolated static func contextByAppendingRuntimeContext(
        _ context: TurnContext,
        runtimeContext: String
    ) -> TurnContext {
        let trimmed = runtimeContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return context }
        var copy = context
        copy.turnReach.facts.append(trimmed)
        return copy
    }

    /// Human wall-clock and active quiet hours belong in the dynamic segment to keep the prefix stable.
    nonisolated static func renderClockContext(
        now: Date,
        localTimeZone: TimeZone = .current,
        quietHours: TurnQuietHoursWindow? = nil
    ) -> String {
        let local = formatClockDate(now, timeZone: localTimeZone)
        var line = "Local time: \(local) (\(localTimeZone.identifier))."
        if let quietHours {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = localTimeZone
            let hour = calendar.component(.hour, from: now)
            if quietHours.contains(hour: hour) {
                line += " Quiet hours: \(formatHour(quietHours.startHour))–\(formatHour(quietHours.endHour)) local."
            }
        }
        return line
    }

    nonisolated static func renderRuntimeContext(
        surface: String,
        provider: String,
        model: String
    ) -> String {
        "Current runtime: surface=\(surface); provider=\(provider); model=\(model)."
    }

    /// Spell out weekday and AM/PM so the time-of-day word need not be inferred from a 24-hour number.
    private nonisolated static func formatClockDate(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a zzz"
        return formatter.string(from: date)
    }

    private nonisolated static func formatHour(_ hour: Int) -> String {
        let normalized = ((hour % 24) + 24) % 24
        let suffix = normalized < 12 ? "AM" : "PM"
        let display = normalized % 12 == 0 ? 12 : normalized % 12
        return "\(display):00 \(suffix)"
    }
}
