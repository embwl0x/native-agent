import Foundation
import NativeAgentShared
// Blueprint: | `FaceWindowAction.swift` | Window commands and shared preference edits retain ordered, checked requests through their mounted scene |

struct FaceWindowAction: Identifiable {
    struct Issue: Identifiable {
        let id: UUID
        let message: String
    }

    enum Operation {
        case browser
        case updates
        case settings(SidebarItem, tab: String?)
        case preference(key: String, value: PartFace.Value)

        var activatesWindow: Bool {
            if case .preference = self { return false }
            return true
        }

        var words: String {
            switch self {
            case .browser: "open the browser"
            case .updates: "check for updates"
            case .settings: "open Settings"
            case .preference(_, let value): value == .null ? "restore the setting's default" : "save the setting"
            }
        }
    }

    let id = UUID()
    let operation: Operation

    @MainActor func perform(_ appModel: AppModel) async throws {
        try Task.checkCancellation()
        switch operation {
        case .browser: try await appModel.client.act(.openBrowser).checkedAcknowledgement()
        case .updates: try await appModel.client.act(.requestUpdate(.check)).checkedAcknowledgement()
        case .settings(let item, let tab): try await SettingsLink.openChecked(item, tab: tab, appModel: appModel)
        case .preference(let key, let value):
            _ = try await appModel.client.act(.setPreference(key: key, value: value)).checkedCommit()
        }
    }
}

@MainActor
extension AppModel {
    func enqueueWindowAction(_ operation: FaceWindowAction.Operation) {
        windowActions.append(.init(operation: operation))
        if operation.activatesWindow || ApplicationLifetime.shared.scene == nil {
            ApplicationLifetime.shared.activateMainWindow()
        }
    }
}
