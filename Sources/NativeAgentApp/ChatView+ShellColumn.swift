import SwiftUI
import NativeAgentShared

// ui-simplify 2026-09-02 (Lane A): the conversations column.
//
// What it replaces: a machine log. `[from: codex, via bridge] …`, `iOS chat
// 03108B46`, `Telegram 1394548068` three times over, a yellow "Warning" badge
// on the header, and a Pinned/Recent split that made forty rows read as eighty.
//
// What it is now: ONE list. Every row says what the conversation was about and
// where it happened. The bridge sessions — real conversations, but hers with
// other agents — ride under one collapsed "Working" row. The warning badge is
// gone from this header; the room's single status dot carries that state.

extension ChatView {
    /// The visible rows, split into the human conversations and the bridge
    /// ones. Both halves come from the same cached projection the classic
    /// sidebar uses, so search, pinning and archiving behave identically.
    var shellConversationSections: (rows: [ChatSession], working: [ChatSession], briefs: [ChatSession]) {
        let sections = sidebarProjection.sections
        var rows: [ChatSession] = []
        var working: [ChatSession] = []
        var briefs: [ChatSession] = []
        // User, 2026-09-06: a pin is a choice. A pinned bridge session sat in
        // the list only while it was on screen and fell into Working the
        // moment another chat was opened, so the pin meant nothing.
        rows.append(contentsOf: sections.pinned)
        for session in sections.unpinned {
            // The conversation on screen is never folded out of sight.
            if session.id == appModel.activeChatSessionId {
                rows.append(session)
            } else if (session.messageCount ?? 0) == 0, !shellSessionHasUnsentWork(session.id) {
                // Agent, 2026-09-02: "a row with no name is a row with no
                // home." An empty conversation nobody is in shows nothing.
                // 2026-09-06: unless something unsent is waiting in it. Text
                // typed here and left behind when the human switched away had
                // no row to click back to, so the draft was unreachable.
                continue
            } else if ChatShellConversationRow.isWorking(session) {
                working.append(session)
            } else if ChatShellConversationRow.isHerOwn(session) {
                // Agent, 2026-09-02: twenty morning briefs where she spoke
                // first are one row, not a wall of the same greeting.
                briefs.append(session)
            } else {
                rows.append(session)
            }
        }
        return (rows, working, briefs)
    }

    /// Unsent text or attachments waiting in a conversation with no messages.
    /// 2026-09-06: such a session is still worth a row — it is the only way
    /// back to the draft.
    func shellSessionHasUnsentWork(_ sessionId: String) -> Bool {
        !appModel.chatDraft(for: sessionId).isEmpty
            || !(appModel.chatPendingAttachments[sessionId] ?? []).isEmpty
    }

    /// Only the HUMAN's pins. 2026-09-06: this read the merged projection,
    /// which carries the live conversation anchor as well, so a row nobody
    /// ever pinned showed a filled pin and "Unpin Tab" — and clicking it
    /// reached the human pin store, which answered "already unpinned". The
    /// anchor still rides in `sections.pinned` and still stays in the list;
    /// it just is not described as the person's choice.
    func shellSessionIsPinned(_ session: ChatSession) -> Bool {
        humanPinnedSessionIds().contains(session.id)
    }

    @ViewBuilder
    var shellConversationsColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // Agent, 2026-09-03: SF Rounded appeared exactly once in the
                // shell, here, 288pt from a system-face "Agent" of the same
                // rank. Every column header is now the system face at 20
                // semibold.
                Text(ChatShellCopy.conversationsTitle)
                    .font(ShellType.title)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                // Agent, 2026-09-02, glyph diet: an archive box and a plus
                // over a list of conversations are a guess each. Same two
                // actions, same code paths — now with their words on them.
                Button {
                    Task { await appModel.archiveActiveChat() }
                } label: {
                    Text("Archive")
                        .font(ShellType.labelSemibold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(NativeAgentShell.secondary)
                .disabled(appModel.activeChatSessionId.isEmpty)
                .help("Archive active chat")
                .accessibilityLabel("Archive active chat")

                Button {
                    Task {
                        await appModel.newChatSession()
                        await MainActor.run {
                            renameTitle = activeSession?.title ?? ""
                        }
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
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.secondary)
                TextField("Search", text: $sessionSearch)
                    .textFieldStyle(.plain)
                    .font(ShellType.label)
                    .accessibilityLabel("Search conversations")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                NativeAgentShell.quietFill,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .padding(.bottom, 8)

            // M12: a list that could not refresh says so rather than passing
            // off an old snapshot as live. Both notices survive the reshape.
            if let notice = appModel.panelStaleNotice(for: .chat) {
                StalePanelNotice(text: notice)
            }
            if appModel.chatSessionIndexRefreshFailed {
                StalePanelNotice(
                    text: "The session list could not update, so it is showing the last known sessions."
                )
            }

            ScrollView {
                // User, 2026-09-04: plain VStack, same reason as the transcript
                // (LazyVStack prefetch loop). The list is dozens of rows.
                VStack(spacing: NativeAgentShellLayout.listRowGap) {
                    let sections = shellConversationSections
                    if sections.rows.isEmpty && sections.working.isEmpty {
                        Text(
                            ChatSessionListEmptyStatePresentation.message(
                                totalSessionCount: appModel.chatSessions.count,
                                searchQuery: sessionSearch
                            )
                        )
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    ForEach(sections.rows) { session in
                        shellSessionRow(session)
                    }
                    if !sections.briefs.isEmpty {
                        ShellWorkingGroupRow(
                            title: ChatShellCopy.briefsRowTitle,
                            count: sections.briefs.count,
                            isExpanded: shellBriefsExpanded,
                            onToggle: {
                                withAnimation(NativeAgentMotion.respecting(
                                    ShellFoldMotion.open, reduceMotion: reduceMotion
                                )) { shellBriefsExpanded.toggle() }
                            }
                        )
                        .padding(.top, 10)
                        if shellBriefsExpanded {
                            ForEach(Array(sections.briefs.enumerated()), id: \.element.id) { index, session in
                                shellSessionRow(session)
                                    .padding(.leading, 10)
                                    .transition(ShellFoldMotion.transition(reduceMotion: reduceMotion))
                                    .animation(
                                        ShellFoldMotion.rowAnimation(index: index, reduceMotion: reduceMotion),
                                        value: shellBriefsExpanded
                                    )
                            }
                        }
                    }
                    if !sections.working.isEmpty {
                        ShellWorkingGroupRow(
                            count: sections.working.count,
                            isExpanded: shellWorkingExpanded,
                            onToggle: {
                                withAnimation(NativeAgentMotion.respecting(
                                    ShellFoldMotion.open, reduceMotion: reduceMotion
                                )) { shellWorkingExpanded.toggle() }
                            }
                        )
                        .padding(.top, 10)
                        if shellWorkingExpanded {
                            ForEach(Array(sections.working.enumerated()), id: \.element.id) { index, session in
                                shellSessionRow(session)
                                    .padding(.leading, 10)
                                    .transition(ShellFoldMotion.transition(reduceMotion: reduceMotion))
                                    .animation(
                                        ShellFoldMotion.rowAnimation(index: index, reduceMotion: reduceMotion),
                                        value: shellWorkingExpanded
                                    )
                            }
                        }
                    }
                }
            }
            .opacity(appModel.chatSidebarSessionListOpacity)
        }
        .padding(.horizontal, NativeAgentShellLayout.conversationsInset)
        // The column is 288 wide edge to edge — the measured number. The
        // source used to say 264, which was the content inside the gutter.
        .frame(width: NativeAgentShellLayout.conversationsWidth)
        // The shell baseline: 20 semibold in a 24pt-tall head row, 22 down
        // from the title strip, puts "Conversations" on window y 72 with
        // "Chat" and the room header.
        .padding(.top, 22)
        .padding(.bottom, 16)
        // User, 2026-09-03: the same move the rail made. The
        // NSVisualEffectView under a 0.28 colour coat could not adapt to what
        // was behind the window, so the column read as paint, not glass — and
        // it read as a different material from the rail beside it. Rail and
        // list now wear one material: a hint of the column's own tone under
        // real Liquid Glass. Reduce transparency takes the fill opaque and the
        // glass to .identity — that setting asks for more opacity, never less.
        // User, 2026-09-03: one sheet. The list sits on the room's own
        // material and coat, and keeps a hairline on its trailing edge.
        // The sheet is the window's (ShellFrame); the list is transparent over
        // it and keeps only its hairline.
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(NativeAgentShell.hairline)
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }

    /// One row. While a rename is in flight the classic `SessionRow` renders
    /// instead — it already owns the single-fire rename state machine, and a
    /// second implementation of "when does an edit commit" is exactly the kind
    /// of drift that loses somebody's typing.
    @ViewBuilder
    func shellSessionRow(_ session: ChatSession) -> some View {
        let renaming = renamingSessionId == session.id
        let isPinned = shellSessionIsPinned(session)
        // A thread is named once. When a placeholder-titled session resolves
        // a first line, that line becomes the stored title, so compaction or
        // a relaunch can never rename the thread later.
        let _ = ChatShellNaming.settle(session, appModel: appModel)
        let selectSession: () -> Void = {
            guard !renaming else { return }
            if renamingSessionId != nil { renamingSessionId = nil }
            renameTitle = session.title
            Task { await appModel.selectChatSession(session) }
        }
        Group {
            if renaming {
                SessionRow(
                    session: session,
                    selected: session.id == appModel.activeChatSessionId,
                    pinState: isPinned
                        ? .pinned(onUnpin: { unpinSession(session.id) })
                        : .unpinned,
                    onSelect: selectSession,
                    renaming: true,
                    onRenameBegin: { renamingSessionId = session.id },
                    onRenameEnd: { title in
                        renamingSessionId = nil
                        if let title { renameSession(session.id, title) }
                    }
                )
            } else {
                ShellConversationRow(
                    session: session,
                    selected: session.id == appModel.activeChatSessionId,
                    isPinned: isPinned,
                    onSelect: selectSession,
                    onTogglePin: {
                        if isPinned { unpinSession(session.id) } else { pinSession(session.id, selectAfterPin: false) }
                    },
                    barNamespace: shellConversationBar
                )
            }
        }
        .overlay {
            if !renaming {
                SessionDragSource(sessionId: session.id, sessionTitle: session.title)
            }
        }
        .contextMenu {
            if isPinned {
                Button("Unpin Tab", systemImage: "pin.slash") { unpinSession(session.id) }
            } else {
                Button("Pin as Tab", systemImage: "pin") {
                    pinSession(session.id, selectAfterPin: false)
                }
            }
            Button("Rename Session", systemImage: "pencil") {
                renamingSessionId = session.id
            }
            Divider()
            if DetachedChatWindowController.shared.isDetached(session.id) {
                Button("Bring Detached Window to Front", systemImage: "macwindow.on.rectangle") {
                    DetachedChatWindowController.shared.focus(sessionId: session.id)
                }
                Button("Close Detached Window", systemImage: "xmark.rectangle") {
                    DetachedChatWindowController.shared.close(sessionId: session.id)
                }
            } else {
                Button("Open in Detached Window", systemImage: "rectangle.badge.plus") {
                    DetachedChatWindowController.shared.open(sessionId: session.id, origin: nil)
                }
            }
        }
        .help("\(ChatShellConversationRow.title(for: session))\n\nRight-click to rename, pin, or detach")
        .id(ChatSidebarSessionRowIdentity(sessionID: session.id, pinned: isPinned))
    }

    // MARK: - The room's felt state

    /// True while an approval is waiting on a decision. This is the ONE thing
    /// that spends the teal.
    var shellHasPendingApproval: Bool {
        appModel.approvals.contains {
            $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "pending"
        }
    }

    /// True when her last turn came apart. Derived from the transcript that is
    /// already loaded — no retry counter to go stale.
    var shellHasTrouble: Bool {
        ChatShellTroubleState.consecutiveFailures(appModel.chatMessages) > 0
    }

    var shellStatus: ChatShellStatus {
        .make(
            permissionLevel: appModel.trustPolicy?.permissionLevel,
            hasPendingApproval: shellHasPendingApproval,
            hasTrouble: shellHasTrouble
        )
    }

    /// 2026-09-06: this used to switch to "Keep typing. I'll send it when I'm
    /// back." on any trouble — a promise about a queue nothing here consults.
    /// One placeholder, and the trouble card says what happened.
    var shellComposerPlaceholder: String {
        ChatShellCopy.composerPlaceholder
    }
}

// MARK: - Transcript viewport motion
//
// These live outside the body because the viewport's ZStack is already at the
// type-checker's limit; each one is a one-liner the compiler can chew alone.
extension ChatView {
    /// Change blindness: a bubble that enters below the fold is motion nobody
    /// sees. Scrolled up, the arrival is instant and the "Latest" pill leads.
    var animatesMessageArrival: Bool { scrollCoordinator.autoFollow }

    var showsLatestPill: Bool {
        ChatViewportPresentation.shouldShowLatestPill(autoFollow: scrollCoordinator.autoFollow)
    }

    var latestPillAnimation: Animation? {
        NativeAgentMotion.respecting(.snappy, reduceMotion: reduceMotion)
    }

    var latestPillTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom))
    }

    /// The transcript itself. Lifted out of the viewport body for the same
    /// type-checker reason as the pill below it.
    var transcriptList: some View {
        ChatMessageListView(
            messages: appModel.chatMessages,
            sessionId: appModel.activeChatSessionId,
            isStreaming: appModel.isBusy
                && appModel.currentChatTaskSessionId == appModel.activeChatSessionId,
            highlightedMessageID: showTranscriptSearch ? transcriptSearch.selectedMessageID : nil,
            animatesArrival: animatesMessageArrival,
            latestRequest: transcriptLatestRequest
        )
    }

    /// The pill that says there is something below the fold. It enters on
    /// `.snappy` and its glyph bounces once per arriving message — the whole
    /// point being that the arrival itself is off-screen.
    func latestPillOverlay(_ proxy: ScrollViewProxy) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if showsLatestPill {
                Button {
                    transcriptLatestRequest &+= 1
                    scrollCoordinator.forceFollow()
                    scrollToBottom(proxy, animated: true, delay: 0.03, force: true)
                } label: {
                    latestPillLabel
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassEffect(.regular.interactive(), in: Capsule())  // Liquid Feel W2
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                // phase 4: lift clear of the floating thinking row while a turn
                // streams so it stays visible/clickable.
                .padding(.bottom, showThinkingRow ? turnCardClearance : 18)
                .transition(latestPillTransition)
            }
        }
        .animation(latestPillAnimation, value: showsLatestPill)
    }

    /// One bounce per arriving message, so the eye is led to what it cannot
    /// see. Under Reduce Motion the value never changes and it never bounces.
    var latestPillLabel: some View {
        Label("Latest", systemImage: "arrow.down.circle.fill")
            .font(NativeAgentFont.tag)
            .symbolEffect(
                .bounce,
                options: .nonRepeating,
                value: reduceMotion ? 0 : appModel.chatMessages.count
            )
    }
}
