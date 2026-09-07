import Foundation
#if canImport(ApplicationServices) && os(macOS)
import ApplicationServices

/// Nil-tolerant AX attribute copies shared by perception and actuation.
enum MacAXAttributeRead {
    static func copyRaw(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
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

    static func copyElementArray(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let raw = copyRaw(element, attribute), CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
        return (raw as! CFArray as [AnyObject]).compactMap { candidate in
            guard CFGetTypeID(candidate) == AXUIElementGetTypeID() else { return nil }
            return (candidate as! AXUIElement)
        }
    }

    static func copyActions(_ element: AXUIElement) -> [String] {
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
