import SwiftUI
import NativeAgentShared

/// The composer's three settings, each rendered as the word that names it.
///
/// User + Agent, 2026-09-15: "nothing on screen until you reach for it; every
/// setting lives behind the word that names it." The Conversation-settings
/// popover, the Thinking segmented control, the Fast toggle row, the
/// capabilities pill and the Context receipt button are gone; what they held
/// lives in three small cards that open above the word they belong to.
///
/// Agent's binding note 1: opening a card must not move the conversation. The
/// card is an *overlay* on this row — it takes no space, so the transcript and
/// the composer stay exactly where they were.
enum ChatComposerCard: Hashable {
    case model
    case effort
    case trust
}

/// Each word publishes its own bounds so the card can be anchored to it and
/// clamped to the room at narrow widths.
struct ChatComposerWordAnchorKey: PreferenceKey {
    static let defaultValue: [ChatComposerCard: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [ChatComposerCard: Anchor<CGRect>],
        nextValue: () -> [ChatComposerCard: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, next in next }
    }
}

/// Reports its own rect in window coordinates. The card is an overlay, so the
/// only cheap way to know where it really is on screen is to ask AppKit from
/// inside it — and that keeps the comparison below in one coordinate system.
private struct ComposerCardRectReporter: NSViewRepresentable {
    @Binding var rect: CGRect

    func makeNSView(context: Context) -> ReporterView { ReporterView(report: { rect = $0 }) }
    func updateNSView(_ view: ReporterView, context: Context) {
        view.report = { rect = $0 }
        view.publish()
    }

    final class ReporterView: NSView {
        var report: (CGRect) -> Void

        init(report: @escaping (CGRect) -> Void) {
            self.report = report
            super.init(frame: .zero)
            postsFrameChangedNotifications = true
        }

        @available(*, unavailable) required init?(coder: NSCoder) { nil }

        // Never a click target: an AppKit view under SwiftUI content hit-tests
        // itself by default and swallowed every click on the card (2026-09-15).
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            publish()
        }

        override func layout() {
            super.layout()
            publish()
        }

        func publish() {
            guard window != nil else { return }
            let windowRect = convert(bounds, to: nil)
            DispatchQueue.main.async { [report] in report(windowRect) }
        }
    }
}

/// Closes an open card on a click that lands neither on the card nor on the
/// words that opened it.
///
/// Sol, 2026-09-15: the composer's own tap gesture only covers the composer
/// box, so a click in the transcript left a card open over it. The monitor
/// returns every event untouched — it dismisses, it never eats the click, so
/// whatever was clicked still happens on the same press.
private struct ComposerCardOutsideClick: NSViewRepresentable {
    var active: Bool
    var cardRect: CGRect
    var flyoutRect: CGRect
    var providerColumnRect: CGRect
    var onOutside: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) {
        view.active = active
        view.cardRect = cardRect
        view.flyoutRect = flyoutRect
        view.providerColumnRect = providerColumnRect
        view.onOutside = onOutside
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        var active = false
        var cardRect: CGRect = .zero
        var flyoutRect: CGRect = .zero
        var providerColumnRect: CGRect = .zero
        var onOutside: (() -> Void)?
        private var monitor: Any?

        // Same: this view sits under the whole words row and must never be
        // what a click lands on — the monitor is the only thing it does.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]
            ) { [weak self] event in
                guard let self, active, event.window === window else { return event }
                let point = event.locationInWindow

                // User, 2026-09-15: a scroll over the card scrolled the CHAT,
                // so a long provider list could not be reached. The two
                // scrollable regions keep their own wheel events; everything
                // else inside the card is swallowed, and while a card is open
                // nothing reaches the transcript at all (Agent (b)).
                if event.type == .scrollWheel {
                    if flyoutRect.contains(point) || providerColumnRect.contains(point) {
                        return event
                    }
                    return nil
                }

                // The words keep their own toggle: a click on the row is the
                // word's business, not a dismissal.
                let rowRect = convert(bounds, to: nil)
                if !cardRect.contains(point), !flyoutRect.contains(point), !rowRect.contains(point) {
                    onOutside?()
                }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}


/// Card and provider bounds, resolved together in the flyout's room.
struct ChatComposerProviderRowAnchorKey: PreferenceKey {
    enum Target: Hashable {
        case card
        case provider(String)
    }

    static let defaultValue: [Target: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [Target: Anchor<CGRect>],
        nextValue: () -> [Target: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, next in next }
    }
}

/// Which composer card is open, and the Trust write a card can start.
///
/// 2026-09-15: the card used to be an overlay on the words row, which lives
/// inside the composer's bottom `safeAreaInset`. The card is offset upward out
/// of that inset into the transcript's region, and SwiftUI hit-tests a child
/// against its parent's frame — so the scroll view won every press and the
/// card was painted but dead. The card VIEW now draws in the chat column's own
/// overlay, above the scroll view and both insets; this object is what the
/// words in the composer and that layer share.
@MainActor
@Observable
final class ChatComposerCardState {
    var open: ChatComposerCard?
    var savingTrust = false
    var confirmingFullMac = false
    var trustError: String?
    /// The open card's measured height, so the Latest pill can clear it.
    var cardHeight: CGFloat = 0
    /// The card's rect in window coordinates, for the outside-click monitor.
    var cardWindowRect: CGRect = .zero
    /// Which provider's models are showing beside the card, and which row of
    /// that flyout the keyboard is on.
    var flyoutProvider: String?
    var flyoutIndex: Int?
    /// Window rects of the two scrollable regions. A scroll over either one
    /// belongs to it; User, 2026-09-15: nothing reaches the transcript while a
    /// card is open.
    var flyoutWindowRect: CGRect = .zero
    var providerColumnWindowRect: CGRect = .zero
    /// Which side the flyout actually opened on, so the row's chevron can
    /// point at it (User, 2026-09-15).
    var flyoutOnLeft = false
    /// The flyout list's own height. A ScrollView has no intrinsic height — it
    /// takes whatever it is offered — so without this the flyout was always
    /// the full clamp, with empty glass under five models.
    var flyoutContentHeight: CGFloat = 0

    func applyTrust(_ preset: TrustPolicyPreset, appModel: AppModel, confirmed: Bool = false) {
        guard !savingTrust else { return }
        if preset == .fullMac, !confirmed {
            confirmingFullMac = true
            return
        }
        open = nil
        savingTrust = true
        Task { @MainActor in
            let outcome = await TrustPolicyPresetAction.apply(
                preset, appModel: appModel, fullMacConfirmed: confirmed
            )
            savingTrust = false
            appModel.statusText = TrustPolicyPresetActionPresentation.statusText(for: outcome)
            switch outcome {
            case .confirmationRequired: confirmingFullMac = true
            case .failed(let reason): trustError = reason
            case .applied: break
            }
        }
    }
}

let chatComposerFallbackEfforts = ["low", "medium", "high", "xhigh"]

/// Everything both halves of the composer's settings derive from the routing
/// snapshot. The words render it and the card edits it, so it lives in one
/// place instead of being computed twice.
@MainActor
protocol ChatComposerRoutingReading {
    var appModel: AppModel { get }
    var botContract: BotChatContract? { get }
    var cardState: ChatComposerCardState? { get }
}

extension ChatComposerRoutingReading {

    // MARK: - Data (provider-blind: the catalog is data, nothing branches on a name)

    var isBotConversation: Bool {
        appModel.activeChatSessionId.hasPrefix("bot-")
    }

    /// Every provider a person can pick from today, each carrying its own
    /// models. Providers are section headers in the card, never a control.
    var providerGroups: [ChatComposerModelGroup] {
        appModel.providersList
            .filter {
                $0.provider_id == "codex"
                    || $0.auth_status.state == "ready"
                    || $0.provider_id == appModel.chatProvider
            }
            .sorted { lhs, rhs in
                // The provider in use leads; the rest are alphabetical.
                if (lhs.provider_id == appModel.chatProvider) != (rhs.provider_id == appModel.chatProvider) {
                    return lhs.provider_id == appModel.chatProvider
                }
                return lhs.display_name < rhs.display_name
            }
            .compactMap { provider in
                let models = provider.models.map { item in
                    let catalogModel = appModel.modelCatalog?.models.first { $0.id == item.id }
                    // Provider-scoped capabilities stay authoritative: the
                    // global catalog holds duplicate ids for transports with
                    // different contracts.
                    return ModelCatalogItem(
                        id: item.id,
                        displayName: item.name,
                        description: catalogModel?.description,
                        defaultReasoningEffort: item.default_reasoning_effort
                            ?? catalogModel?.defaultReasoningEffort ?? "high",
                        supportedReasoningEfforts: item.supported_reasoning_efforts
                            ?? catalogModel?.supportedReasoningEfforts
                            ?? chatComposerFallbackEfforts,
                        supportsFast: item.supports_fast ?? catalogModel?.supportsFast,
                        priority: catalogModel?.priority ?? 0
                    )
                }
                guard !models.isEmpty else { return nil }
                return ChatComposerModelGroup(
                    id: provider.provider_id,
                    provider: provider.display_name,
                    models: models
                )
            }
    }


    /// Which row of a provider's flyout is the live one.
    func flyoutSelectedIndex(for group: ChatComposerModelGroup) -> Int {
        guard group.id == appModel.chatProvider,
              let index = group.models.firstIndex(where: { $0.id == appModel.chatModel })
        else { return 0 }
        return index
    }

    /// What the number keys pick: the first nine rows of the OPEN flyout.
    /// With the card a provider menu, digits address models, never providers.
    var numberedModels: [(provider: String, model: ModelCatalogItem)] {
        guard let providerID = cardState?.flyoutProvider,
              let group = providerGroups.first(where: { $0.id == providerID })
        else { return [] }
        return group.models.prefix(9).map { (providerID, $0) }
    }

    var selectedModel: ModelCatalogItem? {
        providerGroups
            .first { $0.id == appModel.chatProvider }?
            .models.first { $0.id == appModel.chatModel }
    }

    var efforts: [ReasoningEffortOption] {
        let supported = selectedModel?.supportedReasoningEfforts ?? chatComposerFallbackEfforts
        let catalogOptions = Dictionary(
            uniqueKeysWithValues: (appModel.modelCatalog?.reasoningEfforts ?? []).map { ($0.id, $0) }
        )
        return supported.map { effort in
            catalogOptions[effort] ?? ReasoningEffortOption(
                id: effort,
                label: effort == "xhigh" ? "XHigh" : effort.capitalized,
                description: nil
            )
        }
    }

    var effortIndex: Int {
        efforts.firstIndex { $0.id == appModel.chatReasoningEffort } ?? 0
    }

    var selectedModelSupportsFast: Bool {
        selectedModel?.supportsFast == true
    }

    // MARK: - Words

    var modelWord: String {
        if isBotConversation { return botContract?.model ?? "Bot model" }
        // Never "Saving…": the word flipping on every slider step felt
        // clunky (User, 2026-09-15). The save still gates Send quietly.
        guard !appModel.chatModel.isEmpty else { return "Choose model" }
        return selectedModel?.displayName ?? appModel.chatModel
    }

    func effortLabel(_ effort: String) -> String {
        efforts.first { $0.id == effort }?.label
            ?? (effort.isEmpty ? "Thinking" : (effort == "xhigh" ? "XHigh" : effort.capitalized))
    }

    var effortWord: String {
        if isBotConversation {
            guard let effort = botContract?.reasoningEffort else { return "Bot thinking" }
            return effortLabel(effort)
        }
        return effortLabel(appModel.chatReasoningEffort)
    }

    /// The resting chip says Fast is really on for what will send: the bot's
    /// own choice in a bot conversation, and otherwise Chat's override AND the
    /// selected model's capability — `chatFastMode` alone survives a switch to
    /// a model that has no Fast (Sol, 2026-09-15).
    var fastIsOn: Bool {
        if isBotConversation { return botContract?.choice?.fast == true }
        return appModel.chatFastMode && selectedModelSupportsFast
    }

    var trustWord: String {
        guard let policy = appModel.trustPolicy else { return "Trust unavailable" }
        let access = AppModel.agentAccessMode(from: policy, fallback: appModel.chatFileAccess)
        return TrustCenterPolicyStatusPresentation.preset(policy: policy, accessMode: access)?.title
            ?? "Custom Trust"
    }

    var activeTrustPreset: TrustPolicyPreset? {
        guard let policy = appModel.trustPolicy else { return nil }
        let access = AppModel.agentAccessMode(from: policy, fallback: appModel.chatFileAccess)
        return TrustCenterPolicyStatusPresentation.preset(policy: policy, accessMode: access)
    }

    // MARK: - Applying

    /// Provider, model, effort and tier land in ONE write.
    ///
    /// Sol, 2026-09-15: picking a model used to be two optimistic saves — set
    /// the provider, then save the brain — so a failed provider write was
    /// ignored and the model was saved against the rolled-back provider, and a
    /// Send between the two could read a mixed routing snapshot. This is the
    /// same single call the Providers page uses (`saveSurfaceConfiguration`
    /// under one flock), it mutates nothing until the write returns, and the
    /// row then takes the CANONICAL tuple rather than the requested one.
    ///
    /// Effort and Fast on their own keep `saveChatBrainDefaults`: they cannot
    /// change the provider, and its drain coalesces a dragged slider.
    func select(model: ModelCatalogItem, provider: String) {
        guard !appModel.isSavingChatBrain else { return }
        let supported = model.supportedReasoningEfforts ?? chatComposerFallbackEfforts
        let effort = supported.contains(appModel.chatReasoningEffort)
            ? appModel.chatReasoningEffort
            : (model.defaultReasoningEffort ?? supported.first ?? "high")
        let fast = model.supportsFast == true && appModel.chatFastMode

        appModel.isSavingChatBrain = true
        Task { @MainActor in
            defer { appModel.isSavingChatBrain = false }
            do {
                let response = try await appModel.configureSurfaceSelection(
                    surface: "chat",
                    providerID: provider,
                    model: model.id,
                    reasoningEffort: effort,
                    serviceTier: fast ? "priority" : "default"
                )
                // What actually landed on disk, not what was asked for.
                let canonical = response.current.chat
                appModel.chatModel = canonical.model
                appModel.chatReasoningEffort = canonical.reasoningEffort
                appModel.chatFastMode = canonical.serviceTier == "priority"
            } catch {
                appModel.statusText = "Model could not be changed: \(error.localizedDescription)"
            }
        }
    }

    func setEffort(index: Int) {
        // A provider/model transaction owns the tuple until its receipt lands.
        // The effort drain may still coalesce its own subsequent slider edits.
        guard !appModel.isSavingChatBrain || appModel.chatBrainSaveTask != nil else { return }
        guard efforts.indices.contains(index) else { return }
        let effort = efforts[index].id
        guard effort != appModel.chatReasoningEffort else { return }
        appModel.chatReasoningEffort = effort
        Task { @MainActor in await appModel.saveChatBrainDefaults() }
    }

}


/// The three words on the composer row. Observes routing and policy here,
/// never in the draft or transcript owner.
struct ChatComposerSettings: View, ChatComposerRoutingReading {
    @Environment(AppModel.self) var appModel
    @Environment(\.chatPageIsVisible) private var chatPageIsVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ChatComposerCardState.self) var cardState: ChatComposerCardState?

    /// Bumped by the draft when Tab should move into the words.
    var focusWordToken: Int

    /// Sol, 2026-09-15: a bot conversation sends on its OWN model, effort and
    /// Fast, so the words must read the bot's contract — showing (and editing)
    /// the global Chat tuple there was three lies on one row.
    @State var botContract: BotChatContract?
    @FocusState private var focusedWord: ChatComposerCard?

    init(focusWordToken: Int = 0) {
        self.focusWordToken = focusWordToken
    }

    /// The local Tab ring. The window-wide order skips plain buttons, so the
    /// three words walk themselves and hand Tab back at either end.
    private static let ring: [ChatComposerCard] = [.model, .effort, .trust]

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            // How full the context is, at a glance (User, 2026-09-16).
            ComposerContextRing(sessionId: appModel.activeChatSessionId)
                .padding(.trailing, 14)

            word(
                .model,
                text: modelWord,
                help: isBotConversation
                    ? "This conversation uses its bot's own model. Edit it in Bots."
                    : "\(appModel.chatProvider) · \(appModel.chatModel). Choose the model for Chat.",
                accessibility: isBotConversation ? "Bot model. Edit in Bots" : "Model: \(modelWord)",
                identifier: "chat.composer.model"
            )
            .frame(maxWidth: 220, alignment: .trailing)

            // Punctuation between two hit targets, not a control.
            Text("·")
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .padding(.horizontal, 6)
                .accessibilityHidden(true)

            word(
                .effort,
                text: effortWord,
                help: isBotConversation
                    ? "This conversation uses its bot's own thinking level. Edit it in Bots."
                    : "How much thinking \(appModel.agentDisplayName) spends on a turn.",
                accessibility: isBotConversation
                    ? "Bot thinking: \(effortWord). Edit in Bots"
                    : "Thinking: \(effortWord)",
                identifier: "chat.composer.effort"
            )

            // Fast is the one state worth a chip: turned on for a while and
            // forgotten. Off, it is not on screen. It opens the card that
            // holds its switch.
            if fastIsOn {
                Button { toggle(.model) } label: {
                    Text("Fast")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.text)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(NativeAgentShell.softFill, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.leading, 12)
                .help("Fast is on. Turn it off in the model card.")
                .accessibilityIdentifier("chat.composer.fast")
                .accessibilityLabel("Fast is on")
            }

            word(
                .trust,
                text: trustWord,
                help: "Saved Trust posture, across all app surfaces.",
                accessibility: "Trust: \(trustWord)",
                identifier: "chat.composer.trust"
            )
            .padding(.leading, 14)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .font(ShellType.label)
        .foregroundStyle(NativeAgentShell.secondary)

        .background {
            if let state = cardState {
                ComposerCardOutsideClick(
                    active: chatPageIsVisible && state.open != nil,
                    cardRect: state.cardWindowRect,
                    flyoutRect: state.open == .model ? state.flyoutWindowRect : .zero,
                    providerColumnRect: state.open == .model ? state.providerColumnWindowRect : .zero
                ) {
                    state.open = nil
                }
            }
        }
        .task { await appModel.loadProvidersForChat() }
        .task(id: appModel.activeChatSessionId) {
            botContract = nil
            let contract = await BotChatContract.checked(appModel.activeChatSessionId)
            guard !Task.isCancelled else { return }
            botContract = contract
        }
        .onChange(of: focusWordToken) { _, _ in focusedWord = .model }
    }

    /// A setting rendered as the word that names it. Quiet at rest is less
    /// decoration, never dimmer text (Agent's note 8): both states are at or
    /// above `secondary`.
    /// Width of the widest thinking label this model offers, measured with
    /// the word's own font. Cheap: a handful of short strings per render.
    private var widestEffortWordWidth: CGFloat? {
        let labels = efforts.map(\.label)
        guard !labels.isEmpty else { return nil }
        let font = NSFont.systemFont(ofSize: ShellType.labelSize, weight: .medium)
        return labels
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max()
            .map { ceil($0) }
    }

    private func word(
        _ card: ChatComposerCard,
        text: String,
        help: String,
        accessibility: String,
        identifier: String
    ) -> some View {
        Button { toggle(card) } label: {
            Text(text)
                .font(ShellType.labelMedium)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(cardState?.open == card ? NativeAgentShell.text : NativeAgentShell.secondary)
                // The thinking word holds the width of its widest level, so
                // "Low" → "Medium" moves nothing else on the row and the open
                // card stays where it is (User, 2026-09-15).
                .frame(minWidth: card == .effort ? widestEffortWordWidth : nil)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background {
                    if cardState?.open == card {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(NativeAgentShell.softFill)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A plain Button is not in the key view loop on its own, so Tab walked
        // straight past the three words to the rail. Focusable puts them back
        // in the ring and lets the shell's order focus them programmatically.
        .focusable()
        .focused($focusedWord, equals: card)
        .help(help)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(accessibility)
        .accessibilityHint(cardState?.open == card ? "Closes the \(cardName(card)) card" : "Opens the \(cardName(card)) card")
        .anchorPreference(key: ChatComposerWordAnchorKey.self, value: .bounds) { [card: $0] }
        .onKeyPress(.space) { toggle(card); return .handled }
        .onKeyPress(.return) {
            if takeHighlightedModel(card) { return .handled }
            toggle(card)
            return .handled
        }
        .onKeyPress(.escape) {
            guard cardState?.open != nil else { return .ignored }
            cardState?.open = nil
            return .handled
        }
        .onKeyPress(.leftArrow) { arrow(card, forward: false) }
        .onKeyPress(.rightArrow) { arrow(card, forward: true) }
        .onKeyPress(.downArrow) { arrow(card, forward: true, vertical: true) }
        .onKeyPress(.upArrow) { arrow(card, forward: false, vertical: true) }
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            number(card, press.characters)
        }
        .onKeyPress(keys: [.tab]) { press in
            let ring = ChatComposerSettings.ring
            guard let index = ring.firstIndex(of: card) else { return .ignored }
            let next = index + (press.modifiers.contains(.shift) ? -1 : 1)
            guard ring.indices.contains(next) else { return .ignored }
            cardState?.open = nil
            focusedWord = ring[next]
            return .handled
        }
    }

    /// Return inside an open model card takes the highlighted flyout row.
    private func takeHighlightedModel(_ card: ChatComposerCard) -> Bool {
        guard card == .model, let state = cardState, state.open == .model,
              let providerID = state.flyoutProvider else { return false }
        guard let group = providerGroups.first(where: { $0.id == providerID }) else { return false }
        let index = state.flyoutIndex ?? flyoutSelectedIndex(for: group)
        guard group.models.indices.contains(index) else { return false }
        select(model: group.models[index], provider: providerID)
        state.open = nil
        return true
    }

    private func cardName(_ card: ChatComposerCard) -> String {
        switch card {
        case .model: "model"
        case .effort: "thinking"
        case .trust: "Trust"
        }
    }

    private func toggle(_ card: ChatComposerCard) {
        // A bot's model and thinking level belong to the bot, so the words show
        // them and hand the edit to Bots. Trust stays app-wide and opens here.
        if card != .trust, isBotConversation {
            NotificationCenter.default.post(name: .openCommandRouteRequest, object: "bots")
            return
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
            cardState?.open = (cardState?.open == card) ? nil : card
        }
        if let state = cardState, state.open == .model {
            // Agent (a): the live options are what a person came for.
            state.flyoutProvider = appModel.chatProvider
            state.flyoutIndex = nil
        } else {
            cardState?.flyoutProvider = nil
            cardState?.flyoutIndex = nil
        }
        if cardState?.open != nil { focusedWord = card }
    }

    // MARK: - Keyboard inside an open card

    private func arrow(_ card: ChatComposerCard, forward: Bool, vertical: Bool = false) -> KeyPress.Result {
        guard let state = cardState, state.open == card else { return .ignored }
        if card == .effort {
            guard !efforts.isEmpty else { return .ignored }
            let next = min(max(effortIndex + (forward ? 1 : -1), 0), efforts.count - 1)
            setEffort(index: next)
            return .handled
        }
        guard card == .model else { return .ignored }
        if vertical {
            // Agent (a): the arrows land in the live options, so up/down walk
            // the open flyout rather than the column of provider names.
            guard let providerID = state.flyoutProvider,
                  let group = providerGroups.first(where: { $0.id == providerID }),
                  !group.models.isEmpty else { return .ignored }
            let current = state.flyoutIndex ?? flyoutSelectedIndex(for: group)
            state.flyoutIndex = min(max(current + (forward ? 1 : -1), 0), group.models.count - 1)
            return .handled
        }
        if forward {
            if state.flyoutProvider == nil { state.flyoutProvider = appModel.chatProvider }
            return .handled
        }
        state.flyoutProvider = nil
        state.flyoutIndex = nil
        return .handled
    }

    private func number(_ card: ChatComposerCard, _ characters: String) -> KeyPress.Result {
        guard cardState?.open == card, let digit = Int(characters), digit >= 1 else { return .ignored }
        switch card {
        case .model:
            let rows = numberedModels
            guard digit <= rows.count else { return .ignored }
            select(model: rows[digit - 1].model, provider: rows[digit - 1].provider)
        case .effort:
            guard digit <= efforts.count else { return .ignored }
            setEffort(index: digit - 1)
            return .handled
        case .trust:
            let presets = TrustPolicyPreset.allCases
            guard digit <= presets.count else { return .ignored }
            cardState?.applyTrust(presets[digit - 1], appModel: appModel)
        }
        cardState?.open = nil
        return .handled
    }

}


/// The open card, drawn in the chat column's own overlay — above the scroll
/// view and above both safe-area insets, so its rows are actually pressable.
/// It takes no space and is positioned from the word's anchor, so the
/// transcript and the composer still do not move when a card opens.
struct ChatComposerCardLayer: View, ChatComposerRoutingReading {
    @Environment(AppModel.self) var appModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Present in the chat column, absent in the detached panel and snapshots.
    @Environment(ChatTurnCardClearance.self) private var turnCardClearance: ChatTurnCardClearance?

    let state: ChatComposerCardState
    let anchors: [ChatComposerCard: Anchor<CGRect>]

    var cardState: ChatComposerCardState? { state }
    @State var botContract: BotChatContract?

    /// The gap between the composer and the card floating above it.
    private let cardGap: CGFloat = 10

    var body: some View {
        cardOverlay(anchors)
            .onChange(of: state.open) { _, card in
                guard card == .model, state.flyoutProvider == nil else { return }
                #if DEBUG
                // Capture affordance only, same gate as COMPOSER_CARD_OPEN:
                // a long flyout cannot be hovered or scrolled without a hand.
                let environment = ProcessInfo.processInfo.environment
                if let provider = environment["COMPOSER_FLYOUT_PROVIDER"] {
                    state.flyoutProvider = provider
                    state.flyoutIndex = Int(environment["COMPOSER_FLYOUT_INDEX"] ?? "0") ?? 0
                    return
                }
                #endif
                state.flyoutProvider = appModel.chatProvider
                state.flyoutIndex = nil
            }
            .alert("Enable Full Mac access?", isPresented: Binding(
                get: { state.confirmingFullMac }, set: { state.confirmingFullMac = $0 }
            )) {
                Button("Enable Full Mac", role: .destructive) {
                    state.applyTrust(.fullMac, appModel: appModel, confirmed: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The agent can read and modify files anywhere, run shell commands, control the system, and move or trash files across app surfaces. Autonomy is enabled; pre-write backups stay on. macOS privacy permissions still apply. This stays active until you change Trust.")
            }
            .alert("Trust could not be changed", isPresented: Binding(
                get: { state.trustError != nil }, set: { if !$0 { state.trustError = nil } }
            )) {
                Button("OK") { state.trustError = nil }
            } message: {
                Text(state.trustError ?? "")
            }
            // 2026-09-16: the "Context ›" link and its sheet are gone. The
            // context receipt has had no producer since the Python daemon
            // (Context.swift: PORTED-DORMANT-PARTIAL); the reader scanned a
            // file nothing writes, so the sheet only ever said "incomplete".
            // A real receipt card, fed by the turn traces, is the next round.
            .task(id: appModel.activeChatSessionId) {
                botContract = nil
                let contract = await BotChatContract.checked(appModel.activeChatSessionId)
                guard !Task.isCancelled else { return }
                botContract = contract
            }
            // Lift the Latest pill over an open card, and only the pill.
            .onChange(of: state.open) { _, card in
                turnCardClearance?.openComposerCardHeight =
                    card == nil ? 0 : state.cardHeight + cardGap
            }
            .onChange(of: state.cardHeight) { _, height in
                guard state.open != nil else { return }
                turnCardClearance?.openComposerCardHeight = height + cardGap
            }
            .onDisappear { turnCardClearance?.openComposerCardHeight = 0 }
            .onChange(of: state.open) { _, card in
                guard card == nil else { return }
                state.flyoutProvider = nil
                state.flyoutIndex = nil
                state.flyoutWindowRect = .zero
                state.providerColumnWindowRect = .zero
                state.flyoutContentHeight = 0
            }
    }

    // MARK: - The card, anchored to its word and clamped to the room

    @ViewBuilder
    /// Where the card sits in the layer. Both the card and its flyout are
    /// placed from this, as siblings, so the flyout can be clamped against the
    /// room instead of against the card it hangs off.
    private func cardPlacement(
        _ card: ChatComposerCard,
        _ anchors: [ChatComposerCard: Anchor<CGRect>],
        _ proxy: GeometryProxy
    ) -> (x: CGFloat, y: CGFloat, outer: CGFloat)? {
        guard let anchor = anchors[card] else { return nil }
        let rect = proxy[anchor]
        // Sol, 2026-09-15: the clamp has to be the OUTER width. The padding is
        // applied outside the frame, so clamping the inner width let a card
        // hang 2 x padding past the room's edge at the narrow end.
        let outer = min(cardWidth(card), proxy.size.width)
        // Anchored to the word's RIGHT edge: the words are right-aligned, so
        // a word's trailing edge holds still while its text changes width
        // ("Low" → "Medium"). Anchoring to the left edge made the open card
        // hop sideways on every slider step (User, 2026-09-15).
        // Centred over the word (User, 2026-09-15), clamped to the room; the
        // centre holds still because the words are right-aligned and the
        // word's trailing edge does not move while its text changes.
        let x = min(max(0, rect.midX - outer / 2), max(0, proxy.size.width - outer))
        // The word's rect is in THIS layer's space, so the card is placed
        // absolutely above it rather than offset out of a row.
        let y = max(0, rect.minY - cardGap - state.cardHeight)
        return (x, y, outer)
    }

    func cardOverlay(_ anchors: [ChatComposerCard: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
            if let card = state.open, let placement = cardPlacement(card, anchors, proxy) {
                let pad = NativeAgentSpacing.md
                let outer = placement.outer
                let inner = max(0, outer - pad * 2)
                let x = placement.x
                let y = placement.y
                cardBody(card)
                    .frame(width: inner, alignment: .leading)
                    .padding(pad)
                    // The card is its own glass at radius 14, floating above
                    // the composer with a gap — two neighbouring surfaces,
                    // never glass drawn on glass.
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(reduceTransparency
                                  ? Color(nsColor: .controlBackgroundColor)
                                  : NativeAgentShell.room.opacity(0.82))
                    }
                    .overlay {
                        if reduceTransparency {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(NativeAgentShell.hairline, lineWidth: 1)
                        }
                    }
                    .glassEffect(
                        reduceTransparency ? .identity : .regular,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        state.cardHeight = $0
                    }
                    .background {
                        ComposerCardRectReporter(rect: Binding(
                            get: { state.cardWindowRect },
                            set: { state.cardWindowRect = $0 }
                        ))
                    }
                    .offset(x: x, y: y)
                    .transformAnchorPreference(key: ChatComposerProviderRowAnchorKey.self, value: .bounds) {
                        $0[.card] = $1
                    }
                    .transition(.opacity)
                    // Escape used to live only on the word, so once the slider
                    // or the Fast switch took focus nothing closed the card.
                    // The container catches it for the whole card (Sol, 2026-09-15).
                    .onExitCommand { cardState?.open = nil }
            }
            }
            // Offsets below are room-local. A card-sized, centered overlay adds
            // its own origin to those offsets and sends the flyout toward the edge.
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            // The flyout is a SIBLING of the card, not its overlay: only this
            // level knows the room's height, and a submenu that cannot see the
            // bottom edge runs off it.
            .overlayPreferenceValue(ChatComposerProviderRowAnchorKey.self, alignment: .topLeading) { rows in
                // The card's anchors are captured inside a view that has
                // already been `.offset` into place, and they resolve WITHOUT
                // that offset — so on a wide window the flyout believed the
                // card sat at the room's origin (User's glass, 2026-09-15).
                // The card's real rect is the placement we computed; the row
                // is moved by the same delta, which is right whichever way the
                // anchors resolve.
                if state.open == .model,
                   let cardAnchor = rows[.card],
                   let placement = cardPlacement(.model, anchors, proxy) {
                    let resolved = proxy[cardAnchor]
                    let cardRect = CGRect(
                        x: placement.x, y: placement.y,
                        width: resolved.width, height: resolved.height
                    )
                    // The ROW anchors are captured inside the offset view and
                    // do carry the offset; only the card's own bounds anchor
                    // (taken on the outer view) does not. So the rows are used
                    // as resolved and only the card is rebuilt.
                    flyout(rows, layer: proxy, card: cardRect)
                }
            }
        }
    }

    private func cardWidth(_ card: ChatComposerCard) -> CGFloat {
        switch card {
        case .model: 300 + NativeAgentSpacing.md * 2
        case .effort: 262 + NativeAgentSpacing.md * 2
        case .trust: 404 + NativeAgentSpacing.md * 2
        }
    }

    @ViewBuilder
    private func cardBody(_ card: ChatComposerCard) -> some View {
        switch card {
        case .model: modelCard
        case .effort: effortCard
        case .trust: trustCard
        }
    }

    // MARK: - Model card

    /// User, 2026-09-15: the card is a menu. It lists the connected PROVIDERS,
    /// one row each, and a provider's models open beside it as a flyout —
    /// OpenRouter alone is hundreds of models, which no flat card can hold.
    ///
    /// Agent (a): the current provider's flyout is already open when the card
    /// opens, so the arrows land on the live options rather than on a column
    /// of names.
    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 2) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(providerGroups) { group in
                        providerRow(group)
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 220)
            .background {
                ComposerCardRectReporter(rect: Binding(
                    get: { state.providerColumnWindowRect },
                    set: { state.providerColumnWindowRect = $0 }
                ))
            }

            if selectedModelSupportsFast {
                // Agent's note 3: Fast needs an obvious way back on. A real
                // switch, not a badge — and only for models that support it.
                Toggle(isOn: Binding(
                    get: { appModel.chatFastMode },
                    set: { newValue in
                        guard !appModel.isSavingChatBrain || appModel.chatBrainSaveTask != nil else { return }
                        appModel.chatFastMode = newValue
                        Task { @MainActor in await appModel.saveChatBrainDefaults() }
                    }
                )) {
                    Text("Fast")
                        .font(ShellType.labelMedium)
                        .foregroundStyle(NativeAgentShell.text)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(NativeAgentShell.calm)
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .accessibilityIdentifier("chat.composer.model.fast")
            }

            Rectangle()
                .fill(NativeAgentShell.hairline)
                .frame(height: 1)
                .padding(.vertical, 8)

            cardFooterLink("More models") {
                state.open = nil
                NotificationCenter.default.post(name: .openCommandRouteRequest, object: "providers")
            }
            .accessibilityIdentifier("chat.composer.model.more")

            scopeLine("Saved default for Chat")
        }
    }

    /// One connected provider. Agent (c): the row that is in use is
    /// checkmarked AND says which model it is on, so the column answers
    /// "what am I talking to" without opening anything.
    private func providerRow(_ group: ChatComposerModelGroup) -> some View {
        let isCurrent = group.id == appModel.chatProvider
        let isOpen = state.flyoutProvider == group.id
        return HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isCurrent ? NativeAgentShell.text : .clear)
                .frame(width: 11)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.provider)
                    .font(ShellType.labelMedium)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isCurrent, let model = selectedModel {
                    Text(model.displayName)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: state.flyoutOnLeft ? "chevron.left" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NativeAgentShell.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            if isOpen {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(NativeAgentShell.quietFill)
            }
        }
        .contentShape(Rectangle())
        // Agent (d): hovering another provider swaps the flyout, and nothing
        // ever clears it on exit — that is the grace path across the gap.
        .onHover { inside in
            guard inside, state.flyoutProvider != group.id else { return }
            state.flyoutProvider = group.id
            state.flyoutIndex = nil
            // A short list must not inherit the previous one's height.
            state.flyoutContentHeight = 0
        }
        .onTapGesture {
            state.flyoutProvider = group.id
            state.flyoutIndex = nil
        }
        .anchorPreference(key: ChatComposerProviderRowAnchorKey.self, value: .bounds) {
            [.provider(group.id): $0]
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isCurrent
            ? "\(group.provider), in use, \(selectedModel?.displayName ?? "")"
            : group.provider)
    }

    private var flyoutWidth: CGFloat { 264 }

    /// The models of the hovered provider, beside the card and anchored to the
    /// row. It scrolls inside itself — OpenRouter is hundreds of rows — and it
    /// is drawn in the same hoisted layer as the card, so it is pressable.
    @ViewBuilder
    private func flyout(
        _ anchors: [ChatComposerProviderRowAnchorKey.Target: Anchor<CGRect>],
        layer: GeometryProxy,
        card: CGRect
    ) -> some View {
        if let providerID = state.flyoutProvider,
           let group = providerGroups.first(where: { $0.id == providerID }),
           let anchor = anchors[.provider(providerID)] {
            let row = layer[anchor]
            // User, 2026-09-15: it started at the hovered row and ran off the
            // bottom of the window. A macOS submenu never does: its height is
            // capped by the room, and when it would overflow it shifts UP so
            // its bottom sits on the room's edge and scrolls inside for the
            // rest. The card's own bottom is that edge here — it sits just
            // above the composer, which is where the eye already is.
            let margin = NativeAgentSpacing.sm
            let available = max(0, card.maxY - margin)
            let cap = min(flyoutMaxHeight, available)
            // Only as tall as the list. `maxHeight` alone does nothing for a
            // ScrollView, which is greedy — the height has to be the measured
            // content, clamped (User, 2026-09-15).
            let height = min(max(state.flyoutContentHeight, 44), cap)
            let top = min(max(margin, row.minY), max(margin, card.maxY - height))

            // Card and provider row anchors resolve in the same room-local proxy.
            let gap: CGFloat = 3
            let roomMargin: CGFloat = 12
            let preferred = card.maxX + gap
            // The furthest right the flyout may start and still keep a margin
            // inside the room.
            let rightmost = layer.size.width - roomMargin - flyoutWidth
            // Before flipping, slide it left until it fits — overlapping the
            // card's own edge a little is fine, a clipped list is not.
            let leastRightSide = card.maxX - 24
            let fitsRight = rightmost >= leastRightSide
            let left = fitsRight
                ? max(leastRightSide, min(preferred, rightmost))
                : max(roomMargin, card.minX - flyoutWidth - gap)
                // The providers arrive after the card opens, so the highlight
                // follows the SELECTION until a key moves it — otherwise it
                // landed on row one while the checkmark sat further down.
                let highlight = state.flyoutIndex ?? flyoutSelectedIndex(for: group)
                ScrollViewReader { scroller in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(group.models.enumerated()), id: \.element.id) { index, model in
                                modelRow(model, provider: group.id, shortcut: index < 9 ? index + 1 : 0,
                                         highlighted: highlight == index)
                                    .id(index)
                            }
                        }
                        .padding(NativeAgentSpacing.sm)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            state.flyoutContentHeight = $0
                        }
                    }
                    .frame(width: flyoutWidth, height: height)
                    .onChange(of: highlight, initial: true) { _, index in
                        scroller.scrollTo(index, anchor: .center)
                    }
                }
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(reduceTransparency
                              ? Color(nsColor: .controlBackgroundColor)
                              : NativeAgentShell.room.opacity(0.86))
                }
                .overlay {
                    if reduceTransparency {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(NativeAgentShell.hairline, lineWidth: 1)
                    }
                }
                .glassEffect(
                    reduceTransparency ? .identity : .regular,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .background {
                    ComposerCardRectReporter(rect: Binding(
                        get: { state.flyoutWindowRect },
                        set: { state.flyoutWindowRect = $0 }
                    ))
                }
                .offset(x: left, y: top)
                // The chevron follows the flyout, never the other way round.
                .onChange(of: fitsRight, initial: true) { _, fits in
                    state.flyoutOnLeft = !fits
                }
            }
    }

    private var flyoutMaxHeight: CGFloat { 320 }

    private func modelRow(
        _ model: ModelCatalogItem,
        provider: String,
        shortcut: Int,
        highlighted: Bool
    ) -> some View {
        let isSelected = model.id == appModel.chatModel && provider == appModel.chatProvider
        return Button {
            select(model: model, provider: provider)
            state.open = nil
        } label: {
            HStack(spacing: 6) {
                // Agent's note 4 / (c): "selected" is a mark on the current
                // row, and the flyout marks the same model the provider row
                // names in its secondary line.
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? NativeAgentShell.text : .clear)
                    .frame(width: 11)
                Text(model.displayName)
                    .font(ShellType.labelMedium)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if shortcut > 0 {
                    Text("\(shortcut)")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .frame(width: 12, alignment: .trailing)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                if highlighted || isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(highlighted ? NativeAgentShell.softFill : NativeAgentShell.quietFill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelected ? "\(model.displayName), selected" : model.displayName)
    }

    // MARK: - Effort card

    private var effortCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                // Agent's note 2: the ends name the thing being traded, and
                // the thing being traded is thinking.
                Text("Less thinking")
                Spacer(minLength: 8)
                Text("More thinking")
            }
            .font(ShellType.label)
            .foregroundStyle(NativeAgentShell.secondary)

            if efforts.count > 1 {
                // The slider snaps to the levels this model actually supports:
                // a step of one over the supported list, never a free ramp.
                Slider(
                    value: Binding(
                        get: { Double(effortIndex) },
                        set: { setEffort(index: Int($0.rounded())) }
                    ),
                    in: 0...Double(efforts.count - 1),
                    step: 1
                )
                .controlSize(.small)
                .tint(NativeAgentShell.secondary)
                .labelsHidden()
                .accessibilityIdentifier("chat.composer.effort.slider")
                .accessibilityLabel("Thinking level")
                .accessibilityValue(effortWord)
            }

            Text(effortWord)
                .font(ShellType.bodyMedium)
                .foregroundStyle(NativeAgentShell.text)

            // Always drawn, so the card keeps one height while the slider
            // moves; a line that came and went made the card grow, shrink
            // and hop (User, 2026-09-15).
            if let model = selectedModel,
               let defaultLabel = efforts.first(where: { $0.id == model.defaultReasoningEffort })?.label {
                Text("Default for \(model.displayName): \(defaultLabel)")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            scopeLine("Saved default for Chat")
        }
    }

    // MARK: - Trust card

    private var trustCard: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(TrustPolicyPreset.allCases.enumerated()), id: \.element.quietID) { index, preset in
                let isSelected = activeTrustPreset == preset
                Button { state.applyTrust(preset, appModel: appModel) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isSelected ? NativeAgentShell.text : .clear)
                            .frame(width: 11)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title)
                                .font(ShellType.labelMedium)
                                .foregroundStyle(NativeAgentShell.text)
                            // Agent's note 7: the descriptions Trust itself
                            // ships, word for word — the composer does not
                            // invent a shorthand for what a posture permits.
                            Text(preset.summary)
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        Text("\(index + 1)")
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .frame(width: 12, alignment: .trailing)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(NativeAgentShell.quietFill)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(state.savingTrust || appModel.trustPolicy == nil)
                .accessibilityLabel(isSelected ? "\(preset.title), selected" : preset.title)
            }

            scopeLine("Saved default, every app surface")
        }
    }

    // MARK: - Shared card furniture

    private func cardFooterLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            .font(ShellType.labelMedium)
            .foregroundStyle(NativeAgentShell.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Agent's note 4: the scope of a change is said inside the card, never on
    /// the resting row.
    private func scopeLine(_ text: String) -> some View {
        Text(text)
            .font(ShellType.label)
            .foregroundStyle(NativeAgentShell.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .fixedSize(horizontal: false, vertical: true)
    }

}

/// One provider's models, as the card groups them. The provider is a header
/// built from the routing snapshot, never a branch in the code.
struct ChatComposerModelGroup: Identifiable {
    let id: String
    let provider: String
    let models: [ModelCatalogItem]
}
