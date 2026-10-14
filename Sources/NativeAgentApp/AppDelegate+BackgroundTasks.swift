import Agents
import MacControl
import Foundation
import AppKit
import EngineRuntime
import BackgroundLoops
import BackgroundWork
import DoctorChecks
import NativeAgentCore
import NativeAgentShared

extension AppDelegate {
    static func registerBackgroundTaskHandlers() {
        for loopId in BackgroundLoopsManager.retiredSystemBackgroundActivities {
            NSBackgroundActivityScheduler(
                identifier: NativeAgentICloudBridgeConstants.backgroundTaskIdentifier(loopId)).invalidate()
        }
        for entry in BackgroundLoopsManager.systemBackgroundActivities {
            let activity = NSBackgroundActivityScheduler(
                identifier: NativeAgentICloudBridgeConstants.backgroundTaskIdentifier(entry.loopId))
            activity.interval = entry.interval
            activity.tolerance = 12 * 60 * 60
            activity.repeats = true
            activity.qualityOfService = .utility
            activity.schedule { completion in
                Task.detached(priority: .utility) {
                    let outcome = await BackgroundLoopsManager.shared.runTickIfDue(loopId: entry.loopId)
                    if case .failed = outcome { completion(.deferred) }
                    else { completion(.finished) }
                }
            }
        }
    }
}

/// Mounted Inspector and bridge effects for the engine's Doctor owner.
struct AppDoctorPort: EngineDoctorPlatformPort {
    let dataRoot: URL
    var backgroundLoopsManager: BackgroundLoopsManager = .shared

    var runtime: EngineDoctorRuntime<AppDoctorPort> { EngineDoctorRuntime(dataRoot: dataRoot, port: self) }
    var doctorEngine: NativeAgentEngine { .live }
    var doctorManager: BackgroundLoops.BackgroundLoopsManager { backgroundLoopsManager }

    func doctorRestartLoop(id: String) async -> LoopRestartOutcome {
        await NativeAgentEngine.restartBackgroundLoop(id: id, manager: backgroundLoopsManager)
    }
    func doctorStartBridge(name: String) async {
        switch name {
        case "ClaudeBridge": await ClaudeBridgeRuntime.shared.startServer()
        case "MacControlBridge": MacControlBridge.shared.start()
        case "BrowserIPC": await BrowserWindowController.shared.startIPCServer()
        default: break
        }
    }


    func doctorBridgeSnapshots() async -> [DoctorBridgeSnapshot] {
        let browserIPC = await BrowserWindowController.shared.ipcListenerHealth
        let bridges: [(name: String, health: NativeLoopbackListener.Health, expected: Bool)] = [
            ("ClaudeBridge", ClaudeBridgeRuntime.shared.listenerHealth, true),
            ("MacControlBridge", MacControlBridge.shared.listenerHealth, MacControlBridge.shared.startGateAllows()),
            ("BrowserIPC", browserIPC, true),
        ]
        return bridges.map { ($0.name, ($0.health.failure, $0.health.boundPort, $0.health.isActive, $0.health.port), $0.expected) }
    }

    func doctorInspectorCheck() async -> CheckResult {
        await TurnInspectorDoctor.check()
    }

    func doctorInspectorRepair(for check: CheckResult) async -> DoctorExecutableRepair? {
        guard check.id == "live.inspector_feed", check.status == "fail" else { return nil }
        return DoctorExecutableRepair(checkID: check.id) {
            await TurnInspectorDoctor.repairDeadSink()
        }
    }
}
