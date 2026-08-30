import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class ChatToastQueue {
    var current: String?

    private var queue: [String] = []
    private var recentKeys: [(key: String, at: Date)] = []
    private let displayDuration: TimeInterval
    @ObservationIgnored private let visibleEntryDidChange: @MainActor @Sendable (String?) -> Void

    init(
        displayDuration: TimeInterval = 2.0,
        visibleEntryDidChange: @escaping @MainActor @Sendable (String?) -> Void = { _ in }
    ) {
        self.displayDuration = max(0, displayDuration)
        self.visibleEntryDidChange = visibleEntryDidChange
    }

    /// `deduplicating: false` is for the chat composer sink: every call there
    /// is an independently actionable outcome, even when its human text has
    /// the same timestamp/UUID-normalized shape as a prior failure.
    func show(_ message: String, deduplicating: Bool = true) {
        let normalized = normalizedKey(message)
        if deduplicating {
            let normalizedCurrent = normalizedKey(current ?? "")
            if normalized == normalizedCurrent { return }

            let now = Date()
            recentKeys.removeAll { now.timeIntervalSince($0.at) > 10 }
            if recentKeys.contains(where: { $0.key == normalized }) { return }

            recentKeys.append((key: normalized, at: now))
            if recentKeys.count > 5 { recentKeys.removeFirst() }
        }

        if queue.count >= 10 { queue.removeFirst() }
        queue.append(message)
        if current == nil { advance() }
    }

    private func advance() {
        guard !queue.isEmpty else { return }
        setVisibleEntry(queue.removeFirst())
        DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration) {
            self.setVisibleEntry(nil)
            self.advance()
        }
    }

    private func setVisibleEntry(_ entry: String?) {
        current = entry
        visibleEntryDidChange(entry)
    }

    private func normalizedKey(_ value: String) -> String {
        var output = value
        output = output.replacingOccurrences(
            of: "\u{1B}\\][^\u{07}]*\u{07}",
            with: "",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: "\u{1B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        output = output.replacing(/\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z?\b/, with: "<ts>")
        output = output.replacing(/\b\d{2}:\d{2}:\d{2}\b/, with: "<time>")
        output = output.replacing(/\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/, with: "<id>")
        return output
    }
}

/// The composer is the visible sink for ChatView.showToast.  It deliberately
/// retains every producer occurrence: pin persistence, voice, and slash
/// command outcomes may share normalized text while still requiring separate
/// acknowledgement by the user.
@MainActor
enum ChatComposerBottomToastPresentation {
    static func show(_ message: String, in queue: ChatToastQueue) {
        queue.show(message, deduplicating: false)
    }

    static func visibleEntry(from queue: ChatToastQueue) -> String? {
        queue.current
    }
}

@Observable
@MainActor
final class ChatScrollCoordinator {
    var autoFollow = true
    var bottomSpacerVisible = false

    private var serial = 0
    private var scheduled = false
    private var lastScrollAt = Date.distantPast

    func markViewDisappeared() {
        serial &+= 1
        scheduled = false
    }

    func forceFollow() {
        autoFollow = true
    }

    func disarmFollow() {
        autoFollow = false
    }

    func setBottomSpacerVisible(_ visible: Bool) {
        bottomSpacerVisible = visible
    }

    func scrollToBottom(
        _ proxy: ScrollViewProxy,
        bottomAnchor: String,
        animated: Bool,
        delay: TimeInterval,
        force: Bool = false
    ) {
        guard force || autoFollow else { return }
        if force {
            serial &+= 1
            scheduled = false
        } else if scheduled {
            return
        }

        let minInterval: TimeInterval = animated ? 0.12 : 0.16
        let elapsed = Date().timeIntervalSince(lastScrollAt)
        let effectiveDelay = force ? delay : max(delay, max(0, minInterval - elapsed))
        let expectedSerial = serial
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + effectiveDelay) {
            guard expectedSerial == self.serial else { return }
            self.scheduled = false
            guard force || self.autoFollow else { return }
            self.lastScrollAt = Date()
            if animated {
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }
}
