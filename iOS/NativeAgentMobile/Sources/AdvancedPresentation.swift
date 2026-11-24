import SwiftUI
import Foundation
import NativeAgentShared
// Blueprint: | `AdvancedPresentation.swift` | Shared mobile presentation and design samples |

enum MobileDesignSamples {
    static var screen: String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-designScreen"), args.indices.contains(index + 1) {
            return args[index + 1]
        }
        #endif
        return nil
    }
}

extension View {
    func mobileReadingScreen() -> some View {
        scrollContentBackground(.hidden)
            .background { AliveRoom() }
            .presentationBackground { AlivePalette.room }
            .hazeTinted()
            .environment(\.defaultMinListRowHeight, NativeAgentMobileTheme.Layout.controlHeight)
            .navigationBarTitleDisplayMode(.inline)
            .allowsHitTesting(MobileDesignSamples.screen == nil)
    }
}

enum StatusConnectionPresentation {
    enum SyncState: Equatable {
        case current(age: TimeInterval)
        case stale(age: TimeInterval, limit: TimeInterval)
        case neverSynced
        case clockMismatch(futureBy: TimeInterval)
    }

    static func syncState(
        lastSyncedAt: Date?,
        now: Date = Date(),
        staleAfter: TimeInterval? = nil,
        maximumFutureClockSkew: TimeInterval = 60
    ) -> SyncState {
        guard let lastSyncedAt else { return .neverSynced }

        let age = now.timeIntervalSince(lastSyncedAt)
        if age < -max(0, maximumFutureClockSkew) {
            return .clockMismatch(futureBy: -age)
        }
        if let staleAfter, age >= max(0, staleAfter) { return .stale(age: age, limit: max(0, staleAfter)) }
        return .current(age: max(0, age))
    }

    static func ageText(_ interval: TimeInterval) -> String {
        guard interval.isFinite, let seconds = Int(exactly: max(0, interval).rounded(.down)) else { return "age unavailable" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h"
    }

    static func cardValue(for state: SyncState) -> String {
        switch state {
        case .current(let age): return "\(ageText(age)) ago"
        case .stale(let age, _): return "STALE · \(ageText(age)) old"
        case .neverSynced: return "Never synced"
        case .clockMismatch: return "Clock mismatch"
        }
    }

    static func detail(for state: SyncState) -> String? {
        switch state {
        case .current:
            return nil
        case .stale(_, let limit):
            return "Expected a newer iCloud snapshot within \(ageText(limit))."
        case .neverSynced:
            return "No iCloud snapshot has reached this phone yet."
        case .clockMismatch(let futureBy):
            return "The Mac snapshot is \(ageText(futureBy)) ahead of this phone."
        }
    }

    static func presenceDetail(for state: SyncState) -> String? {
        switch state {
        case .current:
            return nil
        case .stale(_, let limit):
            return "Expected to hear from your Mac within \(ageText(limit))."
        case .neverSynced:
            return "This iPhone has not heard from your Mac yet."
        case .clockMismatch(let futureBy):
            return "The Mac's last contact is \(ageText(futureBy)) ahead of this phone."
        }
    }

    static func needsAttention(_ state: SyncState) -> Bool {
        switch state {
        case .current: false
        case .stale, .neverSynced, .clockMismatch: true
        }
    }
}
