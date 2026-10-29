import AuthoredCapabilities
import Foundation
import CryptoKit
import NativeAgentCore
import MacControl
import PersistenceCore
import TrustCenter
#if canImport(Darwin)
import Darwin
import Darwin
#endif
// Blueprint: | `FileReading.swift` | Descriptor-bound file windows, matching and excerpts |
extension FileSystemActions {
    struct FileReadFailure: Error {
        let message: String
        let code: String
    }
    static func openRegularReadHandle(_ path: URL) throws -> FileHandle {
        #if canImport(Darwin)
        // Descriptor-relative walk from the verified root: each parent is
        // opened O_DIRECTORY|O_NOFOLLOW and the final component O_NOFOLLOW, so
        // a symlink swapped in after the sandbox check cannot redirect this
        // read. Everything below reads the DESCRIPTOR, never the path again.
        let descriptor: Int32
        do { descriptor = try VerifiedPath.open(path, flags: O_RDONLY | O_NONBLOCK) }
        catch let failure as VerifiedPath.Failure {
            throw FileReadFailure(message: "Could not open file: \(failure.message)", code: failure.code)
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            close(descriptor)
            throw FileReadFailure(message: "Could not inspect opened file.", code: "read_failed")
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            close(descriptor)
            throw FileReadFailure(message: "File reads support regular files only; pipes, devices and sockets cannot provide file windows.", code: "unsupported_file_type")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        #else
        throw FileReadFailure(message: "Bounded regular-file reads are unavailable on this platform.", code: "unsupported_file_type")
        #endif
    }
    static func readFileWindow(
        handle: FileHandle,
        path: URL,
        maxBytes: Int,
        useCompactDefault: Bool,
        offset: Int,
        expectedVersion: String,
        preserveInvalidUTF8: Bool = false
    ) throws -> (data: Data, totalBytes: Int, version: String, byteLimit: Int) {
        func limit(for totalBytes: Int) -> Int {
            if useCompactDefault && shouldUseCompactReadDefault(path: path, actualBytes: totalBytes) {
                return min(maxBytes, connectorReadFileHandoffDefaultMaxBytes)
            }
            return maxBytes
        }
        #if canImport(Darwin)
        func version(_ metadata: stat) -> String {
            let fields = [path.path, String(metadata.st_dev), String(metadata.st_ino),
                          String(metadata.st_size), String(metadata.st_mtimespec.tv_sec),
                          String(metadata.st_mtimespec.tv_nsec), String(metadata.st_ctimespec.tv_sec),
                          String(metadata.st_ctimespec.tv_nsec)]
            return SHA256.hash(data: Data(fields.joined(separator: "\0").utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
        var metadata = stat()
        if fstat(handle.fileDescriptor, &metadata) == 0,
           metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
           let totalBytes = Int(exactly: metadata.st_size), totalBytes >= 0 {
            let observedVersion = version(metadata)
            if !expectedVersion.isEmpty && expectedVersion != observedVersion {
                throw FileReadFailure(message: "File changed since the previous window. Restart at offset 0 without version.", code: "file_changed")
            }
            guard offset <= totalBytes else {
                throw FileReadFailure(message: "offset exceeds the file size.", code: "bad_input")
            }
            let byteLimit = limit(for: totalBytes)
            if FileReadSourceMaterial.metadataOnly { return (Data(), totalBytes, observedVersion, byteLimit) }
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: byteLimit) ?? Data()
            if !preserveInvalidUTF8 && offset > 0 && (data.isEmpty || data.first.map { $0 & 0xC0 == 0x80 } == true) {
                let prefixCount = min(offset, 3)
                try handle.seek(toOffset: UInt64(offset - prefixCount))
                let nearby = Array(try handle.read(upToCount: prefixCount + 4) ?? Data())
                for start in 0..<min(prefixCount, nearby.count) {
                    let required: Int
                    switch nearby[start] {
                    case 0xC2...0xDF: required = 2
                    case 0xE0...0xEF: required = 3
                    case 0xF0...0xF4: required = 4
                    default: continue
                    }
                    let end = start + required
                    if end > prefixCount, end <= nearby.count,
                       String(data: Data(nearby[start..<end]), encoding: .utf8) != nil {
                        throw FileReadFailure(message: "offset starts inside a UTF-8 character. Use the returned next arguments.", code: "bad_input")
                    }
                }
            }
            var after = stat()
            guard fstat(handle.fileDescriptor, &after) == 0,
                  version(after) == observedVersion else {
                throw FileReadFailure(message: "File changed during the read. Restart at offset 0 without version.", code: "file_changed")
            }
            // Keep complete source scalars together across windows. Invalid
            // source bytes still use replacement decoding; an EOF fragment is
            // malformed source, whereas a window-edge fragment is not.
            var slice = offset + data.count < totalBytes ? completeUTF8Prefix(data) : data
            if preserveInvalidUTF8 { slice = data }
            if byteLimit > 0 && slice.isEmpty && !data.isEmpty {
                throw FileReadFailure(message: "max_bytes cannot hold the next UTF-8 character. Use at least 4 bytes.", code: "window_too_small")
            }
            return (slice, totalBytes, observedVersion, byteLimit)
        }
        #endif
        throw FileReadFailure(message: "Could not establish a regular-file version for this read.", code: "unsupported_file_type")
    }
    private static func completeUTF8Prefix(_ data: Data) -> Data {
        let bytes = Array(data)
        guard !bytes.isEmpty else { return data }
        var start = bytes.count - 1
        while start > 0 && bytes[start] & 0xC0 == 0x80 && bytes.count - start < 4 { start -= 1 }
        let required: Int
        switch bytes[start] {
        case 0xC2...0xDF: required = 2
        case 0xE0...0xEF: required = 3
        case 0xF0...0xF4: required = 4
        default: return data
        }
        guard bytes.count - start < required,
              bytes[(start + 1)...].allSatisfy({ $0 & 0xC0 == 0x80 }) else { return data }
        return Data(bytes.prefix(start))
    }
    static func readFile(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        let rawPath = input["path"]?.stringValue ?? ""
        if rawPath.isEmpty { return errResult("path is required", code: "bad_input") }
        if case .double(let value)? = input["offset"], Int(exactly: value) == nil {
            return errResult("offset must be a nonnegative whole byte count", code: "bad_input")
        }
        guard let offset = safeInt(input["offset"], default: 0), offset >= 0 else {
            return errResult("offset must be a nonnegative byte count", code: "bad_input")
        }
        switch input["version"] {
        case nil, .null?, .string?: break
        default: return errResult("version must be a string", code: "bad_input")
        }
        let expectedVersion = input["version"]?.stringValue ?? ""
        if offset > 0 && expectedVersion.isEmpty {
            return errResult("Use the previous window's next arguments, including version, to continue safely.", code: "bad_input")
        }
        let rawMb = input["max_bytes"]
        let hasExplicitMaxBytes: Bool = {
            switch rawMb {
            case nil, .some(.null): return false
            default: return true
            }
        }()
        guard var maxBytes = safeInt(rawMb, default: connectorReadFileDefaultMaxBytes) else {
            return errResult("max_bytes must be an integer, got \(jsonRepr(rawMb))", code: "bad_input")
        }
        maxBytes = min(maxBytes, connectorReadFileDefaultMaxBytes)
        // Negative max_bytes produces an empty window.
        maxBytes = max(0, maxBytes)
        if let query = input["query"], query != .null {
            guard case .string(let text) = query else { return errResult("query must be a string", code: "bad_input") }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard offset == 0 else { return errResult("Search continues with start_line and version, not offset.", code: "bad_input") }
                return fileExcerpt(input, ctx)
            }
        }
        let resolved = resolvePath(rawPath, repoRoot: ctx.repoRoot, workspaceRoot: ctx.workspaceRoot)
        let allowed = allowedRoots(ctx)
        if !allowed.isEmpty && !isWithinRoots(resolved, allowed) {
            return errResult(
                "Path '\(resolved.path)' is outside allowed sandbox roots: \(rootsRepr(allowed))",
                code: "path_not_allowed"
            )
        }
        if isSensitiveDataPath(resolved, ctx) {
            return errResult(sensitiveReadRefusal(resolved), code: "path_not_allowed")
        }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir)
        if !exists { return errResult("File not found: \(resolved.path)", code: "file_not_found", path: resolved, pathKind: "missing") }
        if isDir.boolValue {
            if FileReadSourceMaterial.metadataOnly, ["pages", "numbers", "key", "rtfd"].contains(resolved.pathExtension.lowercased()) {
                return .object(["ok": .bool(true), "path": .string(resolved.path), "bytes": .int(0)])
            }
            let pattern = input["match"]?.stringValue ?? ""
            guard !pattern.isEmpty else {
                return errResult("Not a file: \(resolved.path). Pass match (e.g. \"*.png\") to read files in this folder.", code: "bad_input",
                                 folder: resolved.path, path: resolved, pathKind: "directory")
            }
            return readMatching(in: resolved, pattern: pattern, input: input, ctx)
        }
        // Nonblocking open plus fstat precedes image decoding too: a FIFO
        // with an image extension must not block inside the pixel loader.
        let handle: FileHandle
        do { handle = try openRegularReadHandle(resolved) }
        catch let error as FileReadFailure { return errResult(error.message, code: error.code) }
        catch { return errResult("could not open file", code: "read_failed") }
        defer { try? handle.close() }
        // Decode from the bytes THIS verified descriptor produces. Reopening the
        // path to decode would validate one
        // file and render another after a swap.
        // Exact bytes only for an explicitly raw read of a binary file; text
        // files keep their windows and errors unchanged.
        let binary: Bool
        do {
            if FileReadSourceMaterial.metadataOnly { binary = false }
            else { binary = try FileReadSourceMaterial.isBinary(handle: handle) }
        }
        catch { return errResult("could not classify file: \(error.localizedDescription)", code: "read_failed") }
        let explicitlyRaw = input["raw"] == .bool(true) && binary
        if !explicitlyRaw && VerifiedImageRead.isImagePath(resolved) {
            guard offset == 0 && expectedVersion.isEmpty else {
                return errResult("Image reads return pixels, not byte windows. Omit offset and version.", code: "bad_input")
            }
            if !FileReadSourceMaterial.metadataOnly {
                let bytes = ((try? handle.read(upToCount: LocalToolImage.maximumBytes + 1)) ?? nil) ?? Data()
                return VerifiedImageRead.deliver(data: bytes, name: resolved.lastPathComponent)
            }
        }
        // Documents read as text through mac.read; other binary kinds need a sense.
        if !explicitlyRaw, !FileReadSourceMaterial.metadataOnly, binary {
            let document = ["pdf", "pages", "numbers", "key", "rtfd", "docx", "doc", "rtf"]
                .contains(resolved.pathExtension.lowercased())
            var refusal: [String: JSONValue] = ["ok": .bool(false), "error_code": .string("binary_file"),
                "error": .string(document
                    ? "\(resolved.lastPathComponent) is a document, not plain text; nothing was read. Its text comes from mac.read."
                    : "\(resolved.lastPathComponent) is binary, not text; nothing was read. Grow a sense with sense.make to understand this kind through ordinary files.read from then on. Pass raw:true for its bytes as base64.")]
            refusal["next_call"] = .object(["tool": .string("app"), "input": .object([
                "action": .string(document ? "mac.read" : "sense.make"),
                "args": .object(document ? ["path": .string(resolved.path)]
                    : ["place": .string(resolved.path), "show": .string("material")])])])
            return .object(refusal)
        }
        let window: (data: Data, totalBytes: Int, version: String, byteLimit: Int)
        do {
            window = try readFileWindow(
                handle: handle, path: resolved, maxBytes: maxBytes, useCompactDefault: !hasExplicitMaxBytes,
                offset: offset, expectedVersion: expectedVersion, preserveInvalidUTF8: explicitlyRaw
            )
        } catch let error as FileReadFailure {
            return errResult(error.message, code: error.code)
        } catch {
            return errResult("could not read file: \(error.localizedDescription)", code: "read_failed")
        }
        if FileReadSourceMaterial.metadataOnly {
            return .object(["ok": .bool(true), "path": .string(resolved.path), "bytes": .int(Int64(window.totalBytes))])
        }
        let nextOffset = offset + window.data.count
        let hasMore = nextOffset < window.totalBytes
        var result: [String: JSONValue] = [
            "ok": .bool(true),
            "path": .string(resolved.path),
            "bytes": .int(Int64(window.totalBytes)),
            "status": .string("ok"),
            "offset": .int(Int64(offset)),
            "read_mode": .string("bytes"),
            "max_bytes": .int(Int64(window.byteLimit)),
            "returned_bytes": .int(Int64(window.data.count)),
            "truncated": .bool(hasMore),
            "has_more": .bool(hasMore),
            "content": .string(decodeUTF8Replacing(window.data)),
        ]
        if explicitlyRaw {
            result["content"] = .string(window.data.base64EncodedString())
            result["encoding"] = .string("base64")
        }
        // A whole-file read carries the hash a guarded replacement checks
        // (version is the paging cursor, not this).
        if offset == 0, !hasMore {
            result["content_sha256"] = .string(SHA256.hash(data: window.data).map { String(format: "%02x", $0) }.joined())
        }
        result["version"] = .string(window.version)
        if hasMore {
            result["next"] = .object([
                "path": .string(rawPath), "offset": .int(Int64(nextOffset)),
                "max_bytes": .int(Int64(max(4, window.byteLimit))), "version": .string(window.version),
            ])
            if explicitlyRaw, case .object(var next)? = result["next"] {
                next["raw"] = .bool(true)
                result["next"] = .object(next)
            }
        }
        return .object(result)
    }
    /// Exact bytes only for an explicitly raw read of a binary file.
    static func rawBytes(_ input: [String: JSONValue], _ path: String) -> Bool {
        input["raw"] == .bool(true) && FileReadSourceMaterial.isBinary(path: path)
    }
    /// read_file on a folder with a glob: the first eight matching files by
    /// name in one call, each through the ordinary single-file read (same
    /// gates; images as pixels).
    static let folderReadLimit = 8
    private static func readMatching(
        in folder: URL, pattern: String, input: [String: JSONValue], _ ctx: ConnectorActionContext
    ) -> JSONValue {
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            return errResult("Could not list folder: \(error.localizedDescription)", code: "read_failed")
        }
        let names = entries
            .filter { name in
                var isDir: ObjCBool = false
                return (!name.hasPrefix(".") || pattern.hasPrefix("."))
                    && fnmatch(pattern, name, FNM_CASEFOLD) == 0
                    && FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isDir)
                    && !isDir.boolValue
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var single = input
        single["match"] = nil; single["offset"] = nil; single["version"] = nil
        // Images past the round's budget come back as paths, read next.
        var files: [JSONValue] = [], later: [JSONValue] = []
        for name in names.prefix(folderReadLimit) {
            let path = folder.appendingPathComponent(name)
            // Only a pixel read spends the budget; raw and metadata-only reads never wait.
            if VerifiedImageRead.isImagePath(path), !rawBytes(single, path.path), !FileReadSourceMaterial.metadataOnly,
               LocalToolImage.sink?.round.hasRoom == false {
                later.append(.string(path.path)); continue
            }
            single["path"] = .string(path.path)
            files.append(.object(["name": .string(name), "result": readFile(single, ctx)]))
        }
        var result: [String: JSONValue] = [
            "status": .string("ok"), "path": .string(folder.path), "match": .string(pattern),
            "matched": .int(Int64(names.count)), "files": .array(files),
        ]
        if !later.isEmpty {
            result["more_images"] = .array(later)
            result["more_images_note"] = .string("\(later.count) more images; read them next.")
        }
        if names.count > folderReadLimit {
            result["omitted"] = .int(Int64(names.count - folderReadLimit))
            result["note"] = .string("\(names.count - folderReadLimit) more matched; narrow match to read them.")
        }
        return .object(result)
    }
    static func fileExcerpt(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        let rawPath = input["path"]?.stringValue ?? ""
        if rawPath.isEmpty { return errResult("path is required", code: "bad_input") }
        guard let startLineRaw = safeInt(input["start_line"], default: 1),
              let maxLinesRaw = safeInt(input["max_lines"], default: 80) else {
            return errResult("start_line and max_lines must be integers", code: "bad_input")
        }
        let startLine = max(1, startLineRaw)
        let maxLines = max(1, min(maxLinesRaw, 240))
        for key in ["query", "version"] {
            switch input[key] {
            case nil, .null?, .string?: break
            default: return errResult("\(key) must be a string", code: "bad_input")
            }
        }
        let query = input["query"]?.stringValue ?? ""
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let expectedVersion = input["version"]?.stringValue ?? ""
        if !terms.isEmpty && startLine > 1 && expectedVersion.isEmpty {
            return errResult("Continue a search with its returned start_line and version.", code: "bad_input")
        }
        let resolved = resolvePath(rawPath, repoRoot: ctx.repoRoot, workspaceRoot: ctx.workspaceRoot)
        let allowed = allowedRoots(ctx)
        if !allowed.isEmpty && !isWithinRoots(resolved, allowed) {
            return errResult(
                "Path '\(resolved.path)' is outside allowed sandbox roots: \(rootsRepr(allowed))",
                code: "path_not_allowed"
            )
        }
        if isSensitiveDataPath(resolved, ctx) {
            return errResult("Path '\(resolved.path)' is under a sensitive data sub-tree.", code: "path_not_allowed")
        }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir)
        if !exists { return errResult("File not found: \(resolved.path)", code: "file_not_found", path: resolved, pathKind: "missing") }
        if isDir.boolValue { return errResult("Not a file: \(resolved.path)", code: "wrong_path_kind", path: resolved, pathKind: "directory") }
        let window: (total: Int, lines: [(number: Int, text: String)], bytes: Int, version: String, matches: Int, next: Int?)
        do {
            let handle = try openRegularReadHandle(resolved)
            defer { try? handle.close() }
            if FileReadSourceMaterial.metadataOnly {
                let metadata = try readFileWindow(handle: handle, path: resolved, maxBytes: 0,
                    useCompactDefault: false, offset: 0, expectedVersion: expectedVersion)
                return .object(["ok": .bool(true), "path": .string(resolved.path), "bytes": .int(Int64(metadata.totalBytes))])
            }
            window = try readExcerptWindow(handle: handle, path: resolved, startLine: startLine,
                maxLines: maxLines, terms: terms, expectedVersion: expectedVersion)
        } catch let failure as FileReadFailure {
            if failure.code == "file_changed" {
                return errResult("The file changed during this read; a consistent excerpt could not be established. Retry the selection. If it came from a search, repeat that search because line positions may have moved.", code: "file_changed")
            }
            return errResult(failure.message, code: failure.code)
        } catch {
            return errResult("could not read file", code: "read_failed")
        }
        let total = window.total
        let startIdx = min(startLine - 1, total)
        let endIdx = min(total, startIdx + maxLines)
        let nextLine = terms.isEmpty ? (endIdx < total ? endIdx + 1 : nil) : window.next
        var next: [String: JSONValue] = ["path": .string(rawPath), "max_lines": .int(Int64(maxLines)),
            "version": .string(window.version)]
        if let nextLine { next["start_line"] = .int(Int64(nextLine)) }
        if !terms.isEmpty { next["query"] = .string(query) }
        var result: [String: JSONValue] = [
            "ok": .bool(true),
            "path": .string(resolved.path),
            "start_line": .int(Int64(total > 0 ? startIdx + 1 : 1)),
            "read_mode": .string("lines"),
            "status": .string("ok"),
            "end_line": .int(Int64(endIdx)),
            "total_lines": .int(Int64(total)),
            "version": .string(window.version),
            "truncated": .bool(nextLine != nil),
            "has_more": .bool(nextLine != nil),
            "next": nextLine != nil ? .object(next) : .null,
        ]
        if terms.isEmpty {
            result["excerpt"] = .string(window.lines.map { "\($0.number): \($0.text)" }.joined(separator: "\n"))
        } else {
            result["query"] = .string(query)
            result["records"] = .array(window.lines.map { .object(["line": .int(Int64($0.number)), "text": .string($0.text)]) })
            result["start_line"] = window.lines.first.map { .int(Int64($0.number)) } ?? .null
            result["end_line"] = window.lines.last.map { .int(Int64($0.number)) } ?? .null
            result["coverage"] = .object(["searched_bytes": .int(Int64(window.bytes)),
                "searched_lines": .int(Int64(total)), "matching_lines": .int(Int64(window.matches)), "complete": .bool(true)])
        }
        return .object(result)
    }
    /// Count the complete stable source while retaining only the requested
    /// lines. Reuse the byte reader's version checks and UTF-8 boundaries;
    /// newline state persists across chunks, including a split CRLF.
    private static func readExcerptWindow(
        handle: FileHandle, path: URL, startLine: Int, maxLines: Int, terms: [String], expectedVersion: String
    ) throws -> (total: Int, lines: [(number: Int, text: String)], bytes: Int, version: String, matches: Int, next: Int?) {
        var offset = 0
        var version = expectedVersion
        var total = 0
        var current = ""
        var currentBytes = 0
        var currentHasContent = false
        var previousWasCR = false
        var retainedBytes = 0
        var lines: [(number: Int, text: String)] = []
        var matches = 0
        var next: Int?
        func selected() -> Bool { total >= startLine - 1 && total - (startLine - 1) < maxLines }
        func finishLine() throws {
            if terms.isEmpty {
                if selected() { lines.append((total + 1, current)) }
            } else if terms.allSatisfy({ current.localizedCaseInsensitiveContains($0) }) {
                matches += 1
                if total >= startLine - 1 && next == nil {
                    let size = try JSONValue.string(current).serialize(pretty: false).utf8.count + 64
                    if lines.count >= maxLines || retainedBytes + size > 24_000 {
                        guard !lines.isEmpty else {
                            throw FileReadFailure(message: "Matching line \(total + 1) exceeds one search page. Read that record with read_file byte windows.", code: "excerpt_too_large")
                        }
                        next = total + 1
                    } else {
                        lines.append((total + 1, current))
                        retainedBytes += size
                    }
                }
            }
            total += 1
            current = ""
            currentBytes = 0
            currentHasContent = false
        }
        while true {
            let chunk = try readFileWindow(
                handle: handle, path: path, maxBytes: 65_536, useCompactDefault: false,
                offset: offset, expectedVersion: version
            )
            let text: String
            if terms.isEmpty { text = decodeUTF8Replacing(chunk.data) }
            else {
                guard !chunk.data.contains(0), let decoded = String(data: chunk.data, encoding: .utf8) else {
                    throw FileReadFailure(message: "query searches plain text only; omit it to read image or binary material.", code: "binary_file")
                }
                text = decoded
            }
            version = chunk.version
            for scalar in text.unicodeScalars {
                if previousWasCR && scalar.value == 0x0A {
                    previousWasCR = false
                    continue
                }
                previousWasCR = scalar.value == 0x0D
                switch scalar.value {
                case 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029:
                    try finishLine()
                default:
                    currentHasContent = true
                    if !terms.isEmpty || selected() {
                        currentBytes += scalar.utf8.count
                        guard currentBytes <= 1_048_576 else {
                            throw FileReadFailure(message: "Line \(total + 1) exceeds 1 MiB of text. Read that record with read_file byte windows.", code: "excerpt_too_large")
                        }
                        if terms.isEmpty { retainedBytes += scalar.utf8.count }
                        guard retainedBytes <= 1_048_576 else {
                            throw FileReadFailure(
                                message: "Requested excerpt exceeds 1 MiB of text. Narrow max_lines, or use read_file byte windows and its returned next arguments for a very long line.",
                                code: "excerpt_too_large"
                            )
                        }
                        current.unicodeScalars.append(scalar)
                    }
                }
            }
            offset += chunk.data.count
            if offset >= chunk.totalBytes { break }
            guard !chunk.data.isEmpty else {
                throw FileReadFailure(message: "File ended before its measured size; retry the read.", code: "file_changed")
            }
        }
        if currentHasContent { try finishLine() }
        return (total, lines, offset, version, matches, next)
    }
}
