#if canImport(AppKit)
import Foundation
import AppKit
import ApplicationServices
import NativeAgentCore
// Blueprint: | `ActivityWatcher+Policy.swift` | Capture-thread policy and purge ordering; external policy may tighten only; deletion follows older writes |

extension ActivityWatcher {
    /// Apply policy on the capture thread before later events; UI callers must never block on AX.
    public func updatePolicy(_ policy: ActivityPolicy) {
        lock.lock()
        let wasEnabled = _captureEnabled && _policyAvailable
        _policyAvailable = true
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
            // Close under the disabled policy before removing event sources.
            if installed {
                applyPolicyOnCaptureThread()
                Task { [weak self] in await self?.stopForPolicyDisable(generation: generation) }
            }
        case (false, true):
            // Cold startup must read the latest policy before its first activation.
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

    /// Fence capture without overwriting consent; restart only after the prior pump actually settles.
    public func policyUnavailable() async {
        withLock { _policyAvailable = false }
        _ = await requestStop()
    }

    /// External file changes may only tighten the current capture policy.
    static func safelyPolled(
        _ polled: ActivityPolicy, current: ActivityPolicy, currentlyEnabled: Bool
    ) -> ActivityPolicy? {
        // Only the direct Trust Center path may enable capture; an external write that enables it while it is off is not consent.
        if polled.captureEnabled { guard currentlyEnabled, current.captureEnabled else { return nil } }

        // Disabling is always allowed, and it tightens like any other external change: an edit that turns capture off cannot also widen
        // what the next enable would allow.
        var safe = polled
        // Keep all existing exclusions when applying an external policy.
        safe.excludedBundleIDs = polled.excludedBundleIDs.union(current.excludedBundleIDs)
        safe.captureTitles = polled.captureTitles && current.captureTitles
        safe.browserTitlesEnabled = polled.browserTitlesEnabled && current.browserTitlesEnabled
        // Model-provider access requires separate explicit consent; external changes may only turn it off.
        safe.allowModelAccess = polled.allowModelAccess && current.allowModelAccess
        // This flag enables privacy, so an external change may only turn it on.
        safe.appNameOnlyMode = polled.appNameOnlyMode || current.appNameOnlyMode
        // External changes may shorten retention, never lengthen it.
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

    /// Hold the controller’s policy slot until the applied exclusion and all older writes precede its purge.
    public func purgeExcluded(bundleID: String) async throws -> Int {
        try await withCheckedThrowingContinuation { completion in
            let handoff = onCaptureThread {
                let policy = self.withLock { self._lastKnownPolicy }
                self.emit(self.engine.updatePolicy(policy, at: self.safeNow()))
                self.continuation?.yield(.purge(bundleID: bundleID, completion: completion))
            }
            if handoff.accepted { return }

            // Join the old pump before direct purging so no accepted write can outlive deletion.
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
