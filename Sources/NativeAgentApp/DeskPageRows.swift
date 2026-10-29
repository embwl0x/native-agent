import StandingBots
import SwiftUI
import AppKit
import PersistenceCore
import Desk
import EngineRuntime
import TriggerScheduler
import WorkshopExecution
import Cognition
import BackgroundLoops
import NativeAgentShared
import ApprovalInbox
import NotificationInbox
import BackgroundWork
import ApprovalTransactions
import Observation
import NativeAgentCore
import DeviceSync

// Blueprint: | `DeskPageRows.swift` | Desk row metrics, project/detail rows, action notices and execution labels |

enum DeskPageMetrics {
    // Row titles and supporting text use the shell's shared type ramp.
    static let titleSize: CGFloat = ShellType.bodySize
    static let lineSize: CGFloat = ShellType.labelSize
    static let metaSize: CGFloat = ShellType.labelSize
    /// How many rows a fold shows before it says how many more there are.
    static let foldRowCap = 60
}

/// A project's Chat entry, next step and counted progress.
struct DeskProjectRow: View {
    let title: String
    let line: String
    let meta: String
    var done: Int? = nil
    var total: Int? = nil
    /// Opening the title carries the item's handle into Chat.
    let onOpenTitle: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Button(action: onOpenTitle) {
                    Text(TodayWords.bounded(title, limit: 64))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(NativeAgentShell.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("desk.row.open")
                if !line.isEmpty {
                    Text(TodayWords.bounded(line, limit: 90))
                        .font(.system(size: 12))
                        .foregroundStyle(NativeAgentShell.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(height: line.isEmpty ? TodayMetrics.rowContentHeightSingle : 34, alignment: .leading)
            Spacer(minLength: 12)
            if let done, let total, total > 0 {
                AliveProgressBar(done: done, total: total)
            } else if !meta.isEmpty {
                Text(meta)
                    .font(.system(size: 12))
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityIdentifier("desk.row")
    }
}

/// An open fold supplies the shared card around these rows.
struct DeskPageDetailRow: View {
    let title: String
    let line: String
    let meta: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: DeskPageMetrics.titleSize, weight: .semibold))
                .foregroundStyle(NativeAgentShell.text)
                .lineLimit(1)
                .truncationMode(.tail)
            if !line.isEmpty {
                Text(line)
                    .font(.system(size: DeskPageMetrics.lineSize, weight: .medium))
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if !meta.isEmpty {
                Text(meta)
                    .font(.system(size: DeskPageMetrics.metaSize))
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("desk.detail-row")
    }
}

struct DeskActionNotice: Equatable {
    let text: String
    let isError: Bool
}

/// Every settled veto gets a notice that distinguishes refusal from completion.
enum DeskPursuitVetoNotice {
    static func receipt(for outcome: WorkshopVeto.Outcome) -> DeskActionNotice {
        switch outcome {
        case .completed:
            return DeskActionNotice(text: "Pursuit vetoed and closed.", isError: false)
        case .alreadyVetoed:
            return DeskActionNotice(text: "Pursuit was already vetoed.", isError: false)
        case .inFlight:
            return DeskActionNotice(text: "That veto is still being written.", isError: false)
        case .failed(let detail):
            return DeskActionNotice(text: "Veto failed: \(detail)", isError: true)
        }
    }
}

extension DeskExecutionPresentation {
    struct Pill: Sendable, Equatable {
        let label: String
        let tone: DeskPresentationTone
    }

    static func pill(for status: String) -> Pill {
        switch status {
        case "running": return Pill(label: "running", tone: .info)
        case "queued": return Pill(label: "queued", tone: .neutral)
        case "blocked_on_approval": return Pill(label: "needs approval", tone: .warning)
        case "completed": return Pill(label: "done", tone: .success)
        case "failed": return Pill(label: "failed", tone: .danger)
        case "cancelled": return Pill(label: "cancelled", tone: .neutral)
        default:
            let human = status.replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Pill(label: human.isEmpty ? "unknown status" : "unknown: \(human)", tone: .neutral)
        }
    }

    static func verificationLabel(_ verification: WorkshopVerificationRecord) -> String {
        switch verification.status {
        case .satisfied:
            let methods = verification.methods.map { method in
                switch method {
                case "exact_output": return "exact output"
                case "file_bytes": return "file bytes"
                default: return method.replacingOccurrences(of: "_", with: " ")
                }
            }.filter { !$0.isEmpty }.joined(separator: " + ")
            return methods.isEmpty ? "verified" : "verified: \(methods)"
        case .failed:
            return "verification failed"
        case .unverified:
            return "completed; outcome not independently verified"
        }
    }
}
