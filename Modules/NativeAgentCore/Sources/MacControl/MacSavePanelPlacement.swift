import Foundation
import Synchronization
import NativeAgentShared
import NativeAgentCore
import TrustCenter
import PersistenceCore
import ApplicationServices
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif
// Blueprint: | `MacSavePanelPlacement.swift` | Event-ordered Go-to-folder sheet, focused-field delivery and native directory URL proof |
extension SwiftNativeMacControl {
    /// Directory and basename use separate controls; the common act loop verifies both.
    func placeInSavePanel(_ placement: MacSavePanelPlacement, target: MacAXActTarget, window: MacAXWindowRef, pid: Int32,
                                 handle: String, frontBefore: MacAXAppInfo?, turn: Turn, context: MacOperationContext) async -> MacActPerformed {
        func wherePopup() throws -> MacAXActTarget? {
            for label in ["Where", "Where:"] {
                if let target = try accessibilityActSource(context: context).uniqueTarget(
                    role: "AXPopUpButton", label: label, labelSource: "title", inWindow: window
                , context: context) { return target }
            }
            return nil
        }
        let inputStart = context.driver?.inputCount ?? 0
        var extra: [String: JSONValue] = ["directory": .string(placement.directory), "name": .string(placement.name),
            "where_before": .null]
        func result(_ error: String? = nil, guidance: String? = nil) -> MacActPerformed {
            extra["posted_events"] = .int(Int64((context.driver?.inputCount ?? inputStart) - inputStart))
            if let guidance { extra["guidance"] = .string(guidance) }
            return MacActPerformed(ok: error == nil, method: "save_panel_placement", requestedAction: "type", error: error, target: target,
                postState: accessibilityActSource(context: context).reread(target, context: context), actedHandle: handle,
                extra: extra, expectedText: placement.name)
        }
        let before: String?
        do { before = try wherePopup()?.value }
        catch { return result("ax_evidence_unavailable", guidance: error.localizedDescription) }
        extra["where_before"] = before.map(JSONValue.string) ?? .null
        guard frontBefore?.processIdentifier == pid else {
            return result("needs_front", guidance: "\(placement.directory) is a place, and a save panel takes a place only through its "
                    + "Go-to-folder sheet, which needs the keyboard, so the app must be in front: go name front:true when the "
                    + "task allows it, then type the path again; or type just the name \"\(placement.name)\" to save where the "
                    + "panel points now" + (before.map { " (\($0))" } ?? "") + ". Nothing was typed.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: placement.directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return result("folder_missing",
                guidance: "there is no folder at \(placement.directory); make it first, or save into one that exists. Nothing was typed.")
        }
        guard let source = accessibilityActSource(context: context) as? SystemMacAXActSource else {
            return result("save_panel_evidence_unavailable", guidance: "Placement requires the native sheet and field observer. Nothing was typed.")
        }
        let openedEvents = MacSavePanelEvents(base: effectObserverSource)
        let openSignals = MacWaitSignals(effects: openedEvents, activation: defaultMacAppActivationObserverSource(), pid: pid)
        defer { openSignals.stop() }
        guard openSignals.isObserving else {
            return result("observer_unavailable", guidance: openSignals.installationFailure)
        }
        func send(_ plan: [MacHandStep], field: MacAXActTarget? = nil) async -> MacControlResult? {
            if let refusal = injectionPreconditions(action: "act", requiresSink: true, context: context) { return refusal }
            let execution = await executeHand(plan, action: "act", turn: turn, context: context) { step in
                guard step.keyEvent?.down == true else { return nil }
                guard self.accessibilitySource(context: context).frontmostApp()?.processIdentifier == pid,
                      !self.eventSink.secureKeyboardEntryActive,
                      field.map({ source.isFocusedElement($0, pid: pid, context: context) }) ?? true else {
                    return self.injectionRefusal(action: "act", error: "save_panel_focus_moved")
                }
                return nil
            }
            return execution.refusal
        }
        func stoppedInput(_ refusal: MacControlResult) -> MacActPerformed {
            extra["input_receipt"] = refusal.output
            extra["input_error"] = refusal.error.map(JSONValue.string) ?? .null
            return result("save_panel_input_stopped", guidance: refusal.error)
        }
        let openPlan: [MacHandStep]
        let confirmPlan: [MacHandStep]
        let pathPlan: [MacHandStep]
        do {
            openPlan = try MacKeySyntax.parseChords("cmd+shift+g").flatMap(MacHandRepertoire.chord)
            confirmPlan = try MacKeySyntax.parseChords("return").flatMap(MacHandRepertoire.chord)
            pathPlan = MacHandRepertoire.type(text: try MacKeySyntax.validateText(placement.directory))
        } catch { return result("invalid_save_panel_input", guidance: error.localizedDescription) }
        if let refusal = await send(openPlan) { return stoppedInput(refusal) }
        var field: MacAXActTarget?
        var evidenceError: String?
        let opened = await macSettle("save_panel_sheet", signals: openSignals, patience: 0.4) {
            guard !Task.isCancelled, evidenceError == nil, openedEvents.saw(kAXSheetCreatedNotification),
                  self.accessibilitySource(context: context).frontmostApp()?.processIdentifier == pid,
                  let focused = source.focusedElement(pid: pid, context: context),
                  source.acceptsTextInput(focused, context: context) else { return false }
            do {
                guard try source.isGoToFolderField(focused, original: target, window: window, context: context) else { return false }
                field = focused
                return true
            } catch { evidenceError = error.localizedDescription; return false }
        }
        if let evidenceError { return result("ax_evidence_unavailable", guidance: evidenceError) }
        guard opened == .held, let field else {
            return result("save_panel_placement_unverified",
                guidance: "The Go-to-folder sheet and its focused field are not observed yet. No path text was typed; inspect the panel.")
        }
        let fieldSource = MacSavePanelFieldSource(source: source, field: field, context: context)
        let fieldEvents = MacSavePanelEvents(base: fieldSource)
        let fieldSignals = MacWaitSignals(effects: fieldEvents, activation: defaultMacAppActivationObserverSource(), pid: pid)
        defer { fieldSignals.stop() }
        guard fieldSignals.isObserving else {
            return result("observer_unavailable", guidance: fieldSource.installationFailure)
        }
        if let refusal = await send(pathPlan, field: field) { return stoppedInput(refusal) }
        let valueHeld = await macSettle("save_panel_path", signals: fieldSignals, patience: 0.25) {
            !Task.isCancelled && source.isFocusedElement(field, pid: pid, context: context)
                && source.textInput(field, context: context)?.value == placement.directory
        }
        guard valueHeld == .held else {
            return result("save_panel_placement_unverified",
                guidance: "Path input was delivered; its value is not verified yet. Return was not pressed; inspect the Go-to-folder sheet.")
        }
        if let refusal = await send(confirmPlan, field: field) { return stoppedInput(refusal) }
        let closed = await macSettle("save_panel_sheet_closed", signals: fieldSignals, patience: 3) {
            fieldEvents.saw(kAXUIElementDestroyedNotification)
        }
        guard closed == .held, !Task.isCancelled else {
            return result("save_panel_placement_unverified",
                guidance: "Return input was delivered; the Go-to-folder sheet has not been observed closing yet. Inspect the panel before saving.")
        }
        var whereNow: String?
        var directoryNow: URL?
        let wantedDirectory = URL(fileURLWithPath: placement.directory, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let directoryHeld = await macSettle("save_panel_directory", signals: openSignals, patience: 3) {
            guard !Task.isCancelled, evidenceError == nil else { return false }
            do {
                let popup = try wherePopup()
                whereNow = popup?.value
                directoryNow = try popup.flatMap { try accessibilityActSource(context: context).url(of: $0, context: context) }
            } catch { evidenceError = error.localizedDescription; return false }
            return directoryNow?.standardizedFileURL.resolvingSymlinksInPath() == wantedDirectory
        }
        if let evidenceError { return result("ax_evidence_unavailable", guidance: evidenceError) }
        let placed = directoryHeld == .held && directoryNow?.standardizedFileURL.resolvingSymlinksInPath() == wantedDirectory
        guard placed, !Task.isCancelled else {
            return result("save_panel_placement_unverified",
                guidance: "Go-to-folder input was delivered; the destination URL is not verified yet. The basename was not changed; inspect the panel.")
        }
        let nameBefore = source.reread(target, context: context)?.value
        if nameBefore != placement.name {
            let nameOutcome = source.setValue(target, value: placement.name, turn: turn, context: context)
            extra.merge(nameOutcome.receipt) { _, new in new }
            guard nameOutcome == .performed else {
                return result("save_panel_placement_unverified", guidance: nameOutcome.cause)
            }
        }
        let nameNow = source.reread(target, context: context)?.value
        let named = nameNow == placement.name
        let ok = named
        let text = ok
            ? """
                Pointed the save panel at \(placement.directory) (Where: \(whereNow ?? "")) and named the file \(placement.name); its Save button saves it \
                there.
                """
            : "The save panel points at \(placement.directory); the basename is not verified yet. Read the panel before pressing Save."
        extra["where_after"] = whereNow.map(JSONValue.string) ?? .null
        extra["directory_url_after"] = directoryNow.map { .string($0.absoluteString) } ?? .null
        extra["name_after"] = nameNow.map(JSONValue.string) ?? .null
        extra["text"] = .string(text)
        return result(ok ? nil : "save_panel_placement_unverified")
    }
}

/// Event latches retain transitions that arrive while input is still being emitted.
private final class MacSavePanelEvents: MacAXEffectObserverSource {
    private let base: any MacAXEffectObserverSource
    private let received = Mutex<Set<String>>([])

    init(base: any MacAXEffectObserverSource) { self.base = base }

    func saw(_ kind: String) -> Bool { received.withLock { $0.contains(kind) } }

    func install(pid: Int32, kinds: [String],
                 onNotification: @escaping @Sendable (MacAXEffectNotification) -> Void) -> (any MacAXEffectObservation)? {
        base.install(pid: pid, kinds: kinds) { [self] event in
            received.withLock { $0.insert(event.kind) }
            onNotification(event)
        }
    }
}

extension SystemMacAXActSource {
    /// A nested sheet must differ from the save name's sheet and belong to the selected window.
    fileprivate func isGoToFolderField(_ field: MacAXActTarget, original: MacAXActTarget, window: MacAXWindowRef,
                                      context: MacOperationContext) throws -> Bool {
        try MacAXExecutionLane.sync {
            Result {
                try MacAXAttributeRead.checked(context: context) { context in
                    guard let focused = element(field.handle), let original = element(original.handle), let root = element(window.handle),
                          let sheet = try savePanelSheet(containing: focused, context: context) else { return false }
                    if let originalSheet = try savePanelSheet(containing: original, context: context), CFEqual(sheet, originalSheet) { return false }
                    return try savePanelAncestors(of: sheet, context: context).contains { CFEqual($0, root) }
                }
            }
        }.get()
    }
}

/// Ancestor reads are checked; a missing parent proves no relationship.
private func savePanelAncestors(of element: AXUIElement, context: MacOperationContext) throws -> [AXUIElement] {
    var ancestors: [AXUIElement] = []
    var current: AXUIElement? = element
    while let node = current {
        guard !ancestors.contains(where: { CFEqual($0, node) }) else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "The save panel's Accessibility parent chain contains a cycle.")
        }
        ancestors.append(node)
        current = MacAXAttributeRead.copyElement(node, kAXParentAttribute, context: context)
        try context.evidence?.check()
    }
    return ancestors
}

private func savePanelSheet(containing element: AXUIElement, context: MacOperationContext) throws -> AXUIElement? {
    for node in try savePanelAncestors(of: element, context: context) {
        let role = MacAXAttributeRead.copyString(node, kAXRoleAttribute, context: context)
        try context.evidence?.check()
        if role == kAXSheetRole { return node }
    }
    return nil
}

/// Field changes and the sheet's own destruction do not need to propagate to the application element.
private final class MacSavePanelFieldSource: MacAXEffectObserverSource {
    let source: SystemMacAXActSource
    let field: MacAXActTarget
    let context: MacOperationContext
    private let failure = Mutex<String?>(nil)

    init(source: SystemMacAXActSource, field: MacAXActTarget, context: MacOperationContext) {
        self.source = source
        self.field = field
        self.context = context
    }

    var installationFailure: String? { failure.withLock { $0 } }

    func install(pid: Int32, kinds _: [String],
                 onNotification: @escaping @Sendable (MacAXEffectNotification) -> Void) -> (any MacAXEffectObservation)? {
        MacAXExecutionLane.sync {
            do {
                return try MacAXAttributeRead.checked(context: context) { context -> (any MacAXEffectObservation)? in
                    guard let field = source.element(field.handle) else {
                        throw MacAccessibilityReader.NativeReadFailure(
                            detail: "The save-panel field no longer resolves; observation was not installed.")
                    }
                    guard let sheet = try savePanelSheet(containing: field, context: context) else {
                        throw MacAccessibilityReader.NativeReadFailure(
                            detail: "The save-panel field has no AXSheet ancestor; observation was not installed.")
                    }
                    let callback = MacSavePanelCallback(onNotification)
                    let refcon = Unmanaged.passRetained(callback).toOpaque()
                    var observer: AXObserver?
                    let status = AXObserverCreate(pid, { _, _, kind, refcon in
                        guard let refcon else { return }
                        let callback = Unmanaged<MacSavePanelCallback>.fromOpaque(refcon).takeUnretainedValue()
                        callback.receive(MacAXEffectNotification(kind: kind as String, at: Date()))
                    }, &observer)
                    guard status == .success, let observer else {
                        Unmanaged<MacSavePanelCallback>.fromOpaque(refcon).release()
                        throw MacAccessibilityReader.NativeReadFailure(
                            detail: "Save-panel AXObserverCreate did not produce an observer (AX status \(status.rawValue)).")
                    }
                    let registrations: [(AXUIElement, String)] = [
                        (field, kAXValueChangedNotification),
                        (sheet, kAXUIElementDestroyedNotification),
                    ]
                    let observation = MacSavePanelFieldObservation(observer: observer, registrations: registrations, refcon: refcon)
                    for (element, kind) in registrations {
                        let status = AXObserverAddNotification(observer, element, kind as CFString, refcon)
                        guard status == .success else {
                            observation.stop()
                            throw MacAccessibilityReader.NativeReadFailure(
                                detail: "Save-panel observation of \(kind) could not be registered (AX error \(status.rawValue)).")
                        }
                    }
                    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
                    return observation
                }
            } catch {
                failure.withLock { $0 = error.localizedDescription }
                MacAXAttributeRead.failed(error, context: context)
                return nil
            }
        }
    }
}

private final class MacSavePanelCallback: Sendable {
    let receive: @Sendable (MacAXEffectNotification) -> Void
    init(_ receive: @escaping @Sendable (MacAXEffectNotification) -> Void) { self.receive = receive }
}

private final class MacSavePanelFieldObservation: MacAXEffectObservation {
    /// AX references are used only on the AX lane; the mutex hands them there once.
    private struct Registration: @unchecked Sendable {
        let observer: AXObserver
        let registrations: [(AXUIElement, String)]
        let refcon: UnsafeMutableRawPointer
    }
    private let registration: Mutex<Registration?>

    init(observer: AXObserver, registrations: [(AXUIElement, String)], refcon: UnsafeMutableRawPointer) {
        registration = Mutex(Registration(observer: observer, registrations: registrations, refcon: refcon))
    }

    func stop() {
        MacAXExecutionLane.sync {
            registration.withLock { state in
                guard let live = state else { return }
                for (element, kind) in live.registrations {
                    AXObserverRemoveNotification(live.observer, element, kind as CFString)
                }
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(live.observer), .defaultMode)
                Unmanaged<MacSavePanelCallback>.fromOpaque(live.refcon).release()
                state = nil
            }
        }
    }

    deinit { stop() }
}

/// A save panel's name field turns a path into a colon-named file; separate the destination folder from the name.
public struct MacSavePanelPlacement: Sendable, Equatable {
    public let directory: String
    public let name: String

    static let nameFieldLabels: Set<String> = ["save as", "export as", "file name", "name"]

    public static func isNameField(role: String, label: String?) -> Bool {
        guard role == "AXTextField", let label else { return false }
        let bare = label.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":")).lowercased()
        return nameFieldLabels.contains(bare)
    }

    /// Only paths with a folder and final component need directory placement; bare names do not.
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
