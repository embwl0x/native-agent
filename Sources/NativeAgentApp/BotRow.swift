import Foundation
import SwiftUI
import NativeAgentShared
import StandingBots
import NativeAgentCore
import EngineRuntime
import Transcripts
import TurnTrace
import ChatTurnRuntime
import ChatSessionWork
import ToolExecution
import MemoryV2
import AppToolRuntime
import ApprovalTransactions
import PersistenceCore
import ToolRegistry
import ProviderRouting
import DoctorChecks
import Research
import TelegramBot
import Connectors
import AttentionRouting
import WidgetKit
import AppIntents
import Observation
import BackgroundLoops
import PersonaEngine
import TrustCenter
import MultimodalTTS
import SystemOps
import DeviceSync
import BackgroundWork
import ChatToolRuntime
import ApprovalInbox
import AppKit
import MacControl
import ChatToolParsing
import UniformTypeIdentifiers
import Desk
// Blueprint: | `BotRow.swift` | Helper shelf rows, status marks, timing and shared accessibility wording |

/// The Mac draws the shared helper status in the shell's colors.
extension BotsShelfRecord {
    var word: String { statusWord }
    var color: Color {
        switch status {
        case .running, .ready: NativeAgentShell.calm
        case .queued, .new, .stopped: NativeAgentShell.secondary
        case .paused: NativeAgentShell.tertiary
        case .waitingForApproval, .waitingOnPerson: NativeAgentShell.needsYou
        case .failed, .interrupted, .needsModelChoice: NativeAgentShell.trouble
        }
    }

}

/// The little bot itself: a rounded tile with one light that breathes while it works.
struct BotMark: View {
    let state: BotsShelfRecord
    var allowsMotion = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
            .overlay {
                if state.running && !reduceMotion && allowsMotion {
                    light.phaseAnimator([false, true]) { content, expanded in
                        content
                            .scaleEffect(expanded ? 1.35 : 1)
                            .opacity(expanded ? 0.55 : 1)
                    } animation: { _ in NativeAgentMotion.breathe }
                } else {
                    light
                }
            }
            .frame(width: 30, height: 30)
            .accessibilityLabel(state.word)
    }

    private var light: some View {
        Circle().fill(state.color)
            .frame(width: 8, height: 8)
            .shadow(color: state.color.opacity(state.running ? 0.6 : 0), radius: 4)
    }
}

/// VoiceOver and the quiet page read share the helper row's description.
enum BotRowAccessibility {
    static func spokenName(_ record: BotsShelfRecord) -> String {
        record.definition.brief.isEmpty
            ? record.definition.name
            : "\(record.definition.name). \(record.definition.brief)"
    }
    /// State word, what it last said, when it runs next, and a run it missed.
    static func spokenState(_ record: BotsShelfRecord) -> String {
        [record.word, record.lastOutcomeLine, record.scheduleLine, record.missedLine]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }
}

/// One helper in the Advanced shell's group card: a glyph tile, the name, its
/// timing and last run in plain words, and a status pill. The tile never
/// animates; a helper waiting on him wears the waiting dot, the one teal.
struct BotRow: View {
    let record: BotsShelfRecord

    private var isManual: Bool {
        if case .manual = record.definition.cadence, record.definition.eventTrigger == nil { return true }
        return false
    }

    /// The state, never the timing: Scheduled, On event, Paused or Manual.
    private var status: String {
        if record.definition.paused { return "Paused" }
        if isManual { return "Manual" }
        return record.definition.eventTrigger != nil ? "On event" : "Scheduled"
    }

    /// Clock for a schedule, bolt for an event, a plain tool for run-by-hand.
    /// Not "play": the tile is decoration (the row opens the helper), and a
    /// play glyph read as a Run button.
    private var glyph: String {
        if record.definition.eventTrigger != nil { return "bolt" }
        return isManual ? "wrench.and.screwdriver" : "clock"
    }

    /// When it runs, in the words the card already uses — never a time the
    /// scheduler will not keep. Nil for a manual helper: the pill says it.
    private var timing: String? {
        if record.needsModelChoice { return "Choose a model" }
        if !record.definition.paused, !record.unattendedAllowed, !record.runsWithUnattendedOff {
            return BotsShelfUnattended.cardLine
        }
        if let trigger = record.definition.eventTrigger { return "Wakes on \(trigger.label)" }
        if isManual { return nil }
        return record.cadence
    }

    /// How its last run went, and a run it missed.
    private var last: String {
        var parts: [String] = []
        if record.running {
            parts.append("running now")
        } else if record.queued {
            parts.append("queued")
        } else if let latest = record.latestEntry {
            let when = BotsShelfRecord.shortDate(latest.runAt)
            switch latest.runtimeStatus {
            case .completed: parts.append("last ran \(when)")
            case .waitingForApproval: parts.append("waiting for approval")
            case .waitingOnPerson: parts.append("waiting on you")
            case .failed: parts.append("last run failed \(when)")
            case .stopped: parts.append("last run stopped \(when)")
            case .interrupted: parts.append("last run interrupted \(when)")
            }
        } else {
            parts.append("no runs yet")
        }
        if let missed = record.missed { parts.append("missed \(BotsShelfRecord.shortDate(missed.dueAt))") }
        return parts.joined(separator: " · ")
    }

    private var waitingOnHim: Bool {
        !record.running && record.latestEntry.map { $0.runtimeStatus == .waitingForApproval || $0.runtimeStatus == .waitingOnPerson } == true
    }

    /// "at 8:30 AM" today, "tomorrow at 8:30 AM", else "on Sep 25 at 8:30 AM".
    static func when(_ date: Date, now: Date = Date()) -> String {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.autoupdatingCurrent
        let time = DateFormatter()
        time.setLocalizedDateFormatFromTemplate("jm")
        time.timeZone = TimeZone.autoupdatingCurrent
        if calendar.isDate(date, inSameDayAs: now) { return "at \(time.string(from: date))" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(time.string(from: date))"
        }
        return "on \(BotsShelfRecord.shortDate(date))"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                .fill(NativeAgentShell.softFill)
                .overlay {
                    Image(systemName: glyph)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NativeAgentShell.secondary)
                }
                .overlay(alignment: .topTrailing) {
                    if waitingOnHim { AliveWaitingDot().offset(x: 3, y: -3) }
                }
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                Text(record.definition.name)
                    .font(ShellType.rowTitle)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text([timing, last].compactMap { $0 }.joined(separator: " · "))
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(height: TodayMetrics.rowContentHeight, alignment: .leading)
            Spacer(minLength: 12)
            AlivePill(status)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BotRowAccessibility.spokenName(record))
        .accessibilityValue(BotRowAccessibility.spokenState(record))
    }
}
