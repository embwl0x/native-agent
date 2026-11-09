import Foundation
// Blueprint: | `ContentView.swift` | Body notification names for canonical navigation requests |

extension Notification.Name {
    static let openApprovalsRequest = Notification.Name("NativeAgent.openApprovalsRequest")
    static let openTrustMultimodalRequest = Notification.Name("openTrustMultimodalRequest")
    static let openCommandRouteRequest = Notification.Name("NativeAgent.openCommandRouteRequest")
    static let openCommandPaletteRequest = Notification.Name("NativeAgent.openCommandPaletteRequest")
    static let newDeskTaskRequest = Notification.Name("NativeAgent.newDeskTaskRequest")
    static let deskTaskCreated = Notification.Name("NativeAgent.deskTaskCreated")
    static let openActivitySectionRequest = Notification.Name("NativeAgent.openActivitySectionRequest")
    static let openActivityRootRequest = Notification.Name("NativeAgent.openActivityRootRequest")
    static let openChatDraftRequest = Notification.Name("NativeAgent.openChatDraftRequest")
    static let openSpokenChatRequest = Notification.Name("NativeAgent.openSpokenChatRequest")
}
