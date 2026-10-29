import SwiftUI
import SwarmRuns
import Foundation
import NativeAgentShared
import EngineRuntime
import Agents
import ChatSessionWork
import AgentWorkspace
import NativeAgentCore
import PersistenceCore
import StandingBots
import ProviderRouting
import AppKit
import AppToolRuntime
// Blueprint: | `SimpleCrewThread.swift` | Read-only crew progress, worker evidence, outcomes and synthesis |

/// A crew's run, read-only: each worker and what it has come back with so far,
/// then the findings pulled together.
struct SimpleCrewThread: View {
    let crew: SimpleCrew
    @State private var reading = ChatScrollFollow(following: false)

    /// How a finished crew went, in words.
    static func outcome(_ crew: SimpleCrew) -> String {
        switch crew.status {
        case "completed": return "Done"
        case "partial": return "Done, some workers fell short"
        case "cancelled": return "Stopped"
        case "interrupted": return "Interrupted · completion time unknown"
        case "unknown": return "Liveness unknown"
        case "failed": return "Didn't finish"
        default: return crew.live ? "Working now" : "Finished"
        }
    }

    var body: some View {
        let count = crew.workers.count == 1 ? "1 worker" : "\(crew.workers.count) workers"
        TranscriptScrollView(coordinator: reading) {
            VStack(alignment: .leading, spacing: 26) {
                Text(crew.live ? "I sent \(count) on this. What each finds comes in here as they finish."
                               : "I sent \(count) on this.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                ForEach(crew.workers) { worker in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(worker.name)
                            .font(ShellType.labelSemibold)
                            .foregroundStyle(NativeAgentShell.text)
                        Text(SimpleTranscriptEntry.inline(crew.liveness == .unknown && worker.status == "working"
                            ? "Liveness unknown" : Self.said(worker)))
                            .font(worker.status == "completed" ? ShellType.body : ShellType.label)
                            .foregroundStyle(worker.status == "completed" ? NativeAgentShell.text : NativeAgentShell.secondary)
                            .lineSpacing(NativeAgentShellLayout.replyLineSpacing)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                    .readingBlock("worker:\(worker.id)")
                }
                if let synthesis = crew.synthesis {
                    SimpleTranscriptEntry(speaker: "Together", text: synthesis, at: crew.at)
                        .readingBlock("synthesis")
                } else if crew.live, crew.settled {
                    Text("Pulling it together…")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.tertiary)
                }
            }
            .simpleRoomColumn()
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .defaultScrollAnchor(.top, for: .alignment)
        .roomTopChrome {
            SimpleThreadHeader(title: crew.task, subtitle: "\(Self.outcome(crew)) · \(count)") {
                SimpleClockTile(size: 36, symbol: "person.3", working: crew.live)
            }
        }
    }

    private static func said(_ worker: SimpleCrew.Worker) -> String {
        switch worker.status {
        case "working": return "Working…"
        case "completed": return worker.text
        case "cancelled": return "Stopped" + (worker.text.isEmpty ? "." : ": " + worker.text)
        default: return "Didn't finish" + (worker.text.isEmpty ? "." : ": " + worker.text)
        }
    }
}
