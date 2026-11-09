import SwiftUI
import AppKit
import CoreGraphics
import ScreenVision
import UniformTypeIdentifiers
import NativeAgentShared
import ChatSessionWork
import MemoryV2
import PersistenceCore
import ProviderRouting

// Blueprint: | `ChatContextFillBar.swift` | `ContextFillPresentation`: Shared context usage; missing measurements remain unavailable |

/// Absent provider figures must stay absent so visible and accessibility readouts cannot invent zero usage.
enum ContextFillPresentation {
    struct Usage: Equatable {
        let percent: Double
        let fillFraction: Double
    }

    /// Zero means the catalog states no window size, never a measured size.
    static func window(_ budget: Int) -> String? {
        budget > 0 ? NumberFormatter.localizedString(from: NSNumber(value: budget), number: .decimal) : nil
    }

    static func roundedPercent(_ value: Double) -> String {
        guard value.isFinite else { return "unavailable" }
        return String(format: "%.0f%%", value.rounded())
    }

    /// Use the owner's measured or estimated share rather than inventing usage locally.
    static func usage(_ status: SessionContextStatus) -> Usage {
        let percent = status.budget > 0 ? status.percent : 0
        return Usage(
            percent: percent,
            fillFraction: min(1, max(0, percent / 100))
        )
    }
}
