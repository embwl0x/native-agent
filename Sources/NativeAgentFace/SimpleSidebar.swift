import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `SimpleSidebar.swift` | The agent's card, the places, and the folded Agents and Helpers lists in the layout's order |

struct SimpleSidebar: View {
    @Binding var pane: SimpleShellView.Pane
    /// The page the window shows.
    let shown: ShellRailRow
    let choose: (ShellSurface, [ShellRailRow]) -> Void
    let select: (ShellRailRow) -> Void
    @Environment(AppModel.self) private var appModel
    @Environment(\.layoutProfile) private var layoutProfile
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One identity preserves the bar's continuity between place rows.
    @Namespace private var selectionBar
    /// Whether each list is open: this window's state, closed when Simple opens.
    @State private var agentsOpen = false
    @State private var helpersOpen = false
    private var contacts: FaceSlot { appModel.face.slot(.contacts) }
    private var helpers: FaceSlot { appModel.face.slot(.helpers) }
    static let width: CGFloat = 280
    private var availableUpdateVersion: String? {
        appModel.face.slot(.settings).select("updates.availableVersion", as: SettingsFace.self) { $0?.updates?.source.availableVersion }
    }

    private var inChat: Bool { shown == .item(.chat) }
    /// The place whose row carries the bar: the shown page's, except while an agent's or helper's thread is open over Chat.
    private var selectedPlace: ShellSurface? { inChat && pane != .agent ? nil : shown.surface }

    var body: some View {
        List(selection: Binding<SimpleShellView.Pane?>(get: { inChat && pane != .agent ? pane : nil },
            set: { if let value = $0 { showInChat(value) } })) {
            Button { showInChat(.agent) } label: { SimpleAgentCard(selected: inChat && pane == .agent).contentShape(Rectangle()) }
                .buttonStyle(.plain).selectionDisabled().padding(.bottom, 22)
            if let layout = appModel.face.slot(.layout).select("availability", as: LayoutFace.self, { $0?.availability }) {
                SurfaceLayoutContent(layout) { availability in
                    placeRows(ShellSurface.shown(availability, profile: layoutProfile).filter { $0.surface != .diagnostics })
                    ForEach(availability.contentNames("home", profile: layoutProfile), id: \.self) { block in
                        if block == "people" { contactsList }
                        if block == "helpers" { helpersList }
                    }
                }
            } else { ProgressView("Waiting on the layout…") }
            if let version = availableUpdateVersion {
                Button("Install version \(version)", systemImage: "arrow.down.circle") {
                    Task {
                        do { try await appModel.client.act(.requestUpdate(.showAvailableUpdate)).checkedAcknowledgement() }
                        catch { appModel.systemToasts.push(error: error.localizedDescription) }
                    }
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).selectionDisabled().listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 12, for: .scrollContent)
        .padding(.top, NativeAgentShellLayout.titleBarInset)
        .padding(.leading, NativeAgentShellLayout.railPlateInset)
        .frame(width: Self.width + NativeAgentShellLayout.railPlateInset)
        .frame(maxHeight: .infinity)
        .faceObservation(.key(.layout))
    }

    /// Show Chat on the conversation, or on an agent's or helper's thread.
    private func showInChat(_ next: SimpleShellView.Pane) {
        pane = next
        if !inChat { select(.item(.chat)) }
    }

    /// The places as Advanced's rail draws them: one row each, the bar on the place shown.
    private func placeRows(_ places: [ShellSurfacePages]) -> some View {
        VStack(spacing: 4) {
            ForEach(places) { place in
                ShellPlaceRow(place: place, isSelected: place.surface == selectedPlace, barNamespace: selectionBar) {
                    pane = .agent
                    choose(place.surface, place.pages)
                }
            }
        }
        // Animate the rows in one transaction so departing and arriving bars stay in sync.
        .animation(NativeAgentMotion.respecting(NativeAgentMotion.standard, reduceMotion: reduceMotion), value: selectedPlace)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .selectionDisabled()
        .padding(.bottom, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Places")
    }

    @ViewBuilder private var contactsList: some View {
        let state = contacts.select("state", as: ContactsFace.self) { $0?.state }
        let ids = contacts.select("ids", as: ContactsFace.self) { $0?.contacts.map(\.id) ?? [] }
        let needsYou = contacts.select("needsYou", as: ContactsFace.self) { $0?.contacts.contains(where: \.needsYou) == true }
        SimpleFoldLine(title: "Agents", count: state == .ready ? ids.count : nil, needsYou: needsYou, isOpen: $agentsOpen)
        if agentsOpen {
            FaceReadStatus(state: state)
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
            if ids.isEmpty, state == .ready {
                Text("None connected yet.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var helpersList: some View {
        let state = helpers.select("state", as: HelpersFace.self) { $0?.state }
        let ids = helpers.select("ids", as: HelpersFace.self) { $0?.rows.map(\.id) ?? [] }
        let needsYou = helpers.select("needsYou", as: HelpersFace.self) { $0?.needsYouIDs.isEmpty == false }
        SimpleFoldLine(title: "Helpers", count: state == .ready ? ids.count : nil, needsYou: needsYou, isOpen: $helpersOpen)
        if helpersOpen {
            FaceReadStatus(state: state)
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
            if ids.isEmpty, state == .ready {
                Text("None yet.").foregroundStyle(.secondary)
            }
        }
    }
}

/// A list's folding line: a chevron, the list's word and its count once read; closed, it carries the waiting-on-you dot when something in
/// the list waits on the person.
private struct SimpleFoldLine: View {
    let title: String
    /// Nil while the list is unread or unreadable; the open list shows why.
    let count: Int?
    let needsYou: Bool
    @Binding var isOpen: Bool

    var body: some View {
        let waiting = needsYou && !isOpen
        Button { isOpen.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(ShellType.captionSemibold)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .accessibilityHidden(true)
                Text(title).font(ShellType.labelSemibold).foregroundStyle(NativeAgentShell.secondary)
                if let count {
                    Text("\(count)").font(ShellType.caption).foregroundStyle(NativeAgentShell.tertiary).monospacedDigit()
                }
                if waiting {
                    Circle().fill(NativeAgentShell.needsYou).frame(width: 6, height: 6).accessibilityHidden(true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .selectionDisabled()
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        .accessibilityValue(isOpen ? "open" : waiting ? "closed, waiting for you" : "closed")
        .accessibilityIdentifier("simple.fold.\(title.lowercased())")
    }
}
