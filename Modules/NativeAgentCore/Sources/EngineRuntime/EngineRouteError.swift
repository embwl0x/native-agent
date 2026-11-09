import Foundation
import NativeAgentShared
import NativeAgentCore
import ProviderRouting
#if canImport(CloudKit)
import CloudKit
// Blueprint: | `EngineRouteError.swift` | Plain failure remedies and full-width POSIX error interpretation |
#endif
/// Keep raw errors in logs; user-facing failures need a plain cause and remedy.
public enum UserFacingError {
    private static let logger = ModuleLog(subsystem: "com.nativeagent.app", category: "user-facing-error")

    public static func message(_ error: Error, action: String) -> String {
        logger("\(action) failed: \(String(describing: error))", level: .error)
        return "Couldn't \(action). " + advice(for: error)
    }

    /// Agent-facing failures also carry the raw cause needed to act, without repeating it.
    public static func forAgent(_ line: String, cause: String?) -> String {
        guard let cause, !cause.isEmpty, !line.contains(cause) else { return line }
        return "\(line) (cause: \(cause))"
    }

    public static func cause(_ error: Error, action: String) -> String {
        logger("\(action) failed: \(String(describing: error))", level: .error)
        return advice(for: error)
    }

    /// Service reason strings stay in logs rather than raw user-facing copy.
    public static func message(detail: String, action: String) -> String {
        logger("\(action) failed: \(detail)", level: .error)
        return "Couldn't \(action). " + fallback
    }

    private static let fallback = "Something went wrong. Try again; if it keeps happening, the details are in the log."

    #if canImport(CloudKit)
    public static func iCloudAccount(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: return iCloudSignedIn
        case .noAccount: return "Not signed in to iCloud"
        case .restricted: return "iCloud is restricted on this Mac"
        case .temporarilyUnavailable: return "iCloud needs you to confirm your account"
        case .couldNotDetermine: return "Couldn't check iCloud"
        @unknown default: return "Couldn't check iCloud"
        }
    }
    #endif
    public static let iCloudSignedIn = "Signed in to iCloud"

    /// Use authored localized errors as written; system NSError bridges and wrapped underlying errors can contain raw diagnostic text.
    public static func ownSentence(_ error: Error) -> String? {
        let ns = error as NSError
        let typeName = String(reflecting: type(of: error))
        let text: String?
        if ns.domain == typeName, error is LocalizedError,
           !foreignModules.contains(where: { typeName.hasPrefix($0) }) {
            text = (error as? LocalizedError)?.errorDescription
        } else if ns.domain.hasPrefix("NativeAgent"), ns.userInfo[NSUnderlyingErrorKey] == nil {
            text = ns.userInfo[NSLocalizedDescriptionKey] as? String
        } else {
            text = nil
        }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static let foreignModules = [
        "Swift.", "Foundation.", "_", "GRDB.", "Sparkle.", "Yams.", "GRPC", "NIO", "Crypto.", "X509.", "SwiftASN1.",
        "Logging.", "SwiftProtobuf.", "Algorithms.", "AsyncAlgorithms.", "Collections.",
    ]

    public static func advice(for error: Error) -> String {
        let ns = error as NSError
        #if canImport(CloudKit)
        if let ck = error as? CKError {
            switch ck.code {
            case .notAuthenticated:
                return "This Mac isn't signed in to iCloud. Sign in under System Settings > Apple Account, then try again."
            case .accountTemporarilyUnavailable:
                return "iCloud needs you to confirm your account. Open System Settings > Apple Account, then try again."
            case .quotaExceeded:
                return "Your iCloud storage is full. Free up space in iCloud, then try again."
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
                return "iCloud couldn't be reached just now. Try again in a minute."
            case .permissionFailure:
                return "iCloud didn't allow this. Check that iCloud is on for NativeAgent, then try again."
            default:
                break
            }
        }
        #endif
        switch ProviderFailure.classify(error) {
        case .authExpired?, .codexCLISessionExpired?:
            return "The sign-in has expired. Reconnect it in Settings, then try again."
        case .rateLimited?:
            return "Too many requests right now. Wait a minute, then try again."
        case .network?:
            return "The connection dropped. Check your internet connection, then try again."
        default:
            break
        }
        if error is ProviderFailure.Report, let person = ProviderRecoveryPolicy.personMessage(error) {
            return person
        }
        if let own = ownSentence(error) { return own }
        if ns.domain == NSURLErrorDomain {
            return "The connection dropped. Check your internet connection, then try again."
        }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteOutOfSpaceError:
                return "This Mac is out of disk space. Free some space, then try again."
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return "NativeAgent doesn't have permission to that file. Check its access in System Settings > Privacy & Security."
            case NSFileWriteVolumeReadOnlyError:
                return "That disk is read-only. Choose a different location."
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return "A file it needs is missing. Try again; if it keeps happening, restart NativeAgent."
            default:
                break
            }
        }
        if ns.domain == NSPOSIXErrorDomain {
            switch ns.code {
            case Int(ENOSPC), Int(EDQUOT):
                return "This Mac is out of disk space. Free some space, then try again."
            case Int(EACCES), Int(EPERM):
                return "NativeAgent doesn't have permission to do that. Check its access in System Settings > Privacy & Security."
            default:
                break
            }
        }
        return fallback
    }
}
