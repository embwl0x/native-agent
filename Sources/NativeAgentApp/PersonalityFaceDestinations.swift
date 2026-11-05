import EngineRuntime
import NativeAgentShared
import SwiftUI
// Blueprint: | `PersonalityFaceDestinations.swift` | Personality face links open its existing editor, minds picker, Dreams and confirmed identity reset |

@MainActor
enum PersonalityFaceDestinations {
    static let tabs = [
        ShellTab(key: "personality", title: "Personality"),
        ShellTab(key: "documents", title: "Read or edit identity"),
        ShellTab(key: "minds", title: "My minds"),
        ShellTab(key: "dreams", title: "Dreams"),
        ShellTab(key: "reset", title: "Reset identity…")
    ]
}

extension View {
    func personalityDestinations() -> some View { modifier(PersonalityFaceDestinationModifier()) }
}

private struct PersonalityFaceDestinationModifier: ViewModifier {
    @Environment(AppModel.self) private var appModel
    @Environment(\.quietOffscreenRead) private var offscreen
    @Environment(\.quietRailTab) private var drawnDestination
    @AppStorage(ShellRailTab.storageKey(.personality)) private var destination = "personality"

    private var isPresented: Binding<Bool> {
        Binding(get: {
            !offscreen && destination != "personality" && PersonalityFaceDestinations.tabs.contains { $0.key == destination }
        }, set: { presented in
            if !presented { destination = "personality" }
        })
    }

    func body(content: Content) -> some View {
        Group {
            if offscreen, let drawnDestination, drawnDestination != "personality" {
                detail(drawnDestination)
            } else {
                content.sheet(isPresented: isPresented) { detail(destination) }
            }
        }
    }

    private func detail(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(PersonalityFaceDestinations.tabs.first { $0.key == key }?.title ?? "Personality").font(.title2)
                Spacer()
                Button("Done") { destination = "personality" }
            }
            destinationView(key)
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 520)
    }

    @ViewBuilder private func destinationView(_ key: String) -> some View {
        switch key {
        case "documents": PersonalityEditor()
        case "minds": SetupMindsView()
        case "dreams": DreamsView()
        case "reset":
            if PersonaFacade.hasInitializedIdentity(in: appModel.engine.persona.documents) {
                ResetPersonaView { _ = await appModel.refreshForSidebarItem(.personality) }
            } else {
                Text("Reset is unavailable until the saved identity documents have been read.")
            }
        default: Text("This Personality destination is unavailable.")
        }
    }
}
