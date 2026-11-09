import AppKit
import Foundation
import NativeAgentShared
import SwiftUI
// Blueprint: | `TodayView.swift` | Today's posted face and Activity destinations; opening the page starts no source reads |

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
    case cognitionProposals

    var id: String { rawValue }

    var sheetTitle: String {
        switch self {
        case .approvals, .inbox: "Inbox"
        case .memoryProposals: "Memories to look at"
        case .cognitionProposals: "REM Replay Lineage"
        }
    }
}

// MARK: - Today face and Activity destinations

struct TodayView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @State private var sheet: ActivitySection?

    var body: some View {
        FacePageView(page: "today", isReading: true)
            .sheet(item: $sheet) { section in
                PageSheetHost(title: section.sheetTitle, onDone: { sheet = nil }) {
                    switch section {
                    case .approvals, .inbox: FacePageView(page: "inbox")
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
    }

    private func openSection(_ raw: String?) {
        guard let raw, let section = ActivitySection(rawValue: raw), section != .memoryProposals else { return }
        sheet = section
    }
}
