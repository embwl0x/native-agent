import SwiftUI
import ChatTurnRuntime
import AppToolRuntime
import AuthoredCapabilities
import NativeAgentShared

// Blueprint: | `AgentScreenView.swift` | Agent Home draws the shared face; other rooms retain read-only text, and explicit Home row acts reach engine.pages |

/// Arrival never marks seen or dispatches a tool. A person's explicit row action reaches its owner through the page port.
struct AgentScreenView: View {
    private struct Watch: Equatable { let scope: String; let room: String }

    @Environment(AppModel.self) private var appModel
    @Binding var room: String
    @State private var feedback: String?
    @State private var activityTarget: ActivityTarget?

    private struct ActivityTarget: Identifiable {
        let reference: WorkOverviewReference
        var id: String { reference.kind.rawValue + ":" + reference.id }
    }

    var body: some View {
        let scope = appModel.activeChatSessionId
        SurfaceLayoutContent(appModel.engine.layout.availability) { layout in
        ShellFrame {
            // Use the native sidebar so every room remains reachable within the window.
            List(AgentScreenPreview.tabs(layout, profile: SimpleViewMode.agent), id: \.self,
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
            VStack(alignment: .leading, spacing: 10) {
                ScrollView {
                    if room == "home" {
                        home
                    } else {
                        Text(appModel.engine.turns.agentScreenPanes[scope]?[room] ?? "")
                        .font(.system(size: ShellType.captionSize, design: .monospaced))
                        .foregroundStyle(NativeAgentShell.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(AliveMetrics.rowInsetH)
                    }
                }
                .aliveCard()
            }
            .padding(.top, 36)
            .padding([.horizontal, .bottom], 20)
        }
        .task(id: Watch(scope: scope, room: room)) {
            if room == "home" { await appModel.engine.pages.refresh(page: "home") }
            else { await appModel.engine.turns.observeAgentScreen(room: room, scope: scope) }
        }
        .sheet(item: $activityTarget) { target in
            MacWorkOverviewDetail(reference: target.reference) { activityTarget = nil }
        }
        .onDisappear { room = "home" }
        }
    }

    @ViewBuilder private var home: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
            if let snapshot = appModel.engine.pages.snapshots["home"] {
                if snapshot.status == .ready, let face = snapshot.face {
                    FaceView(face: face, open: open, act: act)
                } else {
                    Text(snapshot.error?.message ?? "Home returned no readable face.").textSelection(.enabled)
                }
            } else { Text("Home has not published a face.") }
            if let feedback { Text(feedback).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .padding(AliveMetrics.rowInsetH)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func act(_ row: String, _ action: String, _ value: String?) {
        feedback = nil
        Task {
            do { feedback = try await appModel.engine.pages.act(page: "home", row: row, action: action, value: value, by: .person(door: "mac")) }
            catch { feedback = error.localizedDescription }
        }
    }

    private func open(_ link: String) {
        feedback = nil
        Task {
            do { try await follow(link) }
            catch { feedback = error.localizedDescription }
        }
    }

    private func follow(_ link: String) async throws {
        guard PartFace.isLink(link), let colon = link.firstIndex(of: ":") else {
            throw PartCallError(code: "bad_link", message: "This Home row has no supported destination.")
        }
        let kind = String(link[..<colon]), target = String(link[link.index(after: colon)...])
        switch kind {
        case "page":
            let parts = target.split(separator: "/", maxSplits: 1).map(String.init)
            if parts[0] == "home", parts.count == 2 { room = parts[1] }
            else {
                let result = await QuietComposerCommands.setPage(parts[0], item: parts.count == 2 ? parts[1] : "", appModel: appModel)
                if let refusal = result.refusal { feedback = refusal.detail }
            }
        case "chat":
            await appModel.refreshChatSessionIndex()
            guard let session = appModel.engine.transcripts.sessions.first(where: { $0.id == target }) else {
                throw PartCallError(code: "conversation_unavailable", message: "This conversation is not in the readable session index.")
            }
            await appModel.selectChatSession(session)
            guard appModel.activeChatSessionId == target else {
                throw PartCallError(code: "conversation_unavailable", message: appModel.statusText)
            }
            ApplicationLifetime.shared.request(.sidebar(.chat))
        case "approval", "card":
            activityTarget = ActivityTarget(reference: .init(kind: kind == "approval" ? .approval : .inbox, id: target))
        default:
            throw PartCallError(code: "bad_link", message: "This Home row has no supported destination.")
        }
    }
}
