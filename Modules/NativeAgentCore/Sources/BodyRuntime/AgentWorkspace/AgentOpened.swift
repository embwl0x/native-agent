import Synchronization
import AppKit
import SenseCore
import Foundation
import NativeAgentShared
import MacNerves
import NativeAgentCore
import PersistenceCore
import DeskCore
import Darwin
// Blueprint: | `AgentOpened.swift` | Application-launch attribution; observers close at work end or shutdown; apps still running are a body happening |

/// Attribute launches only with known person-input timing; work ending prunes stopped apps and tells the agent's body, never quits apps.
package final class AgentOpened: Sendable {
    package static let shared = AgentOpened()
    struct Changed: BodySignal {}
    /// Exclude launches near person input or after input during active work, including the click that woke it.
    static let personLead: TimeInterval = 10
    private struct State {
        var doing: [String: TimeInterval] = [:]
        var opened: [pid_t: String] = [:]
        var untold: [pid_t: String] = [:]
        var observer: NSObjectProtocol?
        var observationID: UUID?
        var stopped = false

        mutating func retireObservation() {
            observationID = nil
            if let observer { MacBodyNerve.shared.remove(observer) }
            observer = nil
        }
    }
    private let state = Mutex(State())

    package func began(_ work: String) {
        state.withLock { state in
            guard !state.stopped, state.doing[work] == nil else { return }
            state.doing[work] = ProcessInfo.processInfo.systemUptime
            guard state.observer == nil else { return }
            let id = UUID()
            state.observationID = id
            state.observer = MacBodyNerve.shared.listen { [weak self] edge in
                guard case .launched(let pid, let name?, true, _) = edge, !PersonOnlyWindows.isOwnProcess(pid) else { return }
                self?.launched(pid: pid, name: name, observation: id)
            }
        }
    }

    private func launched(pid: pid_t, name: String, observation: UUID) {
        guard let quiet = MacPersonInput.idle()?.seconds else { return }
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock { state in
            guard !state.stopped, state.observationID == observation else { return }
            // Any input of the person's since the agent's work began makes it theirs, however slow the app.
            guard let began = state.doing.values.min(), let latest = state.doing.max(by: { $0.value < $1.value }),
                  quiet > max(now - began, Self.personLead) else { return }
            state.opened[pid] = name
            state.untold[pid] = latest.key
            NotificationCenter.default.post(Changed())
        }
    }

    package func recordedLaunches() -> [pid_t: String] { state.withLock { $0.opened } }

    package func shutdown() {
        state.withLock { state in
            state.stopped = true
            state.doing.removeAll()
            state.untold.removeAll()
            state.retireObservation()
        }
    }

    package func ended(_ work: String, dataRoot: URL) {
        let still: [String]? = state.withLock { state in
            guard !state.stopped else { return nil }
            state.doing[work] = nil
            if state.doing.isEmpty { state.retireObservation() }
            let before = state.opened
            state.opened = state.opened.filter { NSRunningApplication(processIdentifier: $0.key)?.localizedName == $0.value }
            if state.opened != before { NotificationCenter.default.post(Changed()) }
            let told = state.untold.filter { $0.value == work }.keys
            told.forEach { state.untold[$0] = nil }
            guard told.contains(where: { state.opened[$0] != nil }) else { return nil }
            return state.opened.values.sorted()
        }
        guard let still else { return }
        // Each launch is told once (its pid leaves `untold` above), so every telling is a new occurrence with a key of its own.
        Attention.post(Happening(.body, subject: "mac:opened", door: "mac:opened", who: "self",
            words: "Still running, opened by you: " + still.joined(separator: ", ")
                + ". When the job is done, quit what you opened; leave what the person had open.",
            once: "mac-opened:" + UUID().uuidString.lowercased()), dataRoot: dataRoot)
    }
}
