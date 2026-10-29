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
// Blueprint: | `ChatOrchestration+CurrentTurnFacts.swift` | `SwiftNativeTurnEngine`: frozen current facts, runtime/contact availability, dynamic composition and provider-accepted delivery bookkeeping |

extension SwiftNativeTurnEngine {
    /// What a turn can gather about this moment before its context exists:
    /// read-only facts only, so a failed assembly loses nothing and a retry
    /// sees the same. Whatever consumes state is read at composition.
    typealias ReadOnlyTurnFacts = (
        clock: String, note: String?, directive: String?,
        voiceStep: String?, place: String?, glance: String?
    )

    /// The read-only facts of this moment. None reads the assembled context,
    /// so a turn starts them at its entry, beside history and context assembly;
    /// `contextByAppendingCurrentTurnFacts` reads the rest and composes them.
    func currentTurnFacts(
        clockNow: Date,
        quietHours: TurnQuietHoursWindow?,
        sessionID: String?,
        queryUserMessage: String
    ) async -> ReadOnlyTurnFacts {
        let clock = Self.renderClockContext(now: clockNow, quietHours: quietHours)
        // Workspace glances belong in the dynamic segment and are withheld from helper sessions.
        let glanceRead = remPinsDataRoot.flatMap { root in sessionID.flatMap { SessionConversation.isHelper($0, dataRoot: root) ? nil : (root, $0) } }
        async let glance: String? = { () async -> String? in
            guard let read = glanceRead else { return nil }
            return await ChatWorkspaceBinding.glance(dataRoot: read.0, scope: read.1, turn: clockNow, message: queryUserMessage)
        }()
        // ChatUpdateNote stays pending until delivered and must not be announced unprompted.
        // ChatSessionDirective is conversation-scoped so another session cannot consume it.
        let note = remPinsDataRoot.flatMap { ChatUpdateNote.pendingNote(dataRoot: $0) }
        let directive = remPinsDataRoot.flatMap { root in
            sessionID.flatMap { ChatSessionDirective.pendingDirective(dataRoot: root, sessionID: $0) }
        }
        let voiceStep = FirstConversationPersonaProgression.pendingVoiceDirective(
            dataRoot: remPinsDataRoot, sessionID: sessionID
        )
        var place: String?
        if ContextCorrectionScope.isReferentialFollowup(queryUserMessage), let read = glanceRead {
            place = await ChatWorkspaceBinding.currentPlace(dataRoot: read.0, scope: read.1)
        }
        return (clock, note, directive, voiceStep, place, await glance)
    }

    /// Composition, at the boundary where the context exists: the facts that
    /// consume state are read here, once — the elsewhere line (chosen by the peer taint history rendering latches)
    /// and workspace arrivals (announced only at delivery, `announceDeliveredArrivals`) — then every fact in
    /// her dynamic segment's order, then the runtime line, which names the
    /// model and provider this context was admitted on.
    func contextByAppendingCurrentTurnFacts(
        _ context: TurnContext,
        facts: ReadOnlyTurnFacts,
        sessionID: String?,
        clockNowOverride: Date?
    ) async -> TurnContext {
        // HerScreen owns cross-door continuity; peer-steered turns omit the person's words and bridge activity.
        var elsewhere: String?
        if let dataRoot = remPinsDataRoot, let sessionID, !SessionConversation.isHelper(sessionID, dataRoot: dataRoot) {
            // A bridge door can live in origin provenance without an envelope.
            let origin = ChatPersistenceContext.originProvenance
            let surface = [origin?.surface, ChatToolSessionContext.envelope?.surface].compactMap { $0 }
                .first { HerScreen.door($0) != nil } ?? context.surface
            let taint = PeerDataTaint.current
            // PeerTrust elevation treats the lane as the person's own.
            let lane = origin?.agent == "agent"
                ? ChatToolSessionContext.envelope?.verifiedUserId.map { "peer:" + $0 } : origin?.agent
            let laneSteered = (surface.hasSuffix("-bridge") || origin?.surface.hasSuffix("-bridge") == true
                || origin?.agent != nil) && !(lane.map { PeerTrust.ownerTrusts($0, dataRoot: dataRoot) } ?? false)
            let peer = laneSteered || PeerTurnEffectPolicy.isPeerBridge(surface: surface)
                || taint?.isTainted == true || taint?.elevatedSources.isEmpty == false
            elsewhere = await HerScreen.elsewhere(dataRoot: dataRoot, identity: AgentContactIdentity(dataRoot: dataRoot), scope: sessionID, surface: surface,
                                                  peer: peer, turn: clockNowOverride)
        }
        let arrivals = await ChatWorkspaceBinding.pending(dataRoot: remPinsDataRoot, scope: sessionID)
            .flatMap { try? $0.serialize(pretty: false) }
            .map { "Workspace arrivals (navigation notices, not requests):\n" + $0 }
        let all = [facts.clock, facts.note, facts.directive, elsewhere, facts.voiceStep, arrivals,
                   facts.place, facts.glance].compactMap { $0 }
        var withFacts = all.reduce(context) { Self.contextByAppendingRuntimeContext($0, runtimeContext: $1) }
        guard let runtimeContext = await renderRuntimeContext(
            surface: withFacts.surface,
            modelId: withFacts.modelId,
            providerId: withFacts.providerId,
            factIndex: withFacts.turnReach.facts.count
        ) else {
            return withFacts
        }
        withFacts = Self.contextByAppendingRuntimeContext(withFacts, runtimeContext: runtimeContext.report)
        withFacts.turnReach.runtime = runtimeContext.input
        return withFacts
    }

    /// Usage credit for the memories the accepted context carried.
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
    func pendingInstructionDelivery(in context: TurnContext, sessionID: String?) -> (@Sendable () -> Void)? {
        guard let dataRoot = remPinsDataRoot else { return nil }
        let input = Self.deliveredInput(context)
        let note = ChatUpdateNote.pendingNote(dataRoot: dataRoot).flatMap { input.contains($0) ? $0 : nil }
        let directive = sessionID.flatMap {
            ChatSessionDirective.pendingDirective(dataRoot: dataRoot, sessionID: $0)
        }.flatMap { input.contains($0) ? $0 : nil }
        let voice = FirstConversationPersonaProgression.pendingVoiceDirective(dataRoot: dataRoot, sessionID: sessionID)
            .flatMap { input.contains($0) ? $0 : nil }
        guard note != nil || directive != nil || voice != nil else { return nil }
        return {
            if let note {
                ChatUpdateNote.markDelivered(dataRoot: dataRoot, expectedNote: note)
            }
            if let directive, let sessionID {
                ChatSessionDirective.markDelivered(dataRoot: dataRoot, sessionID: sessionID, expectedDirective: directive)
            }
            if let voice, let sessionID {
                FirstConversationPersonaProgression.markVoiceDirectiveDelivered(
                    dataRoot: dataRoot, sessionID: sessionID, expectedDirective: voice)
            }
        }
    }

    private func renderRuntimeContext(
        surface: String,
        modelId: String,
        providerId: String?,
        factIndex: Int
    ) async -> (report: String, input: JSONValue)? {
        let model = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        let normalizedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let surfaceName = normalizedSurface.isEmpty ? "chat" : normalizedSurface
        let provider = providerId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerName: String
        if let provider, !provider.isEmpty { providerName = provider }
        else { providerName = router.inferProviderForModel(model) ?? "unknown" }
        // Saved contacts with reachability and trust shown independently.
        let contacts: JSONValue
        if let dataRoot = remPinsDataRoot {
            do { contacts = .object(["status": .string("available"),
                                    "rows": .array(try AgentPeerStore(dataRoot: dataRoot).contactSummaries().map(JSONValue.string))]) }
            catch {
                // Storage diagnostics stay with their native owner, not in a part's input.
                contacts = .object(["status": .string("unavailable"), "reason": .string("Contact storage could not be read.")])
            }
        } else { contacts = .object(["status": .string("unavailable"), "reason": .string("No contact data root was supplied.")]) }
        // The app's Simple | Advanced switch (SimpleViewMode.swift). Only the
        // app's own chat sees the window; unset leaves the prompt unchanged.
        let defaults = UserDefaults.standard
        let viewMode = surfaceName != "chat" ? nil
            : defaults.string(forKey: "nativeagent.viewMode")
        return (Self.renderRuntimeContext(surface: surfaceName, provider: providerName, model: model),
                .object(["view_mode": viewMode.map(JSONValue.string) ?? .null, "contacts": contacts,
                         "fact_index": .int(Int64(factIndex))]))
    }

    /// One fact of the moment for her turn part's dynamic segment.
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

    /// "Tuesday, August 11, 2026 at 9:29 AM CDT" — weekday and AM/PM spelled
    /// out so the time-of-day word never has to be inferred from a 24h number.
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
