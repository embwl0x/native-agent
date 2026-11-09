import AppKit
import Experiences
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
// Blueprint: | `AgentOpened.swift` | Application-launch attribution; observers close at work end or shutdown; apps still running are a body happening |

/// Attribute launches only with known person-input timing; work ending prunes stopped apps and tells the agent's body, never quits apps.
package final class AgentOpened: @unchecked Sendable {
    package static let shared = AgentOpened()
    /// Exclude launches near person input or after input during active work, including the click that woke it.
    static let personLead: TimeInterval = 10
    private let lock = NSLock()
    /// Retain work-start uptime for launch attribution.
    private var doing: [String: TimeInterval] = [:]
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
                      app.activationPolicy == .regular, !PersonOnlyWindows.isOwnProcess(app.processIdentifier),
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
            // Any input of the person's since the agent's work began makes it theirs, however slow the app.
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
        // Each launch is told once (its pid leaves `untold` above), so every telling is a new occurrence with a key of its own.
        Attention.post(Happening(.body, subject: "mac:opened", door: "mac:opened", who: "self",
            words: "Still running, opened by you: " + still.joined(separator: ", ")
                + ". When the job is done, quit what you opened; leave what the person had open.",
            once: "mac-opened:" + UUID().uuidString.lowercased()), dataRoot: dataRoot)
    }
}
