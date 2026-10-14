import Foundation

func _tgEncodeBotToken(_ token: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return token.addingPercentEncoding(withAllowedCharacters: allowed) ?? token
}

/// Build a Telegram Bot API URL using URLComponents with canonical path-segment
/// encoding (via `percentEncodedPath`) so the bot token and method never end up
/// as raw reserved characters in the URL path. Optional query items are encoded
/// by URLComponents as well.
func _tgBuildBotURL(
    token: String,
    method: String,
    queryItems: [URLQueryItem] = []
) -> URL? {
    let encodedToken = _tgEncodeBotToken(token)
    var comps = URLComponents()
    comps.scheme = "https"
    comps.host = "api.telegram.org"
    if let raw = ProcessInfo.processInfo.environment["NATIVE_AGENT_TELEGRAM_LOOPBACK_API"],
       let local = URLComponents(string: raw), ["127.0.0.1", "localhost"].contains(local.host ?? "") {
        comps.scheme = local.scheme
        comps.host = local.host
        comps.port = local.port
    }
    comps.percentEncodedPath = "/bot\(encodedToken)/\(method)"
    if !queryItems.isEmpty {
        comps.queryItems = queryItems
    }
    return comps.url
}
