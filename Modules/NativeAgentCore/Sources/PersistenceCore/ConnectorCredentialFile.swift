import Foundation
import CryptoKit

/// Google, Notion and X credential files contain metadata and a device-only
/// Keychain reference. The reference is bound to its root and exact file path.
public enum ConnectorCredentialFile {
    public static let relativePaths = ["gmail", "calendar", "notion", "x"].flatMap { connector in
        ["connectors/\(connector)/auth.json", "connectors/\(connector)/oauth_app.json"]
    } + ["oauth_tokens/x.json", "secrets/x.json"]
    private static let service = "NativeAgent.connector.credentials"
    private static let secretKeys: Set<String> = [
        "client_secret", "access_token", "refresh_token", "id_token", "oauth_token", "token",
        "api_key", "api_secret", "access_token_secret",
    ]
    private static let metadataStrings: Set<String> = [
        "client_id", "connector_id", "redirect_uri", "provider", "saved_at", "validated_at",
        "token_type", "scope", "account_id", "refresh_token_account_id", "account_sub",
        "refresh_token_account_sub", "credential_store", "keychain_ref",
    ]
    private static let metadataNumbers: Set<String> = ["expires_at", "expires_in", "credential_version"]

    private static func isMetadata(_ key: String) -> Bool {
        metadataStrings.contains(key) || metadataNumbers.contains(key)
    }

    private static func managed(_ path: URL) -> Bool {
        relativePaths.contains { path.path.hasSuffix("/" + $0) }
    }

    private static func checkedPath(_ path: URL) throws -> URL {
        let file = path.standardizedFileURL
        let root = file.deletingLastPathComponent().deletingLastPathComponent()
        let dataRoot = ["oauth_tokens", "secrets"].contains(file.deletingLastPathComponent().lastPathComponent)
            ? root : root.deletingLastPathComponent()
        let relative = String(file.path.dropFirst(dataRoot.path.count))
        let expected = dataRoot.resolvingSymlinksInPath().path + relative
        guard file.resolvingSymlinksInPath().path == expected else {
            throw CocoaError(.fileReadNoPermission)
        }
        if FileManager.default.fileExists(atPath: file.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        return file
    }

    private static func account(_ reference: String, path: URL) throws -> String {
        guard UUID(uuidString: reference) != nil else { throw CocoaError(.fileReadCorruptFile) }
        let scope = SHA256.hash(data: Data(path.resolvingSymlinksInPath().path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return scope + ":" + reference
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for key in secretKeys where object[key] != nil {
            guard object[key] is String else { throw CocoaError(.fileReadCorruptFile) }
        }
        for key in metadataStrings where object[key] != nil {
            guard object[key] is String else { throw CocoaError(.fileReadCorruptFile) }
        }
        for key in metadataNumbers where object[key] != nil {
            guard object[key] is String || object[key] is NSNumber else { throw CocoaError(.fileReadCorruptFile) }
        }
        return object
    }

    private static func encoded(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func locked<T>(_ path: URL, _ operation: (URL) throws -> T) throws -> T {
        let file = try checkedPath(path)
        _ = try checkedPath(URL(fileURLWithPath: file.path + ".lock"))
        return try CredentialFileLock.withLock(file) { try operation(try checkedPath(file)) }
    }

    public static func read(at path: URL) throws -> Data {
        guard managed(path) else { return try Data(contentsOf: path) }
        return try locked(path) { file in
            var metadata = try object(Data(contentsOf: file))
            if let reference = metadata["keychain_ref"] as? String {
                guard metadata.keys.allSatisfy(isMetadata),
                      let data = try DeviceSecretKeychain.read(service: service, account: account(reference, path: file)) else {
                    throw DeviceSecretKeychain.Failure.unavailable
                }
                let secrets = try object(data)
                guard secrets.keys.allSatisfy({ !isMetadata($0) }) else { throw CocoaError(.fileReadCorruptFile) }
                metadata.removeValue(forKey: "keychain_ref")
                for (key, value) in secrets { metadata[key] = value }
            } else if metadata.keys.contains(where: { !isMetadata($0) }) {
                // Publish only after Keychain insertion and readback succeeds.
                try publish(metadata, at: file)
            }
            return try encoded(metadata)
        }
    }

    /// Revocation validates the saved reference without needing usable secrets.
    public static func metadata(at path: URL) throws -> Data {
        guard managed(path) else { return try Data(contentsOf: path) }
        return try locked(path) { file in
            try checkedMetadata(Data(contentsOf: file), at: file)
        }
    }

    private static func checkedMetadata(_ data: Data, at path: URL) throws -> Data {
        let metadata = try object(data)
        if let reference = metadata["keychain_ref"] as? String {
            _ = try account(reference, path: path)
            guard metadata.keys.allSatisfy(isMetadata) else { throw CocoaError(.fileReadCorruptFile) }
        }
        return data
    }

    public static func write(_ data: Data, to path: URL) throws {
        guard managed(path) else { throw CocoaError(.fileWriteInvalidFileName) }
        let credentials = try object(data)
        try locked(path) { try publish(credentials, at: $0) }
    }

    private static func publish(_ credentials: [String: Any], at path: URL) throws {
        var metadata = credentials
        metadata.removeValue(forKey: "keychain_ref")
        let secrets = metadata.filter { !isMetadata($0.key) }
        metadata = metadata.filter { isMetadata($0.key) }
        let old = FileManager.default.fileExists(atPath: path.path) ? try object(Data(contentsOf: path)) : [:]
        let oldReference = old["keychain_ref"] as? String
        let oldKey = try oldReference.map { try account($0, path: path) }
        let reference = UUID().uuidString
        let key = try account(reference, path: path)
        try DeviceSecretKeychain.insert(try encoded(secrets), service: service, account: key)
        metadata["keychain_ref"] = reference
        let output = try encoded(metadata)
        do {
            try output.write(to: path, options: .atomic)
        } catch {
            try? DeviceSecretKeychain.delete(service: service, account: key)
            throw error
        }
        // Never remove the verified secret if the reference committed but its
        // readback failed. A subsequent read can recover that exact reference.
        guard try Data(contentsOf: path) == output else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        if let oldKey {
            try DeviceSecretKeychain.delete(service: service, account: oldKey)
        }
    }

    public static func remove(at path: URL) throws {
        guard managed(path) else { return try FileManager.default.removeItem(at: path) }
        try locked(path) { file in
            let metadata = try object(Data(contentsOf: file))
            let key = try (metadata["keychain_ref"] as? String).map { try account($0, path: file) }
            if let key { try DeviceSecretKeychain.delete(service: service, account: key) }
            try FileManager.default.removeItem(at: file)
        }
    }

    /// References are device grants, not restorable history. Keep the exact
    /// current files (including absence) without rotating or deleting grants.
    public static func preserveCredentials(safetyRoot: URL, destinationRoot: URL) throws {
        for relative in relativePaths {
            let source = safetyRoot.appendingPathComponent(relative)
            let destination = destinationRoot.appendingPathComponent(relative)
            let bytes: Data?
            do { bytes = try checkedMetadata(Data(contentsOf: source), at: destination) }
            catch CocoaError.fileReadNoSuchFile { bytes = nil }
            try locked(destination) { file in
                if let bytes {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try SwiftNativePersistenceCore.writeDataAtomicDurable(bytes, to: file)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    guard try Data(contentsOf: file) == bytes else { throw CocoaError(.fileWriteUnknown) }
                } else if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
            }
        }
    }
}
