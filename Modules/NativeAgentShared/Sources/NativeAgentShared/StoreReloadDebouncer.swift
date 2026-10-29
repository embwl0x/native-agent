import Foundation

// Blueprint: | `StoreReloadDebouncer.swift` | `StoreReloadDebouncer`: visibility-gated trailing-edge reloads with one in flight; exclusion lasts until actual reload exit; `Timer` owns cancellable delays for reloads, source invalidations, context and cognition |

/// Trailing-edge event debounce with visibility gating and one reload in flight.
public actor StoreReloadDebouncer {
    /// Actor-owned trailing-edge sleeper. Domain state stays with the caller.
    public struct Timer: Sendable {
        private var generation: UInt64 = 0
        private var pending: Task<Void, Never>?
        public init() {}
        public var isPending: Bool { pending != nil }

        public mutating func schedule(delay: Duration, fire: @escaping @Sendable (UInt64) async -> Void) {
            cancel()
            let expected = generation
            pending = Task {
                do { try await Task.sleep(for: delay) } catch { return }
                await fire(expected)
            }
        }

        /// Consume only the currently armed generation on the owning actor.
        public mutating func take(_ expected: UInt64) -> Bool {
            guard expected == generation, pending != nil else { return false }
            pending = nil
            return true
        }

        @discardableResult
        public mutating func cancel() -> Task<Void, Never>? {
            generation &+= 1
            let task = pending
            pending = nil
            task?.cancel()
            return task
        }
    }

    public typealias Reload = @Sendable () async -> Void
    private let delay: Duration
    private let reload: Reload
    private var visible = false
    private var dirty = false
    private var activeReload: Task<Void, Never>?
    private var timer = Timer()

    public init(delay: Duration = .milliseconds(500), reload: @escaping Reload) {
        self.delay = delay
        self.reload = reload
    }

    public func signal() {
        dirty = true
        if visible && activeReload == nil { schedule() }
    }

    public func setVisible(_ value: Bool) {
        visible = value
        if !value {
            timer.cancel()
        } else if dirty && activeReload == nil {
            schedule()
        }
    }

    public func cancel() {
        timer.cancel()
        dirty = false
        visible = false
        // Keep exclusion until reload actually exits, including work that
        // ignores cancellation. A subsequent visible lifecycle waits for it.
        activeReload?.cancel()
    }

    deinit { timer.cancel(); activeReload?.cancel() }

    private func schedule() {
        timer.schedule(delay: delay) { [weak self] expected in
            await self?.fire(expected)
        }
    }

    private func fire(_ expected: UInt64) {
        guard timer.take(expected), visible, dirty, activeReload == nil else { return }
        dirty = false
        activeReload = Task { [weak self, reload] in
            if !Task.isCancelled { await reload() }
            await self?.reloadFinished()
        }
    }

    private func reloadFinished() {
        activeReload = nil
        // Only current visibility and edges may admit a follow-up reload.
        if dirty && visible { schedule() }
    }
}
