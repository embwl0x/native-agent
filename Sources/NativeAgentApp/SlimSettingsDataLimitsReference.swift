import Foundation

/// The Settings link opens the same bounded-data reference that ships in a
/// release bundle. Its result is explicit so a missing or unopenable resource
/// cannot look like a successful button press.
enum SlimSettingsDataLimitsOpenOutcome: Equatable {
    case opened
    case resourceUnavailable
    case openFailed

    var failureMessage: String? {
        switch self {
        case .opened:
            return nil
        case .resourceUnavailable:
            return "The data-limits reference is missing from this copy of NativeAgent. Reinstall or update the app, then try again."
        case .openFailed:
            return "NativeAgent found the data-limits reference but macOS could not open it. Try again or open the document from the installed app bundle."
        }
    }
}

enum SlimSettingsDataLimitsReference {
    static let resourceName = "data-bounds"
    static let resourceExtension = "md"
    static let preferredSubdirectory = "docs"

    typealias ResourceLookup = (_ name: String, _ extension: String?, _ subdirectory: String?) -> URL?

    /// SwiftPM copies the document at the resource root while the signed
    /// release layout keeps it in Resources/docs. Prefer the release layout,
    /// then retain the development-bundle fallback.
    static func bundledURL(using resourceLookup: ResourceLookup) -> URL? {
        resourceLookup(resourceName, resourceExtension, preferredSubdirectory)
            ?? resourceLookup(resourceName, resourceExtension, nil)
    }

    static func open(
        resourceLookup: ResourceLookup,
        opener: (URL) -> Bool
    ) -> SlimSettingsDataLimitsOpenOutcome {
        guard let url = bundledURL(using: resourceLookup) else {
            return .resourceUnavailable
        }
        return opener(url) ? .opened : .openFailed
    }
}
