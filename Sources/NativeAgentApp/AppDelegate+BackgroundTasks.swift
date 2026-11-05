import Agents
import MacControl
import Foundation
import AppKit
import EngineRuntime
import BackgroundLoops
import BackgroundWork
import DoctorChecks
import DeviceSync
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `AppDelegate+BackgroundTasks.swift` | Background handlers; browser health uses the discovery-admitted listener |

extension AppDelegate {
    static func registerBackgroundTaskHandlers() {
        do {
            let activities: [(loopId: String, wake: OrganWake)] = [
                ("self_improvement_sweep", .every(WeeklySelfImprovementLoop.defaultPeriod)),
            ]
            for entry in activities {
                guard let period = entry.wake.period else {
                    NSLog("[BackgroundTasks] Registration refused: %@ runs on change, not an OS rhythm.", entry.loopId)
                    continue
                }
                let activity = NSBackgroundActivityScheduler(
                    identifier: try NativeAgentICloudBridgeConstants.backgroundTaskIdentifier(entry.loopId))
                activity.interval = period
                activity.tolerance = 12 * 60 * 60
                activity.repeats = true
                activity.qualityOfService = .utility
                activity.schedule { completion in
                    Task.detached(priority: .utility) {
                        let outcome = await BackgroundLoopLifetimes.shared.runTickIfDue(loopId: entry.loopId)
                        if case .failed = outcome { completion(.deferred) }
                        else { completion(.finished) }
                    }
                }
            }
        } catch {
            NSLog("[BackgroundTasks] Registration refused: %@", error.localizedDescription)
        }
    }
}

struct AppDoctorPort: EngineDoctorPlatformPort {
    let dataRoot: URL
    var backgroundLoopsManager: BackgroundLoopLifetimes = .shared

    var runtime: EngineDoctorRuntime<AppDoctorPort> { EngineDoctorRuntime(dataRoot: dataRoot, port: self) }
    var doctorEngine: NativeAgentEngine { .live }
    var doctorManager: BackgroundLoops.BackgroundLoopLifetimes { backgroundLoopsManager }

    func doctorRestartLoop(id: String) async -> LoopRestartOutcome {
        await NativeAgentEngine.restartBackgroundLoop(id: id, manager: backgroundLoopsManager)
    }

    func doctorRepairPhoneSync() async -> DoctorRepairAttempt? {
        .unverified(await NativeAgentEngine.liveDeviceSync.engine.repairPhoneSync())
    }

    func doctorStartBridge(name: String) async {
        switch name {
        case "ClaudeBridge": await ClaudeBridgeRuntime.shared.startServer()
        case "BrowserIPC": await BrowserWindowController.shared.startIPCServer()
        default: break
        }
    }


    func doctorBridgeSnapshots() async -> [DoctorBridgeSnapshot] {
        let browserIPC = await BrowserWindowController.shared.ipcListenerSnapshot
        let claude = ClaudeBridgeRuntime.shared.listenerHealth
        return [
            ("ClaudeBridge", (claude.failure, claude.boundPort, claude.isActive, claude.port), true),
            ("BrowserIPC", browserIPC, true),
        ]
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
