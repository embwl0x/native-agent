import SwiftUI
import Foundation
import NativeAgentShared
// Blueprint: | `AdvancedView.swift` | Shared More rows over the Mac layout, local destinations and native pairing |

enum MoreAboutPresentation {
    static let text = """
        Some advanced controls require a live Mac connection. Skill installs and eval runs are Mac-only today. Desk changes sync with the paired Mac.
        """
}

struct AdvancedView: View {
    @Binding var opensMemories: Bool
    init(opensMemories: Binding<Bool> = .constant(false)) { _opensMemories = opensMemories }
    @EnvironmentObject private var pairingStore: PairingStore
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @State private var showPairingRecovery = false
    @State private var localDestination: Destination?
    @State private var remoteDestination: FaceDestination?
    private let sync = iCloudSyncEngine.shared
    private var session: FacePageSession { sync.pageSessions.page("phone-more") }
    private enum Destination: String, Identifiable {
        case settings, graph, turns, tools, diagnostics
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            AlivePage(title: "More", line: "Rooms, settings and tools.", style: .root) {
                FaceView(face: face, door: door, session: session)
            }
            .navigationDestination(isPresented: $opensMemories) { MobileFacePage(page: "memories") }
            .navigationDestination(item: $remoteDestination) { $0.view }
            .navigationDestination(item: $localDestination) { destination in
                switch destination {
                case .settings: SettingsViewFull()
                case .graph: KnowledgeGraphView()
                case .turns: TurnInspectorView()
                case .tools: MacToolsView()
                case .diagnostics: DiagnosticsView()
                }
            }
            .sheet(isPresented: $showPairingRecovery) {
                PairingView(onSkip: { showPairingRecovery = false }, onPaired: { showPairingRecovery = false })
                    .environmentObject(pairingStore)
            }
            #if DEBUG
            .onAppear {
                switch MobileDesignSamples.screen {
                case "settings": localDestination = .settings
                case "mac-tools": localDestination = .tools
                case "graph": localDestination = .graph
                case "turns": localDestination = .turns
                case "status": localDestination = .diagnostics
                case "pairing": showPairingRecovery = true
                case .some(let page): remoteDestination = FaceDestination("page:" + page)
                case .none: break
                }
            }
            #endif
        }
        .macSyncErrorBanner()
    }

    private func link(_ id: String, _ title: String, _ detail: String? = nil, local: Bool = false) -> PartFace.Row {
        .init(id: id, title: title, detail: detail, open: "page:" + (local ? "phone-" : "") + id)
    }

    private var face: PartFace {
        var sections: [PartFace.Section] = []
        if !bridgeClient.connection.holds {
            sections.append(.init(id: "connection", title: "Connection", rows: [
                .init(id: "pair", title: AliveConnection.line(bridgeClient.connection), detail: bridgeClient.connection.headline.lever
                    ?? "Open Settings to repair this iPhone’s connection, or pair with your Mac again.",
                    actions: [.init(id: "pair", label: "Pair with Mac", call: .init("phone.pair"))])
            ]))
        }
        if sync.surfaceLayout?.value != nil, let failure = sync.snapshotHealth.damageSentence(for: ["ui_layout.json"]) {
            sections.append(.init(id: "layout-issue", rows: [.init(id: "cause", title: "Showing the last received Mac layout.", detail: failure)]))
        }
        guard let layout = sync.surfaceLayout?.value else {
            let failure = sync.surfaceLayout?.failure?.localizedDescription
                ?? sync.snapshotHealth.damageSentence(for: ["ui_layout.json"]) ?? "The Mac layout has not arrived."
            sections.append(.init(id: "layout", title: "Layout unavailable", footer: "Keep NativeAgent open on the paired Mac, then refresh.",
                rows: [.init(id: "cause", title: failure)]))
            return .init(sections: sections)
        }
        for block in layout.shown("more", profile: layout.phone).map(\.name) {
            switch block {
            case "rooms":
                sections.append(.init(id: "rooms", title: "Rooms", rows: [
                    link("home", sync.agentDisplayName, "My home: what I'm doing and what waits on you"),
                    link("memories", "Memories", "What I remember"), link("bots", "Helpers", "Run and manage helpers"),
                    link("capabilities", "Capabilities", "What I can do, and what's installed"),
                    link("personality", "Personality", "How I think and sound"),
                    link("connectors", "Connectors", "The services I can reach"), link("trust", "Trust", "What I may do on my own")
                ]))
            case "setup": sections.append(.init(id: "setup", title: "Setup", rows: [
                link("settings", "Settings", "This iPhone, the Mac link and every Mac setting", local: true)
            ]))
            case "power": sections.append(.init(id: "power", title: "Power user", footer: MoreAboutPresentation.text, rows: [
                link("graph", "Knowledge Graph", local: true), link("turns", "Turn Inspector", local: true),
                link("tools", "Mac Tools", local: true), link("diagnostics", "Diagnostics", local: true)
            ]))
            default:
                if let page = SurfaceLayout.ownPage("more", block), let snapshot = sync.faces[page] {
                    sections.append(.init(id: block, rows: [link(page,
                        snapshot.face?.title.flatMap { $0.isEmpty ? nil : $0 } ?? page, snapshot.face?.line)]))
                }
            }
        }
        return .init(sections: sections)
    }

    private var door: ClosureFaceDoor {
        ClosureFaceDoor(open: { link in
            if link.hasPrefix("page:phone-"), let destination = Destination(rawValue: String(link.dropFirst("page:phone-".count))) {
                localDestination = destination
            } else if let destination = FaceDestination(link) { remoteDestination = destination }
            else { SystemToastCenter.shared.push(info: "This page has not arrived from your Mac.") }
        }) { submission in
            guard !submission.checking, submission.expectedCall.action == "phone.pair" else {
                return .init(effects: .unknown)
            }
            showPairingRecovery = true
            return .init(effects: .none, accepted: true)
        }
    }
}
