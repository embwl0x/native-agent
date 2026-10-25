import EngineRuntime
import Foundation
import SchedulerExecution
import NativeAgentCore
import PersistenceCore
import MacControl
import AttentionRouting
// Blueprint: | `AppConnectorPlatform.swift` | live voice, notification, Mac control and device-sync bindings over core connector/integration policy and status owners; remaining composition belongs to Area 1; notification, EventKit and connector platform bindings over core policy/status owners |

/// TrustCenter's Mac control policy. The connector actions, the Mac
/// integration bridge and the Mac control routes all gate through it.
extension TrustCenterMacControlPolicyProvider {
    /// One Mac control route run in-process behind this gate. Unimplemented
    /// actions fail closed in Swift; there is no HTTP fallback. Only the
    /// person's own workbench may carry Full Mac admission.
    static func run(path: String, bodyData: Data, dataRoot: URL, localWorkbench: Bool) async throws -> MacControlRunResult {
        try await MacControlActionRoutes.run(
            path: path, bodyData: bodyData, dataRoot: dataRoot, localWorkbench: localWorkbench
        ) { operatorOrigin, auditPath in
            makeMacControl(
                policyProvider: TrustCenterMacControlPolicyProvider(
                    dataRoot: dataRoot, operatorOrigin: operatorOrigin
                ),
                auditAppendPath: auditPath,
                notificationCenterAdapter: NativeAgentMacControlNotificationAdapter()
            )
        }
    }
}


extension AppConnectorStatusPlatform {
    init() { self.init(subject: { AgentVoice.live.subject }) }
}

extension AppConnectorActionPlatform {
    init(engine: NativeAgentEngine) {
        self.init(dataRoot: engine.dataRoot, statusPlatform: AppConnectorStatusPlatform(),
                  router: { .shared }, macAssistant: engine.macIntegration,
                  notification: { await NativeAgentNotifications.postMessage(title: $0, body: $1).deliveryFields() })
    }
}

extension MacIntegrationDeliveryActions {
    init() {
        self.init(
            postMessage: { await NativeAgentNotifications.postMessage(title: $0, body: $1).deliveryFields() },
            router: { .shared },
            deviceSync: { NativeAgentEngine.liveDeviceSync },
            scheduler: { .shared }
        )
    }
}
