import SenseCore
import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import DeskCore
import Darwin
// Blueprint: | `DirectoryInventory.swift` | File metadata and bounded directory inventory |
extension FileSystemActions {
    static func fileInfo(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        let rawPath = input["path"]?.stringValue ?? ""
        if rawPath.isEmpty { return errResult("path is required", code: "bad_input") }
        let resolved = resolvePath(rawPath, repoRoot: ctx.repoRoot, workspaceRoot: ctx.workspaceRoot, followFinalLink: false)
        let allowed = allowedRoots(ctx)
        if !allowed.isEmpty && !isWithinRoots(resolved, allowed) {
            return errResult("Path '\(resolved.path)' is outside sandbox roots: \(rootsRepr(allowed))", code: "path_not_allowed")
        }
        if isSensitiveDataPath(resolved, ctx) {
            return errResult("Path '\(resolved.path)' is under a sensitive data sub-tree.", code: "path_not_allowed")
        }
        do {
            var metadata = stat()
            if resolved.path == "/" {
                let fd = try VerifiedPath.open(resolved, flags: O_RDONLY | O_DIRECTORY)
                defer { _ = Darwin.close(fd) }
                guard unsafe fstat(fd, &metadata) == 0 else { throw VerifiedPath.Failure.posix(errno) }
            } else {
                let parent = try VerifiedPath.openParent(of: resolved)
                defer { parent.release() }
                guard unsafe fstatat(parent.fd, parent.name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                    let code = errno
                    throw code == ENOENT ? VerifiedPath.Failure.notFound : VerifiedPath.Failure.posix(code)
                }
            }
            let type = metadata.st_mode & mode_t(S_IFMT)
            let modified = Date(timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec) + Double(metadata.st_mtimespec.tv_nsec) / 1e9)
            return .object(["name": .string(resolved.lastPathComponent), "directory": .bool(type == mode_t(S_IFDIR)),
                "regular": .bool(type == mode_t(S_IFREG)), "size": .int(metadata.st_size),
                "modified": .string(ISO8601DateFormatter().string(from: modified))])
        } catch let failure as VerifiedPath.Failure { return errResult(failure.message, code: failure.code, path: resolved) }
        catch { return errResult(error.localizedDescription, code: "read_failed") }
    }
    static func listDir(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        let started = ContinuousClock.now
        let request: DirectoryListingRequest
        switch admitDirectoryListing(input, ctx, started: started) {
        case .admitted(let admitted): request = admitted
        case .refused(let refusal): return refusal
        }
        let resolved = request.resolved
        var entries: [Entry] = []
        var namesComplete = true
        // Reopen each authorized component with O_DIRECTORY|O_NOFOLLOW and list its descriptor to refuse swapped-in symlinks.
        let directoryFD: Int32
        do { directoryFD = try VerifiedPath.open(resolved, flags: O_RDONLY | O_DIRECTORY) }
        catch let failure as VerifiedPath.Failure { return errResult(failure.message, code: failure.code, path: resolved) }
        catch { return errResult("could not open directory") }
        guard let directory = unsafe fdopendir(directoryFD) else {
            let code = errno
            close(directoryFD)
            return errResult(unsafe String(cString: strerror(code)))
        }
        defer { unsafe closedir(directory) }
        var beforeStat = stat()
        if let refusal = unsafe readDirectoryEntries(directory, request: request, ctx: ctx, beforeStat: &beforeStat,
            entries: &entries, namesComplete: &namesComplete) {
            return refusal
        }
        return unsafe directoryListingReceipt(entries: &entries, namesComplete: namesComplete, directory: directory, beforeStat: beforeStat, request: request)
    }

    private struct DirectoryListingRequest {
        let resolved: URL
        let maxEntries: Int
        let offset: Int
        let nameContains: String
        let sort: String
        let budget: Int
        let deadline: ContinuousClock.Instant
        let caseSensitive: Bool
        let expectedSnapshot: String
    }

    private enum DirectoryListingAdmission {
        case admitted(DirectoryListingRequest)
        case refused(JSONValue)
    }

    /// Validate the page arguments and admit the requested directory.
    private static func admitDirectoryListing(_ input: [String: JSONValue], _ ctx: ConnectorActionContext,
        started: ContinuousClock.Instant) -> DirectoryListingAdmission {
        let rawPath = input["path"]?.stringValue ?? ""
        if rawPath.isEmpty { return .refused(errResult("path is required", code: "bad_input")) }
        let rawMe = input["max_entries"]
        guard var maxEntries = safeInt(rawMe, default: connectorListDirMaxEntries) else {
            return .refused(errResult("max_entries must be an integer, got \(jsonRepr(rawMe))", code: "bad_input"))
        }
        maxEntries = min(maxEntries, connectorListDirMaxEntries)
        // Every page must advance, even when a caller supplies zero.
        maxEntries = max(1, maxEntries)
        if case .double(let value)? = input["offset"], Int(exactly: value) == nil {
            return .refused(errResult("offset must be a nonnegative whole entry count", code: "bad_input"))
        }
        for field in ["name_contains", "snapshot", "sort"] {
            switch input[field] {
            case nil, .null?, .string?: break
            default: return .refused(errResult("\(field) must be a string", code: "bad_input"))
            }
        }
        guard let offset = safeInt(input["offset"], default: 0), offset >= 0 else {
            return .refused(errResult("offset must be a nonnegative integer", code: "bad_input"))
        }
        let nameContains = input["name_contains"]?.stringValue ?? ""
        let sort = (input["sort"]?.stringValue ?? "").isEmpty ? "name" : (input["sort"]?.stringValue ?? "")
        guard ["name", "newest", "added", "size"].contains(sort) else { return .refused(errResult("sort must be name, newest, added or size", code: "bad_input")) }
        guard let budget = safeInt(input["time_budget_seconds"], default: 5), (1...20).contains(budget) else {
            return .refused(errResult("time_budget_seconds must be an integer from 1 to 20", code: "bad_input"))
        }
        let deadline = started.advanced(by: .seconds(budget))
        if sort == "size" && offset > 0 { return .refused(errResult(
            "Narrow path for another size scan; size rankings cannot be paged across changing scans", code: "bad_input")) }
        let caseSensitive: Bool
        switch input["case_sensitive"] {
        case .bool(let value)?: caseSensitive = value
        case nil, .null?: caseSensitive = false
        default: return .refused(errResult("case_sensitive must be a boolean", code: "bad_input"))
        }
        let expectedSnapshot = input["snapshot"]?.stringValue ?? ""
        if offset > 0 && expectedSnapshot.isEmpty {
            return .refused(errResult("Use the previous page's next arguments, including snapshot, to continue safely.", code: "bad_input"))
        }
        let resolved = resolvePath(rawPath, repoRoot: ctx.repoRoot, workspaceRoot: ctx.workspaceRoot)
        let allowed = allowedRoots(ctx)
        if !allowed.isEmpty && !isWithinRoots(resolved, allowed) {
            return .refused(errResult(
                "Path '\(resolved.path)' is outside sandbox roots: \(rootsRepr(allowed))",
                code: "path_not_allowed"
            ))
        }
        if isSensitiveDataPath(resolved, ctx) {
            return .refused(errResult(
                "Path '\(resolved.path)' is under a sensitive data sub-tree (OAuth tokens, "
                + "pairing secrets, provider credentials, trust policy). "
                + "Use the app's own actions for this data instead.",
                code: "path_not_allowed"
            ))
        }
        do {
            guard let isDirectory = try readPathIsDirectory(resolved) else {
                return .refused(errResult("Directory not found: \(resolved.path)", code: "file_not_found", path: resolved, pathKind: "missing"))
            }
            if !isDirectory { return .refused(errResult("Not a directory: \(resolved.path)", code: "wrong_path_kind", path: resolved, pathKind: "file")) }
        } catch let failure as FileReadFailure { return .refused(errResult(failure.message, code: failure.code, path: resolved)) }
        catch { return .refused(errResult(error.localizedDescription, code: "read_failed", path: resolved)) }
        return .admitted(DirectoryListingRequest(resolved: resolved, maxEntries: maxEntries, offset: offset,
            nameContains: nameContains, sort: sort, budget: budget, deadline: deadline, caseSensitive: caseSensitive,
            expectedSnapshot: expectedSnapshot))
    }

    // Parent dirent types avoid entering dormant child mounts. Unknown and symlink types display as files; listing must not follow them.
    private struct Entry {
        let name: String; let isFile: Bool; var modified: Date? = nil; var added: Date? = nil
        var bytes: Int64 = 0; var complete = false
        var length: Int64? = nil
    }

    /// Read immediate entries and measure allocated sizes when requested.
    private static func readDirectoryEntries(_ directory: UnsafeMutablePointer<DIR>, request: DirectoryListingRequest, ctx: ConnectorActionContext,
        beforeStat: inout stat, entries: inout [Entry], namesComplete: inout Bool) -> JSONValue? {
        let sort = request.sort, deadline = request.deadline, resolved = request.resolved
        guard unsafe fstat(dirfd(directory), &beforeStat) == 0 else {
            return errResult(unsafe String(cString: strerror(errno)))
        }
        errno = 0
        while let pointer = unsafe readdir(directory) {
            if sort == "size" && ContinuousClock.now >= deadline { namesComplete = false; errno = 0; break }
            var bytes = unsafe pointer.pointee.d_name
            let name = withUnsafePointer(to: &bytes) { tuplePointer in
                unsafe tuplePointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { unsafe String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            var entry = Entry(name: name, isFile: unsafe pointer.pointee.d_type != UInt8(DT_DIR))
            // Include directories in date sorts without following links; the packed buffer begins after its length.
            if sort != "size", unsafe pointer.pointee.d_type == UInt8(DT_REG)
                || (["newest", "added"].contains(sort) && (unsafe pointer.pointee.d_type) == UInt8(DT_DIR)) {
                var attrs = attrlist()
                attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
                attrs.commonattr = UInt32(ATTR_CMN_MODTIME | ATTR_CMN_ADDEDTIME)
                let isRegular = unsafe pointer.pointee.d_type == UInt8(DT_REG)
                if isRegular { attrs.fileattr = UInt32(ATTR_FILE_DATALENGTH) }
                var bytes = [UInt8](repeating: 0, count: 4 + 2 * MemoryLayout<timespec>.size + MemoryLayout<off_t>.size)
                let status = bytes.withUnsafeMutableBytes {
                    unsafe getattrlistat(dirfd(directory), name, &attrs, $0.baseAddress, $0.count, UInt(FSOPT_NOFOLLOW))
                }
                if status == 0 {
                    bytes.withUnsafeBytes {
                        let modified = unsafe $0.loadUnaligned(fromByteOffset: 4, as: timespec.self)
                        let added = unsafe $0.loadUnaligned(fromByteOffset: 4 + MemoryLayout<timespec>.size, as: timespec.self)
                        entry.modified = Date(timeIntervalSince1970: Double(modified.tv_sec) + Double(modified.tv_nsec) / 1e9)
                        if added.tv_sec > 0 { entry.added = Date(timeIntervalSince1970: Double(added.tv_sec) + Double(added.tv_nsec) / 1e9) }
                        if isRegular {
                            entry.length = Int64(unsafe $0.loadUnaligned(fromByteOffset: 4 + 2 * MemoryLayout<timespec>.size, as: off_t.self))
                        }
                    }
                }
            }
            entries.append(entry)
            errno = 0
        }
        if errno != 0 {
            return errResult(unsafe String(cString: strerror(errno)))
        }
        var afterStat = stat()
        guard unsafe fstat(dirfd(directory), &afterStat) == 0 else {
            return errResult(unsafe String(cString: strerror(errno)))
        }
        guard beforeStat.st_mtimespec.tv_sec == afterStat.st_mtimespec.tv_sec,
              beforeStat.st_mtimespec.tv_nsec == afterStat.st_mtimespec.tv_nsec,
              beforeStat.st_ctimespec.tv_sec == afterStat.st_ctimespec.tv_sec,
              beforeStat.st_ctimespec.tv_nsec == afterStat.st_ctimespec.tv_nsec else {
            return errResult("Directory changed while listing. Restart at offset 0.", code: "directory_changed")
        }
        if sort == "size" {
            var seen: Set<UInt64> = []
            for index in entries.indices {
                let size = allocatedSize(parent: unsafe dirfd(directory), name: entries[index].name,
                    path: resolved.appendingPathComponent(entries[index].name), device: beforeStat.st_dev,
                    deadline: deadline, context: ctx, seen: &seen)
                entries[index].bytes = size.bytes
                entries[index].complete = size.complete
            }
        }
        return nil
    }

    /// Order the observed entries, bind continuation and return the selected page.
    private static func directoryListingReceipt(entries: inout [Entry], namesComplete: Bool, directory: UnsafeMutablePointer<DIR>,
        beforeStat: stat, request: DirectoryListingRequest) -> JSONValue {
        let resolved = request.resolved, sort = request.sort, nameContains = request.nameContains, caseSensitive = request.caseSensitive
        let expectedSnapshot = request.expectedSnapshot, offset = request.offset, maxEntries = request.maxEntries, budget = request.budget
        entries.sort { lhs, rhs in
            if sort == "size", lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            if sort == "newest" || sort == "added" {
                // newest tracks arrival via added then modified; added-only ordering must not substitute modified time.
                let left = (sort == "added" ? lhs.added : lhs.added ?? lhs.modified) ?? .distantPast
                let right = (sort == "added" ? rhs.added : rhs.added ?? rhs.modified) ?? .distantPast
                if left != right { return left > right }
            }
            if lhs.isFile != rhs.isFile { return !lhs.isFile && rhs.isFile }
            return lhs.name < rhs.name
        }
        // A stateless token binds continuation to this path, filter, ordering, and observed names/types. It says nothing about child file contents.
        let fingerprintFields = [resolved.path, nameContains, caseSensitive ? "sensitive" : "insensitive", sort]
            + entries.flatMap { [$0.name, $0.isFile ? "other" : "directory", String(
                $0.modified?.timeIntervalSince1970 ?? 0), String($0.added?.timeIntervalSince1970 ?? 0)] }
        let snapshot = SHA256.hash(data: Data(fingerprintFields.joined(separator: "\0").utf8))
            .map { String(format: "%02x", $0) }.joined()
        if !expectedSnapshot.isEmpty && expectedSnapshot != snapshot {
            return errResult("Directory entries or filter changed since the previous page. Restart at offset 0 without snapshot.", code: "directory_changed")
        }
        let matches = entries.filter { entry in
            nameContains.isEmpty || entry.name.range(
                of: nameContains,
                options: caseSensitive ? [.literal] : [.literal, .caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ) != nil
        }
        let start = min(offset, matches.count)
        let page = matches.dropFirst(start).prefix(maxEntries)
        let out = page.map { JSONValue.string($0.isFile ? $0.name : $0.name + "/") }
        let nextOffset = start + out.count
        let hasMore = nextOffset < matches.count || !namesComplete
        let iso = ISO8601DateFormatter()
        var result: [String: JSONValue] = [
            "ok": .bool(true),
            "path": .string(resolved.path),
            "entries": .array(out),
            "items": .array(page.map { .object(["name": .string($0.name), "is_directory": .bool(!$0.isFile),
                "allocated_bytes": sort == "size" ? .int($0.bytes) : .null,
                "size_bytes": $0.length.map { .int($0) } ?? .null,
                "size_complete": sort == "size" ? .bool($0.complete) : .null,
                "modified_at": $0.modified.map { .string(iso.string(from: $0)) } ?? .null,
                "added_at": $0.added.map { .string(iso.string(from: $0)) } ?? .null]) }),
            "sort": .string(sort),
            "status": .string("ok"),
            "count": .int(Int64(out.count)),
            "total_visible": .int(Int64(entries.count)),
            "total_matching": .int(Int64(matches.count)),
            "name_contains": .string(nameContains),
            "case_sensitive": .bool(caseSensitive),
            "offset": .int(Int64(start)),
            "snapshot": .string(snapshot),
            "truncated": .bool(hasMore),
            "has_more": .bool(hasMore),
            "coverage": .string("""
                Immediate children only; dates are read without following links. Date sorts include directory metadata. Link or unavailable \
                dates are null and sort last. newest sorts by added_at, then modified_at when added_at is unknown; added sorts by added_at \
                only. No recursion or file-content search.
                """),
        ]
        if sort == "size" {
            result["allocated_bytes"] = .int(entries.reduce(Int64(0)) { $0 + $1.bytes } + Int64(beforeStat.st_blocks) * 512)
            var afterScan = stat()
            let unchanged = unsafe fstat(dirfd(directory), &afterScan) == 0
                && beforeStat.st_mtimespec.tv_sec == afterScan.st_mtimespec.tv_sec
                && beforeStat.st_mtimespec.tv_nsec == afterScan.st_mtimespec.tv_nsec
            let complete = namesComplete && unchanged && entries.allSatisfy(\.complete)
            result["size_complete"] = .bool(complete)
            if !complete { result["status"] = .string("partial") }
            result["listing_complete"] = .bool(namesComplete)
            result["partial_paths"] = .array(entries.filter { !$0.complete }.map { .string(resolved.appendingPathComponent($0.name).path) }
                + (namesComplete && unchanged ? [] : [.string(resolved.path)]))
            result["coverage"] = .string("""
                Allocated bytes observed during this scan, including hidden entries; hard links count once. Incomplete sizes are lower \
                bounds, never totals. Partial paths include budget exhaustion, unreadable/protected descendants, changed entries or other \
                volumes. Links and other volumes are not traversed. Metadata I/O must return before the budget can be checked; rankings \
                cover observed bytes only. Narrow path to examine a partial folder.
                """)
            result["time_budget_seconds"] = .int(Int64(budget))
        }
        if hasMore && sort != "size" {
            result["next"] = .object([
                "path": .string(resolved.path),
                "name_contains": .string(nameContains),
                "sort": .string(sort),
                "case_sensitive": .bool(caseSensitive),
                "max_entries": .int(Int64(maxEntries)),
                "offset": .int(Int64(nextOffset)),
                "snapshot": .string(snapshot),
            ])
        }
        return .object(result)
    }
    static func allocatedSize(parent: Int32, name: String, path: URL, device: dev_t,
                              deadline: ContinuousClock.Instant, context: ConnectorActionContext,
                              seen: inout Set<UInt64>) -> (bytes: Int64, complete: Bool) {
        guard ContinuousClock.now < deadline, !isSensitiveDataPath(path, context) else { return (0, false) }
        var info = stat()
        guard unsafe fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_dev == device else { return (0, false) }
        let directory = (info.st_mode & S_IFMT) == S_IFDIR
        if !directory && info.st_nlink > 1 && !seen.insert(UInt64(info.st_ino)).inserted { return (0, true) }
        var bytes = Int64(info.st_blocks) * 512
        guard directory else { return (bytes, true) }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return (bytes, false) }
        guard let stream = unsafe fdopendir(fd) else { close(fd); return (bytes, false) }
        defer { unsafe closedir(stream) }
        var opened = stat()
        guard unsafe fstat(fd, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else { return (bytes, false) }
        var complete = true
        while ContinuousClock.now < deadline {
            errno = 0
            guard let pointer = unsafe readdir(stream) else {
                var after = stat()
                return (bytes, complete && errno == 0 && (unsafe fstat(fd, &after)) == 0
                    && opened.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
                    && opened.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
            }
            var raw = unsafe pointer.pointee.d_name
            let child = withUnsafePointer(to: &raw) {
                unsafe $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { unsafe String(cString: $0) }
            }
            guard child != ".", child != ".." else { continue }
            let size = allocatedSize(parent: fd, name: child, path: path.appendingPathComponent(child),
                device: device, deadline: deadline, context: context, seen: &seen)
            bytes += size.bytes
            complete = complete && size.complete
        }
        return (bytes, false)
    }
}
