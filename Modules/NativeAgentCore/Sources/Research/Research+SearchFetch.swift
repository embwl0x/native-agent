import Foundation
import NativeAgentCore
import PersistenceCore
import MacControl
// Blueprint: | `Research+SearchFetch.swift` | SwiftNativeResearchClient: checkedSearxngBaseURL owns search configuration; search/fetch preserve transport causes; fetchURL retains explained source receipts with reader locators and block-shaped HTML; ResearchFetchRecord.readJSON selects find passages or returns the whole retained extraction through output paging |

extension ResearchFetchRecord {
    /// Select from the same extraction that was retained, never a second fetch.
    /// HTML paragraphs, list items and table rows are already newline-delimited.
    public func readJSON(find: String? = nil, around: Int = 1, full: Bool = false) throws -> JSONValue {
        guard (0...3).contains(around), find == nil || find?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ResearchClientError.malformedResponse("find needs words and around must be from 0 through 3")
        }
        guard case .object(var fields) = toJSON() else { return toJSON() }
        if full {
            fields["selection"] = .object(["mode": .string("full"), "whole_text_returned": .bool(true)])
            return .object(fields)
        }
        try Task.checkCancellation()
        var selection: [String: JSONValue]
        let selected: String
        if let find {
            let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            let terms = find.split(whereSeparator: \.isWhitespace).map(String.init)
            var matches: [Int] = []
            for index in paragraphs.indices {
                try Task.checkCancellation()
                if terms.allSatisfy({ paragraphs[index].range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) {
                    matches.append(index)
                }
            }
            // Keep complete matching paragraphs and their neighbours. Additional
            // matches remain in the retained source, named by source_receipt.
            let shown = matches.prefix(8)
            var ranges: [ClosedRange<Int>] = []
            for index in shown {
                let range = max(0, index - around)...min(paragraphs.count - 1, index + around)
                if let last = ranges.last, range.lowerBound <= last.upperBound + 1 {
                    ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
                } else { ranges.append(range) }
            }
            selected = ranges.map { paragraphs[$0].joined(separator: "\n") }.joined(separator: "\n[…]\n")
            selection = ["mode": .string("passages"), "find": .string(find), "around": .int(Int64(around)),
                "matching_paragraphs": .int(Int64(matches.count)), "returned_match_paragraphs": .int(Int64(shown.count)),
                "has_more_matches": .bool(matches.count > shown.count),
                "paragraph_ranges": .array(ranges.map { .object(["start": .int(Int64($0.lowerBound + 1)), "end": .int(Int64($0.upperBound + 1))]) }),
                "note": .string(matches.isEmpty
                    ? "No paragraph in the retained extraction contained every find word. This does not establish absence from bytes or rendered content not read."
                    : "Case-insensitive matches containing every find word, in source order, with surrounding paragraphs. At most eight matching paragraphs are selected; read source_receipt for the retained source.")]
        } else {
            // A plain read is the whole extraction; the tool-output pager
            // bounds a large one. find selects passages instead.
            selected = text
            selection = ["mode": .string("whole"),
                "note": .string("The whole extracted text. find selects the matching paragraphs and their surroundings instead. source_receipt names the retained source without another fetch.")]
        }
        fields["text"] = .string(selected)
        selection["whole_text_returned"] = .bool(selected == text)
        selection["returned_characters"] = .int(Int64(selected.count))
        fields["selection"] = .object(selection)
        return .object(fields)
    }
}

extension SwiftNativeResearchClient {
    /// The one reader of `research/config.json`'s search URL: nil when the file or key is absent,
    /// the trimmed URL when present, and a fault naming the file when it is unreadable or malformed.
    public nonisolated static func checkedSearxngBaseURL(root: URL) throws -> String? {
        let path = root.appendingPathComponent("research", isDirectory: true)
            .appendingPathComponent("config.json")
        do {
            let data = try Data(contentsOf: path)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["searxng_base_url"] == nil || object["searxng_base_url"] is String else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            return (object["searxng_base_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            throw ToolFailureError("Search configuration is unreadable or malformed", effects: .none, owner: path.path)
        }
    }

    static func localServerIsDown(_ error: Error, url: URL) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host ?? "")
            && (error as? URLError)?.code == .cannotConnectToHost
    }
    // MARK: search

    public func search(query: String, categories: String? = nil, timeRange: String? = nil) async throws -> ResearchSearchResponse {
        var base = trimTrailingSlash(try Self.checkedSearxngBaseURL(root: receiptsDir.deletingLastPathComponent()) ?? "")
        // Nothing saved yet: find the local instance the way the Research page
        // does (it saves what answers), so search works without a setup step.
        if base.isEmpty {
            let found = try await autodetectSearXNG()
            if found.found {
                guard let url = found.baseURL, !trimTrailingSlash(url).isEmpty else {
                    throw ResearchClientError.malformedResponse("SearXNG discovery reported an instance without its URL")
                }
                base = trimTrailingSlash(url)
            }
        }
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
            throw ResearchClientError.transportFailure(error, url: url)
        }
        if !(200...299).contains(response.status) {
            throw ResearchClientError.malformedResponse("SearXNG returned HTTP \(response.status)")
        }
        guard !response.truncated else {
            throw ResearchClientError.malformedResponse("SearXNG response exceeds 1,000,000 bytes")
        }
        return try ResearchSearchResponse(data: response.body)
    }

    // MARK: fetch

    public func fetchURL(_ url: String) async throws -> ResearchFetchRecord {
        try Task.checkCancellation()
        // Only http/https URLs are allowed.
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ResearchClientError.malformedResponse("Only http/https URLs are allowed")
        }
        func get(_ target: URL) async throws -> ResearchHTTPResponse {
            let response: ResearchHTTPResponse
            do {
                response = try await http.getBounded(url: target, timeout: 30, maxBytes: 1_000_000,
                                                     pdfMaxBytes: MacDocumentRead.maxFileBytes)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw ResearchClientError.transportFailure(error, url: target)
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
        var response = try await get(parsed)
        var finalURL = response.finalURL
        // A <meta http-equiv=refresh> page ("Redirecting…") is a redirect a
        // browser follows; follow one hop, as an HTTP redirect is followed.
        if mimeOf(response).contains("html"),
           let next = try Self.metaRefreshTarget(String(decoding: response.body, as: UTF8.self), base: finalURL ?? parsed),
           next.absoluteString != (finalURL ?? parsed).absoluteString {
            response = try await get(next)
            finalURL = response.finalURL ?? next
        }
        // A PDF is read by the app's PDF reader, under its own size bound.
        let looksLikePDF = mimeOf(response) == "application/pdf" || response.body.starts(with: Data("%PDF-".utf8))
        let byteLimit = looksLikePDF ? MacDocumentRead.maxFileBytes : 1_000_000
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
        var htmlEvidence: ResearchHTMLExtraction.Evidence?
        var pdfPages: Int?
        var textTruncated = false
        var extracted = false
        let status: String
        let text: String
        if looksLikePDF, response.truncated {
            status = MacDocumentRead.ExtractionFailure.fileTooLarge.rawValue; text = ""
        } else if looksLikePDF {
            switch MacDocumentRead.extract(data: response.body, kind: .pdf) {
            case .success(let document):
                extracted = true
                status = "pdf_text"; text = document.text
                pdfPages = document.pages; textTruncated = document.truncated
            case .failure(let failure):
                status = failure.rawValue; text = ""
            }
        } else if !supported {
            status = "unsupported_content_type"; text = ""
        } else if let decoded = decoding.text {
            extracted = true
            if html {
                let evidence = try ResearchHTMLExtraction.extract(decoded, base: finalURL ?? parsed, decode: Self.decodeHTMLEntities)
                htmlEvidence = evidence
                text = evidence.text
            } else { text = decoded }
            status = text.isEmpty ? "empty_text" : (html ? "html_text" : "plain_text")
        } else {
            status = "unsupported_text_encoding"; text = ""
        }
        try Task.checkCancellation()
        // A short document alone is valid; a script-heavy shell or an explicit
        // JavaScript gate needs a rendered read before claiming page coverage.
        let thinPage = extracted && (response.status == 203
            || (htmlEvidence.map { evidence in
                evidence.bodyCharacters == 0
                    || (evidence.bodyCharacters < 400 && evidence.scripts > 0)
                    || ["enable javascript", "javascript is required", "javascript must be enabled", "turn on javascript"]
                        .contains { text.localizedCaseInsensitiveContains($0) }
            } ?? false))
        let complete = !response.truncated && extracted && !thinPage && !textTruncated
        let hint: JSONValue = thinPage ? .string("The fetched text is thin or requires JavaScript; it does not establish the rendered page's content. Follow next_call to open and read it in your Chrome tab.") : .null
        var verdict: [String: JSONValue] = ["status": .string(extracted ? (complete ? "completed" : (text.isEmpty ? "failed" : "partial")) : "failed")]
        if !extracted { verdict["reason"] = .string(status) }
        else if thinPage { verdict["reason"] = .string("thin_page"); verdict["hint"] = hint }
        else if !complete && text.isEmpty { verdict["reason"] = .string("incomplete_empty_extraction") }
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
            "hint": hint,
            "text_truncated": .bool(textTruncated),
            "complete": .bool(complete),
            "note": .string(extracted
                ? "Text covers the retained response body, without a DOM node cutoff. HTML keeps paragraphs, list items, table rows and inline link targets; scripts and page chrome are omitted. Tool-output paging may expose sections: follow next_call (result.page with next_page), or sense_more when a sense serves the page, to read on. Body truncation means the source was not fully read; a continuation cannot recover bytes beyond the response bound."
                : "No readable text was extracted. Discover an appropriate reader for this content type or encoding; this is not an empty-page finding."),
        ])
        let sourceID = UUID().uuidString.lowercased()
        // The locator names the receipt this call actually writes. It is not
        // an access grant, a permanent archive, or a promise of future presence.
        let receiptPath = receiptsDir.appendingPathComponent("source-\(sourceID).json")
        let sourceReceipt: JSONValue = .object([
            "path": .string(receiptPath.path),
            "purpose": .string("Source receipt: this read kept the extracted text and coverage here so you can inspect or cite what was actually read without fetching again."),
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
            id: sourceID, url: url, text: text, createdAt: Self.isoTimestamp(Date()), verdict: verdict, coverage: coverage,
            sourceReceipt: sourceReceipt
        )
        try Task.checkCancellation()
        try await SwiftNativePersistenceCore.writeJSON(record.toJSON(), to: receiptPath)
        pruneReceiptsIfNeeded()
        return record
    }


    /// The target of a `<meta http-equiv="refresh" content="N; url=…">` in the
    /// document head, resolved against the page's URL; nil when the head has
    /// none or it is not http(s). Comments, scripts and styles are not markup,
    /// so they are stripped first; a no-JS reader honours one inside noscript.
    static func metaRefreshTarget(_ document: String, base: URL) throws -> URL? {
        try Task.checkCancellation()
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
        guard !raw.isEmpty, let target = URL(string: try decodeHTMLEntities(raw), relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(target.scheme?.lowercased() ?? "") else { return nil }
        return target
    }


    /// Decode common named and numeric HTML references; leave unknown references verbatim.
    /// Entity lookup spans at most 32 characters; decoding checks cancellation.
    static func decodeHTMLEntities(_ s: String) throws -> String {
        try Task.checkCancellation()
        guard s.contains("&") else { return s }
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
        var nextCancellationCheck = 0
        while i < n {
            if i >= nextCancellationCheck {
                try Task.checkCancellation()
                nextCancellationCheck = i + min(1_024, n - i)
            }
            if chars[i] == "&" {
                let end = i + min(33, n - i)
                if let semi = chars[i..<end].firstIndex(of: ";") {
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

}
