import Foundation
// Blueprint: | `ContentView.swift` | Body notification names for canonical navigation requests |

extension Notification.Name {
    static let openApprovalsRequest = Notification.Name("NativeAgent.openApprovalsRequest")
    static let openTrustMultimodalRequest = Notification.Name("openTrustMultimodalRequest")
    static let openCommandRouteRequest = Notification.Name("NativeAgent.openCommandRouteRequest")
}
