import ActivityWatch
import AgentWorkspace
import AppKit
import Foundation
import MacControl
import NativeAgentCore
import PersistenceCore
import Senses
import TrustCenter

// Blueprint: | `EngineFrontSense.swift` | One engine workspace activation observer and cancellable 120-second stable-front check; app names only, once per app/local day in mind/front-posted.json; checked activity-model or Full Mac admission, mandatory/default/user exclusions, canonical person presence, console/lock and motor provenance checked before crossing mac:front; stop cancels and joins admitted work without touching activity capture policy |

@MainActor
final class EngineFrontSense {
    static let shared = EngineFrontSense()
    private var observer: NSObjectProtocol?
    private var stopped = false
    private var pending: UUID?
    private var work: [UUID: Task<Void, Never>] = [:]
    private var drain: Task<Void, Never>?

    private struct Posted: Codable {
        var day: String
        var bundles: Set<String>
    }

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
            origin: SecurityOriginContext(surface: "native_actions", source: "mac:front"))
        let policy = try ActivityPolicyStore(dataRoot: dataRoot).loadChecked()
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
                guard try await admitted(bundle: bundle, dataRoot: dataRoot),
                      !stopped, pending == id, !Task.isCancelled else { return }
                try await Task.sleep(for: .seconds(120))
                guard try await admitted(bundle: bundle, dataRoot: dataRoot) else { return }
                guard !stopped, pending == id, !Task.isCancelled,
                      let front = NSWorkspace.shared.frontmostApplication,
                      front.processIdentifier == pid, front.bundleIdentifier == bundle,
                      let crossing = SensesHub.shared.crossing else { return }
                let day = EngineDaySense.dayKey(Date())
                let path = dataRoot.appendingPathComponent("mind/front-posted.json")
                var posted: Posted
                do { posted = try JSONDecoder().decode(Posted.self, from: Data(contentsOf: path)) }
                catch CocoaError.fileReadNoSuchFile { posted = Posted(day: day, bundles: []) }
                if posted.day != day { posted = Posted(day: day, bundles: []) }
                guard posted.bundles.insert(bundle).inserted else { return }
                let line = HerScreen.names(dataRoot).person + " is working in " + name + "."
                try SwiftNativePersistenceCore.writeDataAtomicDurable(try JSONEncoder().encode(posted), to: path)
                _ = await crossing.cross(line, watch: "mac:front", reason: "what is in front of the person",
                                         id: "mac:front:" + bundle + ":" + day, says: line, agent: nil)
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
