#if canImport(AppKit)
import Foundation
import AppKit
import ApplicationServices
import NativeAgentCore
// Blueprint: | `ActivityWatcher+Policy.swift` | The same watcher's queued policy updates, tightening-only external policy reads and capture-ordered purge/wipe requests; policy reaches the engine before capture and deletion follows every older store write |

extension ActivityWatcher {
    /// Apply policy on the capture thread before later events: disabling closes
    /// the span and removes sources, enabling installs them, and exclusion edits
    /// let the engine emit retro-close commands. UI callers never wait on AX.
    public func updatePolicy(_ policy: ActivityPolicy) {
        lock.lock()
        let wasEnabled = _captureEnabled
        _captureEnabled = policy.captureEnabled
        _lastKnownPolicy = policy
        let installed = _installed
        let generation = _generation
        var announceStopping = false
        if policy.captureEnabled {
            if _stopping || _stopRequested { _restartAfterStop = true }
        } else {
            _stopRequested = installed
            _restartAfterStop = false
            if installed, _lifecycleState != .stopping {
                _lifecycleState = .stopping
                announceStopping = true
            }
        }
        let stopPending = _stopping || _stopRequested
        lock.unlock()
        if announceStopping { lifecycleChanged?(.stopping) }

        switch (wasEnabled || installed, policy.captureEnabled) {
        case (_, false):
            // OFF. Push the policy into the engine first so the open span is
            // closed under a policy that forbids capture (the engine's
            // updatePolicy emits the close), then remove every event source.
            if installed {
                applyPolicyOnCaptureThread()
                Task { [weak self] in await self?.stopForPolicyDisable(generation: generation) }
            }
        case (false, true):
            // ON, from cold. Startup reads the latest policy on its own thread
            // before the first activation.
            if stopPending {
                applyPolicyOnCaptureThread()
            } else {
                Task { [weak self] in _ = await self?.startBounded() }
            }
        case (true, true):
            if installed {
                applyPolicyOnCaptureThread()
            } else {
                Task { [weak self] in _ = await self?.startBounded() }
            }
        }
    }

    /// External file changes may only tighten the current capture policy.
    static func safelyPolled(
        _ polled: ActivityPolicy, current: ActivityPolicy, currentlyEnabled: Bool
    ) -> ActivityPolicy? {
        // Disabling is always allowed, whatever else the file says.
        guard polled.captureEnabled else { return polled }
        // An out-of-band write may never ENABLE capture. Only the Trust Center
        // path (a direct `updatePolicy`) can do that.
        guard currentlyEnabled, current.captureEnabled else { return nil }

        var safe = polled
        safe.captureEnabled = true
        // Never drop below the exclusions already in force.
        safe.excludedBundleIDs = polled.excludedBundleIDs.union(current.excludedBundleIDs)
        // false → true is loosening, so it is refused; true → false is tightening.
        safe.captureTitles = polled.captureTitles && current.captureTitles
        safe.browserTitlesEnabled = polled.browserTitlesEnabled && current.browserTitlesEnabled
        // Model-provider access is a separate explicit consent. A file change
        // can turn it off, never on.
        safe.allowModelAccess = polled.allowModelAccess && current.allowModelAccess
        // The one flag whose TRUE is the private setting: it can only go on.
        safe.appNameOnlyMode = polled.appNameOnlyMode || current.appNameOnlyMode
        // Keeping data for longer is loosening; keeping it for less is not.
        safe.retentionDays = min(polled.retentionDays, current.retentionDays)
        return safe
    }

    private func applyPolicyOnCaptureThread() {
        let apply: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            // A queued UI update must not restore a superseded policy.
            let policy = self.withLock { self._lastKnownPolicy }
            self.emit(self.engine.updatePolicy(policy, at: self.safeNow()))
        }
        let runLoop = withLock { _runLoop }
        if let runLoop, CFRunLoopGetCurrent() === runLoop { apply() }
        else { onCaptureThread(apply) }
    }

    /// Apply the exclusion before placing its purge behind every older write.
    /// The controller holds its policy-mutation slot until this completes.
    public func purgeExcluded(bundleID: String) async throws -> Int {
        try await withCheckedThrowingContinuation { completion in
            let handoff = onCaptureThread {
                let policy = self.withLock { self._lastKnownPolicy }
                self.emit(self.engine.updatePolicy(policy, at: self.safeNow()))
                self.continuation?.yield(.purge(bundleID: bundleID, completion: completion))
            }
            if handoff.accepted { return }

            // No capture thread can enqueue more writes. Join any old pump
            // before purging directly, including during shutdown's drain.
            Task {
                await handoff.drainingPump?.value
                do { completion.resume(returning: try await store.purge(bundleID: bundleID)) }
                catch { completion.resume(throwing: error) }
            }
        }
    }

    /// Close, wipe and reseed share the same capture/pump order as ordinary writes.
    public func wipeAll() async throws -> Int {
        try await withCheckedThrowingContinuation { completion in
            let handoff = onCaptureThread {
                self.feed(.terminate(at: self.safeNow()))
                self.detachObserver()
                self.continuation?.yield(.wipe(completion: completion))
                self.seedFromFrontmostApplication()
            }
            if handoff.accepted { return }
            Task {
                await handoff.drainingPump?.value
                do { completion.resume(returning: try await store.wipeAll()) }
                catch { completion.resume(throwing: error) }
            }
        }
    }
}
#endif
