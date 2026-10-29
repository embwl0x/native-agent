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

// Blueprint: | `PageSheetHost.swift` | Shared page sheet framing and focused Desk schedule/research sheets |

/// The focused surfaces the page opens without duplicating their controls.
enum DeskPageSheet: String, Identifiable {
    case schedule
    case research

    var id: String { rawValue }
}

struct DeskPageSheetHost: View {
    let sheet: DeskPageSheet
    let onDone: () -> Void

    private var title: String {
        switch sheet {
        case .schedule: "What runs on a timer"
        case .research: "Look something up"
        }
    }

    var body: some View {
        PageSheetHost(title: title, onDone: onDone) {
            switch sheet {
            case .schedule: SchedulerView()
            case .research: ResearchView()
            }
        }
    }
}

/// Shared title, Done button and full surface for page sheets.
struct PageSheetHost<Content: View>: View {
    let title: String?
    let onDone: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let title { Text(title).font(ShellType.bodySemibold) }
                Spacer(minLength: 0)
                Button("Done", action: onDone)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 520, idealHeight: 700)
    }
}
