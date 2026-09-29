import AppIntents
import Foundation

enum MobileAskDestination: String, AppEnum {
    case ask
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Destination"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.ask: "Quick Ask"]
}

/// Compiled into both the app and its control extension so OpenIntent executes
/// in the app. The group flag also survives a cold scene launch.
struct MobileQuickAskIntent: OpenIntent {
    static let title: LocalizedStringResource = "Quick Ask"
    @Parameter(title: "Destination", default: .ask) var target: MobileAskDestination
    @available(iOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let defaults = MobileQuickAskRoute.defaults else {
            throw NSError(domain: "NativeAgentQuickAsk", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "NativeAgent's shared storage is unavailable."])
        }
        defaults.set(true, forKey: MobileQuickAskRoute.key)
        NotificationCenter.default.post(name: MobileQuickAskRoute.notification, object: nil)
        return .result()
    }
}

enum MobileQuickAskRoute {
    static let key = "NativeAgentMobile.quickAsk"
    static let notification = Notification.Name("NativeAgentMobile.quickAsk")
    static var defaults: UserDefaults? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "NativeAgentAppGroupID") as? String else { return nil }
        return UserDefaults(suiteName: group)
    }
    static var isPending: Bool { defaults?.bool(forKey: key) == true }
    static func consume() -> Bool {
        guard isPending else { return false }
        defaults?.removeObject(forKey: key)
        return true
    }
}
