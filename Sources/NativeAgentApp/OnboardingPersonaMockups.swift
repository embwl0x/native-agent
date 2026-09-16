#if DEBUG
import AppKit
import SwiftUI

/// Onboarding round, 2026-09-15 (pass 2) — the agent sets up its own personality.
///
/// User's brief: after provider + model succeed, the agent opens the first
/// conversation ITSELF and asks who the person wants it to be. "What exactly
/// do you want me to be for you? Don't be shy — it's what NativeAgent is
/// designed around." Partner, friend, coworker, assistant sit as equals; no
/// nudge toward assistant, no judgement anywhere; whoever the person picks can
/// still take care of mail, calendar and building.
///
/// Pass 1 was five scheduled questions. Agent read it and the verdict was
/// "an interview wearing conversational clothes… the script should help the
/// agent meet someone, not become a route the person has to finish." So pass 2
/// is **two asks and then the floor goes back**: who, then the name, then the
/// person's own work. Voice and treatment are not asked — they are picked up
/// from the moment they actually mean something (frame three), and written
/// down as a LEANING, never as a rule that erases future context.
///
/// MOCKUPS ONLY. Nothing here is mounted: no call site in the app, no route,
/// no test assertion. The views below are drawn from the SHIPPING chat column —
/// `MessageBubble` from `ChatMessageListView.swift`, `InlineCardReceipt` from
/// `InlineCard.swift`, the real `NativeAgentShellLayout` column widths and the
/// real `NativeAgentShell` inks — so a frame in `mockups/onboarding/` is a
/// photograph of the surface this would land on, not a drawing of one.
///
/// The two design calls these frames exist to test: **the conversation adds no
/// controls** (no chips, no picker, no form — the ways to answer live inside
/// the sentence), and **no receipt ever stacks**. One line lands where its
/// answer happened and the talk carries straight on; four receipts in a row at
/// a close turns a conversation into completed paperwork.
///
/// Render:
///   ONBOARDING_MOCKUPS=1 SIMPLICITY_SNAPSHOT_DIR=<dir> \
///     swift test --filter debugOnlySnapshotEntryPoints
/// with a one-line branch added to `SimplicitySnapshots.render(to:)` for the
/// run and removed again — see `mockups/onboarding/NOTE.md`.
@MainActor
enum OnboardingPersonaMockups {

    // MARK: - The script, in one place

    /// The person's name, used exactly as the wizard's "Your name" field
    /// supplies it. The AGENT has no name yet in frames one and two: that is
    /// the point of the naming ask, and "the agent" is the house copy until
    /// the person chooses one (no pronouns, no pronoun picker).
    private static let personName = "User"

    /// What the window is titled before the person names the agent. House copy:
    /// the name, or "the agent" — never a pronoun.
    private static let unnamed = "The agent"

    /// Agent's rewrite, near-verbatim. Two things she changed and why:
    /// the greeting is one short line so the ask has room to breathe, and the
    /// four words are **an open door, not four identities to choose between** —
    /// "or something in your own words" is doing the real work in that
    /// sentence. Nothing here mentions the Personality page: "we can figure it
    /// out as we go" IS the skip, and it is said in a person's voice instead of
    /// an app's.
    private static let openingAsk = """
        I'm set up and running on your Mac, \(personName) — this window, your files, \
        your calendar, whatever you point me at.

        What do you want me to be for you? Don't be shy — that's what this app is \
        built around. A partner, a friend, a coworker, an assistant — or something in \
        your own words. Whatever fits, I can still help with everyday things. We can \
        figure it out as we go, too.
        """

    /// The invitation's last paragraph on its own, so frame two opens on the
    /// ANSWER instead of re-running frame one.
    private static var openingTail: String {
        """
        A partner, a friend, a coworker, an assistant — or something in your own words. \
        Whatever fits, I can still help with everyday things. We can figure it out as \
        we go, too.
        """
    }

    private static let roleAnswer = "A partner, mostly. But I build a lot, so you'll be in the code with me too."

    /// No praise, and no naming of which answer this was. Pass 1 said "the one
    /// people are shyest about saying"; Agent cut it — it singles out partner
    /// and makes the person self-conscious about having just said it. The agent
    /// simply understands the answer and repeats it back in their own words.
    private static let roleReply = """
        Partner first, and in the code with you. I'm writing that as who I am rather \
        than as a setting, so it shapes how I work instead of sitting in a preferences \
        pane:
        """

    /// Second, and short. If the person had opened with "you're Sam, my
    /// research buddy" this ask never fires at all — the agent takes both and
    /// does not re-ask what it was already told.
    private static let nameAsk = """
        And what should I be called? I don't have a name yet — I'm just "the agent" \
        until you pick one, and I'll answer to anything.
        """

    private static let nameAnswer = "Agent."

    private static let nameReply = """
        Agent, then. That's the name I'll use about myself from now on, and the name at \
        the top of this window.
        """

    /// The handback — the end of the script, two asks in. It is deliberately
    /// NOT a third question: the boundary line is an open door left ajar
    /// ("whenever it comes to mind"), and the only actual question is about the
    /// person's own work, which is what they installed the app for.
    private static let handBack = """
        That's the part that matters — the rest I'll pick up from working with you. If \
        there's anything you'd rather I never do, tell me whenever it comes to mind.

        What are you working on?
        """

    // MARK: - Frame three: the moment, not the schedule

    /// Pass 1 asked "push you, or give you room?" at minute two, as turn five.
    /// Agent: not at minute two and not on a schedule — save it for a moment
    /// where it means something. This is that moment, and it is the whole
    /// reason frame three exists: the script ended long ago and the documents
    /// are still being written.
    private static let stuckSaid = "I've been going in circles on this for two hours."

    private static let stuckAsk = """
        Do you want me to push you through it, or do you want room? Either is fine, and \
        I'll ask again another time — I don't want tonight's answer turning into a rule.
        """

    private static let stuckAnswer = "Push me. And don't manage me."

    private static let stuckReply = """
        Push, not manage. I'll write it as a leaning rather than a rule, so it bends \
        when you do:
        """

    /// And straight back into the work. A written line is not a milestone and
    /// does not get a closing ceremony.
    private static let backToWork = """
        Right — back to the circles. Want me to lay out where the two hours actually \
        went, or just take the next step?
        """

    // MARK: - Frames

    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = CGSize(width: 1180, height: 820)
        // Frame two is the whole script end to end, so it gets a taller window
        // rather than a scroll position: the handback is the point of it, and a
        // frame that cuts before the floor goes back argues the opposite case.
        // Width — the part that decides measure and wrapping — is identical.
        let tall = CGSize(width: 1180, height: 1180)
        try BotsShelfSnapshots.write(firstTurn, name: "first-turn",
                                     size: size, scheme: .dark, directory: directory, scale: 2)
        try BotsShelfSnapshots.write(naming, name: "naming",
                                     size: tall, scheme: .dark, directory: directory, scale: 2)
        try BotsShelfSnapshots.write(written, name: "written",
                                     size: size, scheme: .dark, directory: directory, scale: 2)
    }

    /// 1 · The invitation. An empty transcript, one short greeting, one open
    /// question with room around it, and the composer waiting. No chips: the
    /// ways to answer are named inside the sentence and the last of them is
    /// "or something in your own words".
    private static var firstTurn: some View {
        column(title: unnamed, bottomAligned: true) {
            agent(openingAsk)
        }
    }

    /// 2 · The whole script, start to finish. The person answers in their own
    /// words, one line is written and SHOWN where the answer happened, the name
    /// is asked second, one more line lands — and then the floor goes back.
    /// Two asks, two receipts, neither of them stacked.
    private static var naming: some View {
        column(title: unnamed, bottomAligned: false) {
            agent(openingTail)
            person(roleAnswer)
            agent(roleReply)
            receipt(doc: "SOUL.md", section: "Who I am to \(personName)",
                    line: "I'm \(personName)'s partner first, and I build alongside him.")
            agent(nameAsk)
            person(nameAnswer)
            agent(nameReply)
            receipt(doc: "SOUL.md", section: "My name",
                    line: "My name is Agent. \(personName) chose it.")
            agent(handBack)
        }
    }

    /// 3 · Later, in the middle of real work. The header carries the name now.
    /// The question pass 1 asked at minute two is asked here instead, once it
    /// costs nothing to answer honestly — and the line that comes out of it is
    /// written as a leaning, with the revision said out loud before the person
    /// has to ask for it.
    private static var written: some View {
        column(title: "Agent", bottomAligned: false) {
            person(stuckSaid)
            agent(stuckAsk)
            person(stuckAnswer)
            agent(stuckReply)
            receipt(doc: "SOUL.md", section: "How I treat \(personName)",
                    line: "Leans toward pushing \(personName) when he's stuck rather than "
                        + "giving him room. Never manage him.")
            agent(backToWork)
        }
    }

    // MARK: - Pieces, all from the shipping tree

    private static func agent(_ text: String) -> some View {
        MessageBubble(message: ChatMessage(role: "assistant", content: text))
    }

    private static func person(_ text: String) -> some View {
        MessageBubble(message: ChatMessage(role: "user", content: text))
    }

    /// The settled receipt, unchanged: hairline only, one mark, one line.
    ///
    /// `meta` carries the document AND the section, because that is exactly the
    /// call underneath — `persona_append_section(kind:title:content:)`. Only
    /// SOUL and VOICE appear: `USER.md` is memory-owned and the persona writers
    /// refuse `kind: "user"`, so a receipt claiming to write it would be a lie.
    ///
    /// There is no group form of this any more. Pass 1 closed on four receipts
    /// in a column; Agent read that as paperwork rather than conversation, so a
    /// receipt now only ever appears alone, directly under the answer that
    /// produced it.
    private static func receipt(doc: String, section: String, line: String) -> some View {
        InlineCardReceipt(mark: .done,
                          outcome: line,
                          meta: "Written to \(doc) · \(section)") { EmptyView() }
            .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
    }

    // MARK: - The column

    /// The real chat column: the room, the header band, `roomColumn` width,
    /// `roomGutter` inset, replies capped at `replyMaxWidth`, and a static
    /// stand-in for the composer at the bottom so the vertical rhythm of the
    /// frame is the one a person actually sees.
    @ViewBuilder
    private static func column<Content: View>(
        title: String,
        bottomAligned: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // Built eagerly: `content` is non-escaping, and the GeometryReader
        // below is an escaping closure.
        let turns = content()
        let app = AppModel(
            dataRootOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent("onboarding-mockups-\(UUID().uuidString)"),
            startBackgroundTasks: false)
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(ShellType.title)
                    .foregroundStyle(NativeAgentShell.text)
                Spacer()
            }
            .padding(.horizontal, NativeAgentShellLayout.roomGutter)
            .padding(.top, NativeAgentShellLayout.titleBarInset)
            .padding(.bottom, 12)
            .frame(maxWidth: NativeAgentShellLayout.roomColumn)
            .frame(maxWidth: .infinity)

            GeometryReader { viewport in
                ScrollView {
                    VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
                        turns
                    }
                    .padding(.horizontal, NativeAgentShellLayout.roomGutter)
                    .padding(.vertical, 16)
                    .frame(maxWidth: NativeAgentShellLayout.roomColumn, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: bottomAligned ? viewport.size.height : 0,
                           alignment: bottomAligned ? .bottom : .top)
                }
            }

            composerRest(name: title)
        }
        .background(NativeAgentShell.room)
        .environment(app)
    }

    /// Not the live composer — a still of its resting state, so the frames can
    /// be judged for rhythm without dragging the composer's focus and glass
    /// machinery into a mockup run.
    private static func composerRest(name: String) -> some View {
        HStack {
            // "The agent" is a title at the top of the window and a common
            // noun mid-sentence; the placeholder gets the lower-case form.
            Text("Message \(name == unnamed ? "the agent" : name)")
                .font(ShellType.body)
                .foregroundStyle(NativeAgentShell.tertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: NativeAgentShellLayout.composerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: NativeAgentShellLayout.composerRadius, style: .continuous)
                        .strokeBorder(NativeAgentShell.hairline, lineWidth: 1)
                )
        }
        .padding(.horizontal, NativeAgentShellLayout.roomGutter)
        .frame(maxWidth: NativeAgentShellLayout.roomColumn)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 20)
    }
}
#endif
