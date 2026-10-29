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
// Blueprint: | `MacControl+Perception.swift` | `SwiftNativeMacControl`: `handleRead` reads live window text unless the caller names a file; semantic view masks pixels from the complete AX snapshot's secret frames before sharing |
#endif
extension SwiftNativeMacControl {
    /// The app's top-level menu titles, in order, from one bounded menu-bar
    /// read; empty when the app's bar cannot be read.
    func menuBarTitles(pid: Int32) -> [String] {
        var titles: [String] = []
        for item in MacMenuBar.read(source: accessibilitySource, pid: pid, depth: 1).items {
            guard let top = item.titlePath.first, !top.isEmpty, !titles.contains(top) else { continue }
            titles.append(top)
        }
        return titles
    }
}
