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
                guard fstat(fd, &metadata) == 0 else { throw VerifiedPath.Failure.posix(errno) }
            } else {
                let parent = try VerifiedPath.openParent(of: resolved)
                defer { parent.release() }
                guard fstatat(parent.fd, parent.name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw VerifiedPath.Failure.posix(errno) }
            }
            let type = metadata.st_mode & mode_t(S_IFMT)
            let modified = Date(timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec) + Double(metadata.st_mtimespec.tv_nsec) / 1e9)
            return .object(["name": .string(resolved.lastPathComponent), "directory": .bool(type == mode_t(S_IFDIR)),
                "regular": .bool(type == mode_t(S_IFREG)), "size": .int(metadata.st_size),
                "modified": .string(ISO8601DateFormatter().string(from: modified))])
        } catch let failure as VerifiedPath.Failure { return errResult(failure.message, code: failure.code) }
        catch { return errResult(error.localizedDescription, code: "read_failed") }
    }
    static func listDir(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        let started = ContinuousClock.now
        let rawPath = input["path"]?.stringValue ?? ""
        if rawPath.isEmpty { return errResult("path is required", code: "bad_input") }
        let rawMe = input["max_entries"]
        guard var maxEntries = safeInt(rawMe, default: connectorListDirMaxEntries) else {
            return errResult("max_entries must be an integer, got \(jsonRepr(rawMe))", code: "bad_input")
        }
        maxEntries = min(maxEntries, connectorListDirMaxEntries)
        // Every page must advance, even when a caller supplies zero.
        maxEntries = max(1, maxEntries)
        if case .double(let value)? = input["offset"], Int(exactly: value) == nil {
            return errResult("offset must be a nonnegative whole entry count", code: "bad_input")
        }
        for field in ["name_contains", "snapshot", "sort"] {
            switch input[field] {
            case nil, .null?, .string?: break
            default: return errResult("\(field) must be a string", code: "bad_input")
            }
        }
        guard let offset = safeInt(input["offset"], default: 0), offset >= 0 else {
            return errResult("offset must be a nonnegative integer", code: "bad_input")
        }
        let nameContains = input["name_contains"]?.stringValue ?? ""
        let sort = (input["sort"]?.stringValue ?? "").isEmpty ? "name" : (input["sort"]?.stringValue ?? "")
        guard ["name", "newest", "added", "size"].contains(sort) else { return errResult("sort must be name, newest, added or size", code: "bad_input") }
        guard let budget = safeInt(input["time_budget_seconds"], default: 5), (1...20).contains(budget) else {
            return errResult("time_budget_seconds must be an integer from 1 to 20", code: "bad_input")
        }
        let deadline = started.advanced(by: .seconds(budget))
        if sort == "size" && offset > 0 { return errResult("Narrow path for another size scan; size rankings cannot be paged across changing scans", code: "bad_input") }
        let caseSensitive: Bool
        switch input["case_sensitive"] {
        case .bool(let value)?: caseSensitive = value
        case nil, .null?: caseSensitive = false
        default: return errResult("case_sensitive must be a boolean", code: "bad_input")
        }
        let expectedSnapshot = input["snapshot"]?.stringValue ?? ""
        if offset > 0 && expectedSnapshot.isEmpty {
            return errResult("Use the previous page's next arguments, including snapshot, to continue safely.", code: "bad_input")
        }
        let resolved = resolvePath(rawPath, repoRoot: ctx.repoRoot, workspaceRoot: ctx.workspaceRoot)
        let allowed = allowedRoots(ctx)
        if !allowed.isEmpty && !isWithinRoots(resolved, allowed) {
            return errResult(
                "Path '\(resolved.path)' is outside sandbox roots: \(rootsRepr(allowed))",
                code: "path_not_allowed"
            )
        }
        if isSensitiveDataPath(resolved, ctx) {
            return errResult(
                "Path '\(resolved.path)' is under a sensitive data sub-tree (OAuth tokens, "
                + "pairing secrets, provider credentials, trust policy). "
                + "Use dedicated Swift runtime tools instead.",
                code: "path_not_allowed"
            )
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: resolved.path, isDirectory: &isDir)
        if !exists { return errResult("Directory not found: \(resolved.path)", code: "file_not_found", path: resolved, pathKind: "missing") }
        if !isDir.boolValue { return errResult("Not a directory: \(resolved.path)", code: "wrong_path_kind", path: resolved, pathKind: "file") }
        // Parent dirent types avoid entering dormant child mounts. Unknown and
        // symlink types display as files; listing must not follow them.
        struct Entry {
            let name: String; let isFile: Bool; var modified: Date? = nil; var added: Date? = nil
            var bytes: Int64 = 0; var complete = false
            /// The file's logical length when the listing stat read it; nil for folders and size scans.
            var length: Int64? = nil
        }
        var entries: [Entry] = []
        var namesComplete = true
        #if canImport(Darwin)
        // Authorize, then list THAT directory: the walk re-opens each component
        // O_DIRECTORY|O_NOFOLLOW from the root and the listing runs on the
        // resulting descriptor via fdopendir, so a symlink swapped in after the
        // sandbox check is refused rather than enumerated.
        let directoryFD: Int32
        do { directoryFD = try VerifiedPath.open(resolved, flags: O_RDONLY | O_DIRECTORY) }
        catch let failure as VerifiedPath.Failure { return errResult(failure.message, code: failure.code) }
        catch { return errResult("could not open directory") }
        guard let directory = fdopendir(directoryFD) else {
            let code = errno
            close(directoryFD)
            return errResult(String(cString: strerror(code)))
        }
        defer { closedir(directory) }
        var beforeStat = stat()
        guard fstat(dirfd(directory), &beforeStat) == 0 else {
            return errResult(String(cString: strerror(errno)))
        }
        errno = 0
        while let pointer = readdir(directory) {
            if sort == "size" && ContinuousClock.now >= deadline { namesComplete = false; errno = 0; break }
            var bytes = pointer.pointee.d_name
            let name = withUnsafePointer(to: &bytes) { tuplePointer in
                tuplePointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            var entry = Entry(name: name, isFile: pointer.pointee.d_type != UInt8(DT_DIR))
            // Date sorts include directories such as app bundles; metadata only,
            // without following links. The packed buffer starts after its length.
            if sort != "size", pointer.pointee.d_type == UInt8(DT_REG)
                || (["newest", "added"].contains(sort) && pointer.pointee.d_type == UInt8(DT_DIR)) {
                var attrs = attrlist()
                attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
                attrs.commonattr = UInt32(ATTR_CMN_MODTIME | ATTR_CMN_ADDEDTIME)
                // A file's logical length rides on the same metadata call.
                let isRegular = pointer.pointee.d_type == UInt8(DT_REG)
                if isRegular { attrs.fileattr = UInt32(ATTR_FILE_DATALENGTH) }
                var bytes = [UInt8](repeating: 0, count: 4 + 2 * MemoryLayout<timespec>.size + MemoryLayout<off_t>.size)
                let status = bytes.withUnsafeMutableBytes {
                    getattrlistat(dirfd(directory), name, &attrs, $0.baseAddress, $0.count, UInt(FSOPT_NOFOLLOW))
                }
                if status == 0 {
                    bytes.withUnsafeBytes {
                        let modified = $0.loadUnaligned(fromByteOffset: 4, as: timespec.self)
                        let added = $0.loadUnaligned(fromByteOffset: 4 + MemoryLayout<timespec>.size, as: timespec.self)
                        entry.modified = Date(timeIntervalSince1970: Double(modified.tv_sec) + Double(modified.tv_nsec) / 1e9)
                        if added.tv_sec > 0 { entry.added = Date(timeIntervalSince1970: Double(added.tv_sec) + Double(added.tv_nsec) / 1e9) }
                        if isRegular {
                            entry.length = Int64($0.loadUnaligned(fromByteOffset: 4 + 2 * MemoryLayout<timespec>.size, as: off_t.self))
                        }
                    }
                }
            }
            entries.append(entry)
            errno = 0
        }
        if errno != 0 {
            return errResult(String(cString: strerror(errno)))
        }
        var afterStat = stat()
        guard fstat(dirfd(directory), &afterStat) == 0 else {
            return errResult(String(cString: strerror(errno)))
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
                let size = allocatedSize(parent: dirfd(directory), name: entries[index].name,
                    path: resolved.appendingPathComponent(entries[index].name), device: beforeStat.st_dev,
                    deadline: deadline, context: ctx, seen: &seen)
                entries[index].bytes = size.bytes
                entries[index].complete = size.complete
            }
        }
        #else
        if sort == "size" || sort == "added" { return errResult("Allocated disk usage and added-date ordering require macOS", code: "unavailable") }
        do {
            entries = try fm.contentsOfDirectory(atPath: resolved.path)
                .map { Entry(name: $0, isFile: true) }
        } catch {
            return errResult(error.localizedDescription)
        }
        #endif
        entries.sort { lhs, rhs in
            if sort == "size", lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            if sort == "newest" || sort == "added" {
                // newest keeps "arrived most recently" (added, else modified); added is added only.
                let left = (sort == "added" ? lhs.added : lhs.added ?? lhs.modified) ?? .distantPast
                let right = (sort == "added" ? rhs.added : rhs.added ?? rhs.modified) ?? .distantPast
                if left != right { return left > right }
            }
            if lhs.isFile != rhs.isFile { return !lhs.isFile && rhs.isFile }
            return lhs.name < rhs.name
        }
        // A stateless token binds continuation to this path, filter, ordering,
        // and observed names/types. It says nothing about child file contents.
        let fingerprintFields = [resolved.path, nameContains, caseSensitive ? "sensitive" : "insensitive", sort]
            + entries.flatMap { [$0.name, $0.isFile ? "other" : "directory", String($0.modified?.timeIntervalSince1970 ?? 0), String($0.added?.timeIntervalSince1970 ?? 0)] }
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
                "size_bytes": $0.length.map { .int($0) } ?? (sort == "size" && $0.isFile ? .int($0.bytes) : .null),
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
            "coverage": .string("Immediate children only; dates are read without following links. Date sorts include directory metadata. Link or unavailable dates are null and sort last. newest sorts by added_at, then modified_at when added_at is unknown; added sorts by added_at only. No recursion or file-content search."),
        ]
        if sort == "size" {
            result["allocated_bytes"] = .int(entries.reduce(Int64(0)) { $0 + $1.bytes } + Int64(beforeStat.st_blocks) * 512)
            var afterScan = stat()
            let unchanged = fstat(dirfd(directory), &afterScan) == 0
                && beforeStat.st_mtimespec.tv_sec == afterScan.st_mtimespec.tv_sec
                && beforeStat.st_mtimespec.tv_nsec == afterScan.st_mtimespec.tv_nsec
            result["size_complete"] = .bool(namesComplete && unchanged && entries.allSatisfy(\.complete))
            result["listing_complete"] = .bool(namesComplete)
            result["partial_paths"] = .array(entries.filter { !$0.complete }.map { .string(resolved.appendingPathComponent($0.name).path) }
                + (namesComplete && unchanged ? [] : [.string(resolved.path)]))
            result["coverage"] = .string("Allocated bytes observed during this scan, including hidden entries; hard links count once. Incomplete sizes are lower bounds, never totals. Partial paths include budget exhaustion, unreadable/protected descendants, changed entries or other volumes. Links and other volumes are not traversed. Metadata I/O must return before the budget can be checked; rankings cover observed bytes only. Narrow path to examine a partial folder.")
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
    #if canImport(Darwin)
    static func allocatedSize(parent: Int32, name: String, path: URL, device: dev_t,
                              deadline: ContinuousClock.Instant, context: ConnectorActionContext,
                              seen: inout Set<UInt64>) -> (bytes: Int64, complete: Bool) {
        guard ContinuousClock.now < deadline, !isSensitiveDataPath(path, context) else { return (0, false) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_dev == device else { return (0, false) }
        let directory = (info.st_mode & S_IFMT) == S_IFDIR
        if !directory && info.st_nlink > 1 && !seen.insert(UInt64(info.st_ino)).inserted { return (0, true) }
        var bytes = Int64(info.st_blocks) * 512
        guard directory else { return (bytes, true) }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return (bytes, false) }
        guard let stream = fdopendir(fd) else { close(fd); return (bytes, false) }
        defer { closedir(stream) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else { return (bytes, false) }
        var complete = true
        while ContinuousClock.now < deadline {
            errno = 0
            guard let pointer = readdir(stream) else {
                var after = stat()
                return (bytes, complete && errno == 0 && fstat(fd, &after) == 0
                    && opened.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
                    && opened.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
            }
            var raw = pointer.pointee.d_name
            let child = withUnsafePointer(to: &raw) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard child != ".", child != ".." else { continue }
            let size = allocatedSize(parent: fd, name: child, path: path.appendingPathComponent(child),
                device: device, deadline: deadline, context: context, seen: &seen)
            bytes += size.bytes
            complete = complete && size.complete
        }
        return (bytes, false)
    }
    #endif
}
