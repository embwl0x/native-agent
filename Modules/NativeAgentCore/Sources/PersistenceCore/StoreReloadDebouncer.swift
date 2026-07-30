import Foundation

/// Trailing-edge event debounce with visibility gating and one reload in flight.
public actor StoreReloadDebouncer {
    public typealias Reload = @Sendable () async -> Void
    private let delay: Duration
    private let reload: Reload
    private var visible = false
    private var dirty = false
    private var loading = false
    private var generation: UInt64 = 0
    private var pending: Task<Void, Never>?

    public init(delay: Duration = .milliseconds(500), reload: @escaping Reload) {
        self.delay = delay
        self.reload = reload
    }

    public func signal() {
        dirty = true
        if visible && !loading { schedule() }
    }

    public func setVisible(_ value: Bool) {
        visible = value
        if !value {
            pending?.cancel()
            pending = nil
        } else if dirty && !loading {
            schedule()
        }
    }

    public func cancel() {
        pending?.cancel()
        pending = nil
        dirty = false
        visible = false
    }

    private func schedule() {
        generation &+= 1
        let expected = generation
        pending?.cancel()
        pending = Task { [weak self, delay] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.fire(expected)
        }
    }

    private func fire(_ expected: UInt64) async {
        guard expected == generation, visible, dirty, !loading else { return }
        pending = nil
        dirty = false
        loading = true
        await reload()
        loading = false
        if dirty && visible { schedule() }
    }
}
