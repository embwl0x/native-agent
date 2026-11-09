import AppKit
import ActivityWatch
import AppToolRuntime
import ChatToolParsing
import ChatTurnContracts
import ChatTurnRuntime
import EngineRuntime
import MacIntegration
import NativeAgentShared
import PersistenceCore
import SwiftUI
import TrustCenter
import TrustPersistence
import UniformTypeIdentifiers
// Blueprint: | `BodyTrustPresentation.swift` | Confirmed native activity-exclusion picker for body presentation calls |

@MainActor enum TrustPresentation {
    static func chooseActivityExclusion(operation: UUID) async throws -> FaceReply {
        let panel = NSOpenPanel()
        panel.identifier = NSUserInterfaceItemIdentifier(operation.uuidString)
        panel.title = "Choose an app to exclude"
        panel.prompt = "Choose App"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard try await FaceNativePanel.choose(panel) == .OK else { return .cancelled }
        try Task.checkCancellation()
        guard let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else {
            throw PartCallError(code: "app_identity_unavailable", message: "The chosen app has no readable bundle identity.")
        }
        let alert = NSAlert()
        alert.messageText = "Exclude this app and delete what was recorded?"
        alert.informativeText = "Everything recorded for \(id) is deleted for good, including the recovery log. Future recording skips it."
        alert.addButton(withTitle: "Exclude and delete")
        alert.addButton(withTitle: "Cancel")
        guard try await FaceNativePanel.confirm(alert) == .alertFirstButtonReturn else { return .cancelled }
        return .exclusion(.init(bundleID: id, confirmed: true))
    }
}
