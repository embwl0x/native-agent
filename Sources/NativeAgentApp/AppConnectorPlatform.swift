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
import SwiftUI
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
        self.init(subject: { AgentVoice.live.subject }, chooseSharedFolder: { renderer in
            let operation = UUID()
            let reply: FaceReply
            if let renderer {
                guard let model = ApplicationLifetime.shared.appModel else { throw FaceWireError.disconnected }
                let target = try BodyFacePresentation.require(renderer, model: model)
                reply = try await target.call(.chooseSharedFolder(operation: operation))
            } else {
                guard NSApp.isActive, NSApp.keyWindow != nil else {
                    throw PartCallError(code: "mac_required", message: "Share a folder on your Mac")
                }
                reply = try await ConnectorPresentation.chooseSharedFolder(operation: operation)
            }
            switch reply {
            case .folder(let selection):
                guard let selection else {
                    throw PartCallError(code: "folder_unconfirmed", message: "The folder picker returned no selection.")
                }
                return try await SharedFolderGrant.resolve(selection, operation: operation)
            case .cancelled: return nil
            case .failed(let failure), .refused(let failure): throw failure
            default: throw FaceWireError.invalidFeedOrder
            }
        }, showGrokSecureSetup: { peer in
            guard let model = ApplicationLifetime.shared.appModel else { throw FaceWireError.disconnected }
            try await BodyFacePresentation.current(model: model).present(.showGrokSetup(contact: peer, operation: UUID()))
        }, showProviderSetup: { provider, root in
            guard let model = ApplicationLifetime.shared.appModel,
                  model.engine.dataRoot.standardizedFileURL == root.standardizedFileURL else { throw FaceWireError.disconnected }
            try await BodyFacePresentation.current(model: model).present(.showProviderSetup(provider: provider.provider_id, operation: UUID()))
        })
    }
}

private enum SharedFolderGrant {
    @concurrent static func resolve(_ selection: ChosenFolder, operation: UUID) async throws -> (name: String, path: String, writable: Bool) {
        guard selection.resource.id == operation, selection.resource.writable == selection.writable else {
            throw PartCallError(code: "folder_grant_invalid", message: "The folder selection does not match its access grant. Choose it again.")
        }
        let folder = try BodyFaceResources.resolve(selection.resource)
        guard folder.isFileURL else {
            throw PartCallError(code: "folder_grant_invalid", message: "Choose a local folder to share.")
        }
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw PartCallError(code: "folder_grant_invalid", message: "The selected resource is not a folder. Choose a folder again.")
        }
        let label = selection.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw PartCallError(code: "folder_name_missing", message: "Choose a name for this shared folder.") }
        return (label, folder.path, selection.writable)
    }
}

extension AppConnectorActionPlatform {
    init(engine: NativeAgentEngine) {
        self.init(dataRoot: engine.dataRoot, statusPlatform: AppConnectorStatusPlatform(),
                  macAssistant: engine.macIntegration,
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
            deviceSync: { NativeAgentEngine.liveDeviceSync }
        )
    }
}
