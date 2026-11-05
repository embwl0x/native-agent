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
// Blueprint: | `MacAXElementSource.swift` | Read-only AX contracts preserve gaps and observation-bound focus |
/// Keep partially readable trees useful without treating gaps as absence.
public protocol MacAXElementSource: Sendable {
    func isTrusted() -> Bool
    func frontmostApp() -> MacAXAppInfo?
    func frontmostWindowRoot(context: MacOperationContext) -> MacAXElementRef?
    /// Whether global wheel input at this point still lands in the captured container. Live AX handles are reminted, so compare underlying elements.
    func documentScrollTargetIsCurrent(window: MacAXElementRef, container: MacAXElementRef, frame: MacAXFrame, pid: Int32, context: MacOperationContext) -> Bool
    /// Window choice in the named process, or nil; identity checks re-read the frame's app. The default frontmost root represents a single-tree source.
    func windowRoot(pid: Int32, context: MacOperationContext) -> MacAXElementRef?
    /// Preserve AXWindows order and composite identities so acts can re-read the captured window; single-tree sources expose index zero.
    func windowRoots(pid: Int32, context: MacOperationContext) -> [MacAXWindowHandle]
    /// Named-process metadata; the default answers only for the frontmost pid, otherwise nil.
    func appInfo(pid: Int32) -> MacAXAppInfo?
    /// App enumeration must leave launch, activation and quit state untouched; single-tree sources expose only their frontmost app.
    func runningApps() -> [MacAXAppInfo]
    /// Read the menu bar separately: window walks exclude it so hundreds of menu items cannot consume every look's node budget. Sources without menus report
    /// nil.
    func menuBarRoot(pid: Int32, context: MacOperationContext) -> MacAXElementRef?
    /// Currently open native menus belonging to this frontmost app. They can be application siblings, not descendants of its document window. These roots are
    /// never window-relative action addresses.
    func transientMenuRoots(pid: Int32, context: MacOperationContext) -> [MacAXElementRef]
    func attributes(of ref: MacAXElementRef, context: MacOperationContext) -> MacAXAttributes?
    func checkedAttributes(of ref: MacAXElementRef, context: MacOperationContext) throws -> MacAXAttributes
    /// Secret-mask reads need role, subrole, title, value, frame and actions; display-only reads add no masking evidence.
    func maskingAttributes(of ref: MacAXElementRef, context: MacOperationContext) -> MacAXAttributes?
    func checkedMaskingAttributes(of ref: MacAXElementRef, context: MacOperationContext) throws -> MacAXAttributes
    /// Query writability only for selected marks to bound AX work.
    func settableAttributes(of ref: MacAXElementRef, context: MacOperationContext) -> [String]
    func children(of ref: MacAXElementRef, context: MacOperationContext) -> [MacAXElementRef]
    /// Use ranged child counts to avoid materializing huge arrays at the depth cap. Nil is an unanswered read, never an empty subtree.
    func childCount(of ref: MacAXElementRef, context: MacOperationContext) -> Int?
    func checkedChildCount(of ref: MacAXElementRef, context: MacOperationContext) throws -> Int
    /// Ranged child fetches avoid bridging children that cannot fit under the node cap.
    func children(of ref: MacAXElementRef, limit: Int, context: MacOperationContext) -> [MacAXElementRef]
    func checkedChildren(of ref: MacAXElementRef, limit: Int, context: MacOperationContext) throws -> [MacAXElementRef]
    /// Focus paths share the window root's child ordering; unknown focus remains nil rather than guessing an editor.
    func focusedElementPath(context: MacOperationContext) -> [Int]?
    /// Anchor focus to the root already walked; focus outside it is unknown. Single-tree sources use their sole focus path.
    func focusedElementPath(relativeTo root: MacAXElementRef?, context: MacOperationContext) -> [Int]?
    /// Focus is an element in this observation, using its actual child ordering.
    func focusedElementPath(in snapshot: MacAXTreeSnapshot, relativeTo root: MacAXElementRef, context: MacOperationContext) -> [Int]?
    /// Deduplicate by native identity so multiple parents cannot make one walk read an element twice; unknown identity deduplicates nothing.
    func elementHash(_ ref: MacAXElementRef) -> Int?
    func sameElement(_ lhs: MacAXElementRef, _ rhs: MacAXElementRef) -> Bool
}
public extension MacAXElementSource {
    func checkedMaskingAttributes(of ref: MacAXElementRef, context: MacOperationContext) throws -> MacAXAttributes {
        guard let value = maskingAttributes(of: ref, context: context) else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility masking attributes are unavailable.")
        }
        return value
    }
    func checkedChildCount(of ref: MacAXElementRef, context: MacOperationContext) throws -> Int {
        guard let count = childCount(of: ref, context: context) else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility child count is unavailable.")
        }
        return count
    }
    func checkedChildren(of ref: MacAXElementRef, limit: Int, context: MacOperationContext) throws -> [MacAXElementRef] { children(of: ref, limit: limit,
        context: context) }
    func checkedAttributes(of ref: MacAXElementRef, context: MacOperationContext) throws -> MacAXAttributes {
        guard let value = attributes(of: ref, context: context) else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility element attributes are unavailable.")
        }
        return value
    }
    func maskingAttributes(of ref: MacAXElementRef, context: MacOperationContext) -> MacAXAttributes? { attributes(of: ref, context: context) }
    func settableAttributes(of ref: MacAXElementRef, context: MacOperationContext) -> [String] { [] }
    func elementHash(_ ref: MacAXElementRef) -> Int? { nil }
    func sameElement(_ lhs: MacAXElementRef, _ rhs: MacAXElementRef) -> Bool { lhs == rhs }
    func documentScrollTargetIsCurrent(window: MacAXElementRef, container: MacAXElementRef, frame: MacAXFrame, pid: Int32,
        context: MacOperationContext) -> Bool {
        frontmostApp()?.processIdentifier == pid && frontmostWindowRoot(context: context) == window
            && attributes(of: container, context: context)?.frame == frame
    }
    func transientMenuRoots(pid: Int32, context: MacOperationContext) -> [MacAXElementRef] { [] }
    func childCount(of ref: MacAXElementRef, context: MacOperationContext) -> Int? { children(of: ref, context: context).count }
    func children(of ref: MacAXElementRef, limit: Int, context: MacOperationContext) -> [MacAXElementRef] {
        limit <= 0 ? [] : Array(children(of: ref, context: context).prefix(limit))
    }
    func focusedElementPath(context: MacOperationContext) -> [Int]? { nil }
    func focusedElementPath(relativeTo root: MacAXElementRef?, context: MacOperationContext) -> [Int]? { focusedElementPath(context: context) }
    func focusedElementPath(in snapshot: MacAXTreeSnapshot, relativeTo root: MacAXElementRef, context: MacOperationContext) -> [Int]? {
        guard let path = focusedElementPath(relativeTo: root, context: context), snapshot.nodes.contains(where: { $0.path == path }) else { return nil }
        return path
    }
    func windowRoot(pid: Int32, context: MacOperationContext) -> MacAXElementRef? { frontmostWindowRoot(context: context) }
    func windowRoots(pid: Int32, context: MacOperationContext) -> [MacAXWindowHandle] {
        guard let root = windowRoot(pid: pid, context: context) else { return [] }
        let attributes = attributes(of: root, context: context)
        return [MacAXWindowHandle(
            ref: root,
            identity: MacAXWindowIdentity(
                pid: pid,
                index: 0,
                role: attributes?.role ?? "AXWindow",
                subrole: attributes?.subrole,
                title: attributes?.title,
                frame: attributes?.frame,
                attributeGaps: attributes?.attributeGaps ?? []
            )
        )]
    }
    func appInfo(pid: Int32) -> MacAXAppInfo? {
        guard let app = frontmostApp(), app.processIdentifier == pid else { return nil }
        return app
    }
    func runningApps() -> [MacAXAppInfo] { [frontmostApp()].compactMap { $0 } }
    func menuBarRoot(pid: Int32, context: MacOperationContext) -> MacAXElementRef? { nil }
}
