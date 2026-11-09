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
// Blueprint: | `AppDelegate+BackgroundTasks.swift` | `AppDoctorPort`: Doctor platform, both Inspectors and discovery-admitted browser health |

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
        await BodyFaceDoctor.check()
    }

    func doctorInspectorRepair(for check: CheckResult) async -> DoctorExecutableRepair? {
        await BodyFaceDoctor.repair(for: check)
    }
}
