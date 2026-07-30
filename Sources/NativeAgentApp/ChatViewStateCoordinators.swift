import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class ChatToastQueue {
    var current: String?

    private var queue: [String] = []
    private var recentKeys: [(key: String, at: Date)] = []

    func show(_ message: String) {
        let normalized = normalizedKey(message)
        let normalizedCurrent = normalizedKey(current ?? "")
        if normalized == normalizedCurrent { return }

        let now = Date()
        recentKeys.removeAll { now.timeIntervalSince($0.at) > 10 }
        if recentKeys.contains(where: { $0.key == normalized }) { return }

        recentKeys.append((key: normalized, at: now))
        if recentKeys.count > 5 { recentKeys.removeFirst() }

        if queue.count >= 10 { queue.removeFirst() }
        queue.append(message)
        if current == nil { advance() }
    }

    private func advance() {
        guard !queue.isEmpty else { return }
        current = queue.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.current = nil
            self.advance()
        }
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
