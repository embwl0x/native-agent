import SwiftUI
import EngineRuntime
import SwarmRuns
import AppKit
import AppToolRuntime
import Agents
import NativeAgentCore
import StandingBots
import NativeAgentShared
// Blueprint: | `SimpleShellView.swift` | Simple and Advanced shells select the engine's shared contact, helper and crew threads |

typealias SimpleContact = AgentContactPresentation
typealias SimpleFlight = AgentContactFlight

typealias SimpleViewStore = ContactThreadReadouts
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

    /// Return to the agent's chat when the selected thread leaves the lists.
    private var gone: some View {
        Color.clear.onAppear { pane = .agent }
    }

    var body: some View {
        ShellFrame {
            SimpleSidebar(store: store, pane: $pane)
        } detail: {
            let showingChat = pane == .agent
            ZStack {
                // Keep chat mounted so visiting a thread never rebuilds it.
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

/// Advanced shows the shared threads beside connection setup.
struct AgentThreadsTab: View {

    @Environment(AppModel.self) private var appModel
    private var store: SimpleViewStore { appModel.engine.contactThreads }
    @State private var pane: SimpleShellView.Pane = .agent

    private func openChat() { ApplicationLifetime.shared.request(.sidebar(.chat)) }

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
