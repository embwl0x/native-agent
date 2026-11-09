import Foundation
import AppKit
import SwiftUI
import NativeAgentShared
// Blueprint: | `SimpleSidebar.swift` | Selected contacts, helpers, layout and shared face preferences |

/// Share preferences with Advanced so changing presentation does not fork settings.
private struct SimpleSettingsMenuItems: View {
    @Environment(AppModel.self) private var appModel
    @FacePreference("uiMoodTint") private var warmth = true
    @FacePreference(HazeColor.key) private var hazeRaw = HazeColor.defaultValue.rawValue
    @Environment(\.colorScheme) private var scheme
    private var availableUpdateVersion: String? {
        appModel.face.slot(.settings).select("updates.availableVersion", as: SettingsFace.self) { $0?.updates?.source.availableVersion }
    }

    var body: some View {
        FacePreferences(keys: ["uiMoodTint", HazeColor.key]) { preferenceContent }
    }

    @ViewBuilder private var preferenceContent: some View {
        if let version = availableUpdateVersion {
            Button("Install version \(version)", systemImage: "arrow.down.circle") {
                Task {
                    do { try await appModel.client.act(.requestUpdate(.showAvailableUpdate)).checkedAcknowledgement() }
                    catch { appModel.systemToasts.push(error: error.localizedDescription) }
                }
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
            SettingsLink.open(.settings)
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
    @Binding var pane: SimpleShellView.Pane
    @Environment(AppModel.self) private var appModel
    @Environment(\.layoutProfile) private var layoutProfile
    @Environment(\.simpleSettingsMenuDrawnOpen) private var settingsMenuDrawnOpen
    private var contacts: FaceSlot { appModel.face.slot(.contacts) }
    private var helpers: FaceSlot { appModel.face.slot(.helpers) }
    static let width: CGFloat = 280

    var body: some View {
        List(selection: Binding<SimpleShellView.Pane?>(get: { pane == .agent ? nil : pane },
            set: { if let value = $0 { pane = value } })) {
            Button { pane = .agent } label: { SimpleAgentCard(selected: pane == .agent).contentShape(Rectangle()) }
                .buttonStyle(.plain).selectionDisabled().padding(.bottom, 22)
            if let layout = appModel.face.slot(.layout).select("availability", as: LayoutFace.self, { $0?.availability }) {
                SurfaceLayoutContent(layout) { availability in
                    ForEach(availability.contentNames("home", profile: layoutProfile), id: \.self) { block in
                        if block == "people" { contactsSection }
                        if block == "helpers" { helpersSection }
                    }
                }
            } else { ProgressView("Waiting on the layout…") }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 12, for: .scrollContent)
        .padding(.top, NativeAgentShellLayout.titleBarInset)
        .safeAreaInset(edge: .bottom, spacing: 0) { settingsRow }
        .padding(.leading, NativeAgentShellLayout.railPlateInset)
        .frame(width: Self.width + NativeAgentShellLayout.railPlateInset)
        .frame(maxHeight: .infinity)
        .faceObservation(.key(.layout))
    }

    private var contactsSection: some View {
        Section("Agents") {
            FaceReadStatus(state: contacts.select("state", as: ContactsFace.self) { $0?.state })
            let ids = contacts.select("ids", as: ContactsFace.self) { $0?.contacts.map(\.id) ?? [] }
            ForEach(ids, id: \.self) { id in
                if let contact = contacts.select("contact." + id, as: ContactsFace.self, { $0?.contacts.first { $0.id == id } }) {
                    HStack(spacing: 10) {
                        SimpleAvatar(contact: contact)
                        VStack(alignment: .leading) {
                            Text(contact.label).font(.system(size: 14, weight: .medium))
                            FaceReadStatus(state: contact.state).font(.caption)
                        }
                    }.frame(height: 44).tag(SimpleShellView.Pane.contact(id))
                }
            }
            if ids.isEmpty, contacts.select("state", as: ContactsFace.self, { $0?.state }) == .ready {
                Text("None connected yet.").foregroundStyle(.secondary)
            }
        }
    }

    private var helpersSection: some View {
        Section("Helpers") {
            FaceReadStatus(state: helpers.select("state", as: HelpersFace.self) { $0?.state })
            let ids = helpers.select("ids", as: HelpersFace.self) { $0?.rows.map(\.id) ?? [] }
            ForEach(ids, id: \.self) { id in
                if let helper = helpers.select("helper." + id, as: HelpersFace.self, { $0?.rows.first { $0.id == id } }) {
                    let working = helpers.select("working." + id, as: HelpersFace.self) {
                        $0?.runningIDs.contains(id) == true || $0?.waitingIDs.contains(id) == true
                    }
                    HStack(spacing: 10) {
                        SimpleClockTile(working: working)
                        FaceView(face: PartFace(sections: [.init(id: "helper", rows: [helper])]), door: ReadOnlyFaceDoor(),
                            session: FacePageSession(), retaining: false)
                    }.frame(minHeight: 44).tag(SimpleShellView.Pane.helper(id))
                }
            }
            if ids.isEmpty, helpers.select("state", as: HelpersFace.self, { $0?.state }) == .ready {
                Text("None yet.").foregroundStyle(.secondary)
            }
        }
    }

    private var settingsRow: some View {
        Menu { SimpleSettingsMenuItems() } label: { Label("Settings", systemImage: "gearshape") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) {
                if settingsMenuDrawnOpen {
                    VStack(alignment: .leading, spacing: 8) { SimpleSettingsMenuItems() }
                        .padding(12).frame(width: 260).background(NativeAgentShell.room)
                        .offset(y: -48).allowsHitTesting(false)
                }
            }
    }
}
