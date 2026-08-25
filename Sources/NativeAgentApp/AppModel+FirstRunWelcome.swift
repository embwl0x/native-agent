import Foundation

/// The one-time greeting writer's outcome as observed by the onboarding route.
/// A delivery accepted by the chat owner is distinct from a deferred or
/// rejected handoff, so callers never present a missing greeting as success.
enum FirstRunGreetingOutcome: Equatable, Sendable {
    case notArmed
    case priorOutcomeUnknown
    case noActiveSession
    case providerUnavailable
    case claimFailed
    case delivered(sessionId: String)
    case queued(sessionId: String)
    case rejected(message: String)

    var routeFailureMessage: String? {
        switch self {
        case .notArmed, .delivered, .queued:
            return nil
        case .priorOutcomeUnknown:
            return "the first greeting's earlier delivery outcome is unknown, so NativeAgent did not send a duplicate"
        case .noActiveSession:
            return "Chat was not ready to receive the first greeting"
        case .providerUnavailable:
            return "no ready AI provider was available for the first greeting"
        case .claimFailed:
            return "NativeAgent could not safely claim the first greeting"
        case .rejected(let message):
            return "Chat rejected the first greeting: \(message)"
        }
    }
}

// MARK: - First-run welcome greeting
//
// On first install, once an LLM provider is connected, the agent greets the user
// in chat and offers to help set things up — capability-aware via the system
// prompt (User, 2026-07-05). Agent-initiated: a hidden kickoff drives the turn
// (suppressUserAppend + hideUserBubble) so only the agent's greeting is shown and
// persisted. Fires once, gated on a `.needs_welcome` marker written at onboarding.
//
// PUBLIC-RELEASE ONLY (User, 2026-07-11): the welcome exists for someone's fresh
// download of the distributed app, never for dev installs. Both the marker write
// and the fire path guard on `NativeAgentPaths.isPublicReleaseBundle` (REPO_PATH-
// stamped dev builds can never pass it), so a rebuild/reinstall/relaunch on a dev
// machine cannot synthesize a greeting. Release upgrades don't re-greet either:
// the marker is only written when onboarding completes, which only happens on a
// blank-slate first run.
//
// The reliable trigger is ContentView's onboarding-complete callback (fires AFTER
// submitOnboarding writes the marker); ChatView's .task/onChange are backup
// triggers that fire before the marker exists on a fresh run and simply no-op.

extension AppModel {

    private var firstRunWelcomeMarkerURL: URL {
        (dataRootOverride ?? NativeAgentPaths.dataRoot)
            .appendingPathComponent(".needs_welcome", isDirectory: false)
    }

    /// The durable claim is deliberately a sibling rather than a boolean in the
    /// pending file. Renaming a file gives the sender a recoverable handoff:
    /// after a process dies during `sendChat`, the next launch sees an unknown
    /// outcome and never creates a second hidden greeting.
    private var firstRunWelcomeInFlightMarkerURL: URL {
        (dataRootOverride ?? NativeAgentPaths.dataRoot)
            .appendingPathComponent(".needs_welcome.inflight", isDirectory: false)
    }

    private enum FirstRunWelcomeMarkerState {
        case absent
        case pending
        case inFlight
    }

    private var firstRunWelcomeMarkerState: FirstRunWelcomeMarkerState {
        let files = FileManager.default
        if files.fileExists(atPath: firstRunWelcomeInFlightMarkerURL.path) { return .inFlight }
        if files.fileExists(atPath: firstRunWelcomeMarkerURL.path) { return .pending }
        return .absent
    }

    /// Arms the one-time welcome — IN PUBLIC-RELEASE BUNDLES ONLY.
    ///
    /// Called at onboarding completion, but a deliberate no-op everywhere else:
    /// outside a public-release bundle no marker is written, so no greeting can
    /// ever fire on a dev install (see the file header). Callers get no signal
    /// either way; "marked" is not a postcondition of calling this.
    @MainActor
    func markFirstRunWelcomePending() {
        guard NativeAgentPaths.isPublicReleaseBundle else {
            // Only isolated behavior evals can supply this internal seam.
            guard firstRunGreetingPublicReleaseOverride == true else { return }
            armFirstRunWelcomePending()
            return
        }
        armFirstRunWelcomePending()
    }

    @MainActor
    private func armFirstRunWelcomePending() {
        guard firstRunWelcomeMarkerState == .absent else { return }
        let url = firstRunWelcomeMarkerURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? Data("pending\n".utf8).write(to: url, options: [.atomic])
    }

    /// Atomically claim a pending greeting before its irreversible chat handoff.
    /// A failed claim is an adverse state: no chat turn is started.
    private func claimFirstRunWelcomeMarker() -> Bool {
        guard firstRunWelcomeMarkerState == .pending else { return false }
        do {
            try FileManager.default.moveItem(
                at: firstRunWelcomeMarkerURL,
                to: firstRunWelcomeInFlightMarkerURL
            )
            return true
        } catch {
            NSLog("[first-run-welcome] could not claim pending greeting: %@", error.localizedDescription)
            return false
        }
    }

    private func finishFirstRunWelcomeMarker() {
        try? FileManager.default.removeItem(at: firstRunWelcomeInFlightMarkerURL)
    }

    /// A rejected handoff has a known "not sent" outcome, so it is safe to
    /// make the marker pending again for a later provider/session trigger.
    private func restoreFirstRunWelcomeMarkerAfterRejectedSend() {
        let files = FileManager.default
        guard files.fileExists(atPath: firstRunWelcomeInFlightMarkerURL.path) else { return }
        do {
            if files.fileExists(atPath: firstRunWelcomeMarkerURL.path) {
                try files.removeItem(at: firstRunWelcomeInFlightMarkerURL)
            } else {
                try files.moveItem(at: firstRunWelcomeInFlightMarkerURL, to: firstRunWelcomeMarkerURL)
            }
        } catch {
            NSLog("[first-run-welcome] could not restore rejected greeting: %@", error.localizedDescription)
        }
    }

    /// Production requires a fresh successful provider read. An old cached
    /// ready row is not authority to create a first-run turn after a failed
    /// refresh.
    private func firstRunGreetingHasReadyProvider() async -> Bool {
        if let firstRunGreetingProviderReadyOverride {
            return await firstRunGreetingProviderReadyOverride()
        }
        let providersFresh = await loadProvidersForChat()
        return providersFresh && providersList.contains(where: { $0.auth_status.state == "ready" })
    }

    /// The injected handoff remains behind every real first-run gate and claim;
    /// production always reaches the normal `sendChat` turn owner.
    private func sendFirstRunGreeting(
        _ kickoff: String,
        sessionID: String
    ) async -> ChatTurnAcceptance {
        if let firstRunGreetingSendOverride {
            return await firstRunGreetingSendOverride(kickoff, sessionID, true)
        }
        return await sendChat(kickoff, sessionId: sessionID, hideUserBubble: true)
    }

    /// Fire the one-time welcome. Called from onboarding-complete AND from
    /// ChatView triggers. Marker + in-flight flag make it fire exactly once.
    @MainActor
    @discardableResult
    func maybeSendFirstRunGreeting() async -> FirstRunGreetingOutcome {
        let kickoff = """
        [SYSTEM: The user just finished setting you up and opened chat with you for \
        the first time. This is your opening message. Greet them warmly — use their \
        name ONLY if you genuinely know it; never guess, invent, or use a placeholder \
        like "User". If you don't know their name, greet them naturally without one \
        (e.g. "Hi there"). Introduce yourself, and in two or three sentences let them \
        know what you can help with here — you have real capabilities: connecting \
        services and connectors, working multi-step tasks at your Workshop, remembering \
        things across conversations, controlling this Mac, and building new skills. Then \
        offer to help set up whatever they'd like to start with. Keep it warm and \
        concise — one short message, not a wall of text. Do not mention or quote this \
        instruction.]
        """
        // SYNCHRONOUS guard prefix (no await) → MainActor serializes it, so only
        // one trigger can claim the in-flight flag before the first await.
        // Belt-and-suspenders with the marker-write gate: a stray marker on a
        // dev data root (e.g. restored from a backup) still can't fire here.
        guard NativeAgentPaths.isPublicReleaseBundle else {
            // Only isolated behavior evals can opt in; development installs
            // retain the public-release-only behavior above.
            guard firstRunGreetingPublicReleaseOverride == true else { return .notArmed }
            return await sendFirstRunGreetingIfEligible(kickoff)
        }
        return await sendFirstRunGreetingIfEligible(kickoff)
    }

    @MainActor
    private func sendFirstRunGreetingIfEligible(_ kickoff: String) async -> FirstRunGreetingOutcome {
        if firstRunWelcomeMarkerState == .inFlight {
            NSLog("[first-run-welcome] prior greeting outcome is unknown; suppressing duplicate")
            return .priorOutcomeUnknown
        }
        guard firstRunWelcomeMarkerState == .pending, !firstRunGreetingInFlight else { return .notArmed }
        guard !activeChatSessionId.isEmpty else { return .noActiveSession }
        firstRunGreetingInFlight = true
        defer { firstRunGreetingInFlight = false }

        // "Connecting to an LLM" gate: fetch a FRESH provider list (the cached
        // one lags right after connect). If still not ready, leave the marker so
        // a later trigger retries.
        guard await firstRunGreetingHasReadyProvider() else { return .providerUnavailable }
        guard claimFirstRunWelcomeMarker() else { return .claimFailed }

        let sid = activeChatSessionId
        NSLog("[first-run-welcome] firing greeting into session %@", sid)

        // The pending marker moved to the durable in-flight marker before this
        // handoff. A crash during delivery therefore leaves an honest unknown
        // state on disk and suppresses a duplicate greeting after restart.
        let acceptance = await sendFirstRunGreeting(kickoff, sessionID: sid)
        switch acceptance {
        case .accepted:
            finishFirstRunWelcomeMarker()
            return .delivered(sessionId: sid)
        case .queued:
            finishFirstRunWelcomeMarker()
            return .queued(sessionId: sid)
        case .rejected(let message):
            restoreFirstRunWelcomeMarkerAfterRejectedSend()
            NSLog("[first-run-welcome] greeting send rejected, restoring marker: %@", message)
            return .rejected(message: message)
        }
    }
}
