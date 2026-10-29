import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace

// Blueprint: | `SessionIdentityCheck.swift` | `SessionIdentityCheck.run`: session mint-site counts and source/row disagreement diagnostics |

// MARK: - One Thread, Many Surfaces — Phase 0 Doctor row
//
// docs/build_plans/one-thread-many-surfaces-plan.md §7 Phase 0:
//
//   "Doctor row: hot session count, rows minted in the last 24h BY MINT SITE,
//    count of sessions whose `source` disagrees with the majority of their
//    rows' `source` (the §1.3 flapping detector)."
//
// The plan's own test for this row is pointed: "Doctor row asserts non-zero on
// the live data root (a health row that reads '0' on a system with 202
// sessions would be exactly the sweep-item-3 lie)." So this check does not get
// to be quiet about what it could not measure. Three separate honesty rules:
//
//   * An unreadable or malformed index is a FAIL. A valid empty or entirely
//     archived index legitimately has 0 hot sessions.
//   * Transcripts this check could not scan are reported as `unreadable`
//     rather than folded into "0 disagreements". A zero that was never
//     measured is the lie the sweep names.
//   * An EMPTY `session.identity` feed says "not yet instrumented", not
//     "nothing minted". Phase 0 has just landed; a feed with no rows means the
//     mint sites have not run since, which is a different fact from silence.
//
// The check is READ-ONLY. It takes no lock, mutates nothing, and never
// repairs — there is nothing here to repair, only something to see.

public struct SessionIdentityCheck: DoctorCheck {
    public let id: String = "session_identity"
    public let title: String = "Chat Session Identity"

    private let root: URL
    /// How many disagreeing session ids to name in `detail` before summarizing.
    /// Bounded so one badly-flapping root cannot produce an unreadable row.
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
        let tally = SessionIdentityLedger.mintTally(dataRoot: root, now: Date())
        if let path = tally.unreadablePaths.first {
            return CheckResult(source: tally.unreadablePaths.joined(separator: ", "),
                id: id, title: title, status: "fail",
                detail: "Session minting could not be measured because turn-trace day files could not be read completely: \(tally.unreadablePaths.joined(separator: ", ")).",
                harm: "Session creation history cannot be checked from the saved turns.",
                human_action: ToolFailureError.fileRepairInstruction(URL(fileURLWithPath: path),
                    shape: "This day file holds one persisted TurnTraceEvent JSON object per line, with its original event identity, timestamp and payload."))
        }

        // Fresh install: no index yet. Honest "ok" with an explicit zero.
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

        // Minted-in-24h, BY MINT SITE — the smoking gun the phase exists for.
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
            parts.append(
                tally.daysRead == 0
                    ? "no turn-trace feed on disk, so minting is UNMEASURED"
                    : "no session.identity rows in the feed yet, so minting is UNMEASURED"
            )
        }

        parts.append("\(report.mixedSourceSessionCount) mixed-source transcript(s)")
        // Continuing a conversation on another surface is informational, never a warning.
        if report.continuedElsewhereSessionCount > 0 {
            parts.append(
                "\(report.continuedElsewhereSessionCount) session(s) continued mostly"
                    + " on a surface other than the one they started on"
            )
        }

        // The §1.3 flapping detector.
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

        // A disagreement is a build finding — a mint site stamped the wrong
        // source — so it goes to the builder, never to her as a triage.
        return CheckResult(source: "chat/sessions.json",
            id: id, title: title, status: status,
            detail: parts.joined(separator: "; ") + ".",
            harm: status == "warn" ? "Conversation messages cannot be reliably matched to their saved session and surface." : nil,
            owner: status == "warn" ? .builder : nil
        )
    }
}
