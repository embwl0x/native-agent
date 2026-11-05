import AppKit
import AppToolRuntime
import AuthoredCapabilities
import DreamREMCycle
import EngineRuntime
import Foundation
import NativeAgentShared
import SwiftUI
import Transcripts
// Blueprint: | `TodayView.swift` | Today's source lifecycle and Activity destinations; the page itself is FacePageView over engine.pages |

// MARK: - Palette

/// Use primary-relative fills so the same palette remains legible in both appearances.
enum TodayPalette {
    /// Opaque cards keep haze beneath their text in either appearance.
    static let cardFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x35 / 255, green: 0x37 / 255, blue: 0x3A / 255, alpha: 1)
            : NSColor(srgbRed: 0.985, green: 0.98, blue: 0.975, alpha: 1)
    })
    /// Dark cards need a silver stroke; light cards need a dark stroke to retain visible boundaries.
    static let cardStroke = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.12)
            : NSColor(white: 0, alpha: 0.06)
    })
}

enum TodayMetrics {
    static let contentWidth: CGFloat = 920
    static let cardRadius: CGFloat = 12
    static let topPadding = NativeAgentSpacing.pageTop
    /// Share row height so body length cannot disrupt timeline alignment.
    static let rowContentHeight: CGFloat = 38
    /// Title-only rows need no empty body line.
    static let rowContentHeightSingle: CGFloat = 18
    /// Bound words before rendering so truncation does not cut them mid-word.
    static let rowLineLimit = 96
}

// MARK: - The full queues

/// Route full queues through Today, except memory proposals which belong to Memories.
enum ActivitySection: String, Sendable, Identifiable {
    case approvals
    case inbox
    case memoryProposals
    case selfImprovement
    case cognitionProposals

    var id: String { rawValue }

    var sheetTitle: String {
        switch self {
        case .approvals, .inbox: "Inbox"
        case .memoryProposals: "Memories to look at"
        case .selfImprovement: "Self-improvement"
        case .cognitionProposals: "REM Replay Lineage"
        }
    }
}

// MARK: - Today source lifecycle and existing Activity destinations

struct TodayView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @State private var sheet: ActivitySection?
    private var today: TodayReadout { appModel.engine.today }

    var body: some View {
        FacePageView(page: "today", isReading: today.isReading || appModel.panelRefreshCounts[.activity, default: 0] > 0)
            .sheet(item: $sheet) { section in
                PageSheetHost(title: section.sheetTitle, onDone: { sheet = nil }) {
                    switch section {
                    case .approvals, .inbox: FacePageView(page: "inbox")
                    case .selfImprovement: SelfImprovementView()
                    case .cognitionProposals: CognitionProposalsView()
                    case .memoryProposals: EmptyView()
                    }
                }
            }
            .liveOnAppear {
                if let raw = appModel.pendingActivitySectionRaw {
                    appModel.pendingActivitySectionRaw = nil
                    openSection(raw)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openActivitySectionRequest)) { note in
                guard !quietOffscreenRead else { return }
                appModel.pendingActivitySectionRaw = nil
                openSection(note.object as? String)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openActivityRootRequest)) { _ in
                guard !quietOffscreenRead else { return }
                sheet = nil
            }
            // Today is read by the engine from launch; while the Mac shows it, its queues and work status ride the same changes.
            .liveTask(id: [String(describing: scenePhase), appModel.activeChatSessionId]) { showToday(scenePhase == .active) }
            .onDisappear { if !quietOffscreenRead { today.extras = nil } }
            .liveTask(id: scenePhase) {
                guard scenePhase == .active else { return }
                appModel.engine.sync.observeStatus()
                await appModel.engine.inbox.observe()
            }
            .quietReadTask(live: false) {
                await today.refresh(appModel.engine, activeSessionID: appModel.activeChatSessionId)
            }
    }

    private func showToday(_ showing: Bool) {
        today.activeSessionID = appModel.activeChatSessionId
        guard showing else { today.extras = nil; return }
        let model = appModel
        today.extras = {
            _ = await model.refreshForSidebarItem(.activity)
            await model.publishWorkStatus()
        }
    }

    private func openSection(_ raw: String?) {
        guard let raw, let section = ActivitySection(rawValue: raw), section != .memoryProposals else { return }
        sheet = section
    }
}
