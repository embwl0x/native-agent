import AppKit
import SwiftUI
import NativeAgentShared
// Blueprint: | `ShellAskBar.swift` | `ShellAskBar`: the line under every page but Chat that sends the person's words about it, then follows that turn |

/// The person says what to change where they are. Return sends the words through the composer's own send to the active conversation,
/// led by the page the window shows and what that page has open, in the link the agent's page read uses ("About Desk (page:desk): …",
/// "About Desk · Board proof (page:desk/desk.335): …"); the window stays on the page, and the page redraws itself when the agent changes
/// it. A control phrase ("let me take over") goes exactly as typed, so the body hears it as the command it is.
struct ShellAskBar: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// The shown page's identity: each page keeps its own draft and its own record.
    let page: String
    @State private var openIssue: String?

    private var subject: String { "ask-bar/" + page }
    private var text: Binding<String> { appModel.editBinding(subject, seed: "") }
    private var placeholder: String {
        let name = appModel.agentDisplayName
        return name.isEmpty ? "Tell me what to change here" : "Tell \(name) what to change here"
    }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: NativeAgentShellLayout.composerRadius, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let openIssue {
                ShellAskNote(text: openIssue)
            } else if let record = appModel.askBar[subject] {
                switch record {
                case .sending: ShellAskNote(text: "Sending…")
                case .refused(let reason): ShellAskNote(text: reason)
                case .sent(let sent): ShellAskedLine(sent: sent) { open(sent.session) }
                }
            }
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(ShellType.label)
                .onSubmit { send() }
                .accessibilityLabel(placeholder)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            if reduceTransparency {
                shape.fill(Color(nsColor: .controlBackgroundColor)).overlay { shape.strokeBorder(NativeAgentShell.hairline, lineWidth: 1) }
            }
        }
        .glassEffect(reduceTransparency ? .identity : HouseGlass.plate, in: shape)
    }

    /// The words leave the draft at Return and are held in the page's one record until the conversation answers: accepted drops them,
    /// refused puts them back in the draft with the reason. While they are in flight, Return does nothing.
    private func send() {
        let draft = subject
        let words = text.wrappedValue
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .sending? = appModel.askBar[draft] { return }
        guard !trimmed.isEmpty else { return }
        guard let message = message(trimmed) else {
            appModel.askBar[draft] = .refused("I can't tell which page this is yet, so nothing was sent. Your words are still here.")
            return
        }
        let session = appModel.activeChatSessionId
        let turn = appModel.turnFace(for: session)
        openIssue = nil
        appModel.askBar[draft] = .sending(words: words)
        appModel.clearEditDraft(draft)
        Task { @MainActor in
            switch await appModel.startActiveChatTurn(message, expectedSessionId: session) {
            case .accepted(let accepted):
                appModel.askBar[draft] = .sent(.init(session: accepted, before: turn?.turnID, joined: turn?.isRunning == true))
            case .rejected(let reason):
                // Only this send writes the record while it is in flight, so it still holds the words. Whatever was typed meanwhile stays
                // after them.
                guard case .sending(let held)? = appModel.askBar[draft] else { return }
                let typed = appModel.editDraft(draft, seed: "")
                appModel.setEditDraft(typed.isEmpty ? held : held + " " + typed, for: draft)
                appModel.askBar[draft] = .refused(reason + " Your words are back in the bar.")
            }
        }
    }

    /// The person's words led by what they are about: the page the window's scene report names, and what that page's own face says it has
    /// open when its link is a link to this page. Every title is one line of at most 80 characters. A control phrase is sent as typed.
    private func message(_ words: String) -> String? {
        if UserMessageIntentSignals.isControlHandoff(words) || UserMessageIntentSignals.isTakeOver(words) { return words }
        guard case .string(let id)? = ApplicationLifetime.shared.visiblePageInput?["page"],
              let name = QuietPages.page(named: id)?.title else { return nil }
        let title = PartFace.oneLine(name, limit: 80)
        if let opened = appModel.face.slot(.page(id)).value(as: PartFaceSnapshot.self)?.drawnFace?.opened,
           case .page(let target, let item)? = FaceLink(opened.link), target == id,
           item.map({ !$0.contains(where: \.isWhitespace) && $0.count <= 120 }) != false {
            let link = "page:" + id + (item.map { "/" + $0 } ?? "")
            return "About \(title) · \(PartFace.oneLine(opened.title, limit: 80)) (\(link)): \(words)"
        }
        return "About \(title) (page:\(id)): \(words)"
    }

    private func open(_ session: String) {
        Task { @MainActor in
            do { try await MacFaceLinks.follow(FaceDestination(page: "chat", item: nil, session: session, message: nil), appModel: appModel) }
            catch { openIssue = error.localizedDescription }
        }
    }
}

/// What a page's ask bar holds, kept beside its draft (`AppModel.askBar`).
enum AskBarRecord: Equatable {
    /// Return took the words out of the draft; they are with the conversation until it answers.
    case sending(words: String)
    /// The conversation took them.
    case sent(AskBarSent)
    /// Nothing was sent, or the conversation refused; the words are in the draft and this says why.
    case refused(String)
}

/// An accepted send: the conversation, the turn it held at Return, and whether that turn was running.
struct AskBarSent: Equatable {
    let session: String
    let before: String?
    let joined: Bool
}

private struct ShellAskNote: View {
    let text: String
    var body: some View {
        Text(text).font(ShellType.caption).foregroundStyle(NativeAgentShell.secondary).lineLimit(1)
    }
}

/// One quiet line after an accepted send, saying only what is true whichever turn the words became, from the conversation's turn face
/// (the face the chat's step box and the Work pane's Steps read), and the one control that opens the conversation.
private struct ShellAskedLine: View {
    @Environment(AppModel.self) private var appModel
    let sent: AskBarSent
    let open: () -> Void

    var body: some View {
        let line = Self.line(appModel.turnFace(for: sent.session), sent: sent)
        HStack(spacing: 6) {
            if line.needsYou {
                Circle().fill(NativeAgentShell.needsYou).frame(width: 7, height: 7)
            }
            Text(line.text)
                .font(ShellType.caption)
                .foregroundStyle(NativeAgentShell.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open chat", action: open)
                .buttonStyle(.plain)
                .font(ShellType.captionMedium)
                .foregroundStyle(NativeAgentShell.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// An approval waiting on the person in that conversation; else a turn running there, in the Steps line's words, led by "I'll read
    /// this as I finish what I'm on" while the turn that was running at Return still runs; else "Sent." It never says how a turn ended:
    /// the line cannot know which turn the words became.
    static func line(_ turn: TurnFace?, sent: AskBarSent) -> (text: String, needsYou: Bool) {
        if let approval = turn?.card?.approval, approval.isActionable {
            return ("I need your OK in our chat: " + approval.act, true)
        }
        if let turn, turn.isRunning {
            let doing = WorkPaneFace.stepsLine(turn)
            return (sent.joined && turn.turnID == sent.before ? "I'll read this as I finish what I'm on · " + doing : doing, false)
        }
        return ("Sent.", false)
    }
}
