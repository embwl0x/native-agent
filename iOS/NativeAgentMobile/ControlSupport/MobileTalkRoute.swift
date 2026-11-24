import AppIntents
import Foundation
// Blueprint: | `MobileTalkRoute.swift` | Foreground talk entry shared by the Control and app, including a cold-launch pending route |

enum MobileTalkDestination: String, AppEnum {
    case talk
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Destination"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.talk: "Talk"]
}

struct MobileOpenTalkIntent: OpenIntent {
    static let title: LocalizedStringResource = "Talk to Your Agent"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Destination", default: .talk) var target: MobileTalkDestination
    @available(iOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @MainActor func perform() async throws -> some IntentResult {
        try MobileTalkRoute.request()
        return .result()
    }
}

enum MobileTalkRoute {
    static let key = "NativeAgentMobile.openTalk"
    struct Requested: NotificationCenter.MainActorMessage {
        typealias Subject = NSObject
    }
    static var isPending: Bool { MobileQuickAskRoute.defaults?.bool(forKey: key) == true }
    @MainActor static func request() throws {
        guard let defaults = MobileQuickAskRoute.defaults else {
            throw NSError(domain: "NativeAgentTalk", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "NativeAgent’s shared storage is unavailable."])
        }
        defaults.set(true, forKey: key)
        NotificationCenter.default.post(Requested())
    }
    static func consume() -> Bool {
        guard isPending else { return false }
        MobileQuickAskRoute.defaults?.removeObject(forKey: key)
        return true
    }
}
