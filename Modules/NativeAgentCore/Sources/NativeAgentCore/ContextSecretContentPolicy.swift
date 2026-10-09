import Foundation

/// One fail-closed secret-shape policy for material entering derived context.
public enum ContextSecretContentPolicy {
    public static func containsSecretLikeContent(_ source: String) -> Bool {
        secretPatterns.contains { pattern in
            source.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Inspect decoded source fragments before prefixing, flattening, clipping
    /// or encoding them. Safe fragments retain their original spelling.
    /// One top-level redaction shares a memo: nested links re-enter this
    /// policy for every component, and without it nested encoded URLs (a
    /// query value carrying a URL carrying a URL) repeat work exponentially.
    /// The policy is pure, so cached results are identical results.
    private final class Memo: @unchecked Sendable {
        // Byte-exact keys: String equality merges canonically equivalent
        // spellings that the secret patterns can still tell apart.
        var fragments: [Data: String] = [:], urls: [Data: String] = [:], texts: [Data: String] = [:]
    }
    @TaskLocal private static var memo: Memo?

    private static func cached(_ table: ReferenceWritableKeyPath<Memo, [Data: String]>, _ source: String,
                               _ compute: (String) -> String) -> String {
        guard let memo else { return $memo.withValue(Memo()) { cached(table, source, compute) } }
        let key = Data(source.utf8)
        if let hit = memo[keyPath: table][key] { return hit }
        let result = compute(source)
        memo[keyPath: table][key] = result
        return result
    }

    public static func redactedFragment(_ source: String) -> String {
        cached(\.fragments, source, uncachedFragment)
    }

    private static func uncachedFragment(_ source: String) -> String {
        // Keep whole-field assignment boundaries, and parse existing links
        // before decoding so escaped delimiters retain their component owner.
        let canonical = redactedText(source)
        let safe = redactedText(redactedLinks(canonical))
        guard let decoded = decodedFragment(safe) else { return "[redacted]" }
        guard decoded != safe else { return safe }
        // Decoding may expose a new authority or an assignment across component
        // boundaries. Inspect that complete decoded field once, not once for
        // every encoding layer or every escape in a large document.
        let inspected = redactedText(redactedLinks(redactedText(decoded)))
        return safe != source || inspected != decoded ? inspected : source
    }

    private static func redactedLinks(_ source: String) -> String {
        let text = source as NSString
        let full = NSRange(location: 0, length: text.length)
        // NSDataDetector supplies ordinary links. Also extract URI syntax,
        // including authorities it can classify as email or miss.
        let detected: [NSRange] = links.matches(in: source, range: full).map(\.range)
        let explicit: [NSRange] = authorities.matches(in: source, range: full).map(\.range)
        // Both matcher outputs are already ordered. Merge them once instead
        // of sorting all link fragments or walking from a String's beginning
        // to convert every UTF-16 range.
        var candidates: [NSRange] = [], detectedIndex = 0, explicitIndex = 0
        candidates.reserveCapacity(detected.count + explicit.count)
        while detectedIndex < detected.count || explicitIndex < explicit.count {
            if explicitIndex == explicit.count || (detectedIndex < detected.count &&
                (detected[detectedIndex].location < explicit[explicitIndex].location ||
                 (detected[detectedIndex].location == explicit[explicitIndex].location && detected[detectedIndex].length >= explicit[explicitIndex].length))) {
                candidates.append(detected[detectedIndex]); detectedIndex += 1
            } else {
                candidates.append(explicit[explicitIndex]); explicitIndex += 1
            }
        }
        var result = ""
        result.reserveCapacity(source.utf8.count)
        var start = 0
        for candidate in candidates {
            // Outer links own overlapping candidates; their path, query and
            // fragment re-enter this policy, exposing every nested URL.
            guard candidate.location >= start else { continue }
            result += text.substring(with: NSRange(location: start, length: candidate.location - start))
            result += redactedURL(text.substring(with: candidate))
            start = candidate.location + candidate.length
        }
        return result + text.substring(from: start)
    }

    private static func redactedText(_ source: String) -> String {
        cached(\.texts, source, uncachedText)
    }

    private static func uncachedText(_ source: String) -> String {
        if containsSecretLikeContent(source) { return "[redacted]" }
        let safe = TurnSecretRedactor.redactText(source)
        return safe
    }

    /// Decode every valid escape run, including nested address/URL encoding.
    /// Each pass removes bytes, so completion needs no arbitrary depth cap.
    /// Invalid UTF-8 escapes are withheld; a literal percent sign is ordinary text.
    private static func decodedFragment(_ source: String) -> String? {
        let bytes = Array(source.utf8)
        guard bytes.contains(37) else { return source }
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        // An append-only reduction stack resolves arbitrarily nested %25
        // spellings as their following digits arrive. Each byte is appended
        // once and removed at most once; no full-string replacement or depth
        // scan is needed. Validate original escape runs and final UTF-8 so
        // malformed encoded bytes never enter derived context.
        var output: [UInt8] = []
        var depths: [Int] = []
        output.reserveCapacity(bytes.count)
        depths.reserveCapacity(bytes.count)
        func append(_ byte: UInt8, depth: Int) {
            output.append(byte)
            depths.append(depth)
            while output.count >= 3 {
                let end = output.count
                guard output[end - 3] == 37,
                      let high = hex(output[end - 2]), let low = hex(output[end - 1]) else { break }
                let nextDepth = max(depths[end - 3], depths[end - 2], depths[end - 1]) + 1
                output.removeLast(3)
                depths.removeLast(3)
                output.append(high * 16 + low)
                depths.append(nextDepth)
            }
        }
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37, index + 2 < bytes.count,
               hex(bytes[index + 1]) != nil, hex(bytes[index + 2]) != nil {
                var run: [UInt8] = []
                repeat {
                    run.append(hex(bytes[index + 1])! * 16 + hex(bytes[index + 2])!)
                    index += 3
                } while index + 2 < bytes.count && bytes[index] == 37 &&
                    hex(bytes[index + 1]) != nil && hex(bytes[index + 2]) != nil
                guard String(bytes: run, encoding: .utf8) != nil else { return nil }
                for byte in run { append(byte, depth: 1) }
            } else {
                append(bytes[index], depth: 0)
                index += 1
            }
        }
        guard let decoded = String(bytes: output, encoding: .utf8) else { return nil }
        // A scalar whose bytes appear in different layers was malformed at
        // an intermediate layer, even if deeper decoding eventually repairs
        // it. Once emitted, non-ASCII bytes cannot be changed by %HH reduction.
        var position = 0
        while position < output.count {
            let byte = output[position]
            let width = byte < 128 ? 1 : byte < 224 ? 2 : byte < 240 ? 3 : 4
            if width > 1 {
                guard depths[(position + 1)..<(position + width)].allSatisfy({ $0 == depths[position] }) else { return nil }
            }
            position += width
        }
        return decoded
    }

    /// Parse before decoding so escaped delimiters still belong to their
    /// component. Every component re-enters the same decoding/text policy.
    private static func redactedURL(_ source: String) -> String {
        cached(\.urls, source, uncachedURL)
    }

    private static func uncachedURL(_ source: String) -> String {
        guard decodedFragment(source) != nil else { return "[redacted]" }
        let hasAuthority = authorities.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil
        let parsed = URLComponents(string: source)
        // A plain email is not URL userinfo. Bare user:pass@host is.
        if parsed?.scheme == nil, parsed?.host == nil, source.contains("@"), !hasAuthority { return source }
        let prefix = source.hasPrefix("//") ? ""
            : parsed?.scheme == nil || (hasAuthority && !source.contains("://")) ? "//" : ""
        guard let url = URLComponents(string: prefix + source), let spelling = url.string else { return "[redacted]" }
        // An extracted URL must own a scheme or authority; otherwise its
        // path could be the entire input and component recursion cannot shrink.
        guard url.scheme != nil || url.host != nil else { return "[redacted]" }
        var edits: [(Range<String.Index>, String)] = []
        func replace(_ component: Range<String.Index>?, using redact: (String) -> String) {
            guard let component else { return }
            let original = String(spelling[component])
            let safe = redact(original)
            if safe != original { edits.append((component, safe)) }
        }
        replace(url.rangeOfUser) { _ in "[redacted]" }
        replace(url.rangeOfPassword) { _ in "[redacted]" }
        if let host = url.host {
            guard let decoded = decodedFragment(host), redactedText(decoded) == decoded else { return "[redacted]" }
        }
        replace(url.rangeOfPath, using: redactedFragment)
        replace(url.rangeOfFragment, using: redactedFragment)
        replace(url.rangeOfQuery) { query in
            query.split(separator: "&", omittingEmptySubsequences: false).map { item in
                // Inspect the whole item before splitting: a nested URL's
                // userinfo can itself contain an equals sign.
                let safeItem = redactedFragment(String(item))
                if safeItem != String(item) { return safeItem }
                let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { return safeItem }
                guard let name = decodedFragment(String(pair[0])),
                      let value = decodedFragment(String(pair[1])) else { return "[redacted]" }
                // The assignment is essential: isCredentialName deliberately
                // differs from the authority's proven key= text pattern.
                let assignment = name + "=" + value
                let canonical = redactedText(assignment)
                if canonical != assignment { return canonical }
                let safeName = redactedFragment(String(pair[0]))
                let safeValue = TurnSecretRedactor.isCredentialName(name) ? "[redacted]" : redactedFragment(String(pair[1]))
                return safeName + "=" + safeValue
            }.joined(separator: "&")
        }
        guard !edits.isEmpty else { return source }
        var safe = spelling
        for (range, value) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            safe.replaceSubrange(range, with: value)
        }
        // Do not serialize redacted components through URL setters: return
        // decoded text, including redaction markers, never encoded secrets.
        return decodedFragment(String(safe.dropFirst(prefix.count))) ?? "[redacted]"
    }

    private static let authorities: NSRegularExpression = {
        // URI grammar, not a credential-name/secret detector. URLComponents
        // owns the component interpretation once an authority is extracted.
        let pattern = #"(?:[A-Za-z][A-Za-z0-9+.-]*://|//)[^\s/?#<>\"'][^\s<>\"']*|[^\s/:?#<>\"']+:[^\s/@?#<>\"']*@[^\s/:?#<>\"']+(?::[0-9]+)?(?:[/?#][^\s<>\"']*)?"#
        do { return try NSRegularExpression(pattern: pattern) }
        catch { preconditionFailure("Context URL authority pattern failed: \(error)") }
    }()

    private static let links: NSDataDetector = {
        do { return try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) }
        catch { preconditionFailure("Context URL detector failed: \(error)") }
    }()

    private static let secretPatterns = [
        #"-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----"#,
        #"\bsk-(?:ant-)?[A-Za-z0-9_-]{20,}\b"#,
        #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#,
        #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#,
        #"\bBearer[ \t]+[A-Za-z0-9._~+/=-]{20,}"#,
        #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#,
        #"(?m)^\s*(?:api[_ -]?key|access[_ -]?token|auth[_ -]?token|password|passwd|client[_ -]?secret)\s*[:=]\s*[\"']?[A-Za-z0-9_./+~=-]{12,}"#,
    ]
}
