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
        case .cognitionProposals: "Growth proposals"
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
                    if let section = ActivitySection(rawValue: raw) { openSection(section) }
                }
            }
            .onMessage(OpenActivitySectionRequest.self) { message in
                guard !quietOffscreenRead else { return }
                appModel.pendingActivitySectionRaw = nil
                openSection(message.section)
            }
            .onMessage(OpenActivityRootRequest.self) { _ in
                guard !quietOffscreenRead else { return }
                sheet = nil
            }
    }

    private func openSection(_ section: ActivitySection) {
        guard section != .memoryProposals else { return }
        sheet = section
    }
}
