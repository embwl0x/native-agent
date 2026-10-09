import SwiftUI
import UIKit
import NativeAgentShared

// MARK: - Bubble

struct BubbleView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: ChatMessage
    var streamingHint: String = "Typing"
    // Set when this assistant bubble timed out locally. The accessory resumes
    // observation of the same signed event; it never queues a second turn.
    var isTimedOut: Bool = false
    var onRetry: (() -> Void)? = nil
    /// A turn another door (the Mac, Telegram) is streaming into this chat.
    /// It paces like her own live reply until its saved answer lands.
    var isLiveTurn = false

    /// The Mac Simple thread: the agent's words are plain large text with
    /// room between the lines, no bubble; the person's own lines are quieter
    /// and smaller, on the same left edge.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 8) {
                if let card = message.interaction, let descriptor = message.interactionDescriptor,
                   let session = message.interactionSessionID {
                    MobileInteractionCard(card: card, descriptor: descriptor, sessionID: session)
                }
                ForEach(imageAttachments) { attachment in
                    AttachmentImagePreview(summary: attachment)
                }
                if attachmentCountWithoutPreview > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "photo.fill")
                        Text(attachmentCountWithoutPreview == 1 ? "1 attachment" : "\(attachmentCountWithoutPreview) attachments")
                    }
                    .font(.footnote)
                    .foregroundStyle(AlivePalette.secondary)
                }
                if message.interaction == nil && (!message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.attachments.isEmpty) {
                    // One view from the wait to the settled reply: the hint
                    // crossfades to the first paced words, and the streamed
                    // text crossfades to markdown. The stack takes the
                    // incoming phase's size, so nothing stacks while it fades.
                    ChatCrossfadeStack(current: phase) {
                        if phase == 0 {
                            waitingHint
                                .layoutValue(key: ChatCrossfadePhase.self, value: 0)
                                .transition(.opacity)
                        }
                        if phase == 2 {
                            ChatMarkdownView(blocks: MobileChatMarkdown.blocks(id: message.id, content: message.text))
                                .layoutValue(key: ChatCrossfadePhase.self, value: 2)
                                .transition(.opacity)
                        } else {
                            plainText
                                .layoutValue(key: ChatCrossfadePhase.self, value: 1)
                                .transition(.opacity)
                        }
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: phase)
                }
            }
            if message.role == .assistant, message.completionState == "failed" || message.failureDetail != nil {
                AliveStatusNote(systemImage: "exclamationmark.circle",
                    text: message.failureDetail.map { "Interrupted · \($0)" } ?? "Interrupted")
            }
            // Collapsed "Used N tools" summary sits BELOW the reply once the
            // turn is done, so it never pushes the text down at finish.
            if message.role == .assistant, !message.isStreaming, !message.toolEvents.isEmpty {
                ToolActivityView(events: message.toolEvents, isLive: false)
            }
            // 2026-09-13: "Keep waiting" is gone. Waiting is no longer
            // something the person has to ask for — the phone never stops
            // observing the request it already sent, so there is nothing
            // here to press.
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, isUser && !dynamicTypeSize.isAccessibilitySize ? 24 : 0)
    }

    /// 0 waiting for the first words, 1 plain (the live reply, the person's
    /// own lines), 2 a settled reply as markdown.
    private var phase: Int {
        if message.isStreaming || isLiveTurn { return message.text.isEmpty ? 0 : 1 }
        return message.role == .assistant && !message.text.isEmpty ? 2 : 1
    }

    @ViewBuilder
    private var waitingHint: some View {
        if !message.toolEvents.isEmpty {
            // Working through tools — flip through them in one line.
            ToolActivityView(events: message.toolEvents, isLive: true)
        } else {
            HStack(spacing: 10) {
                HazePulse()
                Text(streamingHint)
                    .mobileTypography(.body)
                    .foregroundStyle(AlivePalette.secondary)
            }
            .frame(minHeight: 32, alignment: .leading)
        }
    }

    /// Her reply streams through the paced reveal (about 80 words a second,
    /// the newest words fading in, finished paragraphs left alone); it is
    /// mounted from the wait on, so the first batch paces too. The person's
    /// own lines are plain text.
    @ViewBuilder
    private var plainText: some View {
        Group {
            if isUser {
                Text(message.text.isEmpty ? " " : message.text)
            } else {
                // The phone's ~1 s batches carry up to ~1,200 characters (up to 4 bytes each).
                PacedStreamingText(text: message.text, maxLagBytes: 4_800, inline: ChatInlineMarkdown(MobileChatMarkdown.inline))
            }
        }
        .font(isUser ? .subheadline : .body)
        .lineSpacing(isUser ? 3 : 6)
        .foregroundStyle(isUser ? AlivePalette.ownLine : AlivePalette.text)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isUser: Bool { message.role == .user }

    private var imageAttachments: [ChatAttachmentSummary] {
        ChatAttachmentPresentation.previewableImages(in: message.attachments)
    }

    private var attachmentCountWithoutPreview: Int {
        ChatAttachmentPresentation.fallbackCount(in: message.attachments)
    }
}

private struct MobileInteractionCard: View {
    let card: InlineInteraction
    let descriptor: InlineInteractionDescriptor
    let sessionID: String
    @State private var values: [String: String] = [:]
    @State private var busy = false
    @State private var response: String?
    @State private var answeredRevision: Int?
    @State private var showsTrust = false
    @State private var showsProviders = false
    @StateObject private var settingsStore = SettingsStore()

    private var locallyRequired: Bool {
        [.internetAccounts, .chromeSetup, .pairDevice, .connectorOAuth].contains(descriptor.control)
    }
    private var editable: Bool {
        card.state.name == "pending" || card.state.failureReason != nil || (card.state.name == "running" && locallyRequired)
    }
    private var fields: [(String, String, Bool)] {
        if descriptor.control == .providerAPIKey { return [("value", "API key or setup token", true)] }
        guard descriptor.control == .connectorManualToken else { return [] }
        switch descriptor.target {
        case "slack": return [("token", "Bot token", true), ("app_token", "Socket Mode token (optional)", true),
                              ("allowed_channels", "Allowed channel IDs", false), ("allowed_users", "Allowed user IDs", false)]
        case "telegram": return [("token", "Bot token", true), ("allowed_chat_id", "Allowed chat ID (optional)", false)]
        default: return [("token", "Token", true)]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(card.title, systemImage: descriptor.icon ?? "questionmark.circle")
                .font(.headline)
            Text(card.why)
            if let outcome = card.state.outcome { Label(outcome.summary, systemImage: "checkmark.circle") }
            else if card.state == .declined { Text("Not now. " + card.declineConsequence).foregroundStyle(.secondary) }
            else if card.state == .superseded { Text("Replaced by a newer request.").foregroundStyle(.secondary) }
            else if card.state.isUnknown { Text("This build cannot answer this card.").foregroundStyle(.secondary) }
            else {
                if let reason = card.state.failureReason { Text(reason).foregroundStyle(.orange) }
                if let note = card.persistenceNote { Text(note).font(.footnote).foregroundStyle(.secondary) }
                if card.kind == .permission {
                    Text("Access: " + (card.mode?.phrase ?? "read and write")).font(.footnote)
                    Text("macOS privacy grants still require approval on the Mac.").font(.footnote).foregroundStyle(.secondary)
                }
                if locallyRequired {
                    Text("Complete this setup on your Mac, then check again here.").font(.footnote)
                    Button("Check again") { answer("verify") }
                } else if descriptor.control == .trustPostureRequired {
                    Button("Review Trust") { showsTrust = true }
                    Button("Check again") { answer("verify") }
                } else if descriptor.isActionable {
                    if descriptor.control == .providerAPIKey || descriptor.control == .providerGroupModel {
                        Button("Provider settings") { showsProviders = true }
                        Button("Check again") { answer("verify") }
                    }
                    ForEach(fields, id: \.0) { field in
                        Group {
                            if field.2 { SecureField(field.1, text: fieldBinding(field.0)) }
                            else { TextField(field.1, text: fieldBinding(field.0)) }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    }
                    if !fields.isEmpty {
                        Text("Encrypted to your paired Mac. Credentials never enter the conversation.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if card.kind == .choose || card.kind == .modelChoice {
                        ForEach(card.options.filter { $0.id != "__save_for_group__" }) { option in
                            Button { answer("primary", choice: option.id) } label: {
                                VStack(alignment: .leading) {
                                    Text(option.label)
                                    if let detail = option.detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                                }
                            }
                        }
                        if card.kind == .modelChoice {
                            Picker("Applies to", selection: fieldBinding("scope")) {
                                Text("This request").tag(InlineInteraction.Scope.thisRequestOnly.rawValue)
                                Text("Keep for this group").tag(InlineInteraction.Scope.persistent.rawValue)
                            }
                            .pickerStyle(.menu)
                        }
                    } else {
                        Button(card.primaryActionLabel) { answer("primary") }
                    }
                } else { Text(descriptor.unavailableReason ?? "This control is unavailable.") }
                Button("Not now") { answer("decline") }
                Text(card.declineConsequence).font(.footnote).foregroundStyle(.secondary)
            }
            if busy { ProgressView() }
            if let response, !response.isEmpty { Text(response).font(.footnote) }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .disabled(busy || !editable || answeredRevision == card.revision)
        .onAppear { values["scope"] = (card.primaryScope ?? .thisRequestOnly).rawValue }
        .onChange(of: card.revision) { _, _ in answeredRevision = nil; response = nil }
        .sheet(isPresented: $showsTrust) {
            NavigationStack {
                TrustPolicyView(store: settingsStore)
                    .toolbar { Button("Done") { showsTrust = false } }
                    .task { await settingsStore.refresh() }
            }
        }
        .sheet(isPresented: $showsProviders) {
            NavigationStack {
                ProviderSettingsView()
                    .toolbar { Button("Done") { showsProviders = false } }
            }
        }
    }

    private func fieldBinding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }
    private func answer(_ action: String, choice: String? = nil) {
        var input = values
        if let choice { input["choice"] = choice }
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await iCloudSyncEngine.shared.answerInteraction(card, sessionID: sessionID,
                    actionName: action, values: input)
                response = result["message"]
                answeredRevision = card.revision
                values = [:]
                await iCloudSyncEngine.shared.refreshChatTranscriptsSnapshot()
            } catch {
                response = error.localizedDescription
                await iCloudSyncEngine.shared.refreshChatTranscriptsSnapshot()
            }
        }
    }
}

private struct AttachmentImagePreview: View {
    let summary: ChatAttachmentSummary

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 260, maxHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
                }
                .accessibilityLabel(summary.name)
        }
    }

    private var image: UIImage? {
        guard let raw = summary.base64?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = Data(base64Encoded: raw) else {
            return nil
        }
        return UIImage(data: data)
    }
}

// MARK: - Inline chat approvals
//
// Sweep 2026-09-01 item 36. The Mac renders the approval a turn is waiting on
// straight onto that turn's card (MacChatTurnApproval); iOS had zero approval
// references in the whole chat surface, so the phone's only answer to "she is
// blocked on you" was to switch to the Activity tab and hunt for the row.
//
// This adds no store and no authority. It is a pure projection over the
// approvals `iCloudSyncEngine` already publishes, plus a card that dispatches
// through the SAME signed `approveApproval` / `rejectApproval` action the
// Activity tab uses. Activity → Approvals stays the canonical list.

enum MobileChatApprovalProjection {
    /// Questions, expirations and failed executions belonging to this conversation.
    static func pendingApprovals(
        sessionId: String?,
        approvals: [ApprovalRequest]
    ) -> [ApprovalRequest] {
        guard let sessionId = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else { return [] }
        return approvals.filter {
            $0.chatOriginSessionId == sessionId
                && (($0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "pending"
                    && $0.decision == nil) || $0.executionFailed || $0.isExpired)
        }
    }

    /// The turn an inline approval hangs under.
    ///
    /// The Mac fences an approval to a turn by comparing the row's `createdAt`
    /// against that turn's start. The iOS transcript carries no per-message
    /// timestamp at all, so the phone cannot prove which *earlier* turn raised
    /// a given row. The one turn it can prove is the newest assistant turn —
    /// the one in flight or just finished — so the card anchors there and
    /// nowhere else rather than guessing at a bubble it cannot substantiate.
    static func anchorMessageID(in messages: [ChatMessage]) -> UUID? {
        messages.last(where: { $0.role == .assistant })?.id ?? messages.last?.id
    }

    /// Same decision ownership as Activity and the Approvals screen.
    static func canDecideOnPhone(_ approval: ApprovalRequest) -> Bool {
        ActivityScreenPresentation.canDecideRemotely(action: approval.action)
    }
}

/// One pending approval, rendered on the turn that raised it. Approve / Deny
/// go through `iCloudSyncEngine`'s signed action channel; "In Activity" hands
/// the user to the canonical queue via the existing open-activity intent.
struct InlineChatApprovalCard: View {
    @EnvironmentObject private var pairingStore: PairingStore
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @ObservedObject private var bridge = iCloudBridge.shared
    let approval: ApprovalRequest

    @State private var isDeciding = false
    @State private var decisionStatusText: String?
    @State private var decisionStatusIsError = false

    private var canDecide: Bool { MobileChatApprovalProjection.canDecideOnPhone(approval) }
    private var pending: Bool { approval.status.lowercased() == "pending" && approval.decision == nil }

    private var canSendDecision: Bool {
        pairingStore.isICloudSigned && bridge.available && bridgeClient.bridgeStatus != .deviceOffline
    }

    /// Plain words for the risk the Mac assigned, shown only when it is worth
    /// a second look.
    private var riskWords: String? {
        switch approval.risk.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "low", "none": return nil
        case let risk: return "\(risk.capitalized) risk"
        }
    }

    /// The approval sits in the thread as content: a card with the "needs
    /// you" light, the question in the agent's words, and two answers.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if pending { AliveStatusDot(state: .waiting).scaleEffect(0.75) }
                Text(pending ? (canDecide ? "I need your OK" : "\(iCloudSyncEngine.shared.agentDisplayName)’s decision") : approval.decisionSummary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AlivePalette.secondary)
                if let riskWords {
                    Text("· \(riskWords)")
                        .font(.caption)
                        .foregroundStyle(AlivePalette.secondary)
                }
                Spacer(minLength: 0)
            }
            Text(ApprovalText.title(approval))
                .font(.body.weight(.semibold))
                .foregroundStyle(AlivePalette.text)
                .lineLimit(2)
            if let reason = ApprovalText.reason(approval), !reason.isEmpty {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(AlivePalette.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // What will be sent, in plain lines, before Approve.
            PayloadPreview(approval: approval, maxLines: 4)
            if let summary = approval.expirationGuidance(agentName: iCloudSyncEngine.shared.agentDisplayName) ?? approval.executionSummary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(AlivePalette.secondary)
            }
            if let decisionStatusText {
                Text(decisionStatusText)
                    .font(.footnote)
                    .foregroundStyle(decisionStatusIsError ? Color.red : AlivePalette.secondary)
            }
            if pending && !canDecide {
                Text(ApprovalText.agentDecision)
                    .font(.footnote)
                    .foregroundStyle(AlivePalette.secondary)
            }
            HStack(spacing: 10) {
                if pending && canDecide {
                    Button {
                        decide(approve: true)
                    } label: {
                        Text("Approve")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 6)
                            .frame(minHeight: 30)
                            .fixedSize()
                    }
                    .alivePrimaryButton()
                    .disabled(isDeciding || !canSendDecision)

                    Button {
                        decide(approve: false)
                    } label: {
                        Text("Deny")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 6)
                            .frame(minHeight: 30)
                            .fixedSize()
                    }
                    .aliveSecondaryButton()
                    .disabled(isDeciding || !canSendDecision)
                }
                if isDeciding {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
                Button {
                    NotificationCenter.default.post(
                        name: .nativeagentOpenActivity,
                        object: nil,
                        userInfo: ["screen": "approvals"]
                    )
                } label: {
                    Text("In Activity")
                        .font(.footnote)
                        .foregroundStyle(AlivePalette.secondary)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isDeciding)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
        // The transcript column already caps the readable width (roomColumn).
        .frame(maxWidth: .infinity, alignment: .leading)
        .aliveCard(radius: 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(pending ? "Approval needed" : approval.decisionSummary) for \(ApprovalText.title(approval))")
    }

    private func decide(approve: Bool) {
        guard pending, canDecide, canSendDecision, !isDeciding else { return }
        #if DEBUG
        // The -chatSampleExtras fixture is for screenshots only; never send it.
        if approval.id == "sample-approval" { return }
        #endif
        isDeciding = true
        decisionStatusText = nil
        decisionStatusIsError = false
        let id = approval.id
        Task { @MainActor in
            do {
                if approve {
                    _ = try await iCloudSyncEngine.shared.approveApproval(id: id)
                    iOSSystemToastCenter.shared.push(success: "Approval approved")
                } else {
                    _ = try await iCloudSyncEngine.shared.rejectApproval(id: id)
                    iOSSystemToastCenter.shared.push(info: "Approval denied")
                }
                await iCloudSyncEngine.shared.refreshActivitySnapshot()
            } catch {
                // A timeout proves only that the phone did not see the answer.
                // Never claim the decision landed.
                decisionStatusIsError = !iCloudSyncEngine.isMacResponseTimeout(error)
                decisionStatusText = iCloudSyncEngine.isMacResponseTimeout(error)
                    ? "Decision sent; waiting for the Mac to publish the result."
                    : error.localizedDescription
            }
            isDeciding = false
        }
    }
}

// MARK: - Tool / skill activity (flip-box + collapsed summary)

/// iOS counterpart to the Mac `ToolCallGroup`. While she's working, `isLive`
/// shows ONE box that flips through tools as they fire. When done, it collapses
/// to "N tools used" / "N skills used" rows, each tappable to expand the names.
struct ToolActivityView: View {
    let events: [ToolEvent]
    let isLive: Bool
    @State private var toolsExpanded = false
    @State private var skillsExpanded = false

    // Skill use is a shared remote-surface presentation taxonomy. The Mac
    // dispatcher catalog remains executable authority; its parity eval keeps
    // this compact iOS projection in lockstep as names evolve.
    private func isSkill(_ e: ToolEvent) -> Bool {
        ToolActivityPresentation.isSkillReaderTool(named: e.name)
    }

    private var ordered: [ToolEvent] { events.sorted { $0.seq < $1.seq } }
    private var skills: [ToolEvent] { ordered.filter(isSkill) }
    private var tools: [ToolEvent] { ordered.filter { !isSkill($0) } }
    private var latest: ToolEvent? { events.max(by: { $0.seq < $1.seq }) }

    var body: some View {
        if isLive { liveBox } else { collapsed }
    }

    private var liveBox: some View {
        HStack(spacing: 8) {
            HazePulse()
            Group {
                if let latest {
                    Text(latest.activity ?? Self.plainName(latest.name))
                        .id(latest.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)))
                }
            }
            .font(AppFont.body)
            .foregroundStyle(AlivePalette.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(minWidth: 150, maxWidth: 300, minHeight: 32, maxHeight: 32, alignment: .leading)
        .animation(.easeOut(duration: 0.22), value: latest?.id)
    }

    private var collapsed: some View {
        HStack(alignment: .top, spacing: 16) {
            if !tools.isEmpty {
                summaryRow(items: tools, noun: "tool",
                           icon: "wrench.and.screwdriver", expanded: $toolsExpanded)
            }
            if !skills.isEmpty {
                summaryRow(items: skills, noun: "skill",
                           icon: "text.book.closed", expanded: $skillsExpanded)
            }
        }
    }

    /// The same friendly tool phrases as Mac and Telegram.
    static func plainName(_ raw: String) -> String {
        ToolActivityPresentation.title(raw)
    }

    /// "Used 3 tools ›": one quiet line; tap to see which.
    @ViewBuilder
    private func summaryRow(items: [ToolEvent], noun: String, icon: String,
                            expanded: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text("Used " + AliveWords.count(items.count, noun))
                        .font(.footnote)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                }
                .foregroundStyle(AlivePalette.secondary)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
            if expanded.wrappedValue {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { e in
                        Text(e.outcome.map { ToolActivityPresentation.finished(e.name, outcome: $0, detail: e.resultDetail) }
                             ?? Self.plainName(e.name))
                            .font(.footnote)
                            .foregroundStyle(AlivePalette.secondary)
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(AlivePalette.divider).frame(width: 1)
                }
            }
        }
    }
}
