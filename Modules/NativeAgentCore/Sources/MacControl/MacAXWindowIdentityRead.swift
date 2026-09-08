#if canImport(ApplicationServices) && os(macOS)
import ApplicationServices

/// Synchronous identity projection; callers own handle minting, indices and execution lanes.
enum MacAXWindowIdentityRead {
    static func copy(_ window: AXUIElement, pid: Int32, index: Int) -> MacAXWindowIdentity {
        MacAXWindowIdentity(
            pid: pid,
            index: index,
            role: MacAXAttributeRead.copyString(window, kAXRoleAttribute) ?? "AXWindow",
            subrole: MacAXAttributeRead.copyString(window, kAXSubroleAttribute),
            title: MacAXAttributeRead.copyString(window, kAXTitleAttribute),
            frame: MacAXAttributeRead.copyFrame(window)
        )
    }
}
#endif
