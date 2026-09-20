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
    /// The context ring's receipt. Not a setting — a readout of the last
    /// turn — but it reaches for the same shell, above the element that
    /// names it, and publishes its anchor like the words do.
    case context
    case model
    case effort
    case trust
}

/// What the one shell is showing. The panes flow out of each other inside a
/// single surface — `.model` is the provider column, `.models` is a provider's
/// models (beside the column when there is room, in its place when there is
/// not).
enum ComposerPane: Hashable {
    case none
    case model
    case models(String)
    case think
    case trust
    case context

    /// The word (or ring) the shell centres over. `.model` and `.models` share
    /// one word, so moving between them never moves the shell sideways.
    var word: ChatComposerCard? {
        switch self {
        case .none: nil
        case .model, .models: .model
        case .think: .effort
        case .trust: .trust
        case .context: .context
        }
    }

    var isOpen: Bool { self != .none }

    static func opening(_ word: ChatComposerCard, provider: String) -> ComposerPane {
        switch word {
        case .model: .models(provider)
        case .effort: .think
        case .trust: .trust
        case .context: .context
        }
    }
}

/// The shell's fixed widths. The layer lays out from these and the state
/// answers a page read from them, so what `app_page_read` lists and what is
/// drawn cannot disagree about whether the models sit beside the providers
/// (Sol, 2026-09-17).
/// 2026-09-17: the columns were 324 + 1 + 264 = 589 and the margin 12 a side,
/// so the two-column shell "fitted" any room over 613. The chat room at the
/// 1040pt window minimum is 1040 − 112 (rail) − 288 (list) = 640, so it fitted
/// ALWAYS: the shell filled 92% of the room and read as a near-full-width
/// panel, and the replacement layout behind "Back to providers" could not be
/// reached at any window size. The columns are narrower and the margin is the
/// one a floating surface really needs: 284 + 1 + 240 = 525 inside 60 a side,
/// so both columns want a 645pt room. The window minimum's 640 is BELOW that
/// on purpose — the replacement layout is what the smallest window gets, so it
/// is on screen for anyone who opens the app at the minimum, and two columns
/// are what the first 5pt of extra width buys. A larger system text size
/// scales the columns and moves the crossing point up with them.
enum ComposerShellMetrics {
    static let providerColumn: CGFloat = 260 + NativeAgentSpacing.md * 2
    static let modelsColumn: CGFloat = 240
    static let think: CGFloat = 262 + NativeAgentSpacing.md * 2
    static let trust: CGFloat = 404 + NativeAgentSpacing.md * 2
    static let context: CGFloat = 320 + NativeAgentSpacing.md * 2
    static let roomMargin: CGFloat = 60
    static let modelsMaxHeight: CGFloat = 320
    /// +1 for the hairline that divides the two columns of the one shell.
    static var bothColumns: CGFloat { providerColumn + 1 + modelsColumn }

    /// `bothColumns` is passed in because the layer's columns are
    /// `@ScaledMetric`: at a larger system text size the shell is wider and
    /// hands over to the replacement layout sooner. The layer publishes the
    /// width it laid out with, so a page read and the shell agree.
    static func fitsBoth(room: CGFloat, bothColumns: CGFloat = bothColumns) -> Bool {
        room > 0 && bothColumns <= max(0, room - roomMargin * 2)
    }
}

/// One row of whatever pane is open, as the shell renders it. This is what the
/// in-process self-admin verbs read and drive, so they see the same list a
/// person does instead of re-deriving it.
struct ComposerShellRow: Identifiable, Hashable {
    let id: String
    let label: String
    let isSelected: Bool
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
                //
                // 2026-09-17: a scroll OUTSIDE the shell used to be swallowed
                // too, so an open pane froze the whole window's wheel and did
                // not dismiss on one — the click outside it did. A scroll
                // outside dismisses exactly like a click outside, and passes
                // through, so the transcript moves on the same wheel.
                if event.type == .scrollWheel {
                    if flyoutRect.contains(point) || providerColumnRect.contains(point) {
                        return event
                    }
                    if cardRect.contains(point) { return nil }
                    onOutside?()
                    return event
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
final class ComposerShellState {
    /// The one pane the shell is showing.
    var activePane: ComposerPane = .none
    var savingTrust = false
    var confirmingFullMac = false
    var trustError: String?
    /// The shell's measured height, so the Latest pill can clear it and the
    /// bottom-anchored surface can grow upward to it.
    var shellHeight: CGFloat = 0
    /// The shell's rect in window coordinates, for the outside-click monitor.
    var cardWindowRect: CGRect = .zero
    /// Which row of the models pane the keyboard is on.
    var flyoutIndex: Int?
    /// Window rects of the two scrollable regions inside the shell. A scroll
    /// over either one belongs to it; nothing reaches the transcript while the
    /// shell is open.
    var modelsWindowRect: CGRect = .zero
    var providerColumnWindowRect: CGRect = .zero
    /// The provider list's own height, measured the same way and for the same
    /// reason as the models list below.
    var providerContentHeight: CGFloat = 0
    /// The room the layer last laid the shell out in, so the state can answer
    /// a page read with the controls that are really on screen.
    var roomWidth: CGFloat = 0
    /// The two columns' laid-out width, published by the layer because the
    /// columns scale with the system text size.
    var bothColumnsWidth: CGFloat = ComposerShellMetrics.bothColumns
    /// Bumped when Tab should move focus from a word INTO the open pane. Tab
    /// used to dismiss the shell, which left every control inside it — Fast,
    /// More models, Back to providers, the Trust rows, the thinking slider —
    /// unreachable from the keyboard. Esc is still what dismisses.
    var focusShellToken = 0
    /// The measured height of whichever of Think / Trust / Context is open, so
    /// the shell can clamp them the way it clamps the models list.
    var paneContentHeight: CGFloat = 0
    /// The models list's own height. A ScrollView has no intrinsic height — it
    /// takes whatever it is offered — so without this the list was always the
    /// full clamp, with empty glass under five models.
    var modelsContentHeight: CGFloat = 0
    /// The routing the panes read. Set once by the chat column; it is what
    /// lets the verbs below answer without a view in hand.
    var appModel: AppModel?
    /// The last turn's receipt, exactly as the context pane's card loaded it,
    /// and the token line under it. The card publishes both here so a page
    /// read of an open context pane lists the rows the person is looking at
    /// without starting a second, asynchronous read of the trace ledger — the
    /// pane said "Context pane is open" and then listed nothing.
    var contextReceipt: ComposerContextReceiptState = .loading
    var contextWindowLine: String?

    /// Which provider's models are showing, derived from the pane so there is
    /// one source of truth.
    var flyoutProvider: String? {
        if case .models(let provider) = activePane { return provider }
        return nil
    }

    func dismiss() {
        activePane = .none
    }

    // MARK: - What a driver sees and can do

    private var reader: ComposerShellReader? {
        appModel.map { ComposerShellReader(appModel: $0, cardState: self) }
    }

    /// The id of the control that leads back out of a replaced provider column.
    static let backRowID = "back"

    /// Whether the models sit BESIDE the providers at the room's current
    /// width, which is what decides whether the provider column is on screen
    /// at all. The layer publishes the room it laid out in.
    var showsBothColumns: Bool {
        ComposerShellMetrics.fitsBoth(room: roomWidth, bothColumns: bothColumnsWidth)
    }

    /// The options of the active pane, in the order they are drawn — every
    /// control that is actually visible, so a page read and the shell cannot
    /// describe the same open pane differently (Sol, 2026-09-17).
    var rows: [ComposerShellRow] {
        // The receipt pane is answered before the routing reader, because it
        // reads none of it — a shell with no AppModel yet still has a receipt.
        if case .context = activePane { return contextRows() }
        guard let reader else { return [] }
        switch activePane {
        case .none, .context:
            return []
        case .model:
            return providerRows(reader)
        case .models(let provider):
            guard let group = reader.providerGroups.first(where: { $0.id == provider }) else {
                return providerRows(reader)
            }
            let models = group.models.map {
                ComposerShellRow(
                    id: $0.id,
                    label: $0.displayName,
                    isSelected: $0.id == reader.appModel.chatModel && provider == reader.appModel.chatProvider
                )
            }
            // Wide: both columns are drawn, so both are listed. Narrow: the
            // models took the column's place, and the way back is a control.
            return showsBothColumns
                ? providerRows(reader) + models
                : [ComposerShellRow(id: Self.backRowID, label: "Back to providers", isSelected: false)] + models
        case .think:
            return reader.efforts.map {
                ComposerShellRow(id: $0.id, label: $0.label, isSelected: $0.id == reader.appModel.chatReasoningEffort)
            }
        case .trust:
            return TrustPolicyPreset.allCases.map {
                ComposerShellRow(id: $0.quietID, label: $0.title, isSelected: reader.activeTrustPreset == $0)
            }
        }
    }

    /// The receipt, as rows: one per component, then the Assembled line, the
    /// provider's token line and the model-and-when line — the same order and
    /// the same words the card draws, from the same loaded receipt. Nothing
    /// here is a control, so `activateRow` still refuses the pane.
    private func contextRows() -> [ComposerShellRow] {
        switch contextReceipt {
        case .loading:
            return [ComposerShellRow(id: "loading", label: "Reading the last turn…", isSelected: false)]
        case .noTurn:
            return [ComposerShellRow(id: "no-turn", label: "No turn yet", isSelected: false)]
        case .unavailable(let reason):
            return [ComposerShellRow(
                id: "unavailable",
                label: "The turn trace could not be read: \(reason)",
                isSelected: false
            )]
        case .receipt(let receipt):
            var rows = receipt.rows.map { row in
                ComposerShellRow(
                    id: row.id,
                    label: ComposerContextReceiptPresentation.rowAccessibility(
                        row, share: receipt.share(row)
                    ),
                    isSelected: false
                )
            }
            rows.append(ComposerShellRow(
                id: "assembled",
                label: "Assembled \(ComposerContextReceiptPresentation.size(receipt.assembledBytes))",
                isSelected: false
            ))
            if let window = contextWindowLine {
                rows.append(ComposerShellRow(id: "window", label: window, isSelected: false))
            }
            let ran = ComposerContextReceiptPresentation.ranAt(receipt.ranAt)
            rows.append(ComposerShellRow(
                id: "ran",
                label: receipt.model.map { "\($0) · \(ran)" } ?? ran,
                isSelected: false
            ))
            return rows
        }
    }

    private func providerRows(_ reader: ComposerShellReader) -> [ComposerShellRow] {
        reader.providerGroups.map {
            ComposerShellRow(id: $0.id, label: $0.provider, isSelected: $0.id == reader.appModel.chatProvider)
        }
    }

    var selectedRowID: String? { rows.first(where: \.isSelected)?.id }

    /// What the open pane is, in one line, for a page read.
    var paneReadLine: String {
        switch activePane {
        case .none: "No composer pane is open."
        case .model: "Providers pane is open."
        case .models(let provider):
            "Models pane is open for \(reader?.providerGroups.first { $0.id == provider }?.provider ?? provider)."
        case .think: "Thinking pane is open."
        case .trust: "Trust pane is open."
        case .context: "Context pane is open."
        }
    }

    /// Take a row of the active pane by its id. Returns false when the pane
    /// does not hold that row, so a driver gets a real answer.
    @discardableResult
    func activateRow(id: String) -> Bool {
        guard let reader else { return false }
        switch activePane {
        case .none, .context:
            return false
        case .model:
            guard reader.providerGroups.contains(where: { $0.id == id }) else { return false }
            activePane = .models(id)
            flyoutIndex = nil
            return true
        case .models(let provider):
            if id == Self.backRowID {
                activePane = .model
                flyoutIndex = nil
                return true
            }
            // The models of the open provider first — they are the pane's own
            // rows — then the provider column beside them, which is on screen
            // too and switches which models are shown.
            if let group = reader.providerGroups.first(where: { $0.id == provider }),
               let model = group.models.first(where: { $0.id == id }) {
                reader.select(model: model, provider: provider)
                dismiss()
                return true
            }
            guard reader.providerGroups.contains(where: { $0.id == id }) else { return false }
            activePane = .models(id)
            flyoutIndex = nil
            return true
        case .think:
            guard let index = reader.efforts.firstIndex(where: { $0.id == id }) else { return false }
            reader.setEffort(index: index)
            return true
        case .trust:
            guard let preset = TrustPolicyPreset.allCases.first(where: { $0.quietID == id }) else { return false }
            applyTrust(preset, appModel: reader.appModel)
            return true
        }
    }

    func applyTrust(_ preset: TrustPolicyPreset, appModel: AppModel, confirmed: Bool = false) {
        guard !savingTrust else { return }
        if preset == .fullMac, !confirmed {
            confirmingFullMac = true
            return
        }
        dismiss()
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
    var cardState: ComposerShellState? { get }
}

/// The same reading, without a view: what the shell state itself uses to
/// answer a driver.
@MainActor
struct ComposerShellReader: ChatComposerRoutingReading {
    let appModel: AppModel
    var botContract: BotChatContract? { nil }
    let cardState: ComposerShellState?
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
    /// Returns the write in flight, so a caller that must tell the truth about
    /// it can await the receipt (Sol, 2026-09-17: the composer verb reported a
    /// model change as done while the transaction was still open, and a later
    /// failure only moved `statusText`). The words ignore it, exactly as
    /// before: nil means another write already owns the tuple, and the task's
    /// value is nil on success or the failure in words.
    @discardableResult
    func select(model: ModelCatalogItem, provider: String) -> Task<String?, Never>? {
        guard !appModel.isSavingChatBrain else { return nil }
        let supported = model.supportedReasoningEfforts ?? chatComposerFallbackEfforts
        let effort = supported.contains(appModel.chatReasoningEffort)
            ? appModel.chatReasoningEffort
            : (model.defaultReasoningEffort ?? supported.first ?? "high")
        let fast = model.supportsFast == true && appModel.chatFastMode

        appModel.isSavingChatBrain = true
        return Task { @MainActor in
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
                return nil
            } catch {
                appModel.statusText = "Model could not be changed: \(error.localizedDescription)"
                return error.localizedDescription
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
    @Environment(ComposerShellState.self) var cardState: ComposerShellState?

    /// Bumped by the draft when Tab should move into the words.
    var focusWordToken: Int

    /// Sol, 2026-09-15: a bot conversation sends on its OWN model, effort and
    /// Fast, so the words must read the bot's contract — showing (and editing)
    /// the global Chat tuple there was three lies on one row.
    @State var botContract: BotChatContract?
    @FocusState private var focusedWord: ChatComposerCard?
    /// What `ShellType.label` really measures at the current text size.
    @ScaledMetric(relativeTo: .body) private var scaledLabelSize: CGFloat = ShellType.labelSize

    init(focusWordToken: Int = 0) {
        self.focusWordToken = focusWordToken
    }

    /// The local Tab ring. The window-wide order skips plain buttons, so the
    /// three words walk themselves and hand Tab back at either end.
    private static let ring: [ChatComposerCard] = [.context, .model, .effort, .trust]

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            // How full the context is, at a glance — and the receipt behind
            // it: click the ring and the last turn's assembled context opens
            // in the same shell as the words, above the ring.
            contextRing
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
            //
            // 2026-09-17: the chip used to be inserted and removed, so toggling
            // Fast shifted the whole right-aligned words row sideways — under an
            // open pane, which is anchored to a word. It keeps its space at zero
            // opacity instead, and nothing can take it while it is not there.
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
            .opacity(fastIsOn ? 1 : 0)
            .disabled(!fastIsOn)
            .allowsHitTesting(fastIsOn)
            .accessibilityHidden(!fastIsOn)
            .help("Fast is on. Turn it off in the model card.")
            .accessibilityIdentifier("chat.composer.fast")
            .accessibilityLabel("Fast is on")

            word(
                .trust,
                text: trustWord,
                help: "Your saved permissions, used throughout the app.",
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
                    active: chatPageIsVisible && state.activePane.isOpen,
                    cardRect: state.cardWindowRect,
                    flyoutRect: state.activePane.word == .model ? state.modelsWindowRect : .zero,
                    providerColumnRect: state.activePane.word == .model ? state.providerColumnWindowRect : state.cardWindowRect
                ) {
                    state.dismiss()
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
    ///
    /// The size is the SCALED one, not the ramp's 13: measured at a fixed 13
    /// while the words render larger, the reservation is too narrow and the
    /// row moves under an open pane on every "Low" → "Medium" — the exact
    /// thing this reservation exists to stop.
    private var widestEffortWordWidth: CGFloat? {
        let labels = efforts.map(\.label)
        guard !labels.isEmpty else { return nil }
        let font = NSFont.systemFont(ofSize: scaledLabelSize, weight: .medium)
        return labels
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max()
            .map { ceil($0) }
    }

    /// True while the shell is showing this word's pane. `.model` and
    /// `.models` are both the model word's pane, so stepping into a provider's
    /// models never unlights the word.
    private func isActive(_ card: ChatComposerCard) -> Bool {
        cardState?.activePane.word == card
    }

    /// The ring is the context pane's word. It carries the same anchor, the
    /// same focus ring, the same hover rule and the same keys as the three
    /// settings words, so the receipt is reachable exactly like they are — and
    /// it opens the one shell, not a card of its own.
    private var contextRing: some View {
        Button { toggle(.context) } label: {
            ComposerContextRing(sessionId: appModel.activeChatSessionId)
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .background {
                    if isActive(.context) {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(NativeAgentShell.softFill)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focusedWord, equals: .context)
        // Same rule as the words: hover steers an open shell, never opens one.
        .onHover { inside in
            guard inside, let state = cardState, state.activePane.isOpen,
                  state.activePane.word != .context else { return }
            open(.context)
        }
        .accessibilityIdentifier("chat.composer.context")
        .accessibilityHint(isActive(.context)
            ? "Closes the context receipt"
            : "Opens the context receipt for the last turn")
        .anchorPreference(key: ChatComposerWordAnchorKey.self, value: .bounds) { [.context: $0] }
        .onKeyPress(.space) { toggle(.context); return .handled }
        .onKeyPress(.return) { toggle(.context); return .handled }
        .onKeyPress(.escape) {
            guard cardState?.activePane.isOpen == true else { return .ignored }
            cardState?.dismiss()
            return .handled
        }
        .onKeyPress(keys: [.tab]) { press in tab(.context, press) }
    }

    /// Tab off a word. With a pane open it walks INTO the pane's first control
    /// rather than closing the shell — every control inside it (Fast, More
    /// models, Back to providers, the Trust rows, the thinking slider) was
    /// otherwise unreachable from the keyboard. Shift-Tab still walks back out
    /// along the words, and Esc is still what dismisses. The context pane is
    /// a readout with no control to land on, so Tab keeps walking there.
    private func tab(_ card: ChatComposerCard, _ press: KeyPress) -> KeyPress.Result {
        let backwards = press.modifiers.contains(.shift)
        if !backwards, let state = cardState,
           state.activePane.word == card, state.activePane != .context,
           !(card == .effort && efforts.count <= 1),
           !(card == .trust && (appModel.trustPolicy == nil || state.savingTrust)) {
            state.focusShellToken &+= 1
            return .handled
        }
        let ring = ChatComposerSettings.ring
        guard let index = ring.firstIndex(of: card) else { return .ignored }
        let next = index + (backwards ? -1 : 1)
        guard ring.indices.contains(next) else { return .ignored }
        cardState?.dismiss()
        focusedWord = ring[next]
        return .handled
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
                .foregroundStyle(isActive(card) ? NativeAgentShell.text : NativeAgentShell.secondary)
                // The thinking word holds the width of its widest level, so
                // "Low" → "Medium" moves nothing else on the row and the open
                // shell stays where it is (User, 2026-09-15).
                .frame(minWidth: card == .effort ? widestEffortWordWidth : nil)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background {
                    if isActive(card) {
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
        // Hover only STEERS an already-open shell — it never opens one, and
        // leaving a word never closes it, so the pointer can cross from the
        // word to the shell. No timers: the agent can drive the same switch.
        .onHover { inside in
            guard inside, let state = cardState, state.activePane.isOpen,
                  state.activePane.word != card else { return }
            open(card)
        }
        .help(help)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(accessibility)
        .accessibilityHint(isActive(card) ? "Closes the \(cardName(card)) pane" : "Opens the \(cardName(card)) pane")
        .anchorPreference(key: ChatComposerWordAnchorKey.self, value: .bounds) { [card: $0] }
        .onKeyPress(.space) { toggle(card); return .handled }
        .onKeyPress(.return) {
            if takeHighlightedModel(card) { return .handled }
            toggle(card)
            return .handled
        }
        .onKeyPress(.escape) {
            guard cardState?.activePane.isOpen == true else { return .ignored }
            cardState?.dismiss()
            return .handled
        }
        .onKeyPress(.leftArrow) { arrow(card, forward: false) }
        .onKeyPress(.rightArrow) { arrow(card, forward: true) }
        .onKeyPress(.downArrow) { arrow(card, forward: true, vertical: true) }
        .onKeyPress(.upArrow) { arrow(card, forward: false, vertical: true) }
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            number(card, press.characters)
        }
        .onKeyPress(keys: [.tab]) { press in tab(card, press) }
    }

    /// Return inside the model pane takes the highlighted models row.
    private func takeHighlightedModel(_ card: ChatComposerCard) -> Bool {
        guard card == .model, let state = cardState,
              let providerID = state.flyoutProvider else { return false }
        guard let group = providerGroups.first(where: { $0.id == providerID }) else { return false }
        let index = state.flyoutIndex ?? flyoutSelectedIndex(for: group)
        guard group.models.indices.contains(index) else { return false }
        select(model: group.models[index], provider: providerID)
        state.dismiss()
        return true
    }

    private func cardName(_ card: ChatComposerCard) -> String {
        switch card {
        case .context: "context"
        case .model: "model"
        case .effort: "thinking"
        case .trust: "Trust"
        }
    }

    /// Show this word's pane in the one shell. Fast switching just writes the
    /// latest pane: the shell animates to it from wherever it is.
    private func open(_ card: ChatComposerCard) {
        guard let state = cardState else { return }
        guard !isBotConversation || (card != .model && card != .effort) else { return }
        // Agent (a): the live options are what a person came for, so the model
        // word lands on the current provider's models, not a column of names.
        state.activePane = .opening(card, provider: appModel.chatProvider)
        state.flyoutIndex = nil
        state.modelsContentHeight = 0
        focusedWord = card
    }

    private func toggle(_ card: ChatComposerCard) {
        // A bot's model and thinking level belong to the bot, so the words show
        // them and hand the edit to Bots. Trust stays app-wide and opens here.
        if card == .model || card == .effort, isBotConversation {
            NotificationCenter.default.post(name: .openCommandRouteRequest, object: "bots")
            return
        }
        if isActive(card) {
            cardState?.dismiss()
            return
        }
        open(card)
    }

    // MARK: - Keyboard inside the open pane

    private func arrow(_ card: ChatComposerCard, forward: Bool, vertical: Bool = false) -> KeyPress.Result {
        guard let state = cardState, state.activePane.word == card else { return .ignored }
        if card == .effort {
            guard !efforts.isEmpty else { return .ignored }
            let next = min(max(effortIndex + (forward ? 1 : -1), 0), efforts.count - 1)
            setEffort(index: next)
            return .handled
        }
        guard card == .model else { return .ignored }
        if vertical {
            // Agent (a): the arrows land in the live options, so up/down walk
            // the models rather than the column of provider names.
            guard let providerID = state.flyoutProvider,
                  let group = providerGroups.first(where: { $0.id == providerID }),
                  !group.models.isEmpty else { return .ignored }
            let current = state.flyoutIndex ?? flyoutSelectedIndex(for: group)
            state.flyoutIndex = min(max(current + (forward ? 1 : -1), 0), group.models.count - 1)
            return .handled
        }
        // Right walks into a provider's models, left back out to the providers.
        if forward {
            if state.flyoutProvider == nil { state.activePane = .models(appModel.chatProvider) }
            return .handled
        }
        state.activePane = .model
        state.flyoutIndex = nil
        state.modelsContentHeight = 0
        return .handled
    }

    private func number(_ card: ChatComposerCard, _ characters: String) -> KeyPress.Result {
        guard isActive(card), let digit = Int(characters), digit >= 1 else { return .ignored }
        switch card {
        case .context:
            // A readout has no numbered rows to take.
            return .ignored
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
        cardState?.dismiss()
        return .handled
    }

}


/// The one composer shell, drawn in the chat column's own overlay — above the
/// scroll view and above both safe-area insets, so its rows are actually
/// pressable. It takes no space and is bottom-anchored to the composer row, so
/// the transcript and the composer do not move when it opens.
///
/// 2026-09-17: Model, Think and Trust used to be three cards, and a provider's
/// models a second box beside the first. Now there is ONE surface with one
/// active pane: it slides horizontally to the word, grows upward to the pane's
/// height, and the pane content crossfades inside it. One easing, one
/// constant, no per-row geometry.
struct ChatComposerCardLayer: View, ChatComposerRoutingReading {
    @Environment(AppModel.self) var appModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// An offscreen capture has no backdrop for a material to sample, so the
    /// shell draws a solid fill there instead of glass.
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    /// Present in the chat column, absent in the detached panel and snapshots.
    @Environment(ChatTurnCardClearance.self) private var turnCardClearance: ChatTurnCardClearance?

    let state: ComposerShellState
    let anchors: [ChatComposerCard: Anchor<CGRect>]

    var cardState: ComposerShellState? { state }
    @State var botContract: BotChatContract?
    /// The pane's first control. Tab off a word lands here, so the shell's own
    /// controls are keyboard-reachable; exactly one pane is mounted at a time,
    /// so exactly one view carries this binding.
    @FocusState private var shellFocused: Bool

    /// The gap between the composer row and the shell floating above it.
    private let cardGap: CGFloat = 10
    private let shellRadius: CGFloat = 14

    var body: some View {
        shellOverlay(anchors)
            .alert("Enable Full Mac access?", isPresented: Binding(
                get: { state.confirmingFullMac }, set: { state.confirmingFullMac = $0 }
            )) {
                Button("Enable Full Mac", role: .destructive) {
                    state.applyTrust(.fullMac, appModel: appModel, confirmed: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("I can read and change files anywhere, run commands, control your Mac, and move files or put them in the Trash. I can act on my own, and files are backed up before changes. macOS privacy permissions still apply. This stays active until you change Trust.")
            }
            .alert("Trust could not be changed", isPresented: Binding(
                get: { state.trustError != nil }, set: { if !$0 { state.trustError = nil } }
            )) {
                Button("OK") { state.trustError = nil }
            } message: {
                Text(state.trustError ?? "")
            }
            // 2026-09-17: the receipt is back, as the ring's own pane. The
            // old one read the daemon's context store (Context.swift:
            // PORTED-DORMANT-PARTIAL), which nothing has written since, so it
            // only ever said "incomplete"; this one reads the turn traces the
            // engine writes on every turn, and shows only what they record.
            .task(id: appModel.activeChatSessionId) {
                botContract = nil
                let contract = await BotChatContract.checked(appModel.activeChatSessionId)
                guard !Task.isCancelled else { return }
                botContract = contract
            }
            // The routing the panes read, and what a driver answers from.
            // Registering the live shell for the verbs is ChatView's job —
            // `liveOnAppear`, so the offscreen copy a quiet page read mounts
            // never registers itself over the composer on screen.
            .onAppear { state.appModel = appModel }
            .onDisappear { turnCardClearance?.openComposerCardHeight = 0 }
            // Lift the Latest pill over the open shell, and only the pill.
            .onChange(of: state.activePane) { _, pane in
                turnCardClearance?.openComposerCardHeight =
                    pane.isOpen ? state.shellHeight + cardGap : 0
                guard !pane.isOpen else { return }
                // Cleared on DISMISSAL only. Zeroing it on every switch drove
                // the shell down to the 44pt floor and back up on the way to
                // the next pane — a collapse, where the shell is meant to
                // morph once. The incoming pane's own measurement lands in the
                // same pass, so the old height is never what is drawn.
                state.paneContentHeight = 0
                shellFocused = false
                state.flyoutIndex = nil
                state.modelsWindowRect = .zero
                state.providerColumnWindowRect = .zero
                state.modelsContentHeight = 0
                state.providerContentHeight = 0
            }
            // Tab off a word walks into the pane instead of closing it.
            .onChange(of: state.focusShellToken) { _, _ in shellFocused = true }
            .onChange(of: state.shellHeight) { _, height in
                guard state.activePane.isOpen else { return }
                turnCardClearance?.openComposerCardHeight = height + cardGap
            }
            #if DEBUG
            // Capture affordance only, same gate as COMPOSER_CARD_OPEN: a long
            // models list cannot be hovered or scrolled without a hand.
            .onChange(of: state.activePane) { _, pane in
                let environment = ProcessInfo.processInfo.environment
                guard let provider = environment["COMPOSER_FLYOUT_PROVIDER"],
                      pane.word == .model, state.flyoutProvider != provider else { return }
                state.activePane = .models(provider)
                state.flyoutIndex = Int(environment["COMPOSER_FLYOUT_INDEX"] ?? "0") ?? 0
            }
            #endif
    }

    // MARK: - Where the shell sits

    /// Everything the shell needs to place itself: bottom-anchored to the row,
    /// centred over the active word, clamped to the room.
    private struct ShellLayout {
        let pane: ComposerPane
        /// Left edge in the layer's space.
        let x: CGFloat
        /// The shell's outer width for this pane.
        let width: CGFloat
        /// The shell's bottom edge — the same line for every pane, so it never
        /// bobs as the height changes.
        let bottom: CGFloat
        /// Both columns fit side by side in this room.
        let fitsBoth: Bool
        /// The tallest any pane's content may be here.
        let contentCap: CGFloat
        let origin: UnitPoint
    }

    /// The pane widths follow the system's text size. A ramp that grows inside
    /// a fixed box only truncates every row, so the box grows with it.
    /// `@ScaledMetric` returns the wrapped value unchanged at the default text
    /// size: nothing moves for a person who never touched the setting.
    @ScaledMetric(relativeTo: .body) private var providerColumnWidth: CGFloat =
        ComposerShellMetrics.providerColumn
    @ScaledMetric(relativeTo: .body) private var modelsColumnWidth: CGFloat =
        ComposerShellMetrics.modelsColumn
    @ScaledMetric(relativeTo: .body) private var thinkWidth: CGFloat = ComposerShellMetrics.think
    @ScaledMetric(relativeTo: .body) private var trustWidth: CGFloat = ComposerShellMetrics.trust
    @ScaledMetric(relativeTo: .body) private var contextWidth: CGFloat = ComposerShellMetrics.context

    /// +1 for the hairline between the two columns, at whatever text size.
    private var bothColumnsWidth: CGFloat { providerColumnWidth + 1 + modelsColumnWidth }

    private func layout(_ proxy: GeometryProxy) -> ShellLayout? {
        let pane = state.activePane
        guard let word = pane.word, let anchor = anchors[word] else { return nil }
        let room = proxy.size.width
        let fitsBoth = ComposerShellMetrics.fitsBoth(room: room, bothColumns: bothColumnsWidth)

        let natural: CGFloat = switch pane {
        case .none: 0
        case .model: providerColumnWidth
        case .models: fitsBoth ? bothColumnsWidth : modelsColumnWidth
        case .think: thinkWidth
        case .trust: trustWidth
        case .context: contextWidth
        }
        // Sol, 2026-09-15: the clamp has to be the OUTER width, or the shell
        // hangs past the room's edge at the narrow end.
        let width = min(natural, room)
        let rect = proxy[anchor]
        // Centred over the word, clamped to the room. The words are
        // right-aligned, so a word's centre holds still while its text changes.
        let x = min(max(0, rect.midX - width / 2), max(0, room - width))
        // The bottom edge is the row, not the pane: the shell grows upward.
        let bottom = max(0, rect.minY - cardGap)
        let cap = min(ComposerShellMetrics.modelsMaxHeight, max(120, bottom - NativeAgentSpacing.sm * 2))
        let origin = UnitPoint(x: min(1, max(0, (rect.midX - x) / max(1, width))), y: 1)
        return ShellLayout(pane: pane, x: x, width: width, bottom: bottom, fitsBoth: fitsBoth, contentCap: cap, origin: origin)
    }

    func shellOverlay(_ anchors: [ChatComposerCard: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            // The row's own top edge, read from whichever word published it, so
            // the shell's bottom line does not move when the pane changes.
            let rowTop = anchors.values.map { proxy[$0].minY }.min() ?? proxy.size.height
            let placement = layout(proxy)
            let shape = RoundedRectangle(cornerRadius: shellRadius, style: .continuous)

            ZStack(alignment: .bottomLeading) {
                if let placement {
                    // The shell's own frame is what animates. The content is
                    // laid out at its natural height and clipped to that frame,
                    // so growth reveals upward instead of squashing rows.
                    Color.clear
                        .frame(width: placement.width, height: max(state.shellHeight, 1))
                        .overlay(alignment: .bottom) {
                            shellContent(placement)
                                .frame(width: placement.width, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                    state.shellHeight = $0
                                }
                        }
                        .background {
                            // On the glass the room fill is the coat UNDER the
                            // material, and the material's blur is what stops
                            // the transcript. An offscreen capture has nothing
                            // to blur, so the same coat let the transcript read
                            // straight through the receipt rows. A capture
                            // substitutes the settled appearance: the opaque
                            // slate every card already wears.
                            shape.fill(quietOffscreenRead
                                       ? TodayPalette.cardFill
                                       : reduceTransparency
                                       ? Color(nsColor: .controlBackgroundColor)
                                       : NativeAgentShell.room.opacity(0.82))
                        }
                        .overlay {
                            if reduceTransparency || quietOffscreenRead {
                                shape.strokeBorder(quietOffscreenRead
                                                   ? TodayPalette.cardStroke
                                                   : NativeAgentShell.hairline,
                                                   lineWidth: 1)
                            }
                        }
                        .glassEffect(reduceTransparency || quietOffscreenRead ? .identity : .regular, in: shape)
                        .clipShape(shape)
                        .background {
                            ComposerCardRectReporter(rect: Binding(
                                get: { state.cardWindowRect },
                                set: { state.cardWindowRect = $0 }
                            ))
                        }
                        .offset(x: placement.x)
                        // Travel and growth: one easing, and none of it under
                        // Reduced Motion. The fade in and out is scoped OUTSIDE
                        // this view, so the shell still arrives and leaves by
                        // crossfade when travel is off (Sol, 2026-09-17).
                        .animation(reduceMotion ? nil : NativeAgentMotion.standard, value: state.activePane)
                        .animation(reduceMotion ? nil : NativeAgentMotion.standard, value: state.shellHeight)
                        .transition(NativeAgentMotion.reveal(reduceMotion: reduceMotion, anchor: placement.origin))
                        // Escape closes from anywhere inside the shell, not
                        // just from the word that opened it.
                        .onExitCommand { state.dismiss() }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("chat.composer.shell")
                        .accessibilityLabel(paneName(placement.pane))
                }
            }
            .frame(width: proxy.size.width, height: max(0, rowTop - cardGap), alignment: .bottomLeading)
            // The shell's own arrival and departure. Opening and closing are
            // always a crossfade — Reduced Motion drops the travel, not the
            // continuity — so the shell never snaps into existence.
            .animation(NativeAgentMotion.crossfade, value: state.activePane.isOpen)
            // What a page read answers from: the same room the layout used.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { state.roomWidth = $0 }
            // …and the same two-column width, which the text size can change.
            .onChange(of: bothColumnsWidth, initial: true) { _, width in
                state.bothColumnsWidth = width
            }
        }
    }

    /// The active pane's name, for the shell's accessibility element and for
    /// `app_page_read`.
    private func paneName(_ pane: ComposerPane) -> String {
        switch pane {
        case .none: "Composer"
        case .model: "Providers"
        case .models(let provider):
            providerGroups.first { $0.id == provider }.map { "\($0.provider) models" } ?? "Models"
        case .think: "Thinking"
        case .trust: "Trust"
        case .context: "Context"
        }
    }

    /// One pane at a time. Identity is the WORD, so stepping from the provider
    /// column into a provider's models extends the same content instead of
    /// crossfading it away.
    @ViewBuilder
    private func shellContent(_ placement: ShellLayout) -> some View {
        ZStack(alignment: .bottomLeading) {
            switch placement.pane {
            case .none: EmptyView()
            case .model, .models: modelPane(placement)
            case .think: clamped(placement) { effortCard.padding(NativeAgentSpacing.md) }
            case .trust: clamped(placement) { trustCard.padding(NativeAgentSpacing.md) }
            case .context: clamped(placement) { contextPane }
            }
        }
        .id(placement.pane.word)
        .transition(NativeAgentMotion.fade)
        .animation(NativeAgentMotion.crossfade, value: placement.pane.word)
    }

    /// The models list was the only pane the room's height bound. Think, Trust
    /// and Context laid out at their natural height inside a ZStack that does
    /// not clip, so a long context receipt — or the four Trust rows at a short
    /// window — drew up over the chat header. Same cap, and whatever does not
    /// fit scrolls inside the shell, exactly like the models do.
    @ViewBuilder
    private func clamped<Content: View>(
        _ placement: ShellLayout,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            content()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    state.paneContentHeight = $0
                }
        }
        .scrollIndicators(.automatic)
        // A ScrollView has no intrinsic height — it takes whatever it is
        // offered — so the height has to be the measured content, clamped.
        .frame(height: min(max(state.paneContentHeight, 44), placement.contentCap))
    }

    /// The fourth pane: the last turn's receipt, read from the turn traces.
    /// It is content like any other pane — the shell places, sizes, clamps and
    /// animates it, and the ring opens it.
    @ViewBuilder
    private var contextPane: some View {
        ComposerContextReceiptCard(sessionId: appModel.activeChatSessionId, shell: state)
            .padding(NativeAgentSpacing.md)
    }

    // MARK: - Model pane

    /// User, 2026-09-15: the model pane is a menu. It lists the connected
    /// PROVIDERS, one row each, and a provider's models extend from that
    /// column's edge — OpenRouter alone is hundreds of models, which no flat
    /// card can hold.
    ///
    /// 2026-09-17: the models are no longer a second box beside the first.
    /// When both columns fit they are two columns of ONE shell, divided by a
    /// hairline, sharing its material and its shadow. When they do not fit,
    /// the models REPLACE the provider column inside the same shell and a
    /// "Back to providers" control leads out — never a flyout that switches
    /// sides.
    @ViewBuilder
    private func modelPane(_ placement: ShellLayout) -> some View {
        let group = state.flyoutProvider.flatMap { provider in
            providerGroups.first { $0.id == provider }
        }
        // No provider chosen yet (or one that is gone): the column is the pane.
        let showsProviders = placement.pane == .model || placement.fitsBoth || group == nil
        HStack(alignment: .top, spacing: 0) {
            if showsProviders {
                providerColumn
                    .frame(width: placement.fitsBoth && group != nil
                           ? providerColumnWidth
                           : placement.width)
            }
            if let group, showsProviders ? placement.fitsBoth : true {
                if showsProviders {
                    // One shell, two columns: a hairline, not a second edge,
                    // a second shadow or a gap.
                    Rectangle()
                        .fill(NativeAgentShell.hairline)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
                modelsColumn(group, placement: placement, showsBack: !showsProviders)
                    .frame(width: showsProviders ? modelsColumnWidth : placement.width)
            }
        }
    }

    private var providerColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(providerGroups.enumerated()), id: \.element.id) { index, group in
                        providerRow(group, isFirst: index == 0)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    state.providerContentHeight = $0
                }
            }
            .scrollIndicators(.automatic)
            // The shell is laid out at its content's natural height, and a
            // ScrollView has none — so the column is as tall as its list,
            // clamped, exactly like the models list beside it.
            .frame(height: min(max(state.providerContentHeight, 44), 220))
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
                .paneControl($shellFocused)
                .accessibilityIdentifier("chat.composer.model.fast")
            }

            Rectangle()
                .fill(NativeAgentShell.hairline)
                .frame(height: 1)
                .padding(.vertical, 8)

            cardFooterLink("More models") {
                state.dismiss()
                NotificationCenter.default.post(name: .openCommandRouteRequest, object: "providers")
            }
            .paneControl(first: providerGroups.isEmpty, $shellFocused)
            .accessibilityIdentifier("chat.composer.model.more")

            scopeLine("Saved default for Chat")
        }
        .padding(NativeAgentSpacing.md)
    }

    /// One connected provider. Agent (c): the row that is in use is
    /// checkmarked AND says which model it is on, so the column answers
    /// "what am I talking to" without opening anything.
    /// 2026-09-17: this was a combined accessibility element with a tap
    /// gesture — no button trait, no action, no identifier, so VoiceOver could
    /// read the providers and never open one. It is a Button now, which is
    /// what carries the trait and the press, and the first row is where Tab
    /// off the model word lands.
    private func providerRow(_ group: ChatComposerModelGroup, isFirst: Bool) -> some View {
        let isCurrent = group.id == appModel.chatProvider
        let isOpen = state.flyoutProvider == group.id
        return Button { showModels(of: group.id) } label: {
            HStack(spacing: 6) {
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
                // The models always extend to the right of this column now, so
                // the chevron has one direction.
                Image(systemName: "chevron.right")
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
        }
        .buttonStyle(.plain)
        .paneControl(first: isFirst, $shellFocused)
        // Agent (d): hovering another provider swaps the models, and nothing
        // clears them on exit — that is the grace path across the gap.
        .onHover { inside in
            guard inside, state.flyoutProvider != group.id else { return }
            showModels(of: group.id)
        }
        .accessibilityIdentifier("chat.composer.model.provider.\(group.id)")
        .accessibilityLabel(isCurrent
            ? "\(group.provider), in use, \(selectedModel?.displayName ?? "")"
            : group.provider)
        .accessibilityHint("Shows this provider's models")
    }

    private func showModels(of provider: String) {
        state.activePane = .models(provider)
        state.flyoutIndex = nil
        // A short list must not inherit the previous one's height.
        state.modelsContentHeight = 0
    }

    /// The models of the open provider, inside the same shell. It scrolls
    /// within itself — OpenRouter is hundreds of rows — and it is only as tall
    /// as its own content, clamped to the room.
    @ViewBuilder
    private func modelsColumn(
        _ group: ChatComposerModelGroup,
        placement: ShellLayout,
        showsBack: Bool
    ) -> some View {
        // Only as tall as the list. `maxHeight` alone does nothing for a
        // ScrollView, which is greedy — the height has to be the measured
        // content, clamped (User, 2026-09-15).
        let height = min(max(state.modelsContentHeight, 44), placement.contentCap)
        // The providers arrive after the pane opens, so the highlight follows
        // the SELECTION until a key moves it.
        let highlight = state.flyoutIndex ?? flyoutSelectedIndex(for: group)
        VStack(alignment: .leading, spacing: 0) {
            if showsBack {
                // Narrow window: the models took the providers' place, so the
                // way back is a control, never a second box.
                Button {
                    state.activePane = .model
                    state.flyoutIndex = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        Text("Back to providers")
                    }
                    .font(ShellType.labelMedium)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .paneControl(first: true, $shellFocused)
                .accessibilityIdentifier("chat.composer.model.back")
            }
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
                        state.modelsContentHeight = $0
                    }
                }
                .frame(height: height)
                .onChange(of: highlight, initial: true) { _, index in
                    scroller.scrollTo(index, anchor: .center)
                }
            }
            .id(group.id)
            .background {
                ComposerCardRectReporter(rect: Binding(
                    get: { state.modelsWindowRect },
                    set: { state.modelsWindowRect = $0 }
                ))
            }
        }
    }

    private func modelRow(
        _ model: ModelCatalogItem,
        provider: String,
        shortcut: Int,
        highlighted: Bool
    ) -> some View {
        let isSelected = model.id == appModel.chatModel && provider == appModel.chatProvider
        return Button {
            select(model: model, provider: provider)
            state.dismiss()
        } label: {
            HStack(spacing: 6) {
                // Agent's note 4 / (c): "selected" is a mark on the current
                // row, and the models mark the same model the provider row
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
        .paneControl($shellFocused)
        .accessibilityIdentifier("chat.composer.model.item.\(model.id)")
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
                .paneControl(first: true, $shellFocused)
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

    @ViewBuilder
    private var trustCard: some View {
        if appModel.trustPolicy == nil {
            // 2026-09-17: before the policy loads there is nothing to compare
            // a preset against, so all four rows were drawn and disabled with
            // no word for why. One line says what is happening instead.
            Text("Reading the saved posture…")
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("chat.composer.trust.loading")
        } else {
            trustPresets
        }
    }

    private var trustPresets: some View {
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
                .disabled(state.savingTrust)
                .paneControl(first: index == 0, $shellFocused)
                .accessibilityIdentifier("chat.composer.trust.\(preset.quietID)")
                .accessibilityLabel(isSelected ? "\(preset.title), selected" : preset.title)
                .accessibilityHint(preset.summary)
            }

            scopeLine("Saved default throughout the app")
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

private extension View {
    /// Puts an actionable pane control in the shell's key view loop. A plain
    /// Button is not in it on its own, which is why the pane was a dead end:
    /// Tab landed on one control and the arrow and number keys stayed behind
    /// on the word that no longer had focus, so the remaining providers, the
    /// models, the Trust rows, Fast and More models could not be reached at
    /// all. Every one of them is focusable now and Tab walks them in the order
    /// they are drawn; the FIRST also carries the landing binding, which is
    /// where Tab off the word arrives. Esc still dismisses, from anywhere
    /// inside the shell.
    @ViewBuilder
    func paneControl(first: Bool = false, _ focus: FocusState<Bool>.Binding) -> some View {
        if first {
            focusable().focused(focus)
        } else {
            focusable()
        }
    }
}

/// One provider's models, as the card groups them. The provider is a header
/// built from the routing snapshot, never a branch in the code.
struct ChatComposerModelGroup: Identifiable {
    let id: String
    let provider: String
    let models: [ModelCatalogItem]
}
