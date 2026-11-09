import Foundation
import NativeAgentShared
import SwiftUI
// Blueprint: | `PersonalityFaceDestinations.swift` | Personality face links open its existing identity editor and Dreams |

@MainActor
enum PersonalityFaceDestinations {
    static let tabs = [
        ShellTab(key: "personality", title: "Personality"),
        ShellTab(key: "documents", title: "Read or edit identity"),
        ShellTab(key: "dreams", title: "Dreams")
    ]

    static func open(_ item: String) throws {
        guard tabs.contains(where: { $0.key == item }) else {
            throw PartCallError(code: "personality_destination_unknown", message: "This Personality destination is unavailable.")
        }
        let key = ShellRailTab.storageKey(.personality)
        if UserDefaults.standard.string(forKey: key) != item { UserDefaults.standard.set(item, forKey: key) }
    }
}

extension View {
    func personalityDestinations() -> some View { modifier(PersonalityFaceDestinationModifier()) }
}

private struct PersonalityFaceDestinationModifier: ViewModifier {
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
        .frame(width: 780, height: 680)
    }

    @ViewBuilder private func destinationView(_ key: String) -> some View {
        switch key {
        case "documents": PersonalityEditor()
        case "dreams": DreamsView()
        default: Text("This Personality destination is unavailable.")
        }
    }
}
