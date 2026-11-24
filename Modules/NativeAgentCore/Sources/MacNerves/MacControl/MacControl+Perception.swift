import Foundation
import NativeAgentShared
import SenseCore
import NativeAgentCore
import PersistenceCore
import DeskCore
import AppKit
import CoreGraphics
import ApplicationServices
// Blueprint: | `MacControl+Perception.swift` | Checked shallow menus retain availability/coverage for native pages and windowless apps |
extension SwiftNativeMacControl {
    func menuBarReading(pid: Int32, context: MacOperationContext) -> MacMenuBar.Reading {
        MacMenuBar.read(source: accessibilitySource(context: context), pid: pid, depth: 1, context: context)
    }
}
