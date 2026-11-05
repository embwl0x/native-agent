import Foundation
import NativeAgentShared
import Senses
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ApplicationServices)
import ApplicationServices
// Blueprint: | `MacControl+Perception.swift` | Checked shallow menus retain availability/coverage for native pages and windowless apps |
#endif
extension SwiftNativeMacControl {
    func menuBarReading(pid: Int32, context: MacOperationContext) -> MacMenuBar.Reading {
        MacMenuBar.read(source: accessibilitySource(context: context), pid: pid, depth: 1, context: context)
    }
}
