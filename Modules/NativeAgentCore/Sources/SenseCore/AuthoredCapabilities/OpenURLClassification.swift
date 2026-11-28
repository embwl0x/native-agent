import Foundation
import PersistenceCore
// Blueprint: | `OpenURLClassification.swift` | Exact app URL request, declared scheme reach and shared shell-level classification |

package enum OpenURLClassification: String, Sendable {
    case forbidden, standard, shellLevel = "shell_level"

    private static let forbiddenSchemes: Set<String> = ["file", "http", "https", "javascript", "data", "blob", "about", "smb", "afp", "vnc", "nfs",
        "ftp", "tel", "facetime", "facetime-audio", "mailto"]
    private static let shellSchemes: Set<String> = ["shortcuts", "shortcuts-production", "workflow", "ssh", "slogin", "telnet", "x-man-page",
        "iterm2", "warp", "ghostty", "kitty", "x-apple.systempreferences", "prefs", "applescript", "raycast", "alfred", "kmtrigger", "btt", "x-script-editor"]
    private static let shellBundles: Set<String> = ["com.apple.shortcuts", "com.apple.shortcuts.events", "com.apple.terminal", "com.googlecode.iterm2",
        "dev.warp.warp-stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "com.panic.prompt",
        "com.apple.systempreferences", "com.apple.scripteditor2", "com.apple.automator", "com.raycast.macos", "com.runningwithcrayons.alfred",
        "com.runningwithcrayons.alfred-5", "com.stairways.keyboardmaestro.engine", "com.stairways.keyboardmaestro.editor", "com.hegenberg.bettertouchtool"]

    package static func normalizedBundleID(_ bundleID: String) -> String? {
        guard bundleID.range(of: #"\A[A-Za-z0-9.-]+\z"#, options: .regularExpression) != nil else { return nil }
        return bundleID.lowercased()
    }

    package static func normalizedScheme(_ scheme: String) -> String? {
        guard scheme.range(of: #"\A[A-Za-z][A-Za-z0-9+.-]*\z"#, options: .regularExpression) != nil else { return nil }
        return scheme.lowercased()
    }

    package static func classify(bundleID: String, scheme: String) -> Self {
        if forbiddenSchemes.contains(scheme) { return .forbidden }
        return shellSchemes.contains(scheme) || shellBundles.contains(bundleID) ? .shellLevel : .standard
    }
}

package struct PartOpenURLRequest: Sendable {
    package static let operation = "app.openURL"
    package static let effect = operation.lowercased()
    package let bundleID: String
    package let url: URL
    package let scheme: String
    package let activate: Bool
    package let classification: OpenURLClassification

    package init(_ arguments: JSONValue) throws {
        guard Keyring.names(in: arguments).isEmpty else {
            throw SenseFailure(code: "secret_in_url_forbidden", message: "host.app.openURL refuses secret placeholders.")
        }
        guard case .object(let args) = arguments, Set(args.keys).isSubset(of: ["bundle_id", "url", "activate"]),
              case .string(let suppliedID)? = args["bundle_id"], let bundleID = OpenURLClassification.normalizedBundleID(suppliedID),
              case .string(let rawURL)? = args["url"], rawURL.utf8.count <= 8_192,
              rawURL.utf8.allSatisfy({ $0 != 0 && $0 != 10 && $0 != 13 }),
              let components = URLComponents(string: rawURL), let rawScheme = components.scheme,
              let scheme = OpenURLClassification.normalizedScheme(rawScheme), let url = components.url,
              args["activate"] == nil || args["activate"] == .bool(true) || args["activate"] == .bool(false) else {
            throw SenseFailure(code: "invalid_args", message: """
                host.app.openURL takes an explicit ASCII bundle_id, a custom URL of at most 8192 bytes, and an optional Boolean activate.
                """)
        }
        let classification = OpenURLClassification.classify(bundleID: bundleID, scheme: scheme)
        guard classification != .forbidden else {
            throw SenseFailure(code: "url_scheme_forbidden", message: "host.app.openURL refuses the \(scheme) scheme.")
        }
        self.bundleID = bundleID
        self.url = url
        self.scheme = scheme
        activate = args["activate"] == .bool(true)
        self.classification = classification
    }

    package func missingAppReach(_ grants: Set<PartReachGrant>) -> [String] {
        var missing: [String] = []
        let names = Self.appReachNames(bundleID: bundleID, scheme: scheme)
        let canWrite = grants.contains { grant in
            guard case .appWrite(let declaredID) = grant else { return false }
            return OpenURLClassification.normalizedBundleID(declaredID) == bundleID
        }
        if !canWrite { missing.append(names.write) }
        if !grants.contains(.appURL(bundleID, scheme)) { missing.append(names.url) }
        return missing
    }

    package static func appReachNames(bundleID: String, scheme: String) -> (write: String, url: String) {
        ("app_write:\(bundleID)", "app_url:\(bundleID):\(scheme)")
    }

    package func needsShellReach(_ grants: Set<PartReachGrant>) -> Bool {
        classification == .shellLevel && !grants.contains(.flag(.shell))
    }
}
