import AppKit
import SwiftUI
import StandingBots
import NativeAgentShared
import Foundation
import EngineRuntime
import Agents
import ChatSessionWork
import AgentWorkspace
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import AppToolRuntime
// Blueprint: | `SimpleSidebar.swift` | Engine contact and helper rows and shared settings |

/// Share preferences with Advanced so changing presentation does not fork settings.
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
            if HazeColor(stored: hazeRaw) == .unavailable {
                Text("Unsupported saved color — choose a color").tag(hazeRaw).disabled(true)
            }
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

    /// Use a filled colour image because menus render template images grey.
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

struct SimpleSidebar: View {
    let store: SimpleViewStore
    @Binding var pane: SimpleShellView.Pane
    var embedded = false
    @Environment(AppModel.self) private var appModel
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.layoutProfile) private var layoutProfile
    @Environment(\.simpleSettingsMenuDrawnOpen) private var settingsMenuDrawnOpen
    @State private var showQuiet = false
    /// Refresh relative times on user activity and owner changes instead of polling.
    @State private var now = Date()

    static let width: CGFloat = 280
    static let sectionGap: CGFloat = 22
    static let rowName = Font.system(size: 14, weight: .medium)
    static let rowLine = Font.system(size: 12)
    private var agentName: String { AgentVoice(name: appModel.agentDisplayName).name }

    var body: some View {
        // Fold untouched contacts after recent ones so active conversations remain reachable.
        let contacts = store.contacts
        let talked = contacts.filter { !isQuiet($0) }
        let unheard = contacts.filter(isQuiet)
        List(selection: Binding<SimpleShellView.Pane?>(get: { pane == .agent && !embedded ? nil : pane },
                                                       set: { if let next = $0 { pane = next } })) {
            ConversationReadNotice(detail: appModel.engine.transcripts.navigationReadIssue)
                .selectionDisabled()
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
            SurfaceLayoutContent(appModel.engine.layout.availability) { layout in
            ForEach(layout.contentNames("home", profile: layoutProfile).filter { ["people", "helpers"].contains($0) },
                    id: \.self) { block in
                if block == "people" { agentsSection(talked: talked, unheard: unheard) } else { helpersSection }
            }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // Inset below the title strip so rows cannot scroll beneath the traffic lights.
        .contentMargins(.top, 12, for: .scrollContent)
        .padding(.top, embedded ? 0 : NativeAgentShellLayout.titleBarInset)
        .scrollIndicators(.never)
        // Use an inset for pinned settings; safeAreaBar stalls this window's main thread.
        .safeAreaInset(edge: .bottom, spacing: 0) { if !embedded { settingsRow } }
        .padding(.leading, embedded ? 0 : NativeAgentShellLayout.railPlateInset)
        .frame(width: Self.width + (embedded ? 0 : NativeAgentShellLayout.railPlateInset))
        .frame(maxHeight: .infinity)
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
            if let error = store.helpersRefreshError { quiet(error) }
            if store.helpersLoaded && store.helpersRefreshError == nil && store.helpers.isEmpty {
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
        } header: {
            sectionTitle("Helpers", "Bots I made that can do real work for you. Talk to any of them here.")
        }
    }

    private var settingsRow: some View {
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
        // Fade beneath pinned settings without making the last row unreachable.
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

    private func isQuiet(_ contact: SimpleContact) -> Bool {
        contact.lastActivityAt == nil && (store.lines[contact.id] ?? []).isEmpty && !store.waiting.contains(contact.id)
            && store.status[contact.id] == nil && store.flight(for: contact.id) == nil && contact.health?.problem == nil
            && contact.owedExperiences.isEmpty
    }

    private func contactRow(_ contact: SimpleContact) -> some View {
        let selected = pane == .contact(contact.id)
        // Lead with the connection so contacts sharing an app icon remain distinguishable.
        let line = [contact.link?.words, lastLine(contact)].compactMap { $0 }.joined(separator: " · ")
        return row(.contact(contact.id)) {
            HStack(spacing: 10) {
                SimpleAvatar(contact: contact, size: 30)
                rowText(contact.name, line, selected: selected)
            }
        }
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
        // Show when the thread moved; a quoted reply or probe output can be mistaken for status.
        let ago = RelativeDateTimeFormatter()
        ago.unitsStyle = .short
        // A line whose time is unreadable still says what moved, without inventing when.
        let when = (last.fromAgent ? "sent" : "replied")
            + (last.at.map { " " + ago.localizedString(for: $0, relativeTo: max(Date(), $0)) } ?? "")
        return word.map { "\($0) · \(when)" } ?? when.prefix(1).uppercased() + when.dropFirst()
    }

    /// Distinguish agents from helpers with both a section title and description.
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
