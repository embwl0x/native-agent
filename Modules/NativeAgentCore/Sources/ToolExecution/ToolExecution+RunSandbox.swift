import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import ToolRegistry
import Senses
import Network
import Security
import MacControl

/// Declared-reach primitives for the shared JavaScript executor.
actor ToolPrimitiveBroker {
    static let knownPermissions: Set<String> = [
        "app_data_read", "app_data_write", "network_localhost", "network_public",
        "network", "shell", "computer_files", "arbitrary_file_write",
    ]
    static let readOperations = Set(AuthoredToolEffects.primitiveCapabilities.compactMap { $0.value.contains("safe_read") ? $0.key : nil })
    static let operations = Set(AuthoredToolEffects.primitiveCapabilities.keys)
    static func appTargets(_ permissions: Set<String>) -> [String: String] {
        var targets: [String: String] = [:]
        for permission in permissions {
            let parts = permission.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, ["app_read", "app_write"].contains(parts[0]) {
                if targets[parts[1]] != "write" { targets[parts[1]] = parts[0] == "app_write" ? "write" : "read" }
            }
        }
        return targets
    }
    static func knownPermission(_ permission: String) -> Bool {
        knownPermissions.contains(permission) || !appTargets([permission]).isEmpty
    }
    static func readOnly(_ operation: String, _ arguments: JSONValue) -> Bool {
        AuthoredToolEffects.primitiveEffects(operation, arguments: arguments).contains("safe_read")
    }
    static let privateStores = [
        "secrets", "credentials", "oauth_tokens", "providers", "codex_home", "codex_child_home",
        "connectors", "telegram/config.json", "slack/config.json", "tools/.manifest_signing_key",
        "catalog/.pack_signing_key", "icloud_pairing_secret.bin", "mobile", "mobile_push",
        "notifications/push_tokens.json", "claude", "bridge-config", "senses/ledger", "senses/news",
    ]
    private let root: URL
    private let permissions: Set<String>
    private var connections: [String: NWConnection] = [:]
    private var listeners: [String: (NWListener, AsyncThrowingStream<String, Error>, AsyncThrowingStream<String, Error>.Continuation)] = [:]
    private let queue = DispatchQueue(label: "nativeagent.authored.network")
    private var closed = false
    private static let byteLimit = 4 * 1024 * 1024

    init(root: URL, permissions: Set<String>) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath(); self.permissions = permissions
    }

    func check(_ operation: String, arguments: JSONValue) throws {
        try Task.checkCancellation()
        guard !closed, Self.operations.contains(operation), case .object(let args) = arguments else {
            throw SenseFailure(code: "bad_input", message: "A known primitive and named arguments are required.")
        }
        if operation == "apps.call" {
            guard case .string(let bundleID)? = args["bundle_id"], let access = Self.appTargets(permissions)[bundleID] else {
                throw SenseFailure(code: "undeclared_target", message: "Declare app_read:<bundle_id> or app_write:<bundle_id> for this target.")
            }
            guard access == "write" || AuthoredToolEffects.appReadOnly(args) else {
                throw SenseFailure(code: "read_only", message: "A read-declared app refuses modifying or unclassified events.")
            }
            try SystemAppleScriptAdapter.checkAppScript(args)
        } else if operation.hasPrefix("files.") {
            _ = try path(args, write: !Self.readOperations.contains(operation) && operation != "files.copy")
            if operation == "files.copy" || operation == "files.move" { _ = try path(args, key: "to", write: true) }
        } else {
            guard !permissions.isDisjoint(with: ["network", "network_public", "network_localhost"]) else {
                throw denied("Declare the network permission this operation needs.")
            }
            if operation == "network.connect" || operation == "network.listen" {
                let local = Self.loopback(try text(args, "host"))
                guard permissions.contains("network") || local && permissions.contains("network_localhost")
                    || operation == "network.connect" && !local && permissions.contains("network_public") else {
                    throw denied("This network host or listening operation is outside the declared reach.")
                }
                _ = try port(args, zero: operation == "network.listen")
            }
        }
    }

    func perform(_ operation: String, arguments: JSONValue) async throws -> JSONValue {
        try check(operation, arguments: arguments)
        let args = SwiftNativeToolExecution.fields(arguments)
        if operation == "apps.call" { return try await SystemAppleScriptAdapter().callApp(arguments, targets: Self.appTargets(permissions)) }
        if operation.hasPrefix("network.") { return try await network(operation, args: args) }
        let source = try path(args, write: !Self.readOperations.contains(operation) && operation != "files.copy")
        switch operation {
        case "files.read":
            let fd = try VerifiedPath.open(source, flags: O_RDONLY | O_NONBLOCK)
            defer { _ = Darwin.close(fd) }
            var metadata = stat()
            guard fstat(fd, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  metadata.st_size >= 0 else {
                throw SenseFailure(code: "bad_input", message: "Read a regular file.")
            }
            let offset = try offset(args), length = args["length"] ?? .int(Int64(Self.byteLimit))
            guard case .int(let count) = length, count > 0, count <= Self.byteLimit else {
                throw SenseFailure(code: "bad_input", message: "Read length is 1 to 4 MiB; use offset for the next chunk.")
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            try handle.seek(toOffset: offset)
            let bytes = try handle.read(upToCount: Int(count)) ?? Data()
            return .object(["base64": .string(bytes.base64EncodedString()), "bytes": .int(Int64(bytes.count)),
                            "offset": .int(Int64(offset)), "eof": .bool(offset + UInt64(bytes.count) >= UInt64(metadata.st_size))])
        case "files.write":
            let bytes = try Self.data(args)
            let parent = try VerifiedPath.openParent(of: source)
            defer { parent.release() }
            let name = ".\(UUID().uuidString).write"
            let fd = openat(parent.fd, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw VerifiedPath.Failure.posix(errno) }
            defer { _ = Darwin.close(fd); _ = unlinkat(parent.fd, name, 0) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            if args["offset"] != nil || args["append"] == .bool(true) {
                let original = openat(parent.fd, parent.name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                if original >= 0 {
                    defer { _ = Darwin.close(original) }
                    var metadata = stat()
                    guard fstat(original, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                        throw SenseFailure(code: "bad_input", message: "Write a regular file.")
                    }
                    guard fcopyfile(original, fd, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else { throw VerifiedPath.Failure.posix(errno) }
                } else if errno != ENOENT { throw VerifiedPath.Failure.posix(errno) }
                if args["append"] == .bool(true) { try handle.seekToEnd() }
                else { try handle.seek(toOffset: offset(args)) }
            }
            try Task.checkCancellation()
            try handle.write(contentsOf: bytes)
            try Task.checkCancellation()
            try permitted(source, write: true)
            guard renameat(parent.fd, name, parent.fd, parent.name) == 0 else { throw VerifiedPath.Failure.posix(errno) }
            return .object(["path": .string(source.path), "bytes": .int(Int64(bytes.count))])
        case "files.mkdir":
            if args["parents"] == .bool(true) {
                let parent = try VerifiedPath.openParent(of: source.appendingPathComponent(".directory"), createIntermediates: true)
                parent.release()
            } else {
                let parent = try VerifiedPath.openParent(of: source)
                defer { parent.release() }
                try Task.checkCancellation()
                guard mkdirat(parent.fd, parent.name, 0o755) == 0 else { throw VerifiedPath.Failure.posix(errno) }
            }
        case "files.remove":
            let parent = try VerifiedPath.openParent(of: source)
            defer { parent.release() }
            try remove(parent.fd, name: parent.name)
        case "files.copy": try copy(source, to: path(args, key: "to", write: true))
        case "files.move": try VerifiedPath.transfer(from: source, to: path(args, key: "to", write: true), copy: false, overwrite: false)
        case "files.info":
            var metadata = stat()
            if source.path == "/" {
                let fd = try VerifiedPath.open(source, flags: O_RDONLY | O_DIRECTORY)
                defer { _ = Darwin.close(fd) }
                guard fstat(fd, &metadata) == 0 else { throw VerifiedPath.Failure.posix(errno) }
            } else {
                let parent = try VerifiedPath.openParent(of: source)
                defer { parent.release() }
                guard fstatat(parent.fd, parent.name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw VerifiedPath.Failure.posix(errno) }
            }
            let type = metadata.st_mode & mode_t(S_IFMT)
            return .object(["path": .string(source.path), "bytes": .int(metadata.st_size),
                            "regular": .bool(type == mode_t(S_IFREG)), "directory": .bool(type == mode_t(S_IFDIR)),
                            "symbolicLink": .bool(type == mode_t(S_IFLNK))])
        case "files.list", "files.count":
            let fd = try VerifiedPath.open(source, flags: O_RDONLY | O_DIRECTORY)
            defer { _ = Darwin.close(fd) }
            var paths: [JSONValue] = [], count: Int64 = 0
            let options: FileManager.DirectoryEnumerationOptions = args["skipHidden"] == .bool(true) ? [.skipsHiddenFiles] : []
            guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: options)
                else { throw SenseFailure(code: "world_error", message: "The folder could not be enumerated.") }
            while let entry = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                guard let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    else { enumerator.skipDescendants(); continue }
                if values.isSymbolicLink == true || args["recursive"] != .bool(true) { enumerator.skipDescendants() }
                do { try permitted(entry, write: false) }
                catch { enumerator.skipDescendants(); continue }
                if args["regularOnly"] == .bool(true), values.isSymbolicLink == true || values.isRegularFile != true { continue }
                count += 1
                if operation == "files.list" { paths.append(.string(entry.path)) }
            }
            let result: JSONValue = operation == "files.count" ? .object(["count": .int(count)]) : .array(paths)
            guard try result.serializedData(pretty: false).count <= Self.byteLimit else {
                throw SenseFailure(code: "output_limit", message: "File listing exceeds the 4 MiB primitive limit.")
            }
            return result
        default: throw SenseFailure(code: "unsupported", message: "Unknown file primitive.")
        }
        return .object(["path": .string(source.path)])
    }

    private func path(_ args: [String: JSONValue], key: String = "path", write: Bool) throws -> URL {
        let scope = try text(args, "root"), given = try text(args, key)
        guard !given.split(separator: "/").contains("..") else { throw denied("Paths must not contain '..' components.") }
        let url: URL
        if scope == "app_data" {
            guard !given.hasPrefix("/"), !given.hasPrefix("~"),
                  !given.contains("\0") else { throw denied("App-data paths must stay relative to the app-data root.") }
            url = root.appendingPathComponent(given.split(separator: "/").filter { $0 != "." }.joined(separator: "/"))
            guard under(url, root) else { throw denied("The app-data path resolves outside its root.") }
            guard permissions.contains("app_data_write") || !write && permissions.contains("app_data_read") else {
                throw denied("Declare app_data_read or app_data_write for this path.")
            }
        } else if scope == "computer" {
            guard given.hasPrefix("/") || given.hasPrefix("~"), !given.contains("\0") else { throw denied("Computer paths must be absolute.") }
            let expanded = (given as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw denied("Computer paths must be absolute.") }
            url = URL(fileURLWithPath: "/" + expanded.split(separator: "/").filter { $0 != "." }.joined(separator: "/"))
            guard write ? permissions.contains("arbitrary_file_write") : permissions.contains("computer_files") else {
                throw denied("This path is outside the declared reach (requires \(write ? "arbitrary_file_write" : "computer_files")).")
            }
        } else { throw denied("The file root is app_data or computer.") }
        try permitted(url, write: write)
        return url
    }

    private func permitted(_ path: URL, write: Bool) throws {
        if write { try CapabilityLifecycle.requireFileMutation(path, dataRoot: root) }
        let privatePaths = Self.privateStores.map { root.appendingPathComponent($0).resolvingSymlinksInPath() }
        guard !privatePaths.contains(where: { under(path, $0) || write && under($0, path) }) else {
            throw denied("The path reaches a protected app store or executable authority.")
        }
        if write {
            let protected = CapabilityLifecycle.protectedStores.map { root.appendingPathComponent($0).resolvingSymlinksInPath() }
                + [PersistenceCore.defaultPersonaRoot(dataRoot: root).resolvingSymlinksInPath()]
            guard !protected.contains(where: { under(path, $0) || under($0, path) }) else {
                throw denied("The path reaches a protected app store or executable authority.")
            }
        }
    }

    private func under(_ path: URL, _ root: URL) -> Bool { path.path == root.path || path.path.hasPrefix(root.path + "/") }
    private func remove(_ parent: Int32, name: String, checkingCancellation: Bool = true) throws {
        if checkingCancellation { try Task.checkCancellation() }
        var metadata = stat()
        guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw VerifiedPath.Failure.posix(errno) }
        let directory = metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        if directory {
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0, let stream = fdopendir(fd) else {
                if fd >= 0 { _ = Darwin.close(fd) }
                throw VerifiedPath.Failure.posix(errno)
            }
            defer { closedir(stream) }
            while let entry = readdir(stream) {
                let child = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if child != ".", child != ".." { try remove(fd, name: child, checkingCancellation: checkingCancellation) }
            }
        }
        if checkingCancellation { try Task.checkCancellation() }
        guard unlinkat(parent, name, directory ? AT_REMOVEDIR : 0) == 0 else { throw VerifiedPath.Failure.posix(errno) }
    }

    private func copy(_ source: URL, to target: URL) throws {
        try Task.checkCancellation()
        guard !under(target, source) else { throw SenseFailure(code: "bad_input", message: "Copy to a path outside the source folder.") }
        let parent = try VerifiedPath.openParent(of: target, createIntermediates: true)
        defer { parent.release() }
        let temporary = ".\(UUID().uuidString).copy"
        let stage = target.deletingLastPathComponent().appendingPathComponent(temporary)
        defer { try? remove(parent.fd, name: temporary, checkingCancellation: false) }
        try copyContents(source, to: stage)
        try Task.checkCancellation()
        guard renameatx_np(parent.fd, temporary, parent.fd, parent.name, UInt32(RENAME_EXCL)) == 0 else {
            throw VerifiedPath.Failure.posix(errno)
        }
    }

    private func copyContents(_ source: URL, to target: URL) throws {
        try Task.checkCancellation()
        try permitted(source, write: false); try permitted(target, write: true)
        let fd = try VerifiedPath.open(source, flags: O_RDONLY | O_NONBLOCK)
        defer { _ = Darwin.close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw VerifiedPath.Failure.posix(errno) }
        if metadata.st_mode & mode_t(S_IFMT) != mode_t(S_IFDIR) {
            try VerifiedPath.transfer(from: source, to: target, copy: true, overwrite: false)
            return
        }
        let parent = try VerifiedPath.openParent(of: target)
        defer { parent.release() }
        try Task.checkCancellation()
        guard mkdirat(parent.fd, parent.name, 0o755) == 0 else { throw VerifiedPath.Failure.posix(errno) }
        guard let stream = fdopendir(dup(fd)) else { throw VerifiedPath.Failure.posix(errno) }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            let child = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if child != ".", child != ".." { try copyContents(source.appendingPathComponent(child), to: target.appendingPathComponent(child)) }
        }
    }
    private func denied(_ detail: String) -> SenseFailure { SenseFailure(code: "permission_denied", message: detail) }
    private func text(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard case .string(let text)? = args[key], !text.isEmpty else { throw SenseFailure(code: "bad_input", message: "\(key) is required.") }
        return text
    }
    private func offset(_ args: [String: JSONValue]) throws -> UInt64 {
        guard case .int(let value) = args["offset"] ?? .int(0), let offset = UInt64(exactly: value) else {
            throw SenseFailure(code: "bad_input", message: "offset must be a nonnegative integer.")
        }
        return offset
    }
    private func port(_ args: [String: JSONValue], zero: Bool) throws -> NWEndpoint.Port {
        guard case .int(let value)? = args["port"], value >= (zero ? 0 : 1), let raw = UInt16(exactly: value),
              let port = NWEndpoint.Port(rawValue: raw) else { throw SenseFailure(code: "bad_input", message: "Pass a valid network port.") }
        return port
    }
    private static func data(_ args: [String: JSONValue]) throws -> Data {
        guard case .string(let base64)? = args["base64"], let data = Data(base64Encoded: base64), data.count <= byteLimit else {
            throw SenseFailure(code: "bad_input", message: "Pass base64 bytes of at most 4 MiB.")
        }
        return data
    }
    private static func loopback(_ host: String) -> Bool {
        host.lowercased() == "localhost" || host == "::1" || host.hasPrefix("127.") || host.hasPrefix("::ffff:127.")
    }

    private func address(_ host: String) throws -> String {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var first: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &first) == 0, let start = first else {
            throw SenseFailure(code: "world_error", message: "Network host could not be resolved.")
        }
        defer { freeaddrinfo(start) }
        var cursor: UnsafeMutablePointer<addrinfo>? = start, addresses: [String] = []
        while let at = cursor {
            var bytes = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(at.pointee.ai_addr, at.pointee.ai_addrlen, &bytes, socklen_t(bytes.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
            cursor = at.pointee.ai_next
        }
        guard let chosen = addresses.first, permissions.contains("network")
            || addresses.allSatisfy({ Self.loopback($0) ? permissions.contains("network_localhost") : permissions.contains("network_public") }) else {
            throw denied("The resolved address is outside the declared network reach.")
        }
        return chosen
    }

    private func network(_ operation: String, args: [String: JSONValue]) async throws -> JSONValue {
        switch operation {
        case "network.connect", "network.listen":
            let host = try text(args, "host"), address = try address(host), port = try port(args, zero: operation == "network.listen")
            let parameters: NWParameters
            if args["transport"] == .string("udp") { parameters = .udp }
            else if args["tls"] == .bool(true), operation == "network.connect" {
                let tls = NWProtocolTLS.Options()
                sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
                parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            } else { parameters = .tcp }
            let id = UUID().uuidString
            if operation == "network.connect" {
                let connection = NWConnection(host: NWEndpoint.Host(address), port: port, using: parameters)
                connections[id] = connection
                try await ready(connection)
                return .object(["id": .string(id)])
            }
            guard permissions.contains("network") || Self.loopback(address) && permissions.contains("network_localhost") else {
                throw denied("Listening requires the declared inbound network reach.")
            }
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
            let listener = try NWListener(using: parameters, on: port)
            let stream = AsyncThrowingStream<String, Error>.makeStream(bufferingPolicy: .bufferingOldest(OwnedProgramRunner.actionLimit))
            listeners[id] = (listener, stream.stream, stream.continuation)
            listener.newConnectionHandler = { connection in Task { await self.incoming(connection, listener: id) } }
            try await networkReply(cancel: { listener.cancel() }) { (done: AsyncThrowingStream<Void, Error>.Continuation) in
                listener.stateUpdateHandler = { state in
                    if case .ready = state { done.yield(()); done.finish() }
                    if case .failed(let error) = state { done.finish(throwing: error); stream.continuation.finish(throwing: error) }
                    if case .cancelled = state { done.finish(throwing: CancellationError()); stream.continuation.finish(throwing: CancellationError()) }
                }
                listener.start(queue: self.queue)
            }
            return .object(["id": .string(id), "port": .int(Int64(listener.port?.rawValue ?? port.rawValue))])
        case "network.accept":
            let id = try text(args, "id")
            guard let slot = listeners[id] else { throw denied("This invocation does not own that listener.") }
            let accepted = try await withTaskCancellationHandler {
                var iterator = slot.1.makeAsyncIterator()
                return try await iterator.next()
            } onCancel: { slot.2.finish(throwing: CancellationError()); slot.0.cancel() }
            guard let accepted, let connection = connections[accepted] else { throw CancellationError() }
            try await ready(connection)
            return .object(["id": .string(accepted)])
        case "network.send", "network.receive":
            let id = try text(args, "id")
            guard let connection = connections[id] else { throw denied("This invocation does not own that connection.") }
            if operation == "network.send" {
                let data = try Self.data(args)
                try await networkReply(cancel: { connection.cancel() }) { (done: AsyncThrowingStream<Void, Error>.Continuation) in
                    connection.send(content: data, completion: .contentProcessed { error in
                        if let error { done.finish(throwing: error) } else { done.yield(()); done.finish() }
                    })
                }
                return .object(["bytes": .int(Int64(data.count))])
            }
            return try await networkReply(cancel: { connection.cancel() }) { (done: AsyncThrowingStream<JSONValue, Error>.Continuation) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: Self.byteLimit) { data, _, complete, error in
                    if let error { done.finish(throwing: error) }
                    else {
                        done.yield(.object(["base64": .string((data ?? Data()).base64EncodedString()),
                                            "bytes": .int(Int64(data?.count ?? 0)), "eof": .bool(complete)])); done.finish()
                    }
                }
            }
        case "network.close":
            let id = try text(args, "id")
            if let connection = connections.removeValue(forKey: id) { connection.cancel() }
            else if let slot = listeners.removeValue(forKey: id) { slot.0.cancel(); slot.2.finish() }
            else { throw denied("This invocation does not own that network handle.") }
            return .object(["id": .string(id)])
        default: throw SenseFailure(code: "unsupported", message: "Unknown network primitive.")
        }
    }

    private func incoming(_ connection: NWConnection, listener id: String) {
        guard !closed, let slot = listeners[id] else { connection.cancel(); return }
        let key = UUID().uuidString
        connections[key] = connection
        if case .dropped = slot.2.yield(key) { connections.removeValue(forKey: key); connection.cancel() }
    }

    private func ready(_ connection: NWConnection) async throws {
        try await networkReply(cancel: { connection.cancel() }) { (done: AsyncThrowingStream<Void, Error>.Continuation) in
            connection.stateUpdateHandler = { state in
                if case .ready = state { done.yield(()); done.finish() }
                if case .failed(let error) = state { done.finish(throwing: error) }
                if case .cancelled = state { done.finish(throwing: CancellationError()) }
            }
            connection.start(queue: self.queue)
        }
    }

    private func networkReply<T: Sendable>(cancel: @escaping @Sendable () -> Void,
                                  start: (AsyncThrowingStream<T, Error>.Continuation) -> Void) async throws -> T {
        let stream = AsyncThrowingStream<T, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        try Task.checkCancellation()
        start(stream.continuation)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            var iterator = stream.stream.makeAsyncIterator()
            guard let value = try await iterator.next() else { throw CancellationError() }
            return value
        } onCancel: { stream.continuation.finish(throwing: CancellationError()); cancel() }
    }

    func close() {
        closed = true
        for connection in connections.values { connection.cancel() }
        for slot in listeners.values { slot.0.cancel(); slot.2.finish() }
        connections.removeAll(); listeners.removeAll()
    }

    static func checkInput(_ input: JSONValue, schema: JSONValue) throws {
        guard case .object(let fields) = input, case .object(let spec) = schema else {
            throw SenseFailure(code: "bad_input", message: "Tool input and inputSchema must be JSON objects.")
        }
        guard SwiftNativeToolExecution.strings(spec["required"]).allSatisfy({ fields[$0] != nil }) else {
            throw SenseFailure(code: "bad_input", message: "Tool input is missing a required schema field.")
        }
    }
}
