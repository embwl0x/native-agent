import SwiftUI
import Foundation
import NativeAgentShared

// Blueprint: | `AgentScreenView.swift` | Read-only Home and room slots with live navigation |

struct AgentScreenView: View {

    @Environment(AppModel.self) private var appModel
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @Binding var room: String
    @State private var feedback: String?
    @State private var activityTarget: ActivityTarget?

    private static let homeWidth: CGFloat = 1040

    private struct ActivityTarget: Identifiable {
        let reference: WorkOverviewReference
        var id: String { reference.kind.rawValue + ":" + reference.id }
    }

    var body: some View {
        let scope = appModel.activeChatSessionId
        SurfaceLayoutContent(appModel.shellLayout) { layout in
        ShellFrame {
            // Use the native sidebar so every room remains reachable within the window.
            List(ShellAgentRooms.names(layout), id: \.self,
                 selection: Binding<String?>(get: { room }, set: { if let next = $0 { room = next } })) { name in
                Text(name).font(ShellType.label)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 12, for: .scrollContent)
            .padding(.top, NativeAgentShellLayout.titleBarInset)
            .frame(width: 200)
            .overlay(alignment: .trailing) {
                Rectangle().fill(NativeAgentShell.hairline).frame(width: 1).allowsHitTesting(false)
            }
            .accessibilityLabel("Rooms")
        } detail: {
            ScrollView {
                if room == "home" {
                    home
                } else {
                    let pane = appModel.face.slot(.agentScreen(room: room, scope: scope)).value(as: AgentScreenFace.self)
                    VStack(alignment: .leading, spacing: 10) {
                        FaceReadStatus(state: pane?.state)
                        if let text = pane?.text {
                            Text(text)
                                .font(ShellType.scaled(ShellType.captionSize, design: .monospaced))
                                .foregroundStyle(NativeAgentShell.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(AliveMetrics.rowInsetH)
                                .macContentCard()
                        }
                    }
                    .padding(.horizontal, AliveMetrics.rowInsetH)
                    .padding(.top, 12)
                    .padding(.bottom, AliveMetrics.rowInsetH)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .scrollEdgeEffectStyle(quietOffscreenRead ? nil : .soft, for: .top)
            .padding(.top, NativeAgentShellLayout.titleBarInset)
        }
        .modifier(FaceObservation(demand: room == "home" ? .key(.page("home")) : .agentScreen(room: room, scope: scope)))
        .sheet(item: $activityTarget) { target in
            MacWorkOverviewDetail(reference: target.reference) { activityTarget = nil }
        }
        .onDisappear { room = "home" }
        }
    }

    @ViewBuilder private var home: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
            if let snapshot = appModel.face.slot(.page("home")).value(as: PartFaceSnapshot.self) {
                FaceView(snapshot: snapshot, title: "Home", door: homeDoor,
                         session: appModel.pageSessions.page("home"), leaf: { FacePageView.leaf($0) })
            } else { Text("Waiting on Home's face.") }
            if let feedback { Text(feedback).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .padding(.horizontal, AliveMetrics.rowInsetH)
        .padding(.top, 12)
        .padding(.bottom, AliveMetrics.rowInsetH)
        .frame(maxWidth: Self.homeWidth, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var homeDoor: any FaceDoor {
        if quietOffscreenRead { return ReadOnlyFaceDoor() }
        return ReadOnlyFaceDoor(open: open)
    }

    private func open(_ link: String) {
        feedback = nil
        Task {
            do {
                _ = try await MacFaceLinks.follow(link, appModel: appModel, here: { page, item in
                    guard page == "home", let item else { return false }
                    room = item
                    return true
                }) { activityTarget = ActivityTarget(reference: $0) }
            } catch { feedback = error.localizedDescription }
        }
    }
}

enum ShellAgentRooms {
    static func names(_ layout: SurfaceLayoutAvailability) -> [String] {
        var names = ["home"]
        for name in (layout.contentNames("places", profile: ShellViewMode.agent)
                     + ["people", "helpers", "mac", "conversations", "windows", "arrivals", "work"]).map(AppDoorNames.resolve)
            where !names.contains(name) { names.append(name) }
        return names
    }
}
