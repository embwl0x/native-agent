import EngineRuntime
import Foundation
import SchedulerExecution
import NativeAgentCore
import PersistenceCore
import MacControl
import AttentionRouting

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
    init(dataRoot: URL) {
        self.init(dataRoot: dataRoot, statusPlatform: AppConnectorStatusPlatform(),
                  router: { .shared }, deviceSync: { NativeAgentEngine.liveDeviceSync },
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
