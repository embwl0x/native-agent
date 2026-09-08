import Foundation

enum OAuthProductionSession {
    static func make(requestTimeout: String?, resourceTimeout: String?) -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeoutValue(requestTimeout, fallback: 240)
        cfg.timeoutIntervalForResource = timeoutValue(resourceTimeout, fallback: 600)
        cfg.waitsForConnectivity = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }

    private static func timeoutValue(_ raw: String?, fallback: TimeInterval) -> TimeInterval {
        guard let raw else { return fallback }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = TimeInterval(trimmed), parsed > 0 else { return fallback }
        return parsed
    }
}
