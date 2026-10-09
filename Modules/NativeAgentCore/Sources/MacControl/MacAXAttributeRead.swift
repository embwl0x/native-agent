import Foundation
#if canImport(ApplicationServices) && os(macOS)
import ApplicationServices

/// Nil-tolerant AX attribute copies shared by perception and actuation.
enum MacAXAttributeRead {
    static func prepare(_ element: AXUIElement) -> Bool {
        guard !Task.isCancelled else { return false }
        if let deadline = MacAXLimits.readDeadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            _ = AXUIElementSetMessagingTimeout(element, Float(min(0.25, remaining)))
        }
        return true
    }

    static func copyTextRange(_ element: AXUIElement) -> NSRange? {
        guard let raw = copyRaw(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range),
              range.location >= 0, range.length >= 0,
              range.location <= Int.max - range.length else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    static func copyRaw(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        guard prepare(element) else { return nil }
        defer { if MacAXLimits.readDeadline != nil { _ = AXUIElementSetMessagingTimeout(element, 0) } }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw
    }

    static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let raw = copyRaw(element, attribute), CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        let string = raw as! CFString as String
        return string.isEmpty ? nil : string
    }

    static func copyBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let raw = copyRaw(element, attribute), CFGetTypeID(raw) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((raw as! CFBoolean))
    }

    static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = copyRaw(element, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    /// Perception and action paths share the same visible-child ordering.
    static func childAttribute(_ element: AXUIElement) -> String {
        guard let role = copyString(element, kAXRoleAttribute),
              ["AXList", "AXTable", "AXOutline"].contains(role) else { return kAXChildrenAttribute }
        guard prepare(element) else { return kAXVisibleChildrenAttribute }
        defer { if MacAXLimits.readDeadline != nil { _ = AXUIElementSetMessagingTimeout(element, 0) } }
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let names = names as? [String] else { return kAXVisibleChildrenAttribute }
        return [kAXVisibleRowsAttribute, kAXVisibleChildrenAttribute].first(where: names.contains)
            ?? kAXChildrenAttribute
    }

    static func listSummary(_ element: AXUIElement, role: String) -> String? {
        guard ["AXList", "AXTable", "AXOutline"].contains(role) else { return nil }
        let attribute = childAttribute(element)
        guard attribute != kAXChildrenAttribute, prepare(element) else { return nil }
        defer { if MacAXLimits.readDeadline != nil { _ = AXUIElementSetMessagingTimeout(element, 0) } }
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

    static func copyElementArray(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        let attribute = attribute == kAXChildrenAttribute ? childAttribute(element) : attribute
        if MacAXLimits.readDeadline != nil {
            guard prepare(element) else { return [] }
            defer { _ = AXUIElementSetMessagingTimeout(element, 0) }
            var raw: CFArray?
            guard AXUIElementCopyAttributeValues(element, attribute as CFString, 0,
                CFIndex(MacAXLimits.deepPageMaxNodes), &raw) == .success, let raw else { return [] }
            return (raw as [AnyObject]).compactMap { candidate in
                CFGetTypeID(candidate) == AXUIElementGetTypeID() ? (candidate as! AXUIElement) : nil
            }
        }
        guard let raw = copyRaw(element, attribute), CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
        return (raw as! CFArray as [AnyObject]).compactMap { candidate in
            guard CFGetTypeID(candidate) == AXUIElementGetTypeID() else { return nil }
            return (candidate as! AXUIElement)
        }
    }

    /// Own title/description, else — for a field or popup Cocoa names with a
    /// separate label ("Save As:", "Where:") — that label's text: its
    /// AXTitleUIElement, else the previous sibling static text ending in ":".
    /// The ONE identity rule for perception and the act-side drift check.
    /// Display cleanup is opt-in; it must never remove a redaction caption.
    static func copyLabel(
        _ element: AXUIElement, role: String,
        forDisplay: Bool = false,
        prepare: (AXUIElement) -> AXUIElement = { $0 }
    ) -> String? {
        func isName(_ text: String) -> Bool {
            text != role && text != MacScreenRender.kindName(role: role)
                && text != copyString(element, kAXRoleDescriptionAttribute)
        }
        // Window furniture has an authoritative semantic subrole. Its help
        // describes a gesture, not the control's name.
        if role == kAXButtonRole,
           let subrole = copyString(element, kAXSubroleAttribute),
           [kAXCloseButtonSubrole, kAXMinimizeButtonSubrole, kAXZoomButtonSubrole].contains(subrole) {
            return MacScreenRender.kindName(role: String(subrole.dropLast("Button".count)))
        }
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel"] {
            if let own = copyString(element, attribute), isName(own),
               (!forDisplay && attribute != kAXDescriptionAttribute)
                || own != copyString(element, kAXHelpAttribute) {
                return own
            }
        }
        let fallback = copyCaption(element, role: role, prepare: prepare)
        guard fallback == nil, hintNamedRoles.contains(role) else { return fallback }
        // Last resort for a control that names itself nowhere else: its
        // placeholder ("Reply to Claude…"), else — an icon-only button — the
        // tooltip a person reads on hover. Only when nothing else names it.
        for attribute in [kAXPlaceholderValueAttribute, kAXHelpAttribute] {
            if let hint = copyString(element, attribute), isName(hint) { return hint }
        }
        return nil
    }

    static func valueState(_ element: AXUIElement, role: String) -> String? {
        guard let raw = copyRaw(element, kAXValueAttribute) else { return nil }
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

    /// Fields that answer to their placeholder as a second name.
    static let placeholderRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    private static let hintNamedRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXComboBox", "AXPopUpButton", "AXMenuButton",
        "AXCheckBox", "AXRadioButton", "AXLink", "AXSlider", "AXDisclosureTriangle",
    ]

    private static func copyCaption(
        _ element: AXUIElement, role: String, prepare: (AXUIElement) -> AXUIElement
    ) -> String? {
        if hintNamedRoles.contains(role), let caption = copyElement(element, kAXTitleUIElementAttribute) {
            let caption = prepare(caption)
            return MacPerceptionCompiler.captionText(
                copyString(caption, kAXValueAttribute) ?? copyString(caption, kAXTitleAttribute)
            )
        }
        guard MacPerceptionCompiler.captionedRoles.contains(role) else { return nil }
        guard let parent = copyElement(element, kAXParentAttribute).map(prepare) else { return nil }
        let siblings = copyElementArray(parent, kAXChildrenAttribute)
        guard let index = siblings.firstIndex(where: { CFEqual($0, element) }), index > 0 else { return nil }
        let previous = prepare(siblings[index - 1])
        guard copyString(previous, kAXRoleAttribute) == "AXStaticText",
              let raw = copyString(previous, kAXValueAttribute) ?? copyString(previous, kAXTitleAttribute),
              raw.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(":") else { return nil }
        return MacPerceptionCompiler.captionText(raw)
    }

    static func copyActions(_ element: AXUIElement) -> [String] {
        guard prepare(element) else { return [] }
        defer { if MacAXLimits.readDeadline != nil { _ = AXUIElementSetMessagingTimeout(element, 0) } }
        var raw: CFArray?
        guard AXUIElementCopyActionNames(element, &raw) == .success, let raw else { return [] }
        return (raw as [AnyObject]).compactMap { $0 as? String }
    }

    /// Both position and size must be readable; never fabricate a missing half.
    static func copyFrame(_ element: AXUIElement) -> MacAXFrame? {
        var point = CGPoint.zero
        var size = CGSize.zero
        var hasPoint = false
        var hasSize = false
        if let raw = copyRaw(element, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
            hasPoint = AXValueGetValue((raw as! AXValue), .cgPoint, &point)
        }
        if let raw = copyRaw(element, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
            hasSize = AXValueGetValue((raw as! AXValue), .cgSize, &size)
        }
        guard hasPoint && hasSize else { return nil }
        return MacAXFrame(x: Double(point.x), y: Double(point.y), w: Double(size.width), h: Double(size.height))
    }
}
#endif
