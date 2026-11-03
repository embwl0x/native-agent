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
// Blueprint: | `MacControl+Perception.swift` | Shallow checked menu reading preserves availability and coverage for native page and windowless-app projections |
#endif
extension SwiftNativeMacControl {
    func menuBarReading(pid: Int32) -> MacMenuBar.Reading {
        MacMenuBar.read(source: accessibilitySource, pid: pid, depth: 1)
    }
}
