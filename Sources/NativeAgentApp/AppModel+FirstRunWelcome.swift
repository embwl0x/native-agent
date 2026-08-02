import Foundation

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
        NativeAgentPaths.dataRoot.appendingPathComponent(".needs_welcome", isDirectory: false)
    }

    /// Arms the one-time welcome — IN PUBLIC-RELEASE BUNDLES ONLY.
    ///
    /// Called at onboarding completion, but a deliberate no-op everywhere else:
    /// outside a public-release bundle no marker is written, so no greeting can
    /// ever fire on a dev install (see the file header). Callers get no signal
    /// either way; "marked" is not a postcondition of calling this.
    @MainActor
    func markFirstRunWelcomePending() {
        guard NativeAgentPaths.isPublicReleaseBundle else { return }
        let url = firstRunWelcomeMarkerURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? Data("pending\n".utf8).write(to: url, options: [.atomic])
    }

    private var firstRunWelcomePending: Bool {
        FileManager.default.fileExists(atPath: firstRunWelcomeMarkerURL.path)
    }

    private func clearFirstRunWelcomeMarker() {
        try? FileManager.default.removeItem(at: firstRunWelcomeMarkerURL)
    }

    /// Fire the one-time welcome. Called from onboarding-complete AND from
    /// ChatView triggers. Marker + in-flight flag make it fire exactly once.
    @MainActor
    func maybeSendFirstRunGreeting() async {
        // SYNCHRONOUS guard prefix (no await) → MainActor serializes it, so only
        // one trigger can claim the in-flight flag before the first await.
        // Belt-and-suspenders with the marker-write gate: a stray marker on a
        // dev data root (e.g. restored from a backup) still can't fire here.
        guard NativeAgentPaths.isPublicReleaseBundle else { return }
        guard firstRunWelcomePending, !firstRunGreetingInFlight else { return }
        guard !activeChatSessionId.isEmpty else { return }
        firstRunGreetingInFlight = true
        defer { firstRunGreetingInFlight = false }

        // "Connecting to an LLM" gate: fetch a FRESH provider list (the cached
        // one lags right after connect). If still not ready, leave the marker so
        // a later trigger retries.
        await loadProvidersForChat()
        guard providersList.contains(where: { $0.auth_status.state == "ready" }) else { return }

        let sid = activeChatSessionId
        NSLog("[first-run-welcome] firing greeting into session %@", sid)

        // A2.5 (W1#9): "by name" used to be unconditional, so a no-name install
        // (the onboarding fallback substitutes the placeholder "User") produced
        // an awkward "Hi User" greeting. Instruct the model to use a real name
        // only if it genuinely knows one and to greet naturally otherwise —
        // never parroting a placeholder — so the no-name path reads warmly.
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

        // Consume the marker only once the turn is actually accepted — a busy
        // or rejected session leaves it in place so a later trigger retries,
        // instead of a fresh install silently losing its one-shot welcome.
        // Concurrent re-fire during the await is blocked by the in-flight flag.
        let acceptance = await sendChat(kickoff, sessionId: sid, hideUserBubble: true)
        switch acceptance {
        case .accepted, .queued:
            clearFirstRunWelcomeMarker()
        case .rejected(let message):
            NSLog("[first-run-welcome] greeting send rejected, keeping marker: %@", message)
        }
    }
}
