import EngineRuntime
import Connectors
import Foundation
import SchedulerExecution
import NativeAgentCore
import PersistenceCore
import MacControl
import AttentionRouting
import AppKit
import NativeAgentShared
// Blueprint: | `AppConnectorPlatform.swift` | Voice, notification, Mac control, EventKit and device-sync platform bindings |

/// Connector actions, the integration bridge and Mac control routes must share TrustCenter's policy.
extension TrustCenterMacControlPolicyProvider {
    /// Bridge requests carry no local-workbench admission.
    static func run(path: String, bodyData: Data, dataRoot: URL, turn: Turn, context: MacOperationContext) async throws -> JSONValue {
        try await MacControlActionRoutes.run(
            path: path, bodyData: bodyData, dataRoot: dataRoot, turn: turn, context: context
        ) { auditRoot in
            makeMacControl(
                policyProvider: TrustCenterMacControlPolicyProvider(dataRoot: dataRoot),
                auditDataRoot: auditRoot,
                notificationCenterAdapter: MacNotificationPosting(turn: turn, deadline: context.deadline)
            )
        }
    }
}


extension AppConnectorStatusPlatform {
    init() {
        self.init(subject: { AgentVoice.live.subject }, chooseSharedFolder: {
            guard NSApp.isActive, NSApp.keyWindow != nil else {
                throw PartCallError(code: "mac_required", message: "Share a folder on your Mac")
            }
            let panel = NSOpenPanel()
            panel.title = "Share a folder"
            panel.prompt = "Share Folder"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            panel.resolvesAliases = false
            let name = NSTextField(string: "")
            name.placeholderString = "Folder name (leave blank to use its name)"
            name.setAccessibilityLabel("Shared folder name")
            let writable = NSButton(checkboxWithTitle: "Let me write to it", target: nil, action: nil)
            let accessory = NSStackView(views: [name, writable])
            accessory.orientation = .vertical
            accessory.alignment = .leading
            accessory.spacing = 8
            accessory.frame = NSRect(x: 0, y: 0, width: 360, height: 64)
            name.widthAnchor.constraint(equalToConstant: 360).isActive = true
            panel.accessoryView = accessory
            let response = await panel.begin()
            try Task.checkCancellation()
            guard response == .OK else { return nil }
            guard let folder = panel.url else {
                throw PartCallError(code: "folder_unavailable", message: "The picker did not return a folder. Choose Share a folder again.")
            }
            let label = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return (label.isEmpty ? folder.lastPathComponent : label, folder.path, writable.state == .on)
        }, showBrowser: {
            BrowserWindowController.shared.showWindow()
        })
    }
}

extension AppConnectorActionPlatform {
    init(engine: NativeAgentEngine) {
        self.init(dataRoot: engine.dataRoot, statusPlatform: AppConnectorStatusPlatform(),
                  router: { .shared }, macAssistant: engine.macIntegration,
                  notification: { title, body, turn in
                      await NativeAgentNotifications.postMessage(title: title, body: body, router: .shared,
                          turn: turn, deadline: nil).deliveryFields()
                  })
    }
}

extension MacIntegrationDeliveryActions {
    init() {
        self.init(
            connectorActions: { ConnectorActions(platform: AppConnectorActionPlatform(engine: .live)) },
            router: { .shared },
            deviceSync: { NativeAgentEngine.liveDeviceSync },
            scheduler: { .shared }
        )
    }
}
