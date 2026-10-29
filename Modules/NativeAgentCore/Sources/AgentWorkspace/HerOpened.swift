import AppKit
import Foundation
import NativeAgentShared
import MacControl
import NativeAgentCore
import PersistenceCore
import Desk
import StandingBots
import ChatSessionWork
import Transcripts
import ChatToolParsing
import Darwin
// Blueprint: | `HerOpened.swift` | Application-launch attribution and its observer lifetime, retired at work end or shutdown |

/// Regular-app launches attributed to her active work by person-input timing. Unknown input is excluded. Work ending prunes stopped apps and requests one reminder through `ResidentWake`; it never quits them.
package final class HerOpened: @unchecked Sendable {
    package static let shared = HerOpened()
    /// Attribution requires no person input this close before launch, nor since the oldest active work began (including a click that woke her).
    static let personLead: TimeInterval = 10
    private let lock = NSLock()
    /// Her open work (a turn's session, a wake run's id), with the uptime each began at.
    private var doing: [String: TimeInterval] = [:]
    /// Recorded attribution, pruned when work ends: pid → name; and work not yet told.
    private var opened: [pid_t: String] = [:]
    private var untold: [pid_t: String] = [:]
    private var observer: NSObjectProtocol?
    private var observationID: UUID?
    private var stopped = false

    package func began(_ work: String) {
        lock.withLock {
            guard !stopped, doing[work] == nil else { return }
            doing[work] = ProcessInfo.processInfo.systemUptime
            guard observer == nil else { return }
            let id = UUID()
            observationID = id
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.activationPolicy == .regular, app.processIdentifier != getpid(),
                      let name = app.localizedName else { return }
                self?.launched(pid: app.processIdentifier, name: name, observation: id)
            }
        }
    }

    private func launched(pid: pid_t, name: String, observation: UUID) {
        guard let quiet = MacPersonInput.idle()?.seconds else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            guard !stopped, observationID == observation else { return }
            // Any input of the person's since her work began makes it theirs, however slow the app.
            guard let began = doing.values.min(), let latest = doing.max(by: { $0.value < $1.value }),
                  quiet > max(now - began, Self.personLead) else { return }
            opened[pid] = name
            untold[pid] = latest.key
        }
    }

    package func recordedLaunches() -> [pid_t: String] { lock.withLock { opened } }

    /// No launch observation lives beyond its last work item or the engine.
    private func retireObservation() {
        observationID = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    package func shutdown() {
        lock.withLock {
            stopped = true
            doing.removeAll()
            untold.removeAll()
            retireObservation()
        }
    }

    package func ended(_ work: String, dataRoot: URL) {
        let still: [String]? = lock.withLock {
            guard !stopped else { return nil }
            doing[work] = nil
            if doing.isEmpty { retireObservation() }
            opened = opened.filter { NSRunningApplication(processIdentifier: $0.key)?.localizedName == $0.value }
            let told = untold.filter { $0.value == work }.keys
            told.forEach { untold[$0] = nil }
            guard told.contains(where: { opened[$0] != nil }) else { return nil }
            return opened.values.sorted()
        }
        guard let still else { return }
        ResidentWake.shared.request(dataRoot: dataRoot, reason: "apps you opened are still running", items: [.init(
            id: "mac-opened:" + UUID().uuidString,
            line: "Still running, opened by you: " + still.joined(separator: ", ")
                + ". When the job is done, quit what you opened; leave what the person had open.",
            key: "mac-opened")])
    }
}
