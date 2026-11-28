import CoreFoundation
import CoreGraphics
import Foundation
import Synchronization
import NativeAgentShared
import ApplicationServices
// Blueprint: | `MacAXAttributeRead.swift` | Checked AX reads isolate node gaps, retain sibling evidence and share ordering |

/// Shared checked copies keep perception and actuation on the same native evidence.
package enum MacAXAttributeRead {
    /// Transport/preparation failures belong to the transaction. Only an optional attribute's AXError.failure inside an element read is a gap.
    final class Evidence: Sendable {
        private let cause = Mutex<Error?>(nil)
        func record(_ error: Error) { cause.withLock { if $0 == nil { $0 = error } } }
        func check() throws { if let error = cause.withLock({ $0 }) { throw error } }
    }

    /// A failed node must not poison its siblings. The search owns the error; cancellation and the operation deadline still bound every transaction.
    static func node<Value>(context: MacOperationContext, _ body: (MacOperationContext) throws -> Value) throws -> Value {
        try context.evidence?.check()
        return try context.holding(\.evidence, Evidence()) { context in
            try context.holding(\.attributeGaps, nil) { context in try checked(context: context, body) }
        }
    }
    final class AttributeGaps: Sendable {
        struct Gap: Equatable {
            let attribute: String?
            let detail: String
        }
        private let gaps = Mutex([Gap]())
        func record(_ error: ElementAttributeFailure) {
            record(Gap(attribute: error.attribute, detail: "\(error.attribute): AX error \(error.status.rawValue)"))
        }
        func record(_ gap: String) {
            record(Gap(attribute: nil, detail: gap))
        }
        func record(_ gap: Gap) {
            gaps.withLock { if !$0.contains(gap) { $0.append(gap) } }
        }
        var entries: [Gap] { gaps.withLock { $0 } }
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
            try collectingAttributeGaps(context: context) { gaps, context in
                let keys = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute]
                let values = try checkedBatch(window, keys, context: context, gaps: gaps)
                guard let role = try string(values[kAXRoleAttribute], attribute: kAXRoleAttribute) else {
                    throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility window identity has no readable AXRole. Read this app again before acting.")
                }
                let subrole = try string(values[kAXSubroleAttribute], attribute: kAXSubroleAttribute)
                let title = try string(values[kAXTitleAttribute], attribute: kAXTitleAttribute)
                let frame = try Self.frame(values)
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
        if let targets = context.axTargets {
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success { targets.note(pid) }
        }
        guard !Task.isCancelled else { return false }
        do { try context.evidence?.check() } catch { return false }
        if let deadline = context.readDeadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            _ = AXUIElementSetMessagingTimeout(element, Float(min(0.25, remaining)))
        }
        return true
    }

    struct Values {
        var slots: [String: CFTypeRef] = [:]
        var gaps: AttributeGaps?

        subscript(attribute: String) -> CFTypeRef? {
            get throws {
                guard let slot = slots[attribute], CFGetTypeID(slot) != CFNullGetTypeID() else { return nil }
                guard CFGetTypeID(slot) == AXValueGetTypeID(), AXValueGetType(slot as! AXValue) == .axError else { return slot }
                var code = AXError.success
                guard unsafe AXValueGetValue(slot as! AXValue, .axError, &code), code != .success else {
                    throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility returned an invalid error for \(attribute).")
                }
                if code == .noValue || code == .attributeUnsupported { return nil }
                let error = ElementAttributeFailure(attribute: attribute, status: code)
                guard code == .failure else { throw MacAccessibilityReader.NativeReadFailure(detail: error.localizedDescription) }
                guard attribute != kAXRoleAttribute, let gaps else { throw error }
                gaps.record(error)
                return nil
            }
        }
    }

    static func batch(_ element: AXUIElement, _ attributes: [String], gaps: AttributeGaps? = nil) throws -> Values {
        var raw: CFArray?
        let status = unsafe AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &raw)
        try Task.checkCancellation()
        guard status == .success else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility read of \(attributes) failed (AX error \(status.rawValue)).", status: status)
        }
        guard let raw, CFArrayGetCount(raw) == attributes.count else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility returned an incomplete attribute batch for \(attributes).")
        }
        return Values(slots: Dictionary(uniqueKeysWithValues: zip(attributes, raw as [AnyObject])), gaps: gaps)
    }

    static func checkedBatch(_ element: AXUIElement, _ attributes: [String], context: MacOperationContext,
                             gaps: AttributeGaps? = nil) throws -> Values {
        try Task.checkCancellation()
        try context.evidence?.check()
        try SystemMacAXElementSource.ensureRenderer(element, context: context)
        guard prepareMessage(element, context: context) else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility read of \(attributes) exhausted the shared reader time budget.")
        }
        defer { if context.readDeadline != nil { _ = AXUIElementSetMessagingTimeout(element, 0) } }
        return try batch(element, attributes, gaps: gaps)
    }

    static func copyTextRange(_ element: AXUIElement, context: MacOperationContext) -> NSRange? {
        textRange(copyRaw(element, kAXSelectedTextRangeAttribute, context: context))
    }

    static func textRange(_ raw: CFTypeRef?) -> NSRange? {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard unsafe AXValueGetValue(raw as! AXValue, .cfRange, &range),
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
        if attribute == kAXValueAttribute {
            let metadata = try checkedBatch(element, [kAXRoleAttribute, kAXSubroleAttribute], context: context)
            guard let role = try string(metadata[kAXRoleAttribute], attribute: kAXRoleAttribute) else {
                throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility value read has no readable AXRole.")
            }
            guard valueReadable(role: role, context: context) else { return nil }
            if textValueRoles.contains(role) {
                _ = try string(metadata[kAXSubroleAttribute], attribute: kAXSubroleAttribute)
            }
            return try checkedBatch(element, [attribute], context: context)[attribute]
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
        let status = unsafe AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        try Task.checkCancellation()
        switch status {
        case .success: return raw
        case .attributeUnsupported, .noValue: return nil
        case .failure: throw ElementAttributeFailure(attribute: attribute, status: status)
        default: throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility read of \(attribute) failed (AX error \(status.rawValue)).",
            status: status)
        }
    }

    package static func checkedParameterized(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef,
        context: MacOperationContext) throws -> CFTypeRef? {
        try context.evidence?.check()
        try Task.checkCancellation()
        try SystemMacAXElementSource.ensureRenderer(element, context: context)
        guard prepareMessage(element, context: context) else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility read of \(attribute) exhausted the shared reader time budget.")
        }
        defer { if context.readDeadline != nil { _ = AXUIElementSetMessagingTimeout(element, 0) } }
        var raw: CFTypeRef?
        let status = unsafe AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &raw)
        try Task.checkCancellation()
        switch status {
        case .success: return raw
        case .attributeUnsupported, .parameterizedAttributeUnsupported, .noValue: return nil
        case .failure: throw ElementAttributeFailure(attribute: attribute, status: status)
        default: throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility read of \(attribute) failed (AX error \(status.rawValue)).",
            status: status)
        }
    }

    /// Whether the element lets the attribute be written; an unreadable answer is no.
    package static func isSettable(_ element: AXUIElement, _ attribute: String, context: MacOperationContext) -> Bool {
        guard prepare(element, context: context) else { return false }
        defer { if context.readDeadline != nil { _ = AXUIElementSetMessagingTimeout(element, 0) } }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    package static func copyString(_ element: AXUIElement, _ attribute: String, context: MacOperationContext) -> String? {
        do { let value = try checkedText(element, attribute, context: context); return value.isEmpty ? nil : value }
        catch { failed(error, context: context); return nil }
    }

    /// A disabled control says so. One that doesn't publish AXEnabled (TextEdit's text area) makes no claim, so it is not disabled; only a failed read leaves the state unknown.
    package static func checkedEnabled(_ element: AXUIElement, context: MacOperationContext) throws -> Bool {
        try checkedBool(element, kAXEnabledAttribute, context: context) ?? true
    }

    static func copyBool(_ element: AXUIElement, _ attribute: String, context: MacOperationContext) -> Bool? {
        do { return try checkedBool(element, attribute, context: context) }
        catch { failed(error, context: context); return nil }
    }

    package static func checkedBool(_ element: AXUIElement, _ attribute: String, context: MacOperationContext) throws -> Bool? {
        try boolean(checkedRaw(element, attribute, context: context), attribute: attribute)
    }

    static func boolean(_ raw: CFTypeRef?, attribute: String) throws -> Bool? {
        guard let raw else { return nil }
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

    static let listRoles: Set<String> = ["AXList", "AXTable", "AXOutline"]

    static func arrayCount(_ element: AXUIElement, _ attribute: String, context: MacOperationContext) throws -> Int? {
        try Task.checkCancellation()
        try context.evidence?.check()
        try SystemMacAXElementSource.ensureRenderer(element, context: context)
        guard prepareMessage(element, context: context) else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility child count exhausted the reader time budget.")
        }
        defer { if context.readDeadline != nil { _ = AXUIElementSetMessagingTimeout(element, 0) } }
        var count: CFIndex = 0
        let status = AXUIElementGetAttributeValueCount(element, attribute as CFString, &count)
        try Task.checkCancellation()
        if status == .attributeUnsupported { return nil }
        if status == .noValue { throw ElementAttributeFailure(attribute: attribute, status: status) }
        guard status == .success, count >= 0 else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility \(attribute) count read failed (AX error \(status.rawValue)).",
                status: status)
        }
        return count
    }

    /// A list's visible children are whichever visible array it actually declares. A count alone cannot say: some lists (Finder's icon view) answer
    /// a zero count for AXVisibleRows they do not use, so the element's own attribute names decide.
    static func visibleChildList(_ element: AXUIElement, context: MacOperationContext) throws -> (attribute: String, count: Int) {
        try context.evidence?.check()
        try SystemMacAXElementSource.ensureRenderer(element, context: context)
        guard prepareMessage(element, context: context) else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility child-attribute discovery exhausted the reader time budget.")
        }
        var names: CFArray?
        let status = unsafe AXUIElementCopyAttributeNames(element, &names)
        if context.readDeadline != nil { _ = AXUIElementSetMessagingTimeout(element, 0) }
        guard status == .success, let names = names as? [String] else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility child-attribute names could not be read (AX error \(status.rawValue)).")
        }
        let attribute = [kAXVisibleRowsAttribute, kAXVisibleChildrenAttribute].first(where: names.contains) ?? kAXChildrenAttribute
        guard let count = try arrayCount(element, attribute, context: context) else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility list exposes no readable \(attribute) array.")
        }
        return (attribute, count)
    }

    static func childList(_ element: AXUIElement, role: String? = nil, context: MacOperationContext) throws -> (attribute: String, count: Int?) {
        try context.evidence?.check()
        let role = try role ?? checkedText(element, kAXRoleAttribute, context: context)
        guard listRoles.contains(role) else { return (kAXChildrenAttribute, nil) }
        let list = try visibleChildList(element, context: context)
        return (list.attribute, list.count)
    }

    static func childAttribute(_ element: AXUIElement, role: String? = nil, context: MacOperationContext) throws -> String {
        try childList(element, role: role, context: context).attribute
    }

    enum ListRead: Equatable, Sendable {
        case counted(attribute: String, count: Int)
        case unreadable(String)

        var children: (attribute: String, count: Int) {
            get throws {
                switch self {
                case let .counted(attribute, count): return (attribute, count)
                case let .unreadable(detail): throw MacAccessibilityReader.NativeReadFailure(detail: detail)
                }
            }
        }
    }

    static func listReading(_ element: AXUIElement, role: String, context: MacOperationContext) -> (children: ListRead?, summary: String?) {
        guard listRoles.contains(role) else { return (nil, nil) }
        let list: (attribute: String, count: Int)
        do { list = try visibleChildList(element, context: context) }
        catch { return (.unreadable(error.localizedDescription), "Visible item count unavailable: child attributes could not be read.") }
        let children = ListRead.counted(attribute: list.attribute, count: list.count)
        guard list.attribute != kAXChildrenAttribute else { return (children, nil) }
        let rows = list.attribute == kAXVisibleRowsAttribute
        let kind = rows ? "rows" : "items"
        guard let total = try? arrayCount(element, rows ? kAXRowsAttribute : kAXChildrenAttribute, context: context) else {
            return (children, "\(list.count) \(kind) on screen; total count unavailable.")
        }
        return (children, "\(list.count) of \(total) \(kind) on screen." + (total > list.count ? " More \(kind) off screen." : ""))
    }

    package static func copyElementArray(
        _ element: AXUIElement, _ attribute: String, limit: Int? = nil,
        context: MacOperationContext
    ) -> [AXUIElement] {
        do {
            let list: (attribute: String, count: Int?) = attribute == kAXChildrenAttribute
                ? try childList(element, context: context) : (attribute, nil)
            return try checkedElementArray(element, list.attribute, count: list.count, limit: limit, context: context)
        } catch { failed(error, context: context); return [] }
    }

    static func checkedElementArray(
        _ element: AXUIElement, _ attribute: String, count knownCount: Int? = nil, limit: Int? = nil,
        context: MacOperationContext
    ) throws -> [AXUIElement] {
        func wholeArray() throws -> [AnyObject] {
            guard let raw = try checkedRaw(element, attribute, context: context) else {
                if let knownCount, knownCount > 0 { throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility \(attribute) child array is unavailable.") }
                return []
            }
            guard CFGetTypeID(raw) == CFArrayGetTypeID() else {
                throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility \(attribute) returned a non-array value.")
            }
            return raw as! CFArray as [AnyObject]
        }
        func boundedArray(limit: Int) throws -> [AnyObject] {
            guard limit > 0 else { return [] }
            if let knownCount, knownCount <= limit { return try wholeArray() }
            guard prepare(element, context: context) else {
                throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility child-array preparation failed or exhausted the reader time budget.")
            }
            defer { if context.readDeadline != nil { _ = AXUIElementSetMessagingTimeout(element, 0) } }
            var count: CFIndex = 0
            if knownCount == nil, AXUIElementGetAttributeValueCount(element, attribute as CFString, &count) == .success, count <= limit {
                return try wholeArray()
            }
            var raw: CFArray?
            let status = unsafe AXUIElementCopyAttributeValues(element, attribute as CFString, 0, CFIndex(limit), &raw)
            try Task.checkCancellation()
            if knownCount == nil, status == .attributeUnsupported || status == .noValue { return [] }
            if status == .failure { throw ElementAttributeFailure(attribute: attribute, status: status) }
            guard status == .success, let raw else {
                throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility \(attribute) array read failed (AX error \(status.rawValue)).",
                    status: status)
            }
            return raw as [AnyObject]
        }
        let limit = limit ?? (context.readDeadline != nil ? MacAXLimits.deepPageMaxNodes : nil)
        let array = try limit.map(boundedArray) ?? wholeArray()
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

    static let labelAttributes = [kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel",
                                  kAXHelpAttribute, kAXPlaceholderValueAttribute, kAXRoleDescriptionAttribute, kAXPositionAttribute, kAXSizeAttribute]
    typealias Label = (identity: String?, display: String?, subrole: String?, help: String?, placeholder: String?, frame: MacAXFrame?,
                       unreadable: Bool, caption: String?)

    static func copyLabel(_ element: AXUIElement, role: String, context: MacOperationContext) -> Label {
        let owner = context.attributeGaps
        return collectingAttributeGaps(context: context) { gaps, context in
            defer { for gap in gaps.entries { owner?.record(gap) } }
            do {
                let values = try checkedBatch(element, labelAttributes, context: context, gaps: gaps)
                return try readLabel(element, role: role, values: values, context: context, prepare: { $0 })
            } catch {
                failed(error, context: context)
                return (nil, nil, nil, nil, nil, nil, true, nil)
            }
        }
    }

    static func readLabel(_ element: AXUIElement, role: String, values: Values, context: MacOperationContext,
                          prepare: (AXUIElement) -> AXUIElement,
                          checkRelated: ((AXUIElement, MacOperationContext) throws -> Void)? = nil) throws -> Label {
        let subrole = try string(values[kAXSubroleAttribute], attribute: kAXSubroleAttribute)
        let help = try string(values[kAXHelpAttribute], attribute: kAXHelpAttribute)
        let placeholder = try string(values[kAXPlaceholderValueAttribute], attribute: kAXPlaceholderValueAttribute)
        let roleDescription = try string(values[kAXRoleDescriptionAttribute], attribute: kAXRoleDescriptionAttribute)
        let frame = try Self.frame(values)
        func isName(_ text: String) -> Bool {
            text != role && text != MacScreenRender.kindName(role: role)
                && text != roleDescription
        }
        var identity: String?, display: String?, relatedCaption: String?
        if role == kAXButtonRole, let subrole,
           [kAXCloseButtonSubrole, kAXMinimizeButtonSubrole, kAXZoomButtonSubrole].contains(subrole) {
            identity = MacScreenRender.kindName(role: String(subrole.dropLast("Button".count)))
            display = identity
        } else {
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel"] {
                let own = try string(values[attribute], attribute: attribute)
                if context.attributeGaps?.contains(attribute: attribute) == true {
                    return (nil, nil, subrole, help, placeholder, frame, true, nil)
                }
                guard let own, isName(own) else { continue }
                if identity == nil, attribute != kAXDescriptionAttribute || own != help { identity = own }
                if display == nil, own != help { display = own }
                if identity != nil, display != nil { break }
            }
            if identity == nil || display == nil {
                let caption = copyCaption(element, role: role, frame: frame, context: context, prepare: prepare, checkRelated: checkRelated)
                if caption.unreadable {
                    // No hint or nearby text may stand in for a failed name.
                    return (nil, nil, subrole, help, placeholder, frame, true, nil)
                }
                relatedCaption = caption.text
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
        return (identity, display, subrole, help, placeholder, frame, false, relatedCaption)
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
    /// The roles whose value is words a person typed or reads; only these can hold a secret of their own.
    static let textValueRoles = placeholderRoles.union(MacScreenViewBuilder.textRoles).union(["AXSecureTextField"])

    static func valueReadable(role: String, context: MacOperationContext) -> Bool {
        !textValueRoles.contains(role) || context.attributeGaps?.contains(attribute: kAXSubroleAttribute) != true
    }

    private static let hintNamedRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXComboBox", "AXPopUpButton", "AXMenuButton",
        "AXCheckBox", "AXRadioButton", "AXLink", "AXSlider", "AXDisclosureTriangle",
    ]

    private static func copyCaption(
        _ element: AXUIElement, role: String, frame: MacAXFrame?, context: MacOperationContext, prepare: (AXUIElement) -> AXUIElement,
        checkRelated: ((AXUIElement, MacOperationContext) throws -> Void)?) -> (text: String?, unreadable: Bool) {
        // These reads establish a label source, not attributes of the control. Keep foreign element errors in their own scope, then publish ONE caption gap on
        // the control. Checked reads stop at the first failure.
        do {
            let text = try collectingAttributeGaps(context: context) { _, context in
                let text = try readCaption(element, role: role, frame: frame, context: context, prepare: prepare, checkRelated: checkRelated)
                try context.evidence?.check()
                return text
            }
            return (text, false)
        } catch is MacAccessibilityReader.StrictReadCut {
            return (nil, true)
        } catch let error as ElementAttributeFailure {
            context.attributeGaps?.record("caption read: \(error.localizedDescription)")
            return (nil, true)
        } catch {
            failed(error, context: context)
            return (nil, true)
        }
    }

    private static func readCaption(
        _ element: AXUIElement, role: String, frame: MacAXFrame?, context: MacOperationContext, prepare: (AXUIElement) -> AXUIElement,
        checkRelated: ((AXUIElement, MacOperationContext) throws -> Void)?) throws -> String? {
        func relatedElement(_ element: AXUIElement, _ attribute: String) throws -> AXUIElement? {
            guard let raw = try checkedRaw(element, attribute, context: context) else { return nil }
            guard CFGetTypeID(raw) == AXUIElementGetTypeID() else {
                throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility caption read of \(attribute) returned a non-element value.")
            }
            return raw as! AXUIElement
        }
        func captionText(_ element: AXUIElement) throws -> String? {
            try checkRelated?(element, context)
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
        try checkRelated?(parent, context)
        let list = try childList(parent, context: context)
        let siblings = try checkedElementArray(parent, list.attribute, count: list.count, context: context)
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
        let status = unsafe AXUIElementCopyActionNames(element, &raw)
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
        do { return try checkedFrame(element, context: context, gaps: context.attributeGaps) }
        catch { failed(error, context: context); return nil }
    }

    static func checkedFrame(_ element: AXUIElement, context: MacOperationContext, gaps: AttributeGaps? = nil) throws -> MacAXFrame? {
        try frame(checkedBatch(element, [kAXPositionAttribute, kAXSizeAttribute], context: context, gaps: gaps))
    }

    private static func frame(_ values: Values) throws -> MacAXFrame? {
        let position = try values[kAXPositionAttribute]
        if values.gaps?.contains(attribute: kAXPositionAttribute) == true { return nil }
        let rawSize = try values[kAXSizeAttribute]
        var point = CGPoint.zero
        var size = CGSize.zero
        guard let position, CFGetTypeID(position) == AXValueGetTypeID(),
              let rawSize, CFGetTypeID(rawSize) == AXValueGetTypeID(),
              unsafe AXValueGetValue(position as! AXValue, .cgPoint, &point),
              unsafe AXValueGetValue(rawSize as! AXValue, .cgSize, &size),
              point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width >= 0, size.height >= 0,
              (point.x + size.width).isFinite, (point.y + size.height).isFinite else { return nil }
        return MacAXFrame(x: Double(point.x), y: Double(point.y), w: Double(size.width), h: Double(size.height))
    }

    package static func text(_ element: AXUIElement, _ attribute: String, context: MacOperationContext) -> String {
        copyString(element, attribute, context: context) ?? ""
    }

    package static func checkedText(_ element: AXUIElement, _ attribute: String, context: MacOperationContext) throws -> String {
        try string(checkedRaw(element, attribute, context: context), attribute: attribute) ?? ""
    }

    static func string(_ raw: CFTypeRef?, attribute: String) throws -> String? {
        guard let raw else { return nil }
        guard let value = raw as? String else {
            throw MacAccessibilityReader.NativeReadFailure(detail: "Accessibility \(attribute) returned a non-text value.")
        }
        return value.isEmpty ? nil : value
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
