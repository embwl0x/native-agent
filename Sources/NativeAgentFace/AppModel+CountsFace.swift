import NativeAgentShared
// Blueprint: | `AppModel+CountsFace.swift` | Per-control selections of the agent's finished counts and panel freshness |

extension AppModel {
    func countPart<Part: Equatable>(_ name: String, _ part: @escaping (CountsFace?) -> Part) -> Part {
        face.slot(.counts).select(name, as: CountsFace.self, part)
    }

    func panelRefreshStatus(for item: SidebarItem) -> PanelRefreshStatus? {
        countPart("panel.receipt.\(item.rawValue)") { $0?.panels.panels[item.rawValue]?.receipt }
    }

    func panelIsReading(_ item: SidebarItem) -> Bool {
        countPart("panel.reading.\(item.rawValue)") { face in
            face?.panels.panels[item.rawValue]?.isReading ?? true
        }
    }

    func detachedRefreshStatus(for session: String) -> PanelRefreshStatus? {
        countPart("panel.detached.\(session)") { $0?.panels.detached[session] }
    }
}
