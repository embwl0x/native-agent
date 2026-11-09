import Foundation
import NativeAgentShared
#if canImport(ApplicationServices) && os(macOS)
import ApplicationServices
// Blueprint: | `MacAXAttributeRead.swift` | Checked AX reads isolate node gaps, retain sibling evidence and share ordering |

/// Shared checked copies keep perception and actuation on the same native evidence.
package enum MacAXAttributeRead {
    /// Transport/preparation failures belong to the transaction. Only an optional attribute's AXError.failure inside an element read is a gap.
    final class Evidence: @unchecked Sendable {
        private let lock = NSLock()
        private var cause: Error?
        func record(_ error: Error) { lock.lock(); defer { lock.unlock() }; if cause == nil { cause = error } }
        func check() throws { lock.lock(); let error = cause; lock.unlock(); if let error { throw error } }
    }

    /// A failed node must not poison its siblings. The search owns the error; cancellation and the operation deadline still bound every transaction.
    static func node<Value>(context: MacOperationContext, _ body: (MacOperationContext) throws -> Value) throws -> Value {
        try context.evidence?.check()
        return try context.holding(\.evidence, Evidence()) { context in
            try context.holding(\.attributeGaps, nil) { context in try checked(context: context, body) }
        }
    }
    final class AttributeGaps: @unchecked Sendable {
        struct Gap: Equatable {
            let attribute: String?
            let detail: String
        }
        private let lock = NSLock()
        private var gaps: [Gap] = []
        func record(_ error: ElementAttributeFailure) {
            record(Gap(attribute: error.attribute, detail: "\(error.attribute): AX error \(error.status.rawValue)"))
        }
        func record(_ gap: String) {
            record(Gap(attribute: nil, detail: gap))
        }
        func record(_ gap: Gap) {
            lock.lock(); defer { lock.unlock() }
            if !gaps.contains(gap) { gaps.append(gap) }
        }
        var entries: [Gap] { lock.lock(); defer { lock.unlock() }; return gaps }
        var values: [String] { entries.map(\.detail) }
        func contains(attribute: String) -> Bool { entries.contains { $0.attribute == attribute } }
    }

    static func collectingAttributeGaps<Value>(context: MacOperationContext, _ body: (AttributeGaps, MacOperationContext) throws -> Value) rethrows -> Value {
        let gaps = AttributeGaps()
        return try context.holding(\.attributeGaps, gaps) { context in try body(gaps, context) }
    }
    static func checked<Value>(context: MacOperationContext, _ body: (MacOperationContext) throws -> Value) throws -> Value {
        if let evidence = context.evidence {
            let value: Value
            do { value = try body(context) }
            catch { try evidence.check(); throw error }
            try evidence.check()
            return value
        }
        let reading = Evidence()
        return try context.holding(\.evidence, reading) { context in
            let value: Value
            do { value = try body(context) }
            catch { try reading.check(); throw error }
            try reading.check()
            return value
        }
    }
    static func failed(_ error: Error, context: MacOperationContext) {
        if let error = error as? ElementAttributeFailure, let attributeGaps = context.attributeGaps {
            attributeGaps.record(error)
            return
        }
        context.evidence?.record(error)
        nativeLog("AX evidence read failed: %@", error.localizedDescription)
    }
    static func copyWindowIdentity(_ window: AXUIElement, pid: Int32, index: Int, context: MacOperationContext) throws -> MacAXWindowIdentity {
        try checked(context: context) { context in
            let role = try checkedText(window, kAXRoleAttribute, context: context)
            guard !role.isEmpty else {
                throw MacAccessibilityReader.NativeReadFailure(
                    detail: "Accessibility window identity has no readable AXRole. Read this app again before acting."
                )
            }
            return collectingAttributeGaps(context: context) { gaps, context in
                let subrole = copyString(window, kAXSubroleAttribute, context: context)
                let title = copyString(window, kAXTitleAttribute, context: context)
                let frame = copyFrame(window, context: context)
                return MacAXWindowIdentity(pid: pid, index: index, role: role,
                    subrole: subrole, title: title, frame: frame,
                    attributeGaps: gaps.values).retaining(window)
            }
        }
    }

    static func prepare(_ element: AXUIElement, context: MacOperationContext) -> Bool {
        guard !Task.isCancelled else { failed(CancellationError(), context: context); return false }
        do { try context.evidence?.check(); try SystemMacAXElementSource.ensureRenderer(element, context: context) }
        catch {
            failed(error, context: context)
            return false
        }
        return prepareMessage(element, context: context)
    }
    /// IPC budget only, also used by observer teardown, which must not wake a renderer.
    static func prepareMessage(_ element: AXUIElement, context: MacOperationContext) -> Bool {
        guard !Task.isCancelled else { return false }
        do { try context.evidence?.check() } catch { return false }
        if let deadline = context.readDeadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            _ = AXUIElementSetMessagingTimeout(element, Float(min(0.25, remaining)))
        }
        return true
    }

    static func copyTextRange(_ element: AXUIElement, context: MacOperationContext) -> NSRange? {
        guard let raw = copyRaw(element, kAXSelectedTextRangeAttribute, context: context),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range),
              range.location >= 0, range.length >= 0,
              range.location <= Int.max - range.length else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    package static func copyRaw(_ element: AXUIElement, _ attribute: String, context: MacOperationContext) -> CFTypeRef? {
        do { return try checkedRaw(element, attribute, context: context) }
        catch { failed(error, context: context); return nil }
    }

    package static func checkedRaw(_ element: AXUIElement, _ attribute: String, context: MacOperationContext) throws -> CFTypeRef? {
        try context.evidence?.check()
        try Task.checkCancellation()
        // Every value path, including a foreign caption, proves the text element's own subrole before copying its value.
        if attribute == kAXValueAttribute {
            let role = try checkedText(element, kAXRoleAttribute, context: context)
            guard !role.isEmpty else {
                throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility value read has no readable AXRole.")
            }
            if textValueRoles.contains(role) {
                if context.attributeGaps?.contains(attribute: kAXSubroleAttribute) == true { return nil }
                _ = try checkedText(element, kAXSubroleAttribute, context: context)
            }
        }
        // Application reads begin a new source transaction. Descendant reads share the same process preparation, including native subtree callers.
        var pid: pid_t = 0
        let application = [kAXWindowsAttribute, kAXFocusedWindowAttribute, kAXMainWindowAttribute,
                           kAXFocusedUIElementAttribute, kAXMenuBarAttribute].contains(attribute)
            && AXUIElementGetPid(element, &pid) == .success && pid > 0
            && CFEqual(element, AXUIElementCreateApplication(pid))
        try SystemMacAXElementSource.ensureRenderer(element, refresh: application, context: context)
        guard prepareMessage(element, context: context) else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility read of \(attribute) exhausted the shared reader time budget.")
        }
        defer { if context.readDeadline != nil { _ = AXUIElementSetMessagingTimeout(element, 0) } }
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        try Task.checkCancellation()
        switch status {
        case .success: return raw
        case .attributeUnsupported, .noValue: return nil
        case .failure: throw ElementAttributeFailure(attribute: attribute, status: status)
        default: throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility read of \(attribute) failed (AX error \(status.rawValue)).")
        }
    }

    package static func copyString(_ element: AXUIElement, _ attribute: String, context: MacOperationContext) -> String? {
        do { let value = try checkedText(element, attribute, context: context); return value.isEmpty ? nil : value }
        catch { failed(error, context: context); return nil }
    }

    /// A disabled control says so. One that doesn't publish AXEnabled (TextEdit's text area) makes no claim, so it is not disabled; only a failed read leaves the state unknown.
    package static func checkedEnabled(_ element: AXUIElement, context: MacOperationContext) throws -> Bool {
        try checkedBool(element, kAXEnabledAttribute, context: context) ?? true
    }

    static func copyEnabled(_ element: AXUIElement, context: MacOperationContext) -> Bool? {
        do { return try checkedBool(element, kAXEnabledAttribute, context: context) }
        catch { failed(error, context: context); return nil }
    }

    static func copyBool(_ element: AXUIElement, _ attribute: String, context: MacOperationContext) -> Bool? {
        do { return try checkedBool(element, attribute, context: context) }
        catch { failed(error, context: context); return nil }
    }

    package static func checkedBool(_ element: AXUIElement, _ attribute: String, context: MacOperationContext) throws -> Bool? {
        guard let raw = try checkedRaw(element, attribute, context: context) else { return nil }
        guard CFGetTypeID(raw) == CFBooleanGetTypeID() else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility \(attribute) returned a non-Boolean value.")
        }
        return CFBooleanGetValue(raw as! CFBoolean)
    }

    package static func copyElement(_ element: AXUIElement, _ attribute: String, context: MacOperationContext) -> AXUIElement? {
        guard let raw = copyRaw(element, attribute, context: context) else { return nil }
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            failed(MacAccessibilityReader.NativeReadFailure(detail: "Accessibility \(attribute) returned a non-element value."), context: context)
            return nil
        }
        return (raw as! AXUIElement)
    }

    /// Share visible-child ordering so perception paths resolve to the same action targets.
    static func childAttribute(_ element: AXUIElement, role: String? = nil, context: MacOperationContext) throws -> String {
        try context.evidence?.check()
        let role = try role ?? checkedText(element, kAXRoleAttribute, context: context)
        guard !role.isEmpty,
              ["AXList", "AXTable", "AXOutline"].contains(role) else { return kAXChildrenAttribute }
        try SystemMacAXElementSource.ensureRenderer(element, context: context)
        guard prepareMessage(element, context: context) else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility child-attribute discovery exhausted the reader time budget.")
        }
        defer { if context.readDeadline != nil { _ = AXUIElementSetMessagingTimeout(element, 0) } }
        var names: CFArray?
        let status = AXUIElementCopyAttributeNames(element, &names)
        guard status == .success, let names = names as? [String] else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility child-attribute names could not be read (AX error \(status.rawValue)).")
        }
        return [kAXVisibleRowsAttribute, kAXVisibleChildrenAttribute].first(where: names.contains)
            ?? kAXChildrenAttribute
    }

    static func listSummary(_ element: AXUIElement, role: String, context: MacOperationContext) -> String? {
        guard ["AXList", "AXTable", "AXOutline"].contains(role) else { return nil }
        guard let attribute = try? childAttribute(element, role: role,
            context: context) else { return "Visible item count unavailable: child attributes could not be read." }
        guard attribute != kAXChildrenAttribute, prepare(element, context: context) else { return nil }
        defer { if context.readDeadline != nil { _ = AXUIElementSetMessagingTimeout(element, 0) } }
        var visible: CFIndex = 0, total: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, attribute as CFString, &visible) == .success else { return nil }
        let rows = attribute == kAXVisibleRowsAttribute
        let kind = rows ? "rows" : "items"
        guard AXUIElementGetAttributeValueCount(element, (rows ? kAXRowsAttribute : kAXChildrenAttribute) as CFString,
                                               &total) == .success else {
            return "\(visible) \(kind) on screen; total count unavailable."
        }
        return "\(visible) of \(total) \(kind) on screen."
            + (total > visible ? " More \(kind) off screen." : "")
    }

    package static func copyElementArray(
        _ element: AXUIElement, _ attribute: String, limit: Int? = nil, preservingIndices: Bool = false,
        context: MacOperationContext
    ) -> [AXUIElement] {
        do { return try checkedElementArray(element, attribute, limit: limit, context: context) }
        catch { failed(error, context: context); return [] }
    }

    private static func checkedElementArray(
        _ element: AXUIElement, _ attribute: String, limit: Int? = nil,
        context: MacOperationContext
    ) throws -> [AXUIElement] {
        let attribute = attribute == kAXChildrenAttribute ? try childAttribute(element, context: context) : attribute
        func wholeArray() throws -> [AnyObject] {
            guard let raw = try checkedRaw(element, attribute, context: context) else { return [] }
            guard CFGetTypeID(raw) == CFArrayGetTypeID() else {
                throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility \(attribute) returned a non-array value.")
            }
            return raw as! CFArray as [AnyObject]
        }
        let array: [AnyObject]
        if let limit = limit ?? (context.readDeadline != nil ? MacAXLimits.deepPageMaxNodes : nil) {
            guard limit > 0 else { return [] }
            guard prepare(element, context: context) else {
                throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility child-array preparation failed or exhausted the reader time budget.")
            }
            defer { if context.readDeadline != nil { _ = AXUIElementSetMessagingTimeout(element, 0) } }
            // A range exists to avoid bridging a pathological array. Some elements fail a range yet answer a plain read (Music's text fields, -25200),
            // so a read that wants every child never asks for one.
            var count: CFIndex = 0
            if AXUIElementGetAttributeValueCount(element, attribute as CFString, &count) == .success, count <= limit {
                array = try wholeArray()
            } else {
                var raw: CFArray?
                let status = AXUIElementCopyAttributeValues(element, attribute as CFString, 0, CFIndex(limit), &raw)
                try Task.checkCancellation()
                if status == .attributeUnsupported || status == .noValue { return [] }
                if status == .failure { throw ElementAttributeFailure(attribute: attribute, status: status) }
                guard status == .success, let raw else {
                    throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility \(attribute) array read failed (AX error \(status.rawValue)).")
                }
                array = raw as [AnyObject]
            }
        } else {
            array = try wholeArray()
        }
        let elements: [AXUIElement] = array.compactMap { candidate in
            guard CFGetTypeID(candidate) == AXUIElementGetTypeID() else { return nil }
            return (candidate as! AXUIElement)
        }
        guard elements.count == array.count else {
            throw MacAccessibilityReader.NativeReadFailure(
                detail: "Accessibility \(attribute) returned a non-element array member; child addresses are unavailable."
            )
        }
        return elements
    }

    /// Derive identity and help-cleaned display names from the same copies. Captions and hints name otherwise unnamed controls; values stay separate.
    static func copyLabel(
        _ element: AXUIElement, role: String,
        context: MacOperationContext, prepare: (AXUIElement) -> AXUIElement = { $0 }) -> (identity: String?, display: String?, subrole: String?, help: String?,
            placeholder: String?, frame: MacAXFrame?, unreadable: Bool) {
        // Every caller, including act-time resolution, gets an element scope. A surrounding observation retains these same-element gaps.
        let owner = context.attributeGaps
        return collectingAttributeGaps(context: context) { gaps, context in
            defer { for gap in gaps.entries { owner?.record(gap) } }
            return readLabel(element, role: role, context: context, prepare: prepare)
        }
    }

    private static func readLabel(
        _ element: AXUIElement, role: String, context: MacOperationContext, prepare: (AXUIElement) -> AXUIElement) -> (identity: String?, display: String?,
            subrole: String?, help: String?, placeholder: String?, frame: MacAXFrame?, unreadable: Bool) {
        let subrole = copyString(element, kAXSubroleAttribute, context: context)
        let help = copyString(element, kAXHelpAttribute, context: context)
        let placeholder = copyString(element, kAXPlaceholderValueAttribute, context: context)
        let roleDescription = copyString(element, kAXRoleDescriptionAttribute, context: context)
        let frame = copyFrame(element, context: context)
        func isName(_ text: String) -> Bool {
            text != role && text != MacScreenRender.kindName(role: role)
                && text != roleDescription
        }
        var identity: String?, display: String?
        if role == kAXButtonRole, let subrole,
           [kAXCloseButtonSubrole, kAXMinimizeButtonSubrole, kAXZoomButtonSubrole].contains(subrole) {
            identity = MacScreenRender.kindName(role: String(subrole.dropLast("Button".count)))
            display = identity
        } else {
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel"] {
                let own: String
                do { own = try checkedText(element, attribute, context: context) }
                catch {
                    failed(error, context: context)
                    // A failed name is unknown, not absent. Do not rename it through another label attribute, caption or hint.
                    return (nil, nil, subrole, help, placeholder, frame, true)
                }
                guard !own.isEmpty, isName(own) else { continue }
                if identity == nil, attribute != kAXDescriptionAttribute || own != help { identity = own }
                if display == nil, own != help { display = own }
                if identity != nil, display != nil { break }
            }
            if identity == nil || display == nil {
                let caption = copyCaption(element, role: role, frame: frame, context: context, prepare: prepare)
                if caption.unreadable {
                    // No hint or nearby text may stand in for a failed name.
                    return (nil, nil, subrole, help, placeholder, frame, true)
                }
                identity = identity ?? caption.text
                display = display ?? caption.text
            }
            if hintNamedRoles.contains(role) {
                for hint in [placeholder, help].compactMap({ $0 }) where isName(hint) {
                    identity = identity ?? hint
                    display = display ?? hint
                }
            }
        }
        return (identity, display, subrole, help, placeholder, frame, false)
    }

    static func valueState(_ raw: CFTypeRef?, role: String) -> String? {
        guard let raw else { return nil }
        let checkable = role == "AXCheckBox" || role == "AXRadioButton" || role == "AXSwitch"
        let number: Int
        if CFGetTypeID(raw) == CFBooleanGetTypeID() {
            number = CFBooleanGetValue(raw as! CFBoolean) ? 1 : 0
        } else if checkable, CFGetTypeID(raw) == CFNumberGetTypeID() {
            var value = 0
            guard CFNumberGetValue(raw as! CFNumber, .intType, &value), (0...2).contains(value) else { return nil }
            number = value
        } else { return nil }
        if checkable {
            return number == 2 ? "mixed" : number == 1 ? "checked" : "unchecked"
        }
        return number == 1 ? "on" : "off"
    }

    static let placeholderRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    private static let textValueRoles = placeholderRoles.union(MacScreenViewBuilder.textRoles).union(["AXSecureTextField"])

    private static let hintNamedRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXComboBox", "AXPopUpButton", "AXMenuButton",
        "AXCheckBox", "AXRadioButton", "AXLink", "AXSlider", "AXDisclosureTriangle",
    ]

    private static func copyCaption(
        _ element: AXUIElement, role: String, frame: MacAXFrame?, context: MacOperationContext, prepare: (AXUIElement) -> AXUIElement) -> (text: String?,
            unreadable: Bool) {
        // These reads establish a label source, not attributes of the control. Keep foreign element errors in their own scope, then publish ONE caption gap on
        // the control. Checked reads stop at the first failure.
        do {
            let text = try collectingAttributeGaps(context: context) { _, context in
                let text = try readCaption(element, role: role, frame: frame, context: context, prepare: prepare)
                try context.evidence?.check()
                return text
            }
            return (text, false)
        } catch let error as ElementAttributeFailure {
            context.attributeGaps?.record("caption read: \(error.localizedDescription)")
            return (nil, true)
        } catch {
            failed(error, context: context)
            return (nil, true)
        }
    }

    private static func readCaption(
        _ element: AXUIElement, role: String, frame: MacAXFrame?, context: MacOperationContext, prepare: (AXUIElement) -> AXUIElement) throws -> String? {
        func relatedElement(_ element: AXUIElement, _ attribute: String) throws -> AXUIElement? {
            guard let raw = try checkedRaw(element, attribute, context: context) else { return nil }
            guard CFGetTypeID(raw) == AXUIElementGetTypeID() else {
                throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility caption read of \(attribute) returned a non-element value.")
            }
            return raw as! AXUIElement
        }
        func captionText(_ element: AXUIElement) throws -> String? {
            let value = try checkedText(element, kAXValueAttribute, context: context)
            let text: String
            if value.isEmpty { text = try checkedText(element, kAXTitleAttribute, context: context) }
            else { text = value }
            return MacPerceptionCompiler.captionText(text)
        }
        if hintNamedRoles.contains(role), let caption = try relatedElement(element, kAXTitleUIElementAttribute) {
            let caption = prepare(caption)
            return try captionText(caption)
        }
        guard MacPerceptionCompiler.captionedRoles.contains(role) else { return nil }
        // The label a person reads: among the field's own siblings, the nearest static text before it with nothing else between, on its row to the left or
        // directly above, one line tall. Anything else and the field has no label; its placeholder still names it.
        guard let field = frame,
              let parent = try relatedElement(element, kAXParentAttribute).map(prepare) else { return nil }
        let siblings = try checkedElementArray(parent, kAXChildrenAttribute, context: context)
        guard let index = siblings.firstIndex(where: { CFEqual($0, element) }) else { return nil }
        for sibling in siblings[..<index].reversed() {
            let sibling = prepare(sibling)
            guard try checkedText(sibling, kAXRoleAttribute, context: context) == "AXStaticText" else { return nil }
            guard let text = try captionText(sibling) else { continue }
            guard let frame = try checkedFrame(sibling, context: context), frame.h <= 2 * field.h,
                  MacScreenViewTextRedaction.labelDistance(frame, forValueAt: field,
                      proximity: MacScreenViewTextRedaction.proximityPoints) != nil else { return nil }
            return text
        }
        return nil
    }

    struct ElementAttributeFailure: Error, LocalizedError {
        let attribute: String
        let status: AXError
        var errorDescription: String? {
            "Accessibility read of \(attribute) failed (AX error \(status.rawValue))."
        }
    }
    /// Action names retain their own gap because AX actions must recheck them. Transport, preparation, cancellation and deadline failures still throw.
    static func observationActions(_ element: AXUIElement, context: MacOperationContext) throws -> (names: [String], unreadable: String?) {
        do { return (try copyActions(element, context: context), nil) }
        catch let error as ElementAttributeFailure { return ([], error.localizedDescription) }
    }
    package static func copyActions(_ element: AXUIElement, context: MacOperationContext) throws -> [String] {
        try context.evidence?.check()
        try Task.checkCancellation()
        try SystemMacAXElementSource.ensureRenderer(element, context: context)
        guard prepareMessage(element, context: context) else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility action-name read exhausted the reader time budget.")
        }
        defer { if context.readDeadline != nil { _ = AXUIElementSetMessagingTimeout(element, 0) } }
        var raw: CFArray?
        let status = AXUIElementCopyActionNames(element, &raw)
        try Task.checkCancellation()
        if status == .attributeUnsupported || status == .noValue || status == .notImplemented { return [] }
        if status == .failure { throw ElementAttributeFailure(attribute: "AXActionNames", status: status) }
        guard status == .success, let names = raw as? [String] else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility action names could not be read (AX error \(status.rawValue)).")
        }
        return names
    }

    /// Both position and size must be readable; never fabricate a missing half.
    package static func copyFrame(_ element: AXUIElement, context: MacOperationContext) -> MacAXFrame? {
        do { return try checkedFrame(element, context: context) }
        catch { failed(error, context: context); return nil }
    }

    package static func checkedFrame(_ element: AXUIElement, context: MacOperationContext) throws -> MacAXFrame? {
        var point = CGPoint.zero
        var size = CGSize.zero
        var hasPoint = false
        var hasSize = false
        if let raw = try checkedRaw(element, kAXPositionAttribute, context: context), CFGetTypeID(raw) == AXValueGetTypeID() {
            hasPoint = AXValueGetValue((raw as! AXValue), .cgPoint, &point)
        }
        if let raw = try checkedRaw(element, kAXSizeAttribute, context: context), CFGetTypeID(raw) == AXValueGetTypeID() {
            hasSize = AXValueGetValue((raw as! AXValue), .cgSize, &size)
        }
        guard hasPoint && hasSize,
              point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width >= 0, size.height >= 0,
              (point.x + size.width).isFinite, (point.y + size.height).isFinite else { return nil }
        return MacAXFrame(x: Double(point.x), y: Double(point.y), w: Double(size.width), h: Double(size.height))
    }

    package static func text(_ element: AXUIElement, _ attribute: String, context: MacOperationContext) -> String {
        copyString(element, attribute, context: context) ?? ""
    }

    package static func checkedText(_ element: AXUIElement, _ attribute: String, context: MacOperationContext) throws -> String {
        guard let raw = try checkedRaw(element, attribute, context: context) else { return "" }
        guard let value = raw as? String else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility \(attribute) returned a non-text value.")
        }
        return value
    }

    /// Native selectors use the same identity as the hands. Static text is named by its text when it has no separate caption; fields keep values separate from
    /// identity, including inside credential views.
    package static func label(_ element: AXUIElement, context: MacOperationContext) -> String {
        let role = text(element, kAXRoleAttribute, context: context)
        let names = copyLabel(element, role: role, context: context)
        guard !names.unreadable else { return "" }
        return names.identity
            ?? (role == kAXStaticTextRole ? copyString(element, kAXValueAttribute, context: context) : nil) ?? ""
    }

    package static func parent(_ element: AXUIElement, context: MacOperationContext) -> AXUIElement? {
        copyElement(element, kAXParentAttribute, context: context)
    }

    package static func frame(_ element: AXUIElement, context: MacOperationContext) -> CGRect? {
        guard let frame = copyFrame(element, context: context),
              frame.x.isFinite, frame.y.isFinite, frame.w.isFinite, frame.h.isFinite,
              frame.w > 0, frame.h > 0 else { return nil }
        return CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h)
    }
}
#endif
