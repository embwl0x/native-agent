// MARK: - ScreenVisionPermissions
//
// Free-function entry points for Screen Recording TCC checks. The actor in
// ScreenVision.swift delegates to these so a caller that just wants to know
// "are we authorized?" (e.g. to gate a UI button) doesn't have to instantiate
// the actor.

import Foundation
import CoreGraphics

public enum ScreenVisionPermissions {
    /// Synchronous preflight — does NOT trigger a prompt.
    /// Wraps `CGPreflightScreenCaptureAccess()`.
    public static func isAuthorized() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    /// Returns true iff Screen Recording is granted. Triggers the OS prompt
    /// on first call if not yet granted; on subsequent calls just returns
    /// the current decision (CG semantics).
    public static func requestAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }
}
