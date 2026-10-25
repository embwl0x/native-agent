import AppKit
import EngineRuntime
import AppToolRuntime
import Agents
import SwiftUI
import NativeAgentCore
import StandingBots
import SwarmRuns
import NativeAgentShared
// Blueprint: | `SimpleShellView.swift` | Simple and Advanced shells render the engine's shared contact, helper and typed crew projection; only selection and formatting remain local |

// Simple view's window: one floating glass sidebar (the rail's plate) and the
// agent's ordinary chat, a contact's or helper's thread, or a crew's work beside it.
// Renders the engine's root-scoped contact, helper and crew projections.

typealias SimpleContact = AgentContactPresentation
typealias SimpleThreadLine = AgentContactThreadLine
typealias SimpleFlight = AgentContactFlight

typealias SimpleViewStore = ContactThreadsProjection
typealias SimpleCrew = SwarmCrew

extension EnvironmentValues {
    /// app_page_screenshot's "simple_settings_menu": the settings menu drawn
    /// open in place, since a popover is its own window and never draws offscreen.
    @Entry var simpleSettingsMenuDrawnOpen = false
}

struct SimpleShellView: View {
    enum Pane: Hashable { case agent, contact(String), helper(UUID), crew(String) }

    @Environment(AppModel.self) private var appModel
    private var store: SimpleViewStore { appModel.engine.contactThreads }
    @State private var pane: Pane = .agent

    /// The open contact, helper or crew left the lists (unreachable, deleted,
    /// or a finished crew past the newest three): back to the agent's chat,
    /// not a blank pane.
    private var gone: some View {
        Color.clear.onAppear { pane = .agent }
    }

    var body: some View {
        ShellFrame {
            SimpleSidebar(store: store, pane: $pane)
        } detail: {
            let showingChat = pane == .agent
            ZStack {
                // The agent's chat, whole, as Advanced has it — only the
                // conversation list is gone. Mounted for the life of the view
                // like ContentView's, so a thread visit never rebuilds it.
                ChatView()
                    .environment(\.chatPageIsVisible, showingChat)
                    .opacity(showingChat ? 1 : 0)
                    .allowsHitTesting(showingChat)
                    .disabled(!showingChat)
                    .accessibilityHidden(!showingChat)
                    .accessibilityElement(children: showingChat ? .contain : .ignore)
                switch pane {
                case .agent:
                    EmptyView()
                case .contact(let id):
                    if let contact = store.contacts.first(where: { $0.id == id }) {
                        SimpleContactThread(contact: contact, store: store) { pane = .agent }
                            .id(contact.id)
                    } else { gone }
                case .helper(let id):
                    if let helper = store.helpers.first(where: { $0.id == id }) {
                        SimpleHelperRuns(record: helper, store: store) { pane = .agent }
                            .id(helper.id)
                    } else { gone }
                case .crew(let id):
                    if let crew = store.crews.first(where: { $0.id == id }) {
                        SimpleCrewThread(crew: crew)
                            .id(crew.id)
                    } else { gone }
                }
            }
        }
        .onAppear { store.start() }
        // An offscreen drawing waits for the first read, so the lists are there.
        .quietReadTask(live: false) {
            while !store.loaded, !Task.isCancelled { try? await Task.sleep(nanoseconds: 50_000_000) }
        }
        .environment(\.layoutProfile, SimpleViewMode.simple)
    }
}

/// The Settings menu's items: a waiting update, the haze colour, the warmth
/// switch, and the way to all settings. The same keys Advanced writes.
private struct SimpleSettingsMenuItems: View {
    @AppStorage(MoodTintPreference.key) private var warmth = true
    @AppStorage(SimpleViewMode.key) private var viewMode = ""
    @AppStorage(HazeColor.key) private var hazeRaw = HazeColor.defaultValue.rawValue
    @Environment(\.colorScheme) private var scheme
    @State private var updates = UpdateController.shared

    var body: some View {
        if let version = updates.status.availableVersion {
            Button("Install version \(version)", systemImage: "arrow.down.circle") {
                updates.checkForUpdates()
            }
            Divider()
        }
        Picker(selection: $hazeRaw) {
            ForEach(HazeColor.allCases) { color in
                Label { Text(color.name) } icon: { Image(nsImage: Self.swatch(color)) }
                    .tag(color.rawValue)
            }
        } label: {
            Label("Color", systemImage: "paintpalette")
        }
        // The warmth only lands in dark mode (MoodTintGate).
        if scheme == .dark {
            Toggle(isOn: $warmth) { Label("Warmth in the glass", systemImage: "sun.max") }
        }
        Divider()
        Button("More settings…", systemImage: "gearshape") {
            viewMode = SimpleViewMode.advanced
            _ = NativeAgentAppCoordinator.shared.request(.sidebar(.settings))
        }
    }

    /// A filled circle in the haze colour; menus draw template images grey.
    static func swatch(_ color: HazeColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(color.base).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Advanced's Connectors ▸ Agents: Simple's lists — the agent's threads with
/// each agent, the helpers it talks to, the crews at work — beside the open
/// one, so the full app can do what Simple does. Nothing open is the
/// connection setup the tab always had.
struct AgentThreadsTab: View {

    @Environment(AppModel.self) private var appModel
    private var store: SimpleViewStore { appModel.engine.contactThreads }
    @State private var pane: SimpleShellView.Pane = .agent

    private func openChat() { NativeAgentAppCoordinator.shared.request(.sidebar(.chat)) }

    var body: some View {
        HStack(spacing: 0) {
            SimpleSidebar(store: store, pane: $pane, embedded: true)
            Group {
                switch pane {
                case .agent:
                    AgentContactsSection()
                case .contact(let id):
                    if let contact = store.contacts.first(where: { $0.id == id }) {
                        SimpleContactThread(contact: contact, store: store, openChat: openChat).id(contact.id)
                    } else { Color.clear.onAppear { pane = .agent } }
                case .helper(let id):
                    if let helper = store.helpers.first(where: { $0.id == id }) {
                        SimpleHelperRuns(record: helper, store: store, openChat: openChat).id(helper.id)
                    } else { Color.clear.onAppear { pane = .agent } }
                case .crew(let id):
                    if let crew = store.crews.first(where: { $0.id == id }) {
                        SimpleCrewThread(crew: crew).id(crew.id)
                    } else { Color.clear.onAppear { pane = .agent } }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { store.start() }
        // An offscreen drawing waits for the first read, so the lists are there.
        .quietReadTask(live: false) {
            while !store.loaded, !Task.isCancelled { try? await Task.sleep(nanoseconds: 50_000_000) }
        }
    }
}

/// The agent's card, then Agents and Helpers in her home's order
/// (ui/layout.json), on the room's one sheet (Sidebar C, User 10-04): no
/// plate; a hairline parts it from the chat.
/// Embedded in Advanced's Agents tab, a Connections row stands in for the
/// card and the settings menu stays with Simple.
private struct SimpleSidebar: View {
    let store: SimpleViewStore
    @Binding var pane: SimpleShellView.Pane
    var embedded = false
    @Environment(AppModel.self) private var appModel
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.layoutProfile) private var layoutProfile
    @State private var showQuiet = false
    @State private var showCrews = false
    /// "last ran … ago" is measured from this, re-stamped when the plate
    /// appears, the window comes forward, a helper changes or the pointer
    /// arrives; no timer.
    @State private var now = Date()

    static let width: CGFloat = 280
    static let sectionGap: CGFloat = 22
    static let rowName = Font.system(size: 14, weight: .medium)
    static let rowLine = Font.system(size: 12)
    private var agentName: String { AgentVoice(name: appModel.agentDisplayName).name }

    var body: some View {
        // Talked to, newest first; the rest fold at the end.
        let contacts = store.contacts
        let talked = contacts.filter { !isQuiet($0) }
        let unheard = contacts.filter(isQuiet)
        // The Mac's own sidebar List (User 09-27: all controls native): its
        // selection, arrow keys and folds.
        // Her card is home, not a row: it wears its own quiet wash instead
        // of the system's blue block (User 09-27: tune her back after native).
        List(selection: Binding<SimpleShellView.Pane?>(get: { pane == .agent && !embedded ? nil : pane },
                                                       set: { if let next = $0 { pane = next } })) {
            if embedded {
                row(.agent) {
                    HStack(spacing: 10) {
                        SimpleClockTile(size: 30, symbol: "link", working: false)
                        rowText("Connections", "Connect, test or disconnect", selected: pane == .agent)
                    }
                }
                .padding(.bottom, Self.sectionGap)
            } else {
            Button { pane = .agent } label: {
                SimpleAgentCard(selected: pane == .agent).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .selectionDisabled()
                .padding(.bottom, Self.sectionGap)
            }
            // Her home's people and helpers, in its order: the two sections.
            ForEach(appModel.engine.layout.layout.shown("home", profile: layoutProfile).filter { ["people", "helpers"].contains($0.name) },
                    id: \.name) { block in
                if block.name == "people" { agentsSection(talked: talked, unheard: unheard) } else { helpersSection }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // The list starts below the title strip, so no row ever scrolls up
        // under the traffic lights; its first row sits 12 lower still.
        .contentMargins(.top, 12, for: .scrollContent)
        .padding(.top, embedded ? 0 : NativeAgentShellLayout.titleBarInset)
        .scrollIndicators(.never)
        // Settings stays at the sidebar's foot: under the lists while there is
        // room, and in a short window the lists scroll beneath it, its own
        // coat keeping it legible, not a second glass (User, 09-24). An inset, not safeAreaBar: that pinned the main thread
        // at 100% in this window on 09-23 (f24194bb0).
        .safeAreaInset(edge: .bottom, spacing: 0) { if !embedded { settingsRow } }
        .padding(.leading, embedded ? 0 : NativeAgentShellLayout.railPlateInset)
        .frame(width: Self.width + (embedded ? 0 : NativeAgentShellLayout.railPlateInset))
        .frame(maxHeight: .infinity)
        // Sidebar C: on the window's sheet, edge to edge, parted from the
        // chat by one hairline. Her card is the one glass piece.
        .overlay(alignment: .trailing) {
            Rectangle().fill(NativeAgentShell.hairline).frame(width: 1).allowsHitTesting(false)
        }
        .onAppear { now = Date() }
        .onChange(of: activeState) { now = Date() }
        .onChange(of: store.helpers) { now = Date() }
        .onHover { if $0 { now = Date() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(agentName), agents and helpers")
    }

    private func agentsSection(talked: [SimpleContact], unheard: [SimpleContact]) -> some View {
        Section {
            if let error = store.refreshError { quiet(error) }
            if store.loaded && store.contacts.isEmpty {
                quiet("None connected yet. Ask \(agentName) to connect one.")
            }
            ForEach(talked) { contactRow($0) }
            if !unheard.isEmpty {
                DisclosureGroup(isExpanded: $showQuiet) {
                    ForEach(unheard) { contactRow($0) }
                } label: {
                    foldLabel("Not talked to yet", count: unheard.count)
                }
            }
        } header: {
            sectionTitle("Agents", "Other AIs I work with.")
        }
    }

    private var helpersSection: some View {
        Section {
            // Running and unknown crews stay here until their owner settles them.
            ForEach(store.crews.filter { $0.liveness != .settled }) { crewRow($0) }
            if store.loaded && store.helpers.isEmpty {
                quiet("None yet. Ask \(agentName) to make one.")
            }
            ForEach(store.helpers) { helper in
                let selected = pane == .helper(helper.id)
                let timing = Self.timing(helper, now: now)
                let working = store.running.contains(helper.id) || store.waiting.contains(SimpleViewStore.key(helper.id))
                row(.helper(helper.id)) {
                    HStack(spacing: 10) {
                        SimpleClockTile(size: 30, working: working)
                        rowText(helper.definition.name, timing, selected: selected)
                    }
                }
                .accessibilityLabel("\(helper.definition.name), \(working ? "working now, " : "")\(timing)")
            }
            let finished = store.crews.filter { $0.liveness == .settled }
            if !finished.isEmpty {
                DisclosureGroup(isExpanded: $showCrews) {
                    ForEach(finished) { crewRow($0) }
                } label: {
                    foldLabel("Recent crews", count: finished.count)
                }
            }
        } header: {
            sectionTitle("Helpers", "Bots I made that can do real work for you. Talk to any of them here.")
        }
    }

    /// A little gear and the word, at the plate's foot (User, 09-24: "just a
    /// settings thing"); it opens the settings menu upward.
    private var settingsRow: some View {
        // The Mac's own menu (User 09-27: all controls native).
        HStack(spacing: 0) {
            Menu {
                SimpleSettingsMenuItems()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                    Text("Settings")
                        .font(Self.rowLine)
                }
                .foregroundStyle(NativeAgentShell.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .shellKeyboardTarget(.rail, sortsLast: true)
            Spacer(minLength: 0)
        }
        .padding(.leading, NativeAgentShellLayout.railWordInset)
        .frame(height: 32)
        .padding(.bottom, 8)
        // A flat coat of the room, fading in over 16pt, so rows sliding under
        // it are gone before they reach the word (the edge effect alone left
        // text on text at 600pt). Inside the bar, so the last row still
        // scrolls clear of it; paint, not a second glass.
        .padding(.top, 16)
        .background {
            VStack(spacing: 0) {
                LinearGradient(colors: [NativeAgentShell.room.opacity(0), NativeAgentShell.room.opacity(1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 16)
                NativeAgentShell.room.opacity(1)
            }
            .allowsHitTesting(false)
        }
    }

    private func foldLabel(_ title: String, count: Int) -> some View {
        Text("\(title) (\(count))")
            .font(Self.rowLine)
            .foregroundStyle(NativeAgentShell.secondary)
            .accessibilityLabel("\(title), \(count)")
    }

    /// "Working now · <task> · 3 workers" while it runs; the task and how it
    /// went once it has finished.
    private func crewRow(_ crew: SimpleCrew) -> some View {
        let selected = pane == .crew(crew.id)
        let workers = crew.workers.count == 1 ? "1 worker" : "\(crew.workers.count) workers"
        let name = crew.liveness == .unknown ? "Liveness unknown" : crew.live ? "Working now" : crew.task
        let line = crew.liveness != .settled ? "\(crew.task) · \(workers)" : "\(SimpleCrewThread.outcome(crew)) · \(workers)"
        return row(.crew(crew.id)) {
            HStack(spacing: 10) {
                SimpleClockTile(size: 30, symbol: "person.3", working: crew.live)
                rowText(name, line, selected: selected)
            }
        }
        .accessibilityLabel("\(name), \(line)")
    }

    private func isQuiet(_ contact: SimpleContact) -> Bool {
        contact.lastActivityAt == nil && (store.lines[contact.id] ?? []).isEmpty && !store.waiting.contains(contact.id)
            && store.status[contact.id] == nil && store.flight(for: contact.id) == nil && contact.health?.problem == nil
            && contact.owedExperiences.isEmpty
    }

    private func contactRow(_ contact: SimpleContact) -> some View {
        let selected = pane == .contact(contact.id)
        // Lead with how it is connected, so two contacts behind one app's
        // icon ("Grok", "Grok Bot") read as the two things they are.
        let line = [contact.link?.words, lastLine(contact)].compactMap { $0 }.joined(separator: " · ")
        return row(.contact(contact.id)) {
            HStack(spacing: 10) {
                SimpleAvatar(contact: contact, size: 30)
                rowText(contact.name, line, selected: selected)
            }
        }
        // Working with her: the whole row wears the moving rim.
        .background {
            if store.waiting.contains(contact.id) || store.flight(for: contact.id)?.working == true {
                WorkingRim(cornerRadius: 10).padding(.horizontal, -6).padding(.vertical, 1)
            }
        }
        .accessibilityLabel("\(contact.name), \(line)")
    }

    private func rowText(_ name: String, _ line: String, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(Self.rowName)
                .foregroundStyle(selected ? NativeAgentShell.text : NativeAgentShell.text.opacity(0.88))
            Text(line)
                .font(Self.rowLine)
                .foregroundStyle(NativeAgentShell.secondary)
        }
        .lineLimit(1)
    }

    /// "Daily at 09:00 · last ran 2 hr. ago", or "Paused".
    static func timing(_ helper: BotsShelfRecord, now: Date = Date()) -> String {
        if helper.definition.paused { return "Paused" }
        guard let last = helper.entries.map(\.runAt).max() else { return helper.cadence }
        let ago = RelativeDateTimeFormatter()
        ago.unitsStyle = .short
        return helper.cadence + " · last ran " + ago.localizedString(for: last, relativeTo: max(now, last))
    }

    private func lastLine(_ contact: SimpleContact) -> String {
        let word = contact.status(flight: store.flight(for: contact.id),
            waiting: store.waiting.contains(contact.id), delivery: store.status[contact.id])
        let latest = contact.latestLine(in: store.lines[contact.id] ?? [])
        guard let last = latest else {
            return word ?? (contact.lastActivityAt == nil ? "No messages yet" : "No retained messages")
        }
        // When the thread last moved, never a quote: a reply of "ok" or a
        // probe's output reads like a status and is not one. The words are in the thread.
        let ago = RelativeDateTimeFormatter()
        ago.unitsStyle = .short
        let when = (last.fromAgent ? "sent " : "replied ") + ago.localizedString(for: last.at, relativeTo: max(Date(), last.at))
        return word.map { "\($0) · \(when)" } ?? when.prefix(1).uppercased() + when.dropFirst()
    }

    /// A section's word, and one line saying what lives there, so a stranger
    /// can tell agents from helpers (Agent's crew review, User 09-23).
    private func sectionTitle(_ title: String, _ line: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(ShellType.captionSemibold)
                .foregroundStyle(NativeAgentShell.tertiary)
                .accessibilityAddTraits(.isHeader)
            Text(line)
                .font(ShellType.caption)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(Self.rowLine)
            .foregroundStyle(NativeAgentShell.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
            .selectionDisabled()
    }

    private func row<Content: View>(_ target: SimpleShellView.Pane,
                                    @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 44)
            .tag(target)
    }
}

/// The agent at the top of the sidebar, the sidebar's one glass piece
/// (Sidebar C): name, a breathing orb in the haze colour, and what the agent
/// is doing now, never a quote of what it said. The card shimmers for her
/// whole turn (ThinkingGlow); the transcript's live line narrates the steps.
/// Its own view so the turn-state reads stay out of the rest of the sidebar.
private struct SimpleAgentCard: View {
    let selected: Bool
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var activeState

    static let radius: CGFloat = 14

    /// The mockup's serif title: the one name in the window with presence.
    static let nameFont = Font.system(size: 28, weight: .semibold, design: .serif)

    /// "Working · with Codex" while she works with another agent, else
    /// "Thinking…" / "Replying…" while a turn runs; "Waiting on you" (the
    /// teal, its one job) while the Desk's Needs you holds anything;
    /// otherwise "Here". Never her steps: the live line has those.
    private var doing: (text: String, waiting: Bool) {
        if appModel.isBusy || appModel.isChatStreaming,
           let presentation = appModel.engine.turns.lifecycle(for: appModel.activeChatSessionId)?.presentation,
           !presentation.isTerminal, presentation.phase == .delegation,
           let partner = presentation.delegateName, !partner.isEmpty {
            return ("Working · with \(partner)", false)
        }
        if appModel.engine.turns.isThinkingBeforeReply(for: appModel.activeChatSessionId) { return ("Thinking…", false) }
        if appModel.isBusy || appModel.isChatStreaming { return ("Replying…", false) }
        return (appModel.ownerWaitingCount ?? 0) > 0 ? ("Waiting on you", true) : ("Here", false)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.radius, style: .continuous) }

    var body: some View {
        let name = AgentVoice(name: appModel.agentDisplayName).name
        let line = doing
        // The rim while the reply streams; before it, the plate shimmers.
        let replying = (appModel.isBusy || appModel.isChatStreaming) && !appModel.engine.turns.isThinkingBeforeReply(for: appModel.activeChatSessionId)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                SimpleBreathingOrb(replying: replying)
                Text(name)
                    .font(Self.nameFont)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if line.waiting {
                    Circle().fill(NativeAgentShell.needsYou).frame(width: 7, height: 7)
                }
                Text(line.text)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background { shape.fill(selected ? NativeAgentShell.softFill : .clear) }
        .background { ThinkingGlow(kind: .shimmer, cornerRadius: Self.radius, wholeTurn: true) }
        .glassEffect(reduceTransparency ? .identity : HouseGlass.plate, in: shape)
        // A background window loses the glass's own rim; the hairline keeps
        // the card's edge there.
        .overlay {
            if activeState == .inactive || reduceTransparency {
                shape.strokeBorder(NativeAgentShell.hairline, lineWidth: 1).allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name). \(line.text)")
        .accessibilityHint("Opens the chat with \(name)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A small disc in the haze colour that breathes. Still under Reduce Motion.
/// Core Animation, not a SwiftUI repeatForever: a SwiftUI loop wakes the main
/// thread every frame and re-evaluates the window's tree, which pinned Simple
/// view at 12% idle and 100% while a long reply streamed (2026-09-23 soak).
private struct SimpleBreathingOrb: View {
    var replying = false
    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BreathingOrbLayer(haze: HazeColor(stored: colorRaw), still: reduceMotion)
            .frame(width: 22, height: 22)
            // Round the 14pt disc with a 2pt gap.
            .overlay { if replying { WorkingRim(cornerRadius: 8).frame(width: 16, height: 16) } }
            .padding(-4)
            .accessibilityHidden(true)
    }
}

private struct BreathingOrbLayer: NSViewRepresentable {
    var haze: HazeColor
    var still: Bool

    func makeNSView(context: Context) -> OrbView { OrbView() }
    func updateNSView(_ view: OrbView, context: Context) { view.apply(haze: haze, still: still) }

    final class OrbView: NSView {
        private let disc = CAGradientLayer()
        private var applied: (HazeColor, Bool)?

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            disc.type = .radial
            disc.startPoint = CGPoint(x: 0.35, y: 0.7)
            disc.endPoint = CGPoint(x: 1.1, y: -0.1)
            disc.shadowRadius = 5
            disc.shadowOffset = .zero
            layer?.addSublayer(disc)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let side: CGFloat = 14
            disc.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
            disc.cornerRadius = side / 2
            CATransaction.commit()
        }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }

        func apply(haze: HazeColor, still: Bool) {
            if let applied, applied.0 == haze, applied.1 == still { return }
            applied = (haze, still)
            let base = NSColor(haze.base), light = NSColor(haze.edgeLight)
            disc.colors = [light.cgColor, base.cgColor]
            disc.shadowColor = base.cgColor
            disc.removeAllAnimations()
            disc.shadowOpacity = 0.45
            guard !still else { return }
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.92; scale.toValue = 1.08
            let glow = CABasicAnimation(keyPath: "shadowOpacity")
            glow.fromValue = 0.35; glow.toValue = 0.7
            let group = CAAnimationGroup()
            group.animations = [scale, glow]
            group.duration = 2.8
            group.autoreverses = true
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            group.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 24)
            disc.add(group, forKey: "breathe")
        }
    }
}

/// The contact's app icon in a circle, or its initial on a tint of its own.
struct SimpleAvatar: View {
    @Environment(AppModel.self) private var appModel
    let contact: SimpleContact
    var size: CGFloat = 30

    /// Eight hues 45° apart (OKLCH h 25…340, L 0.53, C 0.075): one muted
    /// lightness, so no slot is louder than another, each ≥5.09:1 under a
    /// white initial. Adjacent slots are a full eighth of the wheel apart.
    nonisolated private static let tints: [UInt32] = [0x925A56, 0x886439, 0x6A713C, 0x42795D, 0x2B7880, 0x496F96, 0x6F6393, 0x895A79]
    nonisolated static var slotCount: Int { tints.count }

    @State private var loadedIcon: NSImage?


    private var tint: Color {
        let index = appModel.engine.contactThreads.contacts.filter { $0.appBundleID == nil }
            .sorted { $0.id < $1.id }.firstIndex { $0.id == contact.id } ?? 0
        let rgb = Self.tints[index * 3 % Self.slotCount]
        return Color(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    var body: some View {
        Group {
            if contact.clawd {
                ClawdMark(size: size)
            } else if let icon = loadedIcon {
                // The icon's squircle fills the circle; its transparent margin falls outside.
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit().scaleEffect(1.24)
            } else {
                tint.overlay {
                    Text(contact.initial)
                        .font(.system(size: size * 0.46, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(NativeAgentShell.hairline, lineWidth: 0.5) }
        // A small window on the desktop app's corner: this contact is the app itself.
        .overlay(alignment: .bottomTrailing) {
            if contact.link == .desktopApp {
                Image(systemName: "macwindow")
                    .font(.system(size: size * 0.24, weight: .semibold))
                    .foregroundStyle(NativeAgentShell.text)
                    .frame(width: size * 0.44, height: size * 0.44)
                    .background(Circle().fill(NativeAgentShell.room))
                    .overlay { Circle().strokeBorder(NativeAgentShell.hairline, lineWidth: 0.5) }
                    .offset(x: size * 0.08, y: size * 0.08)
            }
        }
        .accessibilityHidden(true)
        .task(id: contact) {
            guard let bundleID = contact.appBundleID else { loadedIcon = nil; return }
            let icon = await Task.detached(priority: .utility) {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
            }.value
            if !Task.isCancelled { loadedIcon = icon }
        }
    }
}

/// Clawd, Claude Code's little pixel mascot, on a dark disc: body, two eye
/// holes, arms and four legs on a 9×5 grid of square blocks, each snapped to
/// whole device pixels so he stays crisp at sidebar size.
struct ClawdMark: View {
    var size: CGFloat
    @Environment(\.displayScale) private var displayScale
    private static let rows = [
        " ####### ",
        " # ### # ",
        "#########",
        " ####### ",
        " # # # # ",
    ]

    var body: some View {
        Canvas { context, canvas in
            let scale = max(displayScale, 1)
            let pixel = max(1, (canvas.width * 0.9 / 9 * scale).rounded(.down)) / scale
            let origin = CGPoint(x: ((canvas.width - pixel * 9) / 2 * scale).rounded() / scale,
                                 y: ((canvas.height - pixel * 5) / 2 * scale).rounded() / scale)
            for (y, row) in Self.rows.enumerated() {
                for (x, cell) in row.enumerated() where cell == "#" {
                    let rect = CGRect(x: origin.x + CGFloat(x) * pixel, y: origin.y + CGFloat(y) * pixel,
                                      width: pixel, height: pixel)
                    context.fill(Path(rect), with: .color(Color(red: 0.851, green: 0.467, blue: 0.341)))
                }
            }
        }
        .frame(width: size, height: size)
        .background(Color(red: 0.12, green: 0.118, blue: 0.114))
    }
}
