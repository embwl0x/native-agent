import Foundation

func isMainAppSourceKey(_ sourceKey: String?) -> Bool {
    guard let raw = sourceKey?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty else {
        return false
    }
    if raw == "app" { return true }
    return raw.hasSuffix("_app")
}
