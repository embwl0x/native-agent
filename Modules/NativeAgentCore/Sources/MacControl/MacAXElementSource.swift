import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(AppKit)
import AppKit
import TrustCenter
import CoreGraphics
import UserNotifications
import Senses
import Experiences
import CryptoKit
import os
import CoreText
import ScreenCaptureKit
#endif
// Blueprint: | `MacAXElementSource.swift` | Read-only element source contracts and defaults |
/// because a half-readable tree is still useful perception.
public protocol MacAXElementSource: Sendable {
    /// `AXIsProcessTrusted()` in production.
    func isTrusted() -> Bool
    func frontmostApp() -> MacAXAppInfo?
    /// Frontmost (focused, else main, else first) window of the frontmost app.
    func frontmostWindowRoot() -> MacAXElementRef?
    /// Whether global wheel input at this point still lands in the captured
    /// container. Live AX handles are reminted, so compare underlying elements.
    func documentScrollTargetIsCurrent(window: MacAXElementRef, container: MacAXElementRef, frame: MacAXFrame, pid: Int32) -> Bool
    /// Window choice in the named process, or nil; identity checks re-read the frame's app.
    /// The default frontmost root represents a single-tree source.
    func windowRoot(pid: Int32) -> MacAXElementRef?
    /// Every window in `AXWindows` order with composite identity, so acts can re-read the captured window.
    /// Default: `windowRoot(pid:)` at index 0 for a single-tree source.
    func windowRoots(pid: Int32) -> [MacAXWindowHandle]
    /// Named-process metadata; the default answers only for the frontmost pid, otherwise nil.
    func appInfo(pid: Int32) -> MacAXAppInfo?
    /// Enumerate running UI apps without activating, launching or quitting them.
    /// The default reports only the frontmost app for a single-tree source.
    func runningApps() -> [MacAXAppInfo]
    /// The app's `AXMenuBar` element, or nil when it has
    /// none. Its own member rather than a role the ordinary walk may reach:
    /// every window walk in this module DELIBERATELY refuses to descend into a
    /// menu bar (400 items would eat the node budget on every look), and this
    /// keeps that refusal intact while giving the menu organ its one door.
    ///
    /// Default nil — a synthetic source has no menu bar unless it says it does,
    /// and "no menu bar" is a truthful answer that the organ reports in words.
    func menuBarRoot(pid: Int32) -> MacAXElementRef?
    /// Currently open native menus belonging to this frontmost app. They can
    /// be application siblings, not descendants of its document window.
    /// These roots are never window-relative action addresses.
    func transientMenuRoots(pid: Int32) -> [MacAXElementRef]
    func attributes(of ref: MacAXElementRef) -> MacAXAttributes?
    /// Only what the desktop capture's secret mask reads: role, subrole,
    /// title, value, frame and actions, without the display-only reads.
    /// Default: the full attribute read.
    func maskingAttributes(of ref: MacAXElementRef) -> MacAXAttributes?
    /// Writable action attributes, queried only for selected screen marks.
    func settableAttributes(of ref: MacAXElementRef) -> [String]
    func children(of ref: MacAXElementRef) -> [MacAXElementRef]
    /// Child count WITHOUT materializing the array. Default falls back to
    /// `children(of:).count`; the live source uses the ranged AX count API so a
    /// pathological node (100k children) can't force a huge bridge just to be
    /// counted at the depth cap. nil = the
    /// app did not answer: unknown, never an empty subtree.
    func childCount(of ref: MacAXElementRef) -> Int?
    /// At most `limit` children. Default prefixes `children(of:)`; the live
    /// source uses `AXUIElementCopyAttributeValues` ranged fetch so the whole
    /// child array is never bridged when only a bounded slice can still fit
    /// under the node cap.
    func children(of ref: MacAXElementRef, limit: Int) -> [MacAXElementRef]
    /// The child-index path of the app's focused element, relative to the same
    /// window root `frontmostWindowRoot()` returns — or nil when this source
    /// CANNOT TELL. The default is nil for exactly that reason: a source that
    /// has no notion of focus must report absence, never a guess (the
    /// perception compiler reports "focus: unknown" rather than naming "the
    /// first text field", which is how a look starts lying about the cursor).
    /// Read-only like every other member here.
    func focusedElementPath() -> [Int]?
    /// Focus path anchored to a root the caller ALREADY WALKED: nil when the
    /// focused element is not under that root (focus moved to another window
    /// between the walk and this call). Default defers to `focusedElementPath()`
    /// for sources with a single tree (synthetic/test sources).
    func focusedElementPath(relativeTo root: MacAXElementRef?) -> [Int]?
    /// The underlying element's identity, so one walk
    /// never reads the same element twice through two parents. nil = cannot
    /// tell (synthetic sources), which dedupes nothing.
    func elementHash(_ ref: MacAXElementRef) -> Int?
    func sameElement(_ lhs: MacAXElementRef, _ rhs: MacAXElementRef) -> Bool
}
public extension MacAXElementSource {
    func maskingAttributes(of ref: MacAXElementRef) -> MacAXAttributes? { attributes(of: ref) }
    func settableAttributes(of ref: MacAXElementRef) -> [String] { [] }
    func elementHash(_ ref: MacAXElementRef) -> Int? { nil }
    func sameElement(_ lhs: MacAXElementRef, _ rhs: MacAXElementRef) -> Bool { lhs == rhs }
    func documentScrollTargetIsCurrent(window: MacAXElementRef, container: MacAXElementRef, frame: MacAXFrame, pid: Int32) -> Bool {
        frontmostApp()?.processIdentifier == pid && frontmostWindowRoot() == window
            && attributes(of: container)?.frame == frame
    }
    func transientMenuRoots(pid: Int32) -> [MacAXElementRef] { [] }
    func childCount(of ref: MacAXElementRef) -> Int? { children(of: ref).count }
    func children(of ref: MacAXElementRef, limit: Int) -> [MacAXElementRef] {
        limit <= 0 ? [] : Array(children(of: ref).prefix(limit))
    }
    func focusedElementPath() -> [Int]? { nil }
    func focusedElementPath(relativeTo root: MacAXElementRef?) -> [Int]? { focusedElementPath() }
    func windowRoot(pid: Int32) -> MacAXElementRef? { frontmostWindowRoot() }
    func windowRoots(pid: Int32) -> [MacAXWindowHandle] {
        guard let root = windowRoot(pid: pid) else { return [] }
        let attributes = attributes(of: root)
        return [MacAXWindowHandle(
            ref: root,
            identity: MacAXWindowIdentity(
                pid: pid,
                index: 0,
                role: attributes?.role ?? "AXWindow",
                subrole: attributes?.subrole,
                title: attributes?.title,
                frame: attributes?.frame
            )
        )]
    }
    func appInfo(pid: Int32) -> MacAXAppInfo? {
        guard let app = frontmostApp(), app.processIdentifier == pid else { return nil }
        return app
    }
    func runningApps() -> [MacAXAppInfo] { [frontmostApp()].compactMap { $0 } }
    func menuBarRoot(pid: Int32) -> MacAXElementRef? { nil }
}
