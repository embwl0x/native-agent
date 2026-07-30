import Foundation
import NativeAgentCore
import PersistenceCore

extension SwiftToolDispatcher {
    func impl_market_status(input: [String: JSONValue]) async throws -> JSONValue {
        _ = input
        let markets = readMarketSecretsConfig()
        let tradingView = readTradingViewSecretsConfig()
        let sourceRows = marketSourceRows(from: markets)
        let watchlistRows = localMarketWatchlistRows(from: markets, includeSymbols: false, group: nil)
        return .object([
            "status": .string((markets != nil || tradingView != nil) ? "ok" : "missing_config"),
            "runtime": .string("swift-native"),
            "secrets_policy": .string("configured secrets stay in data/secrets and are never returned"),
            "markets_configured": .bool(markets != nil),
            "tradingview_configured": .bool(tradingView != nil),
            "sources": .array(sourceRows),
            "watchlists": .array(watchlistRows),
            "tradingview": tradingViewStatus(from: tradingView),
        ])
    }

    func impl_market_watchlists(input: [String: JSONValue]) async throws -> JSONValue {
        let source = marketJSONString(input["source"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "local"
        let includeSymbols = marketJSONBool(input["includeSymbols"]) ?? marketJSONBool(input["include_symbols"]) ?? true
        if source == "tradingview" || source == "tv" {
            return try await fetchTradingViewWatchlists(includeSymbols: includeSymbols)
        }
        let group = marketJSONString(input["group"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let markets = readMarketSecretsConfig()
        let rows = localMarketWatchlistRows(from: markets, includeSymbols: includeSymbols, group: group)
        return .object([
            "status": .string(markets == nil ? "missing_config" : "ok"),
            "runtime": .string("swift-native"),
            "source": .string("local"),
            "group": group.map(JSONValue.string) ?? .null,
            "count": .int(Int64(rows.count)),
            "watchlists": .array(rows),
        ])
    }

    func impl_tradingview_watchlist(input: [String: JSONValue]) async throws -> JSONValue {
        var routed = input
        routed["source"] = .string("tradingview")
        return try await impl_market_watchlists(input: routed)
    }

    func impl_market_quote(input: [String: JSONValue]) async throws -> JSONValue {
        let symbols = marketSymbols(from: input)
        guard !symbols.isEmpty else {
            throw AutonomyGateError.toolDenied(reason: "market_quote requires symbol or symbols")
        }
        let provider = marketJSONString(input["provider"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "tradingview"
        switch provider {
        case "tradingview", "tv":
            return try await fetchTradingViewQuote(symbols: symbols)
        case "yahoo", "yfinance":
            return try await fetchYahooQuote(symbols: symbols)
        default:
            throw AutonomyGateError.toolDenied(reason: "Unsupported market_quote provider '\(provider)'")
        }
    }

    private func readMarketSecretsConfig() -> JSONValue? {
        readSecretsJSON(named: "markets.json")
    }

    private func readTradingViewSecretsConfig() -> JSONValue? {
        readSecretsJSON(named: "tradingview.json")
    }

    private func readSecretsJSON(named name: String) -> JSONValue? {
        let url = dataRoot
            .appendingPathComponent("secrets", isDirectory: true)
            .appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONValue.parse(data)
    }

    private func marketSourceRows(from config: JSONValue?) -> [JSONValue] {
        guard case .object(let root)? = config,
              case .object(let sources)? = root["sources"] else {
            return []
        }
        return sources.keys.sorted().map { id in
            let source = sources[id]
            let obj = marketJSONObject(source)
            let enabled = marketJSONBool(obj["enabled"]) ?? false
            let configured = obj.keys.contains { key in
                ["key", "api_key", "token", "auth_token"].contains(key.lowercased())
                    && (marketJSONString(obj[key])?.isEmpty == false)
            }
            return .object([
                "id": .string(id),
                "enabled": .bool(enabled),
                "configured": .bool(configured || enabled),
                "has_secret": .bool(configured),
            ])
        }
    }

    private func localMarketWatchlistRows(
        from config: JSONValue?,
        includeSymbols: Bool,
        group: String?
    ) -> [JSONValue] {
        guard case .object(let root)? = config,
              case .object(let watchlists)? = root["watchlists"] else {
            return []
        }
        let wanted = group?.lowercased()
        return watchlists.keys.sorted().compactMap { id in
            if let wanted, id.lowercased() != wanted { return nil }
            let symbols = extractMarketSymbols(watchlists[id])
            var row: [String: JSONValue] = [
                "id": .string(id),
                "symbol_count": .int(Int64(symbols.count)),
            ]
            if includeSymbols {
                row["symbols"] = .array(symbols.map { .string($0) })
            }
            return .object(row)
        }
    }

    private func extractMarketSymbols(_ value: JSONValue?) -> [String] {
        switch value {
        case .some(.array(let arr)):
            return arr.compactMap { marketJSONString($0) }.map(normalizeMarketSymbol).filter { !$0.isEmpty }
        case .some(.object(let obj)):
            if case .array(let arr)? = obj["symbols"] {
                return arr.compactMap { marketJSONString($0) }.map(normalizeMarketSymbol).filter { !$0.isEmpty }
            }
            if case .array(let arr)? = obj["tickers"] {
                return arr.compactMap { marketJSONString($0) }.map(normalizeMarketSymbol).filter { !$0.isEmpty }
            }
            return []
        default:
            return []
        }
    }

    private func tradingViewStatus(from config: JSONValue?) -> JSONValue {
        guard case .object(let obj)? = config else {
            return .object(["configured": .bool(false), "status": .string("missing_config")])
        }
        let hasSession = !(marketJSONString(obj["sessionid"]) ?? "").isEmpty
        let hasSessionSign = !(marketJSONString(obj["sessionid_sign"]) ?? "").isEmpty
        let hasAuthToken = !(marketJSONString(obj["auth_token"]) ?? "").isEmpty
        let expires = marketJSONString(obj["jwt_expires_at"])
        return .object([
            "configured": .bool(true),
            "status": .string((hasSession || hasAuthToken) ? "configured" : "missing_session"),
            "plan": marketJSONString(obj["plan"]).map(JSONValue.string) ?? .null,
            "capabilities": sanitizedStringArray(obj["capabilities"]),
            "has_session_cookie": .bool(hasSession),
            "has_session_signature": .bool(hasSessionSign),
            "has_auth_token": .bool(hasAuthToken),
            "jwt_expires_at": expires.map(JSONValue.string) ?? .null,
            "jwt_status": .string(jwtStatus(expires)),
            "watchlist_endpoint_configured": .bool(!(marketJSONString(obj["watchlist_endpoint"]) ?? "").isEmpty),
            "scanner_endpoint_configured": .bool(!(marketJSONString(obj["scanner_endpoint"]) ?? "").isEmpty),
        ])
    }

    private func jwtStatus(_ expires: String?) -> String {
        guard let expires, !expires.isEmpty else { return "unknown" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        let date = formatter.date(from: expires) ?? fallback.date(from: expires)
        guard let date else { return "unknown" }
        return date > Date() ? "valid" : "expired"
    }

    private func fetchTradingViewWatchlists(includeSymbols: Bool) async throws -> JSONValue {
        guard case .object(let cfg)? = readTradingViewSecretsConfig(),
              let endpoint = marketJSONString(cfg["watchlist_endpoint"]),
              let url = URL(string: endpoint) else {
            throw AutonomyGateError.toolDenied(reason: "TradingView watchlist endpoint is not configured")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyTradingViewHeaders(to: &request, config: cfg)
        let json = try await marketJSONRequest(request)
        let sanitized = sanitizeMarketPayload(json)
        if includeSymbols {
            return .object([
                "status": .string("ok"),
                "runtime": .string("swift-native"),
                "source": .string("tradingview"),
                "payload": sanitized,
            ])
        }
        return .object([
            "status": .string("ok"),
            "runtime": .string("swift-native"),
            "source": .string("tradingview"),
            "payload": stripSymbolLists(sanitized),
        ])
    }

    private func fetchTradingViewQuote(symbols: [String]) async throws -> JSONValue {
        guard case .object(let cfg)? = readTradingViewSecretsConfig(),
              let endpoint = marketJSONString(cfg["scanner_endpoint"]),
              let url = URL(string: endpoint) else {
            throw AutonomyGateError.toolDenied(reason: "TradingView scanner endpoint is not configured")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyTradingViewHeaders(to: &request, config: cfg)
        let tickers = symbols.map(tradingViewTicker)
        let columns = [
            "name", "description", "exchange", "type", "subtype", "close",
            "change", "change_abs", "volume", "Recommend.All", "RSI",
            "MACD.macd", "MACD.signal",
        ]
        let body: [String: Any] = [
            "symbols": [
                "tickers": tickers,
                "query": ["types": []],
            ],
            "columns": columns,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let json = try await marketJSONRequest(request)
        return .object([
            "status": .string("ok"),
            "runtime": .string("swift-native"),
            "provider": .string("tradingview"),
            "requested_symbols": .array(symbols.map { .string(normalizeMarketSymbol($0)) }),
            "symbols": .array(tickers.map { .string($0) }),
            "columns": .array(columns.map { .string($0) }),
            "payload": sanitizeMarketPayload(json),
        ])
    }

    private func fetchYahooQuote(symbols: [String]) async throws -> JSONValue {
        let joined = symbols.map(normalizeMarketSymbol).joined(separator: ",")
        guard var comps = URLComponents(string: "https://query1.finance.yahoo.com/v7/finance/quote") else {
            throw AutonomyGateError.toolDenied(reason: "Could not build Yahoo quote URL")
        }
        comps.queryItems = [URLQueryItem(name: "symbols", value: joined)]
        guard let url = comps.url else {
            throw AutonomyGateError.toolDenied(reason: "Could not build Yahoo quote URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("NativeAgent market_quote", forHTTPHeaderField: "User-Agent")
        let json = try await marketJSONRequest(request)
        let rows = yahooQuoteRows(from: json)
        return .object([
            "status": .string("ok"),
            "runtime": .string("swift-native"),
            "provider": .string("yahoo"),
            "symbols": .array(symbols.map { .string(normalizeMarketSymbol($0)) }),
            "quotes": .array(rows),
        ])
    }

    private func marketJSONRequest(_ request: URLRequest) async throws -> JSONValue {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AutonomyGateError.toolDenied(reason: "Market request failed with HTTP \(http.statusCode)")
        }
        return try JSONValue.parse(data)
    }

    private func applyTradingViewHeaders(to request: inout URLRequest, config: [String: JSONValue]) {
        var cookies: [String] = []
        if let session = marketJSONString(config["sessionid"]), !session.isEmpty {
            cookies.append("sessionid=\(session)")
        }
        if let sign = marketJSONString(config["sessionid_sign"]), !sign.isEmpty {
            cookies.append("sessionid_sign=\(sign)")
        }
        if !cookies.isEmpty {
            request.setValue(cookies.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
        if let token = marketJSONString(config["auth_token"]), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("NativeAgent TradingView bridge", forHTTPHeaderField: "User-Agent")
    }

    private func yahooQuoteRows(from json: JSONValue) -> [JSONValue] {
        guard case .object(let root) = json,
              case .object(let quoteResponse)? = root["quoteResponse"],
              case .array(let result)? = quoteResponse["result"] else {
            return []
        }
        return result.compactMap { item in
            guard case .object(let obj) = item else { return nil }
            var row: [String: JSONValue] = [:]
            for key in [
                "symbol", "shortName", "longName", "regularMarketPrice",
                "regularMarketChange", "regularMarketChangePercent",
                "regularMarketVolume", "marketState", "currency",
                "quoteType", "exchange", "regularMarketTime",
            ] {
                if let value = obj[key] { row[key] = value }
            }
            return .object(row)
        }
    }

    private func marketSymbols(from input: [String: JSONValue]) -> [String] {
        var out: [String] = []
        if let symbol = marketJSONString(input["symbol"]) {
            out.append(contentsOf: splitSymbolInput(symbol))
        }
        if case .array(let arr)? = input["symbols"] {
            for item in arr {
                if let symbol = marketJSONString(item) {
                    out.append(contentsOf: splitSymbolInput(symbol))
                }
            }
        }
        var seen: Set<String> = []
        return out.map(normalizeMarketSymbol).filter { symbol in
            guard !symbol.isEmpty, !seen.contains(symbol) else { return false }
            seen.insert(symbol)
            return true
        }
    }

    private func splitSymbolInput(_ raw: String) -> [String] {
        raw.split { ch in ch == "," || ch == " " || ch == "\n" || ch == "\t" }
            .map(String.init)
    }

    private func normalizeMarketSymbol(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    private func tradingViewTicker(_ raw: String) -> String {
        let symbol = normalizeMarketSymbol(raw)
        if symbol.contains(":") { return symbol }
        let mapped: [String: String] = [
            "SPY": "AMEX:SPY",
            "UVXY": "AMEX:UVXY",
            "QQQ": "NASDAQ:QQQ",
            "AAPL": "NASDAQ:AAPL",
            "MSFT": "NASDAQ:MSFT",
            "GOOGL": "NASDAQ:GOOGL",
            "GOOG": "NASDAQ:GOOG",
            "AMZN": "NASDAQ:AMZN",
            "NVDA": "NASDAQ:NVDA",
            "META": "NASDAQ:META",
            "TSLA": "NASDAQ:TSLA",
            "^VIX": "CBOE:VIX",
            "^MOVE": "TVC:MOVE",
            "ES=F": "CME_MINI:ES1!",
            "NQ=F": "CME_MINI:NQ1!",
            "ZN=F": "CBOT:ZN1!",
            "ZB=F": "CBOT:ZB1!",
            "ZT=F": "CBOT:ZT1!",
            "ZF=F": "CBOT:ZF1!",
            "UB=F": "CBOT:UB1!",
            "BTC-USD": "CRYPTO:BTCUSD",
            "ETH-USD": "CRYPTO:ETHUSD",
            "BITCOIN": "CRYPTO:BTCUSD",
            "SOLANA": "CRYPTO:SOLUSD",
            "ZCASH": "CRYPTO:ZECUSD",
            "CELESTIA": "CRYPTO:TIAUSD",
            "SUI": "CRYPTO:SUIUSD",
        ]
        if let direct = mapped[symbol] { return direct }
        if symbol.hasSuffix("USD") && symbol.count <= 10 {
            return "CRYPTO:\(symbol)"
        }
        return "NASDAQ:\(symbol)"
    }

    private func sanitizedStringArray(_ value: JSONValue?) -> JSONValue {
        guard case .array(let arr)? = value else { return .array([]) }
        return .array(arr.compactMap { marketJSONString($0).map(JSONValue.string) })
    }

    private func sanitizeMarketPayload(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let obj):
            var out: [String: JSONValue] = [:]
            for (key, child) in obj {
                if isSensitiveMarketKey(key) {
                    out[key] = .string("[redacted]")
                } else {
                    out[key] = sanitizeMarketPayload(child)
                }
            }
            return .object(out)
        case .array(let arr):
            return .array(arr.map(sanitizeMarketPayload))
        default:
            return value
        }
    }

    private func stripSymbolLists(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let obj):
            var out: [String: JSONValue] = [:]
            for (key, child) in obj {
                if key.lowercased() == "symbols" || key.lowercased() == "tickers" {
                    if case .array(let arr) = child {
                        out["\(key)_count"] = .int(Int64(arr.count))
                    } else {
                        out[key] = .string("[omitted]")
                    }
                } else {
                    out[key] = stripSymbolLists(child)
                }
            }
            return .object(out)
        case .array(let arr):
            return .array(arr.map(stripSymbolLists))
        default:
            return value
        }
    }

    private func isSensitiveMarketKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return lower.contains("token")
            || lower.contains("secret")
            || lower.contains("cookie")
            || lower.contains("session")
            || lower.contains("auth")
            || lower == "key"
            || lower == "api_key"
    }

    private func marketJSONObject(_ value: JSONValue?) -> [String: JSONValue] {
        guard case .object(let obj)? = value else { return [:] }
        return obj
    }

    private func marketJSONString(_ value: JSONValue?) -> String? {
        guard case .string(let s)? = value else { return nil }
        return s
    }

    private func marketJSONBool(_ value: JSONValue?) -> Bool? {
        switch value {
        case .some(.bool(let b)): return b
        case .some(.string(let s)):
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: return nil
            }
        default:
            return nil
        }
    }
}
