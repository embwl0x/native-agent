import Foundation
import NativeAgentCore
import PersistenceCore
import MacControl

extension SwiftNativeResearchClient {
    static func localServerIsDown(_ error: Error, url: URL) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host ?? "")
            && (error as? URLError)?.code == .cannotConnectToHost
    }
    // MARK: search

    public func search(query: String, categories: String? = nil, timeRange: String? = nil) async throws -> ResearchSearchResponse {
        // Pull base from config; empty/missing → ResearchClientError.notConfigured
        // (matches Python's `raise ValueError("SearXNG base URL is not configured")`).
        let raw = try await persistence.readJSON(configPath, ifMissing: .object([:]))
        guard case .object(let obj) = raw,
              case .string(let rawBase) = obj["searxng_base_url"] ?? .null else {
            throw ResearchClientError.notConfigured
        }
        let base = trimTrailingSlash(rawBase)
        if base.isEmpty { throw ResearchClientError.notConfigured }

        var parameters = [("q", query), ("format", "json")]
        if let categories, !categories.isEmpty { parameters.append(("categories", categories)) }
        if let timeRange, ["day", "week", "month", "year"].contains(timeRange) {
            parameters.append(("time_range", timeRange))
        }
        guard let url = makeURL(base: base, path: "/search", query: parameters) else {
            throw ResearchClientError.malformedResponse("could not build SearXNG /search URL")
        }
        let response: ResearchHTTPResponse
        do {
            response = try await http.getBounded(url: url, timeout: 25, maxBytes: 1_000_000)
        } catch {
            if Self.localServerIsDown(error, url: url) {
                throw ResearchClientError.localServerNotRunning(url.absoluteString)
            }
            throw ResearchClientError.transport(String(describing: error))
        }
        if !(200...299).contains(response.status) {
            throw ResearchClientError.malformedResponse("SearXNG returned HTTP \(response.status)")
        }
        guard !response.truncated else {
            throw ResearchClientError.malformedResponse("SearXNG response exceeds 1,000,000 bytes")
        }
        let parsed: JSONValue
        do {
            parsed = try JSONValue.parse(response.body)
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

        // SearXNG sends [[engine, reason], ...].
        var unresponsive: [String] = []
        if case .array(let engines) = payload["unresponsive_engines"] ?? .null {
            for engine in engines {
                guard case .array(let pair) = engine, case .string(let name)? = pair.first else { continue }
                if pair.count > 1, case .string(let reason) = pair[1] {
                    unresponsive.append("\(name): \(reason)")
                } else {
                    unresponsive.append(name)
                }
            }
        }
        return ResearchSearchResponse(results: results, unresponsiveEngines: unresponsive)
    }

    // MARK: fetch (wave 30 W17)

    public func fetchURL(_ url: String) async throws -> ResearchFetchRecord {
        try Task.checkCancellation()
        // Mirror Python: scheme allow-list (http/https only) ->
        // ValueError("Only http/https URLs are allowed").
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ResearchClientError.malformedResponse("Only http/https URLs are allowed")
        }
        func get(_ target: URL, maxBytes: Int) async throws -> ResearchHTTPResponse {
            let response: ResearchHTTPResponse
            do {
                response = try await http.getBounded(url: target, timeout: 30, maxBytes: maxBytes)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if Self.localServerIsDown(error, url: target) {
                    throw ResearchClientError.localServerNotRunning(target.absoluteString)
                }
                throw ResearchClientError.transport(String(describing: error))
            }
            try Task.checkCancellation()
            guard (200...299).contains(response.status) else {
                throw ResearchClientError.httpStatus(response.status)
            }
            return response
        }
        func mimeOf(_ response: ResearchHTTPResponse) -> String {
            response.contentType?.split(separator: ";").first?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        }
        var byteLimit = 1_000_000
        var response = try await get(parsed, maxBytes: byteLimit)
        var finalURL = response.finalURL
        // A <meta http-equiv=refresh> page ("Redirecting…") is a redirect a
        // browser follows; follow one hop, as an HTTP redirect is followed.
        if mimeOf(response).contains("html"),
           let next = Self.metaRefreshTarget(String(decoding: response.body, as: UTF8.self), base: finalURL ?? parsed),
           next.absoluteString != (finalURL ?? parsed).absoluteString {
            response = try await get(next, maxBytes: byteLimit)
            finalURL = response.finalURL ?? next
        }
        // A PDF is read by the app's PDF reader, under its own size bound.
        let looksLikePDF = mimeOf(response) == "application/pdf" || response.body.starts(with: Data("%PDF-".utf8))
        if looksLikePDF, response.truncated {
            byteLimit = MacDocumentRead.maxFileBytes
            response = try await get(finalURL ?? parsed, maxBytes: byteLimit)
            finalURL = response.finalURL ?? finalURL
        }
        let mime = mimeOf(response)
        let supported = mime.isEmpty || mime.hasPrefix("text/") || mime == "application/json"
            || mime.hasSuffix("+json") || mime == "application/xml" || mime.hasSuffix("+xml")
            || mime == "application/xhtml+xml"
        // No binary-to-replacement-character conversion masquerading as a read.
        let decoding = supported && !looksLikePDF
            ? ResearchTextDecoding.decode(response.body, contentType: response.contentType, mime: mime, truncated: response.truncated)
            : ResearchTextDecoding(text: nil, declaredCharset: nil, encoding: nil, source: "not_applicable", discardedTerminalBytes: 0, error: nil)
        try Task.checkCancellation()
        let html = mime.contains("html")
        var htmlEvidence: (text: String, scriptCharacters: Int, scripts: Int, canvases: Int, bodyCharacters: Int)?
        var pdfPages: Int?
        var textTruncated = false
        let status: String
        let text: String
        if looksLikePDF, response.truncated {
            status = MacDocumentRead.ExtractionFailure.fileTooLarge.rawValue; text = ""
        } else if looksLikePDF {
            switch MacDocumentRead.extract(data: response.body, kind: .pdf) {
            case .success(let document):
                status = "pdf_text"; text = document.text
                pdfPages = document.pages; textTruncated = document.truncated
            case .failure(let failure):
                status = failure.rawValue; text = ""
            }
        } else if !supported {
            status = "unsupported_content_type"; text = ""
        } else if let decoded = decoding.text {
            if html {
                htmlEvidence = Self.extractHTML(decoded)
                text = htmlEvidence!.text
            } else { text = decoded }
            status = text.isEmpty ? "empty_text" : (html ? "html_text" : "plain_text")
        } else {
            status = "unsupported_text_encoding"; text = ""
        }
        try Task.checkCancellation()
        let extracted = ["html_text", "plain_text", "empty_text", "pdf_text"].contains(status)
        // A short document alone is valid; a script-heavy shell or an explicit
        // JavaScript gate needs a rendered read before claiming page coverage.
        let thinPage = extracted && (response.status == 203
            || (htmlEvidence.map { evidence in
                evidence.bodyCharacters == 0
                    || (evidence.bodyCharacters < 400 && evidence.scripts > 0)
                    || ["enable javascript", "javascript is required", "javascript must be enabled", "turn on javascript"]
                        .contains { text.localizedCaseInsensitiveContains($0) }
            } ?? false))
        let coverage: JSONValue = .object([
            "requested_url": .string(url),
            "final_url": finalURL.map { .string($0.absoluteString) } ?? .null,
            "content_type": response.contentType.map(JSONValue.string) ?? .null,
            "http_status": .int(Int64(response.status)),
            "retained_body_bytes": .int(Int64(response.body.count)),
            "observed_body_bytes": .int(Int64(response.observedBytes)),
            "body_byte_limit": .int(Int64(byteLimit)),
            "body_truncated": .bool(response.truncated),
            "response_complete": .bool(!response.truncated),
            "extraction_status": .string(status),
            "declared_charset": decoding.declaredCharset.map(JSONValue.string) ?? .null,
            "decoded_encoding": decoding.encoding.map(JSONValue.string) ?? .null,
            "encoding_source": .string(decoding.source),
            "discarded_terminal_bytes": .int(Int64(decoding.discardedTerminalBytes)),
            "encoding_error": decoding.error.map(JSONValue.string) ?? .null,
            "extracted_characters": .int(Int64(text.count)),
            "html_script_characters": .int(Int64(htmlEvidence?.scriptCharacters ?? 0)),
            "html_canvas_elements": .int(Int64(htmlEvidence?.canvases ?? 0)),
            "html_script_elements": .int(Int64(htmlEvidence?.scripts ?? 0)),
            "html_body_characters": htmlEvidence.map { .int(Int64($0.bodyCharacters)) } ?? .null,
            "pdf_pages": pdfPages.map { .int(Int64($0)) } ?? .null,
            "thin_page": .bool(thinPage),
            "hint": thinPage ? .string("The fetched text is thin or requires JavaScript; it does not establish the rendered page's content. Follow next_call to open and read it in your Chrome tab.") : .null,
            "text_truncated": .bool(textTruncated),
            "complete": .bool(!response.truncated && extracted && !thinPage && !textTruncated),
            "note": .string(extracted
                ? "Text covers the retained response body. Tool-output paging may expose it in sections. Body truncation means the source was not fully read."
                : "No readable text was extracted. Discover an appropriate reader for this content type or encoding; this is not an empty-page finding."),
        ])
        let sourceID = receiptIDFactory()
        // The locator names the receipt this call actually writes. It is not
        // an access grant, a permanent archive, or a promise of future presence.
        let receiptPath = receiptsDir.appendingPathComponent("source-\(sourceID).json")
        let sourceReceipt: JSONValue = .object([
            "path": .string(receiptPath.path),
            "source_id": .string(sourceID),
            "contents": .string("JSON with retained extracted text (if any) and coverage from this bounded read. Content beyond the response byte bound is not retained."),
            "retention": .string("Limited local retention: newest \(Self.receiptRetentionLimit) mixed search/fetch receipts. May be pruned or removed; no fixed expiry is promised."),
            "read_tool": .string("app"),
            "read_args": .object([
                "action": .string("files.read"),
                "args": .object(["path": .string(receiptPath.path)]),
            ]),
            "access": .string("Normal file permissions apply. This locator does not grant access."),
        ])
        let record = ResearchFetchRecord(
            id: sourceID, url: url, text: text, createdAt: Self.isoTimestamp(now()), coverage: coverage,
            sourceReceipt: sourceReceipt
        )
        try Task.checkCancellation()
        try await persistence.writeJSON(record.toJSON(), to: receiptPath)
        pruneReceiptsIfNeeded()
        return record
    }


    /// The target of a `<meta http-equiv="refresh" content="N; url=…">` in the
    /// document head, resolved against the page's URL; nil when the head has
    /// none or it is not http(s). Comments, scripts and styles are not markup,
    /// so they are stripped first; a no-JS reader honours one inside noscript.
    static func metaRefreshTarget(_ document: String, base: URL) -> URL? {
        var html = document.replacingOccurrences(of: #"<!--[\s\S]*?-->|<(script|style)\b[\s\S]*?</\1\s*>"#,
                                                 with: "", options: [.regularExpression, .caseInsensitive])
        if let end = html.range(of: #"</head\s*>|<body\b"#, options: [.regularExpression, .caseInsensitive]) {
            html = String(html[..<end.lowerBound])
        }
        guard let tag = html.range(of: #"<meta\b[^>]*http-equiv\s*=\s*["']?refresh\b[^>]*>"#,
                                   options: [.regularExpression, .caseInsensitive]),
              let content = html[tag].range(of: #"content\s*=\s*("[^"]*"|'[^']*')"#,
                                            options: [.regularExpression, .caseInsensitive]),
              let marker = html[content].range(of: #"url\s*=\s*"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let raw = html[marker.upperBound..<html[content].index(before: content.upperBound)]
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\" ").union(.whitespacesAndNewlines))
        guard !raw.isEmpty, let target = URL(string: decodeHTMLEntities(raw), relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(target.scheme?.lowercased() ?? "") else { return nil }
        return target
    }

    static func extractText(fromHTML html: String) -> String {
        extractHTML(html).text
    }

    private static func extractHTML(_ html: String)
        -> (text: String, scriptCharacters: Int, scripts: Int, canvases: Int, bodyCharacters: Int) {
        var parts: [String] = []
        var scriptCharacters = 0, scripts = 0, canvases = 0, bodyCharacters = 0
        var inHead = false
        let chars = Array(html)
        var i = 0
        let n = chars.count
        // 2026-09-23: nav/footer/svg are page chrome; they buried the body.
        // Not header: <article><header> holds the title, and this skipper has no ancestry.
        let skipTags: Set<String> = ["script", "style", "noscript", "nav", "footer", "svg"]

        func appendData(_ raw: String) {
            // Python's `convert_charrefs=True` means entities are decoded
            // BEFORE handle_data; then `" ".join(data.split())` collapses ALL
            // unicode whitespace runs to single spaces and strips ends.
            let decoded = Self.decodeHTMLEntities(raw)
            let collapsed = decoded
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            if !collapsed.isEmpty {
                parts.append(collapsed)
                if !inHead { bodyCharacters += collapsed.count }
            }
        }

        // Parse the tag name out of a `<...>` whose inner text is `inner`
        // (already stripped of the angle brackets). Returns (name, isEnd).
        func tagInfo(_ inner: String) -> (name: String, isEnd: Bool) {
            let isEnd = inner.hasPrefix("/")
            let body = isEnd ? String(inner.dropFirst()) : inner
            let name = body.prefix { $0.isLetter || $0.isNumber }.lowercased()
            return (name, isEnd)
        }

        func tagEnd(from start: Int) -> Int? {
            var quote: Character?
            for index in start..<n {
                let char = chars[index]
                if let current = quote {
                    if char == current { quote = nil }
                } else if char == "\"" || char == "'" {
                    quote = char
                } else if char == ">" {
                    return index
                }
            }
            return nil
        }

        var dataBuf = ""
        while i < n {
            if chars[i] == "<" {
                // Flush the pending text run before processing the tag.
                if !dataBuf.isEmpty { appendData(dataBuf); dataBuf = "" }
                // Comments have no attribute quotes; skip them before tag scanning.
                if chars[i...].starts(with: ["<", "!", "-", "-"]) {
                    var end = i + 4
                    while end + 2 < n {
                        if chars[end] == "-", chars[end + 1] == "-", chars[end + 2] == ">" {
                            break
                        }
                        end += 1
                    }
                    i = end + 2 < n ? end + 3 : n
                    continue
                }
                guard let close = tagEnd(from: i + 1) else {
                    // Unterminated tag: treat the rest as data (Python is lenient).
                    dataBuf.append(contentsOf: chars[i...])
                    break
                }
                let inner = String(chars[(i + 1)..<close])
                let info = tagInfo(inner)
                if info.name == "head" { inHead = !info.isEnd }
                if info.name == "body", !info.isEnd { inHead = false }
                if info.name == "script", !info.isEnd { scripts += 1 }
                if info.name == "canvas", !info.isEnd { canvases += 1 }
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
                                if info.name == "script" { scriptCharacters += j - close - 1 }
                                // Advance past the closing tag's `>` (Python is
                                // lenient about attrs/whitespace before `>`).
                                if let gt = tagEnd(from: j + needle.count) {
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
                        if info.name == "script" { scriptCharacters += n - close - 1 }
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
        return (parts.joined(separator: "\n"), scriptCharacters, scripts, canvases, bodyCharacters)
    }

    /// Decode the HTML char-refs Python's HTMLParser resolves with
    /// `convert_charrefs=True`. Covers the named refs that show up in real
    /// page text plus numeric (`&#NN;` / `&#xNN;`) refs. Unknown refs are
    /// left verbatim.
    static func decodeHTMLEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        // The shipped Swift extractor decodes common named HTML5 references,
        // not the full HTML5 table. Unknown named references remain verbatim.
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
