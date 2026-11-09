import NativeAgentShared
// Blueprint: | `AppModel+PanelRefresh.swift` | Scoped body refresh acts and selected panel freshness presentation |

@MainActor
extension AppModel {
    @discardableResult
    func refreshForSidebarItem(_ item: SidebarItem) async -> Bool {
        await requestFaceRefresh(.panel(item.rawValue))
    }

    func panelStaleNotice(for item: SidebarItem) -> String? {
        let id = item.rawValue
        return face.slot(.counts).select("panel.notice.\(id)", as: CountsFace.self) { $0?.panels.panels[id]?.staleNotice }
    }

    @discardableResult
    func refreshSidebarActivityBadge() async -> Bool {
        await requestFaceRefresh(.panel("sidebar"))
    }
}
