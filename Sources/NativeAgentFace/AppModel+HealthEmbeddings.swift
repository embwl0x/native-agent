import NativeAgentShared
// Blueprint: | `AppModel+HealthEmbeddings.swift` | Health refresh belongs to the body; the window requests its diagnostics panel |

@MainActor
extension AppModel {
    func loadHealthCard() async { _ = await requestFaceRefresh(.panel(SidebarItem.diagnostics.rawValue)) }
}
