import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace

// Blueprint: | `SessionIdentityCheck.swift` | `SessionIdentityCheck.run`: session mint-site counts and source/row disagreement diagnostics |

// MARK: - One Thread, Many Surfaces — Phase 0 Doctor row
// An unreadable index fails; a valid empty or archived index can have zero hot sessions. Unscanned transcripts remain unreadable rather than clean
// disagreements; an empty identity feed remains uninstrumented. This row only observes: it must neither mutate history nor infer unmeasured health.

public struct SessionIdentityCheck: DoctorCheck {
    public let id: String = "session_identity"
    public let title: String = "Chat Session Identity"

    private let root: URL
    /// Bound named disagreement IDs so one flapping root cannot overwhelm the row.
    private let maximumNamedSessions = 5

    public init(root: URL = defaultDataRoot()) {
        self.root = root
    }

    public func run() async -> CheckResult {
        let sessionsPath = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        let indexExists = FileManager.default.fileExists(atPath: sessionsPath.path)

        let report = SessionIdentityLedger.flappingReport(dataRoot: root)
        let tally = await SessionIdentityLedger.mintTally(dataRoot: root, now: Date())
        if tally.readIssue != nil || tally.unreadable > 0 {
            let cause = tally.readIssue.map { "the record could not be read: \($0)" }
                ?? "\(tally.unreadable) session.identity detail(s) no longer decode"
            return CheckResult(source: "experiences/experiences.sqlite",
                id: id, title: title, status: "fail",
                detail: "Session minting could not be measured because \(cause).",
                harm: "Session creation history cannot be checked from the saved turns.")
        }

        guard indexExists else {
            return CheckResult(source: "chat/sessions.json",
                id: id, title: title, status: "ok",
                detail: "No chat session index yet — 0 hot session(s), nothing minted.",
                repair: nil
            )
        }

        if !report.indexReadable {
            return CheckResult(source: "chat/sessions.json",
                id: id, title: title, status: "fail",
                detail: "chat/sessions.json is unreadable or malformed, so session identity cannot be measured.",
                harm: "Saved conversations cannot be reliably identified or reopened.",
                human_action: ToolFailureError.fileRepairInstruction(sessionsPath,
                    shape: "This is a JSON array of saved chat session objects, each with its original nonempty id and saved metadata."))
        }

        var parts: [String] = ["\(report.hotSessionCount) hot session(s)"]

        if tally.totalMinted > 0 {
            let breakdown = tally.mintedByMintSite
                .sorted { lhs, rhs in
                    lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
                }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            parts.append("\(tally.totalMinted) minted in 24h (\(breakdown))")
        } else if tally.totalRows > 0 {
            parts.append("0 minted in 24h across \(tally.totalRows) identity row(s)")
        } else {
            // Distinguish "instrumented and quiet" from "not instrumented".
            parts.append("no session.identity details recorded in 24h, so minting is UNMEASURED")
        }

        parts.append("\(report.mixedSourceSessionCount) mixed-source transcript(s)")
        // Continuing a conversation on another surface is informational, never a warning.
        if report.continuedElsewhereSessionCount > 0 {
            parts.append(
                "\(report.continuedElsewhereSessionCount) session(s) continued mostly"
                    + " on a surface other than the one they started on"
            )
        }

        var status = "ok"
        if report.disagreeingSessionCount > 0 {
            status = "warn"
            let named = report.disagreeingSessionIds
                .prefix(maximumNamedSessions)
                .joined(separator: ", ")
            let overflow = report.disagreeingSessionCount - min(
                maximumNamedSessions,
                report.disagreeingSessionCount
            )
            parts.append(
                "\(report.disagreeingSessionCount) session(s) whose index source disagrees"
                    + " with their own creation row (\(named)"
                    + (overflow > 0 ? ", +\(overflow) more" : "")
                    + ")"
            )
        } else {
            parts.append("0 source disagreements")
        }

        // Never let an unmeasured transcript hide inside a clean number.
        if report.creationUnmeasuredSessionCount > 0 {
            parts.append(
                "\(report.creationUnmeasuredSessionCount) session(s) whose creation row was"
                    + " compacted away, so their creation surface is UNMEASURED and"
                    + " was judged for nothing"
            )
        }
        // Never let an unmeasured transcript hide inside a clean number.
        if report.unreadableSessionCount > 0 {
            parts.append(
                "\(report.unreadableSessionCount) transcript(s) UNREAD (missing, empty,"
                    + " or over the scan budget) and therefore unjudged"
            )
            if status == "ok" { status = "unmeasured" }
        }

        // Source disagreement belongs to the builder's mint site, never the agent's triage.
        return CheckResult(source: "chat/sessions.json",
            id: id, title: title, status: status,
            detail: parts.joined(separator: "; ") + ".",
            harm: status == "warn" ? "Conversation messages cannot be reliably matched to their saved session and surface." : nil,
            owner: status == "warn" ? .builder : nil
        )
    }
}
