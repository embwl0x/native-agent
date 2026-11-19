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


    /// Use the owner's measured or estimated share rather than inventing usage locally.
    static func usage(_ status: SessionContextStatus) -> Usage {
        let percent = status.budget > 0 ? status.percent : 0
        return Usage(
            percent: percent,
            fillFraction: min(1, max(0, percent / 100))
        )
    }
}
