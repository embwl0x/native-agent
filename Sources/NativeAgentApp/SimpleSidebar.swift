import AppKit
import SwiftUI
import StandingBots
import NativeAgentShared
import Foundation
import EngineRuntime
import SwarmRuns
import Agents
import ChatSessionWork
import AgentWorkspace
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import AppToolRuntime
// Blueprint: | `SimpleSidebar.swift` | Shared contact/helper/crew sidebar and Simple settings menu retain engine projections and native navigation |

/// Settings shares update, colour, warmth and view-mode preferences with Advanced.
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
            _ = ApplicationLifetime.shared.request(.sidebar(.settings))
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

/// Home-ordered agent and helper rows share the room, separated by a hairline.
/// Advanced replaces the agent card with Connections and omits Simple settings.
struct SimpleSidebar: View {
    let store: SimpleViewStore
    @Binding var pane: SimpleShellView.Pane
    var embedded = false
    @Environment(AppModel.self) private var appModel
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.layoutProfile) private var layoutProfile
    @Environment(\.simpleSettingsMenuDrawnOpen) private var settingsMenuDrawnOpen
    @State private var showQuiet = false
    @State private var showCrews = false
    /// Relative times refresh on appearance, activation, helper changes and hover.
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
        // Native selection, keys and folds; the home card uses its own quiet wash.
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
        // Use an inset for pinned settings; safeAreaBar stalls this window's main thread.
        .safeAreaInset(edge: .bottom, spacing: 0) { if !embedded { settingsRow } }
        .padding(.leading, embedded ? 0 : NativeAgentShellLayout.railPlateInset)
        .frame(width: Self.width + (embedded ? 0 : NativeAgentShellLayout.railPlateInset))
        .frame(maxHeight: .infinity)
        // One hairline parts the sidebar from chat; only the agent card uses glass.
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

    /// The gear opens settings upward from the sidebar's foot.
    private var settingsRow: some View {
        // Native settings menu.
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
        // Fade rows under settings over 16pt while keeping the last row scrollable.
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
        .overlay(alignment: .bottomLeading) {
            if settingsMenuDrawnOpen {
                VStack(alignment: .leading, spacing: 8) {
                    SimpleSettingsMenuItems()
                }
                .buttonStyle(.plain)
                .padding(12)
                .frame(width: 260, alignment: .leading)
                .background(NativeAgentShell.room, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(NativeAgentShell.hairline) }
                .offset(y: -48)
                .allowsHitTesting(false)
            }
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

    /// A section title and description distinguish agents from helpers.
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
