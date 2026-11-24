import BodyRuntime
import Foundation
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `BodyFollowHistory.swift` | Last eight follow outcomes per origin and the pages the window leaves in place |

actor BodyFollowHistory {
    private struct Trial: Codable {
        let landing: String
        let outcome: FollowOutcome
    }
    private typealias History = [String: [Trial]]
    private let file: URL
    private let feed: SettingsFeedProjection
    private var reportedReadIssue = false

    init(dataRoot: URL, feed: SettingsFeedProjection) {
        file = dataRoot.appendingPathComponent("mind/follow.json")
        self.feed = feed
    }

    private func read() throws -> History {
        do {
            let history = try JSONDecoder().decode(History.self, from: Data(contentsOf: file))
            reportedReadIssue = false
            return history
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // No file yet: no trial has settled, which is a fact, not a failure.
            feed.updateWindowLeaves([])
            return [:]
        } catch {
            if !reportedReadIssue {
                ModuleLog.app("Could not read mind/follow.json: %@", error.localizedDescription)
                reportedReadIssue = true
            }
            feed.updateWindowLeaves([])
            throw error
        }
    }

    func load() {
        do { publish(try read()) }
        catch { return }
    }

    func record(origin: String, landing: String, outcome: FollowOutcome) throws {
        var history = try read()
        let trial = Trial(landing: landing, outcome: outcome)
        history[origin] = Array((history[origin] ?? []).suffix(7)) + [trial]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(history).write(to: file, options: .atomic)
        publish(history)
    }

    private func publish(_ history: History) {
        let origins = history.filter { !$0.value.isEmpty }
        // Each page the person was on stands on its own record, as each carried habit does.
        // A page left in place still follows now and then (`Expectation.withholding`), so a page that stops being taken back comes back.
        var sampling: [String: Double] = [:]
        let leaves = origins.compactMap { origin, trials -> String? in
            let hits = trials.filter { $0.outcome == .tookBack }.count
            guard Expectation.stands(hits: hits, tries: trials.count, cHit: 1, cMiss: 1).stands else { return nil }
            sampling[origin] = Expectation.withholding(tries: trials.count, hits: hits)
            return origin
        }
        feed.updateWindowLeaves(leaves.sorted(), sampling: sampling)
    }
}
