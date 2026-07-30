import Foundation
import NativeAgentCore
import PersistenceCore

extension SwiftNativeResearchClient {
    // MARK: search

    public func search(query: String) async throws -> ResearchSearchResponse {
        // Pull base from config; empty/missing → ResearchClientError.notConfigured
        // (matches Python's `raise ValueError("SearXNG base URL is not configured")`).
        let raw = await persistence.readJSON(configPath, defaultValue: .object([:]))
        guard case .object(let obj) = raw,
              case .string(let rawBase) = obj["searxng_base_url"] ?? .null else {
            throw ResearchClientError.notConfigured
        }
        let base = trimTrailingSlash(rawBase)
        if base.isEmpty { throw ResearchClientError.notConfigured }

        guard let url = makeURL(base: base, path: "/search", query: [("q", query), ("format", "json")]) else {
            throw ResearchClientError.malformedResponse("could not build SearXNG /search URL")
        }
        let (status, body): (Int, Data)
        do {
            let (s, b, _) = try await http.get(url: url, timeout: 25)
            (status, body) = (s, b)
        } catch {
            throw ResearchClientError.transport(String(describing: error))
        }
        if !(200...299).contains(status) {
            throw ResearchClientError.malformedResponse("SearXNG returned HTTP \(status)")
        }
        let parsed: JSONValue
        do {
            parsed = try JSONValue.parse(body)
        } catch {
            throw ResearchClientError.malformedResponse("SearXNG body is not JSON: \(error)")
        }
        guard case .object(let payload) = parsed else {
            throw ResearchClientError.malformedResponse("SearXNG body is not a JSON object")
        }

        var results: [ResearchSearchResult] = []
        if case .array(let items) = payload["results"] ?? .null {
            // Match Python's `[:10]` slice.
            for item in items.prefix(10) {
                guard case .object(let entry) = item else { continue }
                results.append(parseResult(entry))
            }
        }

        // Receipt write: {id, query, url, results, createdAt} →
        // data/research/<id>.json. Matches the retired daemon.
        let receiptID = receiptIDFactory()
        let receiptObj: JSONValue = .object([
            "id": .string(receiptID),
            "query": .string(query),
            "url": .string(url.absoluteString),
            "results": .array(results.map { $0.toJSON() }),
            "createdAt": .string(Self.isoTimestamp(now())),
        ])
        let receiptPath = receiptsDir.appendingPathComponent("\(receiptID).json")
        try await persistence.writeJSON(receiptObj, to: receiptPath)
        pruneReceiptsIfNeeded()

        return ResearchSearchResponse(results: results)
    }

    // MARK: fetch (wave 30 W17)

    public func fetchURL(_ url: String) async throws -> ResearchFetchRecord {
        // Mirror Python: scheme allow-list (http/https only) ->
        // ValueError("Only http/https URLs are allowed").
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ResearchClientError.malformedResponse("Only http/https URLs are allowed")
        }
        let (status, body, contentTypeHeader): (Int, Data, String?)
        do {
            // Python uses urlopen(timeout=30) and reads up to 1_000_000 bytes.
            (status, body, contentTypeHeader) = try await http.get(url: parsed, timeout: 30)
        } catch {
            throw ResearchClientError.transport(String(describing: error))
        }
        // Python's urlopen raises on non-2xx (HTTPError); surface the same
        // failure rather than silently persisting an error page.
        if !(200...299).contains(status) {
            throw ResearchClientError.malformedResponse("fetch returned HTTP \(status)")
        }
        // 1MB cap (Python `resp.read(1_000_000)`). NOTE (gpt-5.5 review #2):
        // this truncates POST-download, not at the transport, because the
        // ResearchHTTPClient seam returns the full Data — same limitation the
        // existing search() impl carries. Acceptable while .research is DORMANT;
        // a streaming-bounded seam is future work if this route goes live.
        let capped = body.count > 1_000_000 ? body.subdata(in: 0..<1_000_000) : body
        // Python: raw.decode("utf-8", errors="replace").
        var text = String(decoding: capped, as: UTF8.self)
        // Content-type sniff: only strip HTML when the header contains the
        // literal substring "html" (Python `if "html" in content_type` is
        // case-SENSITIVE — do not fold case, to stay route-equivalent).
        let contentType = contentTypeHeader ?? ""
        if contentType.contains("html") {
            text = Self.extractText(fromHTML: text)
        }
        let sourceID = receiptIDFactory()
        let truncated = String(text.prefix(40_000))   // Python `text[:40_000]`.
        let createdAt = Self.isoTimestamp(now())
        let record = ResearchFetchRecord(
            id: sourceID, url: url, text: truncated, createdAt: createdAt
        )
        // Receipt path: data/research/source-<id>.json (note the "source-"
        // prefix — distinct from search's "<id>.json").
        let receiptPath = receiptsDir.appendingPathComponent("source-\(sourceID).json")
        try await persistence.writeJSON(record.toJSON(), to: receiptPath)
        pruneReceiptsIfNeeded()
        return record
    }


    static func extractText(fromHTML html: String) -> String {
        var parts: [String] = []
        let chars = Array(html)
        var i = 0
        let n = chars.count
        let skipTags: Set<String> = ["script", "style", "noscript"]

        func appendData(_ raw: String) {
            // Python's `convert_charrefs=True` means entities are decoded
            // BEFORE handle_data; then `" ".join(data.split())` collapses ALL
            // unicode whitespace runs to single spaces and strips ends.
            let decoded = Self.decodeHTMLEntities(raw)
            let collapsed = decoded
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            if !collapsed.isEmpty { parts.append(collapsed) }
        }

        // Parse the tag name out of a `<...>` whose inner text is `inner`
        // (already stripped of the angle brackets). Returns (name, isEnd).
        func tagInfo(_ inner: String) -> (name: String, isEnd: Bool) {
            let isEnd = inner.hasPrefix("/")
            let body = isEnd ? String(inner.dropFirst()) : inner
            let name = body.prefix { $0.isLetter || $0.isNumber }.lowercased()
            return (name, isEnd)
        }

        var dataBuf = ""
        while i < n {
            if chars[i] == "<" {
                // Flush the pending text run before processing the tag.
                if !dataBuf.isEmpty { appendData(dataBuf); dataBuf = "" }
                guard let close = chars[i...].firstIndex(of: ">") else {
                    // Unterminated tag: treat the rest as data (Python is lenient).
                    dataBuf.append(contentsOf: chars[i...])
                    break
                }
                let inner = String(chars[(i + 1)..<close])
                let info = tagInfo(inner)
                // FIX #1 (wave 30 W17 gpt-5.5 review): script/style/noscript
                // bodies are CDATA in Python's HTMLParser — `<` inside them is
                // NOT markup. On an OPENING skip tag (not self-closing), scan
                // forward for the matching literal `</name ...>` and discard
                // everything in between, rather than re-tokenizing the body.
                if skipTags.contains(info.name), !info.isEnd, !inner.hasSuffix("/") {
                    // CDATA scan: find the LITERAL closing tag `</name`
                    // (case-insensitive). Inner `<` that is NOT the closing tag
                    // (e.g. `if (a < b)` in a <script>) is body text, NOT
                    // markup, matching the retired CDATA handling.
                    let needle = Array("</" + info.name)   // lowercased name
                    var j = close + 1
                    var foundClose = false
                    while j < n {
                        if chars[j] == "<" {
                            // Try to match `</name` case-insensitively at j.
                            var k = 0
                            var matched = true
                            while k < needle.count {
                                let idx = j + k
                                if idx >= n || Character(chars[idx].lowercased()) != needle[k] {
                                    matched = false
                                    break
                                }
                                k += 1
                            }
                            if matched {
                                // Advance past the closing tag's `>` (Python is
                                // lenient about attrs/whitespace before `>`).
                                if let gt = chars[(j + needle.count - 1)...].firstIndex(of: ">") {
                                    i = gt + 1
                                } else {
                                    i = n
                                }
                                foundClose = true
                                break
                            }
                        }
                        j += 1
                    }
                    if !foundClose {
                        // No closing tag: Python treats the rest as the
                        // (never-emitted) skip region — discard to EOF.
                        i = n
                    }
                    continue
                }
                i = close + 1
            } else {
                dataBuf.append(chars[i])
                i += 1
            }
        }
        if !dataBuf.isEmpty { appendData(dataBuf) }
        return parts.joined(separator: "\n")
    }

    /// Decode the HTML char-refs Python's HTMLParser resolves with
    /// `convert_charrefs=True`. Covers the named refs that show up in real
    /// page text plus numeric (`&#NN;` / `&#xNN;`) refs. Unknown refs are
    /// left verbatim.
    static func decodeHTMLEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        // Common HTML5 named refs that show up in real page text. NOT the full
        // ~2000-entry HTML5 table (gpt-5.5 review #3): unknown refs pass
        // through verbatim, which is acceptable while .research is DORMANT and
        // the daemon route is the production path.
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
            "nbsp": "\u{00A0}", "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
            "hellip": "\u{2026}", "mdash": "\u{2014}", "ndash": "\u{2013}", "rsquo": "\u{2019}",
            "lsquo": "\u{2018}", "ldquo": "\u{201C}", "rdquo": "\u{201D}", "deg": "\u{00B0}",
            "euro": "\u{20AC}", "pound": "\u{00A3}", "cent": "\u{00A2}", "yen": "\u{00A5}",
            "bull": "\u{2022}", "middot": "\u{00B7}", "sect": "\u{00A7}", "para": "\u{00B6}",
            "laquo": "\u{00AB}", "raquo": "\u{00BB}", "times": "\u{00D7}", "divide": "\u{00F7}",
            "plusmn": "\u{00B1}", "frac12": "\u{00BD}", "frac14": "\u{00BC}", "frac34": "\u{00BE}",
            "dagger": "\u{2020}", "Dagger": "\u{2021}", "permil": "\u{2030}",
            "prime": "\u{2032}", "Prime": "\u{2033}", "infin": "\u{221E}",
            "larr": "\u{2190}", "uarr": "\u{2191}", "rarr": "\u{2192}", "darr": "\u{2193}",
            "harr": "\u{2194}", "hearts": "\u{2665}", "spades": "\u{2660}",
            "clubs": "\u{2663}", "diams": "\u{2666}", "ensp": "\u{2002}", "emsp": "\u{2003}",
            "thinsp": "\u{2009}", "shy": "\u{00AD}", "macr": "\u{00AF}", "micro": "\u{00B5}",
            "sup1": "\u{00B9}", "sup2": "\u{00B2}", "sup3": "\u{00B3}", "ordm": "\u{00BA}",
            "ordf": "\u{00AA}", "iexcl": "\u{00A1}", "iquest": "\u{00BF}",
            "agrave": "\u{00E0}", "aacute": "\u{00E1}", "acirc": "\u{00E2}",
            "atilde": "\u{00E3}", "auml": "\u{00E4}", "aring": "\u{00E5}",
            "aelig": "\u{00E6}", "ccedil": "\u{00E7}", "egrave": "\u{00E8}",
            "eacute": "\u{00E9}", "ecirc": "\u{00EA}", "euml": "\u{00EB}",
            "iacute": "\u{00ED}", "ntilde": "\u{00F1}", "oacute": "\u{00F3}",
            "ouml": "\u{00F6}", "uacute": "\u{00FA}", "uuml": "\u{00FC}",
            "szlig": "\u{00DF}",
        ]
        var out = ""
        let chars = Array(s)
        var i = 0
        let n = chars.count
        while i < n {
            if chars[i] == "&" {
                if let semi = chars[i...].firstIndex(of: ";"), semi - i <= 32 {
                    let entity = String(chars[(i + 1)..<semi])
                    if entity.hasPrefix("#") {
                        let numStr = String(entity.dropFirst())
                        var scalarValue: UInt32? = nil
                        if numStr.hasPrefix("x") || numStr.hasPrefix("X") {
                            scalarValue = UInt32(numStr.dropFirst(), radix: 16)
                        } else {
                            scalarValue = UInt32(numStr)
                        }
                        if let v = scalarValue, let scalar = Unicode.Scalar(v) {
                            out.append(Character(scalar))
                            i = semi + 1
                            continue
                        }
                    } else if let repl = named[entity] {
                        out.append(repl)
                        i = semi + 1
                        continue
                    }
                }
                out.append("&")
                i += 1
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    /// One result row. Title precedence: title || url || "Untitled".
    /// URL: || "". Snippet: content || "". Source: engines (if list)
    /// joined by "," else engine scalar else null. Mirrors L42773-L42778.
    private func parseResult(_ entry: [String: JSONValue]) -> ResearchSearchResult {
        func nonEmptyStr(_ k: String) -> String? {
            if case .string(let s) = entry[k] ?? .null, !s.isEmpty { return s }
            return nil
        }
        let title = nonEmptyStr("title") ?? nonEmptyStr("url") ?? "Untitled"
        let url = nonEmptyStr("url") ?? ""
        let snippet: String
        if case .string(let s) = entry["content"] ?? .null { snippet = s } else { snippet = "" }
        let source: String?
        if case .array(let engines) = entry["engines"] ?? .null {
            // Python: `",".join(engines)` — only meaningful for string members.
            let parts = engines.compactMap { v -> String? in
                if case .string(let s) = v { return s }
                return nil
            }
            source = parts.joined(separator: ",")
        } else if case .string(let s) = entry["engine"] ?? .null {
            source = s
        } else {
            source = nil
        }
        return ResearchSearchResult(title: title, url: url, snippet: snippet, source: source)
    }
}
