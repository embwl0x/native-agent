#if DEBUG
import AppKit
import SwiftUI
import NativeAgentCore

/// The inline-card sheets, drawn from the SHIPPING views.
///
/// This file no longer carries a private copy of the grammar: every card below
/// is the real `InlineCardView` / `InlineCard` / `InlineCardReceipt` from
/// `InlineCard.swift`, the real `MacChatTurnInlineCard`, and the real display
/// values — so a sheet in `mockups/cards/` is a photograph of what ships, not
/// a drawing of what was proposed. The file stays DEBUG and the only entry
/// point is still gated:
///
///   SIMPLICITY_CARDS=1 SIMPLICITY_SNAPSHOT_DIR=<dir> swift test --filter BotsShelfTests
///
/// Agent's design call, now in the views themselves:
///   1. Live = silver fill + hairline; settled receipt = hairline only, one
///      line, mark + outcome, at the live card's own horizontal inset.
///   2. Every decline states its consequence; "→" appears only there.
///   3. Three marks, three colours: green ✓ done, white ✕ declined, yellow ?
///      unknown. "on this Mac", never "through this Mac".
///
/// Her 2026-09-13 round, also in the views:
///   4. Her prose comes FIRST; the card is the handle under it.
///   5. The consequence reads at the subtitle's weight, one contrast step up.
///   6. Four rows before the buttons became three: title, why, buttons — the
///      persistence note moved under "What happens".
///   7. The primary says the OUTCOME ("Connect GitHub", "Allow Calendar",
///      "Use gpt-image-1"); a secret field opens on press, not before.
///   8. One live card per ask: an older identical ask goes quiet ("Asked
///      earlier"), and a decline is one gray line, "Not now — <consequence>".

// MARK: - The values the sheets are drawn from

private enum CardSamples {
    static let connectGitHub = InlineCardModel(
        id: "connect-github",
        kind: .needsConnector,
        target: "GitHub",
        title: "Connect GitHub",
        why: "Connect your account so I can see the repositories you've allowed.",
        primaryLabel: "Connect GitHub",
        secondaryLabel: "Not now",
        consequence: "I'll answer without it.",
        field: InlineCardField(
            label: "Personal access token",
            placeholder: "ghp_",
            helper: "Saved in your Mac Keychain. Get a token at github.com/settings/tokens"
        ),
        detailsLabel: "What I'll be able to read",
        detailsBody: "Repository names, descriptions and file contents for the repositories your token grants — nothing else, and nothing is written.",
        busyLabel: "Checking connection…",
        busyNote: "Checking connection…"
    )

    static var connectGitHubRunning: InlineCardModel {
        var model = connectGitHub
        model.state = .running
        return model
    }

    static let gitHubSettled = InlineCardModel(
        id: "connect-github",
        kind: .needsConnector,
        target: "GitHub",
        title: "Connect GitHub",
        why: "",
        primaryLabel: "Connect GitHub",
        consequence: "I'll answer without it.",
        state: .settled,
        outcome: "GitHub connected · riverbend",
        outcomeMeta: "read-only, 4 repositories"
    )

    static let desktopPermission = InlineCardModel(
        id: "permission-desktop",
        kind: .needsPermission,
        target: "Desktop",
        title: "Allow Mac Control and Desktop access",
        why: "I need both to read Budget.pdf on this Mac.",
        primaryLabel: "Allow Mac Control and Desktop access",
        secondaryLabel: "Not now",
        consequence: "I'll stop here; I can't open the file without both.",
        persistenceNote: "Stays on until you turn it off in Trust.",
        scopeLines: [
            "Mac Control lets me see the screen, click, and type in apps you allow — not only read files.",
            "Desktop access is granted by macOS, in a system prompt you answer."
        ],
        identifier: "~/Desktop/Budget.pdf",
        detailsLabel: "Everything Mac Control covers",
        detailsBody: "Seeing the screen, moving the pointer, clicking, typing, and reading files in the folders macOS has granted."
    )

    static let desktopWorking = InlineCardModel(
        id: "permission-desktop",
        kind: .needsPermission,
        target: "Desktop",
        title: "Reading Budget.pdf…",
        why: "Mac Control is on and macOS granted Desktop access.",
        primaryLabel: "Allow Mac Control and Desktop access",
        consequence: "I'll stop here; I can't open the file without both.",
        state: .running,
        busyLabel: "Reading Budget.pdf…",
        busyNote: "12 pages"
    )

    static let desktopSettled = InlineCardModel(
        id: "permission-desktop",
        kind: .needsPermission,
        target: "Desktop",
        title: "Read Budget.pdf",
        why: "",
        primaryLabel: "Allow Mac Control and Desktop access",
        consequence: "I'll stop here; I can't open the file without both.",
        state: .settled,
        outcome: "Read Budget.pdf",
        outcomeMeta: "Mac Control on · Desktop allowed"
    )

    // A decline says "Not now" and what that cost, in one gray line — never
    // the title, which reads as a thing that happened (Agent, 2026-09-13).
    static let desktopDeclined = InlineCardModel(
        id: "permission-desktop",
        kind: .needsPermission,
        target: "Desktop",
        title: "Allow Mac Control and Desktop access",
        why: "",
        primaryLabel: "Allow Mac Control and Desktop access",
        consequence: "I'll stop here; I can't open the file without both.",
        state: .declined,
        outcome: "Not now — I'll stop here; I can't open the file without both."
    )

    /// The same ask, raised again by a later call. The older card goes quiet.
    static let desktopSuperseded = InlineCardModel(
        id: "permission-desktop-older",
        kind: .needsPermission,
        target: "Desktop",
        title: "Allow Mac Control and Desktop access",
        why: "I need both to read Budget.pdf on this Mac.",
        primaryLabel: "Allow Mac Control and Desktop access",
        consequence: "I'll stop here; I can't open the file without both.",
        state: .superseded
    )

    static let imageModel = InlineCardModel(
        id: "model-images",
        kind: .needsModelChoice,
        target: "Work",
        title: "Choose an image-capable model",
        why: "Your current Work choice, GPT-5.6 Sol, can't generate images.",
        primaryLabel: "Use this model",
        secondaryLabel: "Not now",
        consequence: "I'll answer without it; no image this time.",
        persistenceNote: "Changes your Work choice for future tasks too.",
        choices: [
            InlineCardChoice(id: "gpt-image-1", title: "gpt-image-1 · OpenAI",
                             note: "billed separately", actionLabel: "Use gpt-image-1"),
            InlineCardChoice(id: "imagen-3", title: "Imagen 3 · Google",
                             note: "needs an API key", actionLabel: "Use Imagen 3"),
            InlineCardChoice(id: "flux-1", title: "FLUX.1 · Black Forest Labs",
                             note: "needs an API key", actionLabel: "Use FLUX.1")
        ],
        detailsLabel: "Why these are the eligible choices",
        detailsBody: "Every model here belongs to an account you've connected and reports image output in its own catalog."
    )

    static let imageWorking = InlineCardModel(
        id: "model-images",
        kind: .needsModelChoice,
        target: "Work",
        title: "Making your image…",
        why: "Work now uses gpt-image-1.",
        primaryLabel: "Use this model",
        consequence: "I'll answer without it; no image this time.",
        state: .running,
        busyLabel: "Making your image…",
        busyNote: "Usually about 20 seconds"
    )

    static let imageSettled = InlineCardModel(
        id: "model-images",
        kind: .needsModelChoice,
        target: "Work",
        title: "Image ready",
        why: "",
        primaryLabel: "Use this model",
        consequence: "I'll answer without it; no image this time.",
        state: .settled,
        outcome: "Image ready",
        outcomeMeta: "gpt-image-1 · 1024×1024 · Work choice changed"
    )

    static let approval = InlineCardModel(
        id: "approval-send",
        kind: .confirm,
        target: "agent@nativeagent.local",
        title: "Send this message to Agent?",
        why: "I'll send it to agent@nativeagent.local now.",
        primaryLabel: "Send message",
        secondaryLabel: "Don't send",
        consequence: "Nothing leaves this Mac; I'll keep the draft.",
        detailsLabel: "Show the message",
        detailsBody: "The 0.4.12 DMG is up. The cards round is in: one grammar for connect, permission, choice, approval and settled runs."
    )

    static let approved = InlineCardModel(
        id: "approval-send",
        kind: .confirm,
        target: "agent@nativeagent.local",
        title: "Send this message to Agent?",
        why: "",
        primaryLabel: "Send message",
        secondaryLabel: "Don't send",
        consequence: "Nothing leaves this Mac; I'll keep the draft.",
        state: .settled,
        outcome: "Sent to agent@nativeagent.local",
        outcomeMeta: "delivery confirmed · 14:06"
    )

    static let decision = InlineCardModel(
        id: "choose-folder",
        kind: .choose,
        target: "notes",
        title: "Choose the folder to keep notes in",
        why: "I need to know where the notes go before I continue.",
        primaryLabel: "Use this folder",
        secondaryLabel: "Decide later",
        consequence: "I'll hold the notes in this conversation only.",
        choices: [
            InlineCardChoice(id: "documents", title: "~/Documents/Notes", note: "42 files"),
            InlineCardChoice(id: "reading", title: "~/Desktop/Reading", note: "6 files"),
            InlineCardChoice(id: "new", title: "A new folder", note: "you name it")
        ]
    )

    static let decided = InlineCardModel(
        id: "choose-folder",
        kind: .choose,
        target: "notes",
        title: "Selected ~/Documents/Notes",
        why: "",
        primaryLabel: "Use this folder",
        secondaryLabel: "Decide later",
        consequence: "I'll hold the notes in this conversation only.",
        state: .settled,
        outcome: "Selected ~/Documents/Notes"
    )

    static let keyFailed = InlineCardModel(
        id: "key-google",
        kind: .needsAPIKey,
        target: "Google",
        title: "Add an API key for Google",
        why: "This connection needs a key to make images with Imagen 3.",
        primaryLabel: "Connect Google",
        secondaryLabel: "Not now",
        consequence: "I'll use a model you've already connected.",
        state: .failed,
        field: InlineCardField(label: "API key", placeholder: "AIza"),
        outcome: "That key wasn't accepted",
        outcomeMeta: "Google returned “API key not valid”. Check it and try again — your typing is still here.",
        canRetry: true
    )

    /// The working turn, from the real lifecycle projection's value.
    static let workingTurn = MacChatTurnCardModel(
        identity: MacChatTurnIdentity(sessionId: "s", turnId: "t"),
        phase: .tool,
        title: "Renaming 18 files in ~/Desktop/Reading…",
        detail: "12 renamed, 6 to go.",
        delegateName: nil,
        tone: .working,
        symbolName: "gearshape",
        isTerminal: false,
        showsLiveIndicator: true,
        elapsed: 34,
        secondsSinceMovement: 2,
        cancellationPending: false,
        approval: nil
    )

    static let unknownTurn = MacChatTurnCardModel(
        identity: MacChatTurnIdentity(sessionId: "s", turnId: "t"),
        phase: .outcomeUnknown,
        title: "Stopped — I don't know whether the last rename went through",
        detail: "12 confirmed · 1 unknown · 5 not started",
        delegateName: nil,
        tone: .unresolved,
        symbolName: "questionmark",
        isTerminal: true,
        showsLiveIndicator: false,
        elapsed: 41,
        secondsSinceMovement: nil,
        cancellationPending: false,
        approval: nil
    )
}

private func card(_ model: InlineCardModel) -> some View {
    InlineCardView(model: model) { _ in }
}

// MARK: - Sheet furniture

private struct Sheet<Content: View>: View {
    let title: String
    let note: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.xl) {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                Text(title)
                    .font(ShellType.captionSemibold)
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(NativeAgentShell.tertiary)
                Text(note)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NativeAgentShell.room)
    }
}

/// Agent's voice above a card, so the card is judged where it actually lands:
/// immediately after the sentence that establishes the need.
private struct AgentLine: View {
    let text: String
    var body: some View {
        Text(text)
            .font(ShellType.body)
            .foregroundStyle(NativeAgentShell.text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
    }
}

private struct StepLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(ShellType.captionSemibold)
            .textCase(.uppercase)
            .kerning(0.6)
            .foregroundStyle(NativeAgentShell.tertiary)
    }
}

@MainActor
enum InlineCardMockups {
    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let width: CGFloat = 772
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try BotsShelfSnapshots.write(sheetLiveVsSettled, name: "cards-live-vs-settled-\(suffix)",
                                         size: CGSize(width: width, height: 700),
                                         scheme: scheme, directory: directory)
        }
        // The flows and the family sheet are one appearance each: the pair
        // above carries the light/dark proof for the surface itself.
        try BotsShelfSnapshots.write(sheetGitHub, name: "flow-github",
                                     size: CGSize(width: width, height: 900),
                                     scheme: .dark, directory: directory)
        try BotsShelfSnapshots.write(sheetDesktop, name: "flow-desktop",
                                     size: CGSize(width: width, height: 1180),
                                     scheme: .dark, directory: directory)
        try BotsShelfSnapshots.write(sheetImage, name: "flow-image",
                                     size: CGSize(width: width, height: 900),
                                     scheme: .dark, directory: directory)
        try BotsShelfSnapshots.write(sheetFamily, name: "cards-family",
                                     size: CGSize(width: width, height: 1060),
                                     scheme: .dark, directory: directory)
        // The narrow proof: the title never truncates, and the receipt's
        // metadata drops to a gray second line instead.
        try BotsShelfSnapshots.write(sheetNarrow, name: "cards-narrow",
                                     size: CGSize(width: 420, height: 600),
                                     scheme: .dark, directory: directory)
    }

    // Live and settled, the call that binds.
    private static var sheetLiveVsSettled: some View {
        Sheet(title: "Live and settled",
              note: "Live keeps the silver fill and its hairline. Settled drops the fill: hairline only, one line, mark + outcome — at the live card's own inset, so the mark lands in the icon column. A decline and a superseded ask are quieter still: no box at all.") {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
                StepLabel(text: "Live")
                card(CardSamples.connectGitHub)
                StepLabel(text: "Settled")
                card(CardSamples.gitHubSettled)
                StepLabel(text: "Declined")
                card(CardSamples.desktopDeclined)
                StepLabel(text: "Asked earlier — one live card per ask")
                card(CardSamples.desktopSuperseded)
            }
        }
    }

    // "Can you see my GitHub?"
    private static var sheetGitHub: some View {
        Sheet(title: "Flow — “Can you see my GitHub?”",
              note: "Need → connecting (still, no shimmer) → settled. One card, one identity, three states.") {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.xl) {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                    StepLabel(text: "1 · Need")
                    AgentLine(text: "I need GitHub for this — connect it below, or tell me not now and I'll keep going.")
                    card(CardSamples.connectGitHub)
                }
                VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                    StepLabel(text: "2 · Connecting")
                    card(CardSamples.connectGitHubRunning)
                }
                VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                    StepLabel(text: "3 · Settled")
                    card(CardSamples.gitHubSettled)
                    AgentLine(text: "I can see four repositories: NativeAgent, notes, dotfiles and scratch.")
                }
            }
        }
    }

    // "Read Budget.pdf on my Desktop", Mac Control off. Asked ONCE.
    private static var sheetDesktop: some View {
        Sheet(title: "Flow — “Read Budget.pdf on my Desktop”, Mac Control off",
              note: "Asked once: Mac Control and Desktop access in one card, one Allow, and how long it lasts. Then the receipt — with the decline beside it.") {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.xl) {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                    StepLabel(text: "1 · Asked once")
                    AgentLine(text: "I need your go-ahead for Mac Control and Desktop access — allow it below, or tell me not now and I'll keep going.")
                    card(CardSamples.desktopPermission)
                }
                VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                    StepLabel(text: "2 · Working, then settled")
                    card(CardSamples.desktopWorking)
                    card(CardSamples.desktopSettled)
                    AgentLine(text: "Your largest line is rent at £1,450 a month; everything else together is £980.")
                }
                VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                    StepLabel(text: "Declined — one gray line, and what it cost")
                    card(CardSamples.desktopDeclined)
                }
                VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                    StepLabel(text: "Asked twice — the older ask goes quiet")
                    card(CardSamples.desktopSuperseded)
                    AgentLine(text: "I need your go-ahead for Mac Control and Desktop access — allow it below, or tell me not now and I'll keep going.")
                    card(CardSamples.desktopPermission)
                }
            }
        }
    }

    // "Make me an image", the Work route can't — and the key that was refused.
    private static var sheetImage: some View {
        Sheet(title: "Flow — “Make me an image”, the Work route can't",
              note: "The consequence sits beside the selection. A failure keeps the card, the typing and the retry; it never settles into a receipt.") {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.xl) {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                    StepLabel(text: "1 · Choose")
                    AgentLine(text: "I need to know which model to use — pick one below, or tell me not now and I'll keep going.")
                    card(CardSamples.imageModel)
                }
                VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                    StepLabel(text: "2 · Working, then settled")
                    card(CardSamples.imageWorking)
                    card(CardSamples.imageSettled)
                }
                VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                    StepLabel(text: "A failure, not a receipt")
                    card(CardSamples.keyFailed)
                }
            }
        }
    }

    // The existing cards, in the one grammar.
    private static var sheetFamily: some View {
        Sheet(title: "The family, one grammar",
              note: "Approval, a decision, a settled bot run, and the working card — live above settled. Nothing the existing cards carry is dropped.") {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.xl) {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                    StepLabel(text: "Approval — the message is shown once, the rest opens in place")
                    card(CardSamples.approval)
                    card(CardSamples.approved)
                }

                VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                    StepLabel(text: "Needs a decision")
                    card(CardSamples.decision)
                    card(CardSamples.decided)
                }

                VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                    StepLabel(text: "Bot run — the full reply, the date, the duration and the model all survive")
                    InlineCardReceipt(
                        mark: .done,
                        outcome: "The project published a small update this morning.",
                        meta: "Completed · Today, 09:00 · 12s · GPT-5.5",
                        detailsLabel: "Full reply"
                    ) {
                        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                            Text("The project published a small update this morning. It fixes the export issue mentioned yesterday and adds a way to rename saved drafts. The release notes do not mention any other changes.")
                                .font(ShellType.body)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 6) {
                                Image(systemName: "doc").font(.system(size: 11))
                                Text("Release notes.md").font(ShellType.label)
                            }
                            .foregroundStyle(NativeAgentShell.tertiary)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                    StepLabel(text: "Working card — in the turn, not pinned above the composer; Stop stays")
                    MacChatTurnInlineCard(model: CardSamples.workingTurn, onStop: {})
                    MacChatTurnInlineCard(model: CardSamples.unknownTurn)
                }
            }
        }
    }

    // Narrow: the title wraps rather than truncating, and the receipt's
    // metadata moves to its own gray line.
    private static var sheetNarrow: some View {
        Sheet(title: "Narrow",
              note: "The title never truncates. Metadata drops to a gray second line.") {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
                card(CardSamples.desktopPermission)
                card(CardSamples.desktopSettled)
                card(CardSamples.desktopDeclined)
                card(CardSamples.decided)
            }
        }
    }
}
#endif
