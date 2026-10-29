import Foundation
import NativeAgentShared
import NativeAgentCore
import TrustCenter
import PersistenceCore
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif
// Blueprint: | `MacSavePanelPlacement.swift` | Save-panel placement through the existing act verification loop |
extension SwiftNativeMacControl {
    /// Go-to-folder selects the directory; AXValue sets the basename; the common act loop verifies both.
    func placeInSavePanel(_ placement: MacSavePanelPlacement, target: MacAXActTarget, window: MacAXWindowRef, pid: Int32,
                                 handle: String, frontBefore: MacAXAppInfo?) async -> MacActPerformed {
        func wherePopup() -> MacAXActTarget? {
            ["Where", "Where:"].lazy.compactMap {
                self.accessibilityActSource.uniqueTarget(role: "AXPopUpButton", label: $0, labelSource: "title", inWindow: window)
            }.first
        }
        let before = wherePopup()?.value
        let inputStart = MacDriverContext.binding?.inputCount ?? 0
        var extra: [String: JSONValue] = ["directory": .string(placement.directory), "name": .string(placement.name),
            "where_before": before.map(JSONValue.string) ?? .null]
        func result(_ error: String? = nil, guidance: String? = nil) -> MacActPerformed {
            extra["posted_events"] = .int(Int64((MacDriverContext.binding?.inputCount ?? inputStart) - inputStart))
            if let guidance { extra["guidance"] = .string(guidance) }
            return MacActPerformed(ok: error == nil, method: "save_panel_placement", requestedAction: "type", fallbackReason: nil,
                error: error, target: target, postState: accessibilityActSource.reread(target), actedHandle: handle,
                extra: extra, expectedText: placement.name)
        }
        guard frontBefore?.processIdentifier == pid else {
            return result("needs_front", guidance: "\(placement.directory) is a place, and a save panel takes a place only through its "
                    + "Go-to-folder sheet, which needs the keyboard, so the app must be in front: go name front:true when the "
                    + "task allows it, then type the path again; or type just the name \"\(placement.name)\" to save where the "
                    + "panel points now" + (before.map { " (\($0))" } ?? "") + ". Nothing was typed.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: placement.directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return result("folder_missing", guidance: "there is no folder at \(placement.directory); make it first, or save into one that exists. Nothing was typed.")
        }
        let opened = await handleKeystroke(["keys": .string("cmd+shift+g")])
        guard opened.ok else { return result(opened.error ?? "save_panel_placement_unverified") }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let typed = await handleKeystroke(["text": .string(placement.directory)])
        guard typed.ok else { return result(typed.error ?? "save_panel_placement_unverified") }
        try? await Task.sleep(nanoseconds: 250_000_000)
        let confirmed = await handleKeystroke(["keys": .string("return")])
        guard confirmed.ok else { return result(confirmed.error ?? "save_panel_placement_unverified") }
        var whereNow: String?
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            whereNow = wherePopup()?.value
            if whereNow == placement.directoryName { break }
        }
        let placed = whereNow == placement.directoryName
        let named = accessibilityActSource.setValue(target, value: placement.name) == .performed
        let nameNow = accessibilityActSource.reread(target)?.value
        let ok = placed && named
        let text = ok
            ? "Pointed the save panel at \(placement.directory) (Where: \(whereNow ?? "")) and named the file \(placement.name); its Save button saves it there."
            : "The save panel " + (placed ? "points at \(placement.directory)" : "shows Where: \(whereNow ?? "unknown"), not \(placement.directoryName), after the Go-to-folder sheet")
                + (named ? "; the name \(placement.name) is set" : "; the name field did not take \(placement.name)") + ". Read the panel before pressing Save."
        extra["where_after"] = whereNow.map(JSONValue.string) ?? .null
        extra["name_after"] = nameNow.map(JSONValue.string) ?? .null
        extra["text"] = .string(text)
        return result(named ? nil : "save_panel_placement_unverified")
    }
}


/// A save panel's name field turns a path into a colon-named file; separate the destination folder from the name.
public struct MacSavePanelPlacement: Sendable, Equatable {
    public let directory: String
    public let name: String
    public var directoryName: String { (directory as NSString).lastPathComponent }

    /// The fields a save panel names its file by, as the screen labels them.
    static let nameFieldLabels: Set<String> = ["save as", "export as", "file name", "name"]

    public static func isNameField(role: String, label: String?) -> Bool {
        guard role == "AXTextField", let label else { return false }
        let bare = label.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":")).lowercased()
        return nameFieldLabels.contains(bare)
    }

    /// A place with a name: absolute (or `~`) with at least one folder and a
    /// non-empty last component. A bare name, or a name with no folder, is nil.
    public static func split(_ text: String) -> MacSavePanelPlacement? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else { return nil }
        let expanded = NativeAgentWorkspaceRoot.fileSpelling(trimmed)
        let name = (expanded as NSString).lastPathComponent
        let directory = (expanded as NSString).deletingLastPathComponent
        guard !name.isEmpty, name != "/", directory.hasPrefix("/"), !trimmed.hasSuffix("/") else { return nil }
        return MacSavePanelPlacement(directory: directory, name: name)
    }
}
