import ActivityWatch
import AgentWorkspace
import AppKit
import Experiences
import Foundation
import MacControl
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter

// Blueprint: | `EngineFrontSense.swift` | Front-app perception with presence, policy and provenance gates; once per app per local day as a world happening |

@MainActor
final class EngineFrontSense {
    static let shared = EngineFrontSense()
    private var observer: NSObjectProtocol?
    private var stopped = false
    private var pending: UUID?
    private var work: [UUID: Task<Void, Never>] = [:]
    private var drain: Task<Void, Never>?

    func start(dataRoot: URL) {
        guard !stopped, observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Read provenance at the activation, before the motor epoch fades.
            let agentDriven = NativeAgentMotorEpoch.isAgentDriven()
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundle = app?.bundleIdentifier, name = app?.localizedName, pid = app?.processIdentifier
            MainActor.assumeIsolated {
                self?.activated(bundle: bundle, name: name, pid: pid, agentDriven: agentDriven, dataRoot: dataRoot)
            }
        }
    }

    private func admitted(bundle: String, dataRoot: URL) async throws -> Bool {
        guard !ActivityPolicy.defaultExcludedBundleIDs.contains(bundle),
              !ActivityPolicy.alwaysExcludedBundleIDs.contains(bundle) else { return false }
        let fullMac = await SwiftNativeSecurityCenter(dataRoot: dataRoot).fullMacYoloAuthority(
            origin: SecurityOriginContext(surface: "native_actions", source: "mac:front"), turn: nil)
        let policy = try await Task.detached {
            try ActivityPolicyStore(dataRoot: dataRoot).loadChecked()
        }.value
        try Task.checkCancellation()
        guard !policy.isExcluded(bundleID: bundle), policy.allowModelAccess || fullMac.admitted,
              !NativeAgentMotorEpoch.isAgentDriven(), MacPersonInput.presence()?.here == true else { return false }
        let session = defaultMacSessionStateSource().currentState()
        return try session.sessionReadable && session.onConsole && !session.obstructed && !MacScreenLock.isCovered()
    }

    private func activated(bundle: String?, name: String?, pid: pid_t?, agentDriven: Bool, dataRoot: URL) {
        if let pending { work[pending]?.cancel() }
        pending = nil
        guard !stopped, !agentDriven, let bundle, let name, !name.isEmpty, let pid else { return }
        let id = UUID()
        pending = id
        work[id] = Task {
            defer {
                work.removeValue(forKey: id)
                if pending == id { pending = nil }
            }
            do {
                guard try await admitted(bundle: bundle, dataRoot: dataRoot) else { return }
                let person = await Task.detached { AgentScreen.names(dataRoot).person }.value
                guard !stopped, pending == id, !Task.isCancelled,
                      !NativeAgentMotorEpoch.isAgentDriven(), MacPersonInput.presence()?.here == true,
                      let front = NSWorkspace.shared.frontmostApplication,
                      front.processIdentifier == pid, front.bundleIdentifier == bundle else { return }
                // The key is the app and the local day: the first activation of an app each day is the happening, later ones write nothing.
                Attention.post(Happening(.world, subject: "mac:front:" + bundle, door: "mac:front",
                    words: person + " is working in " + name + ".",
                    once: "mac:front:" + bundle + ":" + EngineDaySense.dayKey(Date())), dataRoot: dataRoot)
            } catch is CancellationError {
                return
            } catch {
                nativeLog("Front-app perception unavailable: %@", error.localizedDescription)
            }
        }
    }

    func stop() -> Task<Void, Never> {
        if let drain { return drain }
        stopped = true
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        pending = nil
        let admitted = Array(work.values)
        for task in admitted { task.cancel() }
        let task = Task { await settle { for task in admitted { await task.value } } }
        drain = task
        return task
    }
}
