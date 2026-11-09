import SwiftUI
import NativeAgentShared
// Blueprint: | `ChatView+ShellColumn.swift` | `ChatView`: identity-only conversation sections, archive and row commands |

// Group by recorded kind so presentation cannot recategorize conversations.

let chatSessionDragType = "com.nativeagent.chat-session"
let chatSessionDragPlainTextPrefix = "nativeagent-chat-session:"
let chatSessionDropTypes = [chatSessionDragType, "public.plain-text"]

private struct SidebarSessionSections: Equatable {
    var rows: [String]
    var working: [String]
    var briefs: [String]
    var empty: [String]
    var navigation: [String]

    init(rows: [String], working: [String], briefs: [String], empty: [String], navigation: [String]) {
        self.rows = rows; self.working = working; self.briefs = briefs; self.empty = empty; self.navigation = navigation
    }

    init(_ face: SessionListFace) {
        rows = face.rows; working = face.working; briefs = face.briefs
        empty = face.emptyIDs; navigation = face.navigationIDs
    }
}

extension ChatView {
    private var sessionSearchQuery: String {
        sessionSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var sidebarSessionSections: SidebarSessionSections? {
        if sessionSearchQuery.isEmpty {
            return appModel.face.slot(.sessions).select("sidebarSections", as: SessionListFace.self) {
                $0.map(SidebarSessionSections.init)
            }
        }
        let answer = appModel.face.slot(.sessionSearch(sessionSearchID)).select("sidebarSearch", as: SessionSearchFace.self) { $0 }
        guard let answer, answer.query == sessionSearchQuery else { return nil }
        return SidebarSessionSections(answer.sections)
    }

    var shellConversationSections: (rows: [String], working: [String], briefs: [String]) {
        guard let sections = sidebarSessionSections else { return ([], [], []) }
        let empty = Set(sections.empty), pinned = Set(sections.navigation)
        let visible: (String) -> Bool = { id in
            !empty.contains(id) || pinned.contains(id) || id == appModel.activeChatSessionId || shellSessionHasUnsentWork(id)
        }
        let active = appModel.activeChatSessionId
        let activeBrief = sections.briefs.contains(active) ? [active] : []
        return (sections.rows.filter(visible) + activeBrief, sections.working.filter(visible),
                sections.briefs.filter { $0 != active && visible($0) })
    }

    /// Unsent text and attachments must keep their conversation reachable.
    func shellSessionHasUnsentWork(_ sessionId: String) -> Bool {
        !appModel.chatDraft(for: sessionId).isEmpty
            || !(appModel.chatPendingAttachments[sessionId] ?? []).isEmpty
    }

    @ViewBuilder
    func shellConversationsColumn(_ layout: SurfaceLayoutAvailability) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let failure = layout.failure {
                Text(failure.localizedDescription).font(.caption).textSelection(.enabled)
            }
            HStack(alignment: .firstTextBaseline, spacing: NativeAgentSpacing.sm) {
                Text(ChatShellCopy.conversationsTitle)
                    .font(ShellType.columnTitle)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                ChatSidebarArchiveButton(shell: true)

                Button {
                    Task {
                        await appModel.newChatSession()
                    }
                } label: {
                    Text("New")
                        .font(ShellType.labelSemibold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            NativeAgentShell.quietFill,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(NativeAgentShell.text)
                .help("New chat")
                .accessibilityLabel("New chat")
                .accessibilityIdentifier("chat.conversations.new")
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)

            NativeSearchField(text: $sessionSearch, prompt: "Search",
                              identifier: "chat.conversations.search",
                              accessibilityLabel: "Search conversations")
                .padding(.bottom, 8)
                .modifier(FaceObservation(demand: .sessionSearch(view: sessionSearchID, query: sessionSearchQuery)))

            // Mark retained rows stale when their list refresh fails.
            PanelStaleNoticeView(item: .chat)
            SessionNavigationNotice()

            // Let native sidebar selection own arrows and collapsible sections.
            let sections = shellConversationSections
            // Draw offscreen selection explicitly because bitmap capture renders the native vibrancy highlight as a black slab.
            List(selection: Binding<String?>(
                get: { quietOffscreenRead ? nil : appModel.activeChatSessionId },
                set: { id in
                    guard let id, id != appModel.activeChatSessionId, renamingSessionId == nil,
                          (sections.rows + sections.briefs + sections.working).contains(id) else { return }
                    Task { await appModel.selectChatSession(id: id) }
                }
            )) {
                if sections.rows.isEmpty && sections.briefs.isEmpty && sections.working.isEmpty {
                    Group {
                        if !sessionSearchQuery.isEmpty, sidebarSessionSections == nil {
                            Text("Searching conversations…").font(ShellType.label).foregroundStyle(NativeAgentShell.secondary)
                        } else {
                            SessionListEmptyNotice(searchQuery: sessionSearch)
                        }
                    }.selectionDisabled()
                }
                // Read block order and fold state from the layout owner so the column reflects saved choices.
                ForEach(layout.contentNames("chat", profile: layoutProfile), id: \.self) { block in
                    switch block {
                    case "rows":
                        ForEach(sections.rows, id: \.self) { sessionID in
                            shellSessionRow(sessionID).tag(sessionID)
                        }
                    case "briefs" where !sections.briefs.isEmpty:
                        Section(isExpanded: shellFold("briefs", layout: layout)) {
                            ForEach(sections.briefs, id: \.self) { sessionID in
                                shellSessionRow(sessionID).tag(sessionID)
                            }
                        } header: {
                            Text("\(ChatShellCopy.briefsRowTitle)  \(sections.briefs.count)")
                                .foregroundStyle(NativeAgentShell.secondary)
                        }
                    case "working" where !sections.working.isEmpty:
                        // The active conversation must not fold out of sight.
                        Section(isExpanded: shellFold("working", layout: layout,
                            openWhile: sections.working.contains(appModel.activeChatSessionId))) {
                            ForEach(sections.working, id: \.self) { sessionID in
                                shellSessionRow(sessionID).tag(sessionID)
                            }
                        } header: {
                            Text("\(ChatShellCopy.workingRowTitle(agentName: appModel.agentAddressName))  \(sections.working.count)")
                                .foregroundStyle(NativeAgentShell.secondary)
                        }
                    default:
                        EmptyView()
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .opacity(appModel.face.slot(.sessionNavigation).select("indexFailed", as: SessionNavigationFace.self) { $0?.issue != nil } ? 0.55 : 1)
        }
        .padding(.horizontal, NativeAgentShellLayout.conversationsInset)
        // Include the gutter in conversation-column measurement so alignment uses its full width.
        .frame(width: NativeAgentShellLayout.conversationsWidth)
        .padding(.top, NativeAgentShellLayout.columnHeaderTopInset)
        .padding(.bottom, 16)
        // Keep the list transparent so it shares the room's sheet.
    }

    /// Persist fold changes as the person's own layout choices.
    func shellFold(_ block: String, layout: SurfaceLayoutAvailability, openWhile forced: Bool = false) -> Binding<Bool> {
        // Without a layout there is no fold state to edit; keep its rows exposed.
        guard case .available(let document) = layout else { return .constant(true) }
        return Binding(get: { forced || document.expanded("chat", block) },
                set: { open in Task {
                    await appModel.performChatMutation(.setSurfaceExpanded(surface: "chat", block: block, open: open), success: "Conversation section saved")
                } })
    }

    func shellSessionRow(_ sessionID: String) -> some View {
        ShellSessionFaceRow(sessionID: sessionID, selected: sessionID == appModel.activeChatSessionId,
            renaming: renamingSessionId == sessionID,
            quietSelection: quietOffscreenRead && sessionID == appModel.activeChatSessionId,
            onPin: { pinSession(sessionID, selectAfterPin: false) }, onUnpin: { unpinSession(sessionID) },
            onRenameBegin: { renamingSessionId = sessionID },
            onRenameEnd: { title in
                renamingSessionId = nil
                if let title { renameSession(sessionID, title) }
            })
            .equatable()
    }

    // MARK: - The room's felt state

    /// Reserve teal for approvals waiting on the user's decision.
    var shellPendingApprovalCount: Int? {
        appModel.face.slot(.counts).select("approvals.waitingCount", as: CountsFace.self) { $0?.approvals.waitingCount }
    }

    /// Derive failure from the loaded transcript so no duplicate retry counter can go stale.
    var shellHasTrouble: Bool {
        appModel.face.slot(.conversation(session: appModel.activeChatSessionId)).select("hasTrouble", as: ConversationFace.self) {
            $0?.actions.contains { $0.failure != nil } == true
        }
    }

    var shellStatus: ChatShellStatus {
        .make(
            pendingApprovals: shellPendingApprovalCount,
            approvalError: appModel.face.slot(.counts).select("approvals.error", as: CountsFace.self) { $0?.approvals.error },
            hasTrouble: shellHasTrouble
        )
    }

    /// Keep one placeholder; failure cards must not promise queued work.
    var shellComposerPlaceholder: String {
        // Observe the agent's name so the placeholder follows identity changes.
        ChatShellCopy.composerPlaceholder(agentName: appModel.agentAddressName)
    }
}

// MARK: - Transcript viewport motion
// Keep these expressions outside the viewport body because its generic chain is at the type-checker's limit.
extension ChatView {
    var latestPillAnimation: Animation? {
        NativeAgentMotion.respecting(NativeAgentMotion.spring, reduceMotion: reduceMotion)
    }

    var latestPillTransition: AnyTransition {
        NativeAgentMotion.reveal(reduceMotion: reduceMotion, anchor: .bottom)
    }

    /// Animate the Latest pill because arriving content itself is offscreen.
    var latestPillOverlay: some View {
        ChatLatestPillGate(handle: transcriptHandle, animation: latestPillAnimation) {
            Button {
                transcriptLatestRequest &+= 1
            } label: {
                latestPillLabel
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    // Use an opaque pill for quiet capture because tinted glass can blank the bitmap.
                    .background {
                        if reduceTransparency || quietOffscreenRead { Capsule().fill(NativeAgentShell.room) }
                    }
                    .glassEffect(reduceTransparency || quietOffscreenRead ? .identity : HouseGlass.plate.interactive(), in: Capsule())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("chat.latest")
            .accessibilityLabel("Jump to latest message")
            .padding(.horizontal, 18)
            .padding(.top, 18)
            // Observe clearance in the modifier so only this pill re-lays out when the card grows.
            .modifier(ChatTurnCardClearancePadding(
                store: turnCardClearanceStore,
                idle: 18
            ))
            .transition(latestPillTransition)
        }
    }

    /// Bounce once per arrival to signal unseen content; Reduce Motion keeps the value unchanged.
    var latestPillLabel: some View {
        Label("Latest", systemImage: "arrow.down.circle.fill")
            .font(NativeAgentFont.tag)
            .symbolEffect(
                .bounce,
                options: .nonRepeating,
                value: reduceMotion ? 0 : appModel.face.slot(.conversation(session: appModel.activeChatSessionId))
                    .select("messageCount", as: ConversationFace.self) { $0?.actions.count ?? 0 }
            )
    }
}

/// Read the at-end signal in the pill's own body so crossing the bottom cannot re-render ChatView.
struct ChatLatestPillGate<Pill: View>: View {
    let handle: TranscriptDocumentHandle
    let animation: Animation?
    @ViewBuilder let pill: () -> Pill

    var body: some View {
        let shows = !handle.isAtEnd
        ZStack(alignment: .bottomTrailing) {
            if shows { pill() }
        }
        .animation(animation, value: shows)
    }
}

/// Mount archive controls independently so hosting the durable route cannot start unrelated chat work.
struct ChatSidebarArchiveButton: View {
    @Environment(AppModel.self) private var appModel
    var shell = false
    @State private var failure: String?
    @State private var isArchiving = false

    var body: some View {
        Button {
            isArchiving = true
            Task {
                let result = await appModel.archiveActiveChat()
                if !result.succeeded { failure = result.userMessage }
                isArchiving = false
            }
        } label: {
            if shell {
                Text("Archive")
                    .font(ShellType.labelSemibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .foregroundStyle(NativeAgentShell.secondary)
            } else {
                Image(systemName: "archivebox")
            }
        }
        .buttonStyle(.borderless)
        .disabled(appModel.activeChatSessionId.isEmpty || isArchiving)
        .help("Archive active chat")
        .accessibilityLabel("Archive active chat")
        .alert("Couldn’t archive conversation", isPresented: Binding(
            get: { failure != nil },
            set: { if !$0 { failure = nil } }
        )) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "The conversation was not archived.")
        }
    }
}
