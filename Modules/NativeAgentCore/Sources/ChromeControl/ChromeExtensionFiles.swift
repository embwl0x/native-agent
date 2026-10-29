import Foundation
import CryptoKit
import PersistenceCore
// Blueprint: | `ChromeExtensionFiles.swift` | `ChromeExtensionFiles`: registered unpacked and bundled manifest identity/version reads; one executable closure supplies completeness, watched paths including missing files and the loaded-code SHA-256 digest shared with the extension |

/// Chrome records the unpacked folder, rather than the native-host installer.
/// Read that exact manifest as well as the app's shipped manifest; never infer
/// a folder from a checkout name or substitute a version literal.
struct ChromeExtensionFiles {
    private var bundled: (url: URL, revision: NSDictionary, key: String, id: String, version: String)?
    private(set) var watchedPaths = Set<URL>()

    static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var result: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part), (0...65535).contains(number) else { return nil }
            result.append(number)
        }
        return result + Array(repeating: 0, count: 4 - result.count)
    }

    static func isOlder(_ version: String, than other: String) -> Bool {
        guard let left = components(version), let right = components(other) else { return false }
        return left.lexicographicallyPrecedes(right)
    }

    static func object(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw ChromeControlRuntimeError.connectionUnavailable("Chrome extension files unavailable: invalid JSON object at \(url.path).")
        }
        return value
    }

    static func version(_ object: [String: Any], path: String) throws -> String {
        guard let value = object["version"] as? String, components(value) != nil else {
            throw ChromeControlRuntimeError.connectionUnavailable("Chrome extension files unavailable: invalid manifest version at \(path).")
        }
        return value
    }

    mutating func read() throws -> (path: String, diskVersion: String, shippedVersion: String, code: String?) {
        watchedPaths.removeAll()
        let root = InstallPaths.current.chromeManifest.deletingLastPathComponent().deletingLastPathComponent()
        watchedPaths.insert(root.appendingPathComponent("Local State"))
        guard let resources = Bundle.main.resourceURL else {
            throw ChromeControlRuntimeError.connectionUnavailable("NativeAgent's shipped Chrome manifest is unavailable.")
        }
        let bundledURL = resources.appendingPathComponent("NativeAgentChrome/manifest.json")
        watchedPaths.insert(bundledURL)
        // File identity detects bundle replacement even when its version and
        // modification date were preserved.
        let revision = try FileManager.default.attributesOfItem(atPath: bundledURL.path) as NSDictionary
        let shipped: (url: URL, revision: NSDictionary, key: String, id: String, version: String)
        if let bundled, bundled.url == bundledURL, bundled.revision == revision {
            shipped = bundled
        } else {
            bundled = nil
            let manifest = try Self.object(bundledURL)
            let version = try Self.version(manifest, path: bundledURL.path)
            guard let key = manifest["key"] as? String, let bytes = Data(base64Encoded: key) else {
                throw ChromeControlRuntimeError.connectionUnavailable("NativeAgent's shipped Chrome manifest has no valid extension identity key.")
            }
            // Chrome's extension id is the first 128 bits of the public key's
            // SHA256, encoded a-p; stable across bundle and unpacked copies.
            let alphabet = Array("abcdefghijklmnop")
            let id = SHA256.hash(data: bytes).prefix(16).map {
                String(alphabet[Int($0 >> 4)]) + String(alphabet[Int($0 & 15)])
            }.joined()
            shipped = (bundledURL, revision, key, id, version)
            bundled = shipped
        }
        let state = try Self.object(root.appendingPathComponent("Local State"))
        guard let profile = state["profile"] as? [String: Any], let profiles = profile["info_cache"] as? [String: Any] else {
            throw ChromeControlRuntimeError.connectionUnavailable("Chrome's profile inventory is unavailable at \(root.path).")
        }
        var paths = Set<String>()
        for name in profiles.keys.sorted() {
            guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
                throw ChromeControlRuntimeError.connectionUnavailable("Chrome's profile inventory contains an invalid folder.")
            }
            let profileURL = root.appendingPathComponent(name, isDirectory: true)
            // These are Chrome's two preference stores, not alternate guesses.
            // Inspect both; contradictory paths are unavailable, never selected.
            for filename in ["Preferences", "Secure Preferences"] {
                let url = profileURL.appendingPathComponent(filename)
                watchedPaths.insert(url)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let prefs = try Self.object(url)
                guard let extensions = prefs["extensions"] as? [String: Any],
                      let settings = extensions["settings"] as? [String: Any],
                      let entry = settings[shipped.id] as? [String: Any] else { continue }
                guard let path = entry["path"] as? String, path.hasPrefix("/") else {
                    throw ChromeControlRuntimeError.connectionUnavailable("Chrome's registered extension folder is not an absolute unpacked path (\(url.path)).")
                }
                paths.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
            }
        }
        guard paths.count == 1, let path = paths.first else {
            throw ChromeControlRuntimeError.connectionUnavailable("Chrome's registered extension folder is \(paths.isEmpty ? "missing" : "ambiguous: " + paths.sorted().joined(separator: ", ")).")
        }
        let manifestURL = URL(fileURLWithPath: path).appendingPathComponent("manifest.json")
        watchedPaths.insert(manifestURL)
        let manifest = try Self.object(manifestURL)
        guard manifest["key"] as? String == shipped.key else {
            throw ChromeControlRuntimeError.connectionUnavailable("Chrome's extension manifest identity differs from NativeAgent's at \(path).")
        }
        return (path: path, diskVersion: try Self.version(manifest, path: manifestURL.path), shippedVersion: shipped.version,
                code: Self.codeDigest(folder: URL(fileURLWithPath: path), manifest: manifest, paths: &watchedPaths))
    }

    /// Match background.js: sorted "<path>\n<bytes>\n" SHA-256 records, first eight bytes in hex.
    /// Roots and static imports serve completeness and watches; unreadable paths remain watched with a nil digest.
    static func codeDigest(folder: URL, manifest: [String: Any], paths: inout Set<URL>) -> String? {
        var queue = ["manifest.json"]
        if let background = manifest["background"] as? [String: Any], let worker = background["service_worker"] as? String { queue.append(worker) }
        for script in manifest["content_scripts"] as? [[String: Any]] ?? [] { queue.append(contentsOf: script["js"] as? [String] ?? []) }
        guard let imports = try? NSRegularExpression(pattern: #"from\s*["'](\.{1,2}/[^"']+\.js)["']|import\s*["'](\.{1,2}/[^"']+\.js)["']"#) else { return nil }
        var files: [String: Data] = [:]
        var seen = Set<String>()
        while !queue.isEmpty {
            let path = queue.removeFirst()
            guard seen.insert(path).inserted else { continue }
            paths.insert(folder.appendingPathComponent(path))
            guard let bytes = try? Data(contentsOf: folder.appendingPathComponent(path)) else { continue }
            files[path] = bytes
            guard path.hasSuffix(".js"), let source = String(data: bytes, encoding: .utf8) else { continue }
            let directory = path.lastIndex(of: "/").map { String(path[...$0]) } ?? ""
            for match in imports.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let range = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
                guard let swiftRange = Range(range, in: source),
                      let resolved = URL(string: String(source[swiftRange]), relativeTo: URL(string: "http://x/" + directory)) else { continue }
                queue.append(String(resolved.standardized.path.dropFirst()))
            }
        }
        guard files.count == seen.count else { return nil }
        var hasher = SHA256()
        for path in files.keys.sorted() {
            hasher.update(data: Data((path + "\n").utf8))
            hasher.update(data: files[path]!)
            hasher.update(data: Data("\n".utf8))
        }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
