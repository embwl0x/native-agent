import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ApplicationServices
import AppKit
import DeskCore
import CoreGraphics
import UserNotifications
import SenseCore
import os
import CoreText
import ScreenCaptureKit
// Blueprint: | `MacAXElementSource.swift` | Read-only AX contracts preserve gaps and observation-bound focus |
/// Keep partially readable trees useful without treating gaps as absence.
public protocol MacAXElementSource: Sendable {
    func isTrusted() -> Bool
    func frontmostApp() -> MacAXAppInfo?
    func frontmostWindowRoot(context: MacOperationContext) -> MacAXElementRef?
    /// Whether global wheel input at this point still lands in the captured container. Live AX handles are reminted, so compare underlying elements.
    func documentScrollTargetIsCurrent(window: MacAXElementRef, container: MacAXElementRef, frame: MacAXFrame, pid: Int32, context: MacOperationContext) -> Bool
    func windowRoot(pid: Int32, context: MacOperationContext) -> MacAXElementRef?
    func windowRoots(pid: Int32, context: MacOperationContext) -> [MacAXWindowHandle]
    func appInfo(pid: Int32) -> MacAXAppInfo?
    func runningApps() -> [MacAXAppInfo]
    /// Read the menu bar separately: window walks exclude it so hundreds of menu items cannot consume every look's node budget. Sources without menus report
    /// nil.
    func menuBarRoot(pid: Int32, context: MacOperationContext) -> MacAXElementRef?
    /// Currently open native menus belonging to this frontmost app. They can be application siblings, not descendants of its document window. These roots are
    /// never window-relative action addresses.
    func transientMenuRoots(pid: Int32, context: MacOperationContext) -> [MacAXElementRef]
    func attributes(of ref: MacAXElementRef, context: MacOperationContext) -> MacAXAttributes?
    func checkedAttributes(of ref: MacAXElementRef, context: MacOperationContext) throws -> MacAXAttributes
    /// A control or row wholly outside the bounds, which cannot appear in a picture of them.
    func liesWhollyOutside(_ ref: MacAXElementRef, bounds: MacAXFrame, context: MacOperationContext) -> Bool
    func checkedMaskingAttributes(of ref: MacAXElementRef, context: MacOperationContext) throws -> MacAXAttributes
    /// Query writability only for selected marks to bound AX work.
    func settableAttributes(of ref: MacAXElementRef, context: MacOperationContext) -> [String]
    func children(of ref: MacAXElementRef, context: MacOperationContext) -> [MacAXElementRef]
    func checkedChildList(of ref: MacAXElementRef, role: String?, context: MacOperationContext) throws -> (attribute: String, count: Int)
    /// Ranged child fetches avoid bridging children that cannot fit under the node cap.
    func children(of ref: MacAXElementRef, limit: Int, context: MacOperationContext) -> [MacAXElementRef]
    func checkedChildren(of ref: MacAXElementRef, list: (attribute: String, count: Int), limit: Int, context: MacOperationContext) throws -> [MacAXElementRef]
    /// A walk's descent: up to `limit` children and how many there are (a floor when more than `limit` exist).
    func checkedChildren(of ref: MacAXElementRef, role: String?, limit: Int, context: MacOperationContext) throws -> (children: [MacAXElementRef], total: Int)
    /// Focus paths share the window root's child ordering; unknown focus remains nil rather than guessing an editor.
    func focusedElementPath(context: MacOperationContext) -> [Int]?
    func focusedElementPath(relativeTo root: MacAXElementRef?, context: MacOperationContext) -> [Int]?
    /// Focus is an element in this observation, using its actual child ordering.
    func focusedElementPath(in snapshot: MacAXTreeSnapshot, relativeTo root: MacAXElementRef, context: MacOperationContext) -> [Int]?
    /// Deduplicate by native identity so multiple parents cannot make one walk read an element twice; unknown identity deduplicates nothing.
    func elementHash(_ ref: MacAXElementRef) -> Int?
    func sameElement(_ lhs: MacAXElementRef, _ rhs: MacAXElementRef) -> Bool
}
