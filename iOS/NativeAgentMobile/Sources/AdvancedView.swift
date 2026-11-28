import SwiftUI
import Foundation
import NativeAgentShared
// Blueprint: | `AdvancedView.swift` | Agent and Advanced indexes over shared faces, local destinations and native pairing |

enum MoreAboutPresentation {
    static let text = """
        Some advanced controls require a live Mac connection. Skill installs and eval runs are Mac-only today. Desk changes sync with the paired Mac.
        """
}

struct AdvancedView: View {
    let isAgent: Bool
    @Binding var opensMemories: Bool
    @Binding var localDestination: Destination?
    init(isAgent: Bool = false, opensMemories: Binding<Bool> = .constant(false), localDestination: Binding<Destination?>) {
        self.isAgent = isAgent
        _opensMemories = opensMemories
        _localDestination = localDestination
    }
    @Environment(PairingStore.self) private var pairingStore
    @Environment(MacBridgeClient.self) private var bridgeClient
    @State private var showPairingRecovery = false
    @State private var remoteDestination: FaceDestination?
    private let sync = iCloudSyncEngine.shared
    private var session: FacePageSession { sync.pageSessions.page(isAgent ? "phone-agent" : "phone-more") }
    enum Destination: String, Identifiable {
        case settings, graph, turns, tools, diagnostics
        var id: String { rawValue }
    }

    var body: some View {
        AlivePage(title: isAgent ? sync.displayName(fallback: "Agent") : "Advanced", style: isAgent ? .root : .pushed) {
            FaceView(face: isAgent ? agentFace : face, door: door, session: session)
        }
        .refreshable {
            await sync.refreshLightweightSnapshots()
            _ = await sync.refreshFacesSnapshot()
            await sync.refreshSnapshotGroup(.advanced)
        }
        .navigationDestination(isPresented: $opensMemories) { MobileFacePage(page: "memories") }
        .navigationDestination(item: $remoteDestination) { $0.view }
        .navigationDestination(item: $localDestination) { destination in
            switch destination {
            case .settings: SettingsViewFull(presentation: .pushed)
            case .graph: KnowledgeGraphView()
            case .turns: TurnInspectorView()
            case .tools: MacToolsView()
            case .diagnostics: DiagnosticsView()
            }
        }
        .sheet(isPresented: $showPairingRecovery) {
            PairingView(onSkip: { showPairingRecovery = false }, onPaired: { showPairingRecovery = false })
                .environment(pairingStore)
        }
        #if DEBUG
        .onAppear {
            guard !isAgent else { return }
            switch MobileDesignSamples.screen {
            case "settings": localDestination = .settings
            case "mac-tools": localDestination = .tools
            case "graph": localDestination = .graph
            case "turns": localDestination = .turns
            case "status", "diagnostics": localDestination = .diagnostics
            case "pairing": showPairingRecovery = true
            case .some(let page): remoteDestination = FaceDestination("page:" + page)
            case .none: break
            }
        }
        #endif
    }

    private func link(_ id: String, _ title: String, _ detail: String? = nil) -> PartFace.Row {
        .init(id: id, title: title, detail: detail, open: "page:" + id)
    }

    private func localLink(_ destination: Destination, _ title: String, _ detail: String? = nil) -> PartFace.Row {
        let id = "phone.local/" + destination.rawValue
        return .init(id: id, title: title, detail: detail, open: "page:" + id)
    }

    private var agentFace: PartFace {
        let rows = [
            link("home", "Home"), link("memories", "Memories"), localLink(.graph, "Knowledge Graph"),
            link("personality", "Personality"), link("dreams", "Dreams"), link("capabilities", "Capabilities"),
        ]
        let own = sync.faces.keys.sorted().compactMap { id -> PartFace.Row? in
            guard AppDoorNames.ownPageRefusal(id) == nil, let snapshot = sync.faces[id] else { return nil }
            return link(id, snapshot.face?.title.flatMap { $0.isEmpty ? nil : $0 } ?? id, snapshot.face?.line)
        }
        return .init(sections: [.init(id: "agent", rows: rows + own)])
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
                localLink(.settings, "Settings", "This iPhone, the Mac link and every Mac setting")
            ]))
            case "power": sections.append(.init(id: "power", title: "Power user", footer: MoreAboutPresentation.text, rows: [
                localLink(.graph, "Knowledge Graph"), localLink(.turns, "Turn Inspector"),
                localLink(.tools, "Mac Tools"), localLink(.diagnostics, "Diagnostics")
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
            if case .page("phone.local", let id?)? = FaceLink(link), let destination = Destination(rawValue: id) {
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
