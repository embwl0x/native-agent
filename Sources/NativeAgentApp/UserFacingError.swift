import Foundation
import os
import ProviderRouting
#if canImport(CloudKit)
import CloudKit
#endif

/// The one place a caught error becomes words for a person: what failed and
/// what to do, in one plain sentence. The raw description goes to the log,
/// never to the main line — "Remember failed: The operation couldn't be
/// completed. (NSCocoaErrorDomain error 640.)" tells nobody anything.
enum UserFacingError {
    private static let logger = Logger(subsystem: "com.nativeagent.app", category: "user-facing-error")

    /// "Couldn't <action>. <cause and what to do>" — `action` is a verb
    /// phrase like "save that memory". The raw error is logged here.
    static func message(_ error: Error, action: String) -> String {
        logger.error("\(action, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        return "Couldn't \(action). " + advice(for: error)
    }

    /// The agent's copy of a plain failure line: the same line plus the raw
    /// cause she needs to act, unless the line already says it.
    static func forAgent(_ line: String, cause: String?) -> String {
        guard let cause, !cause.isEmpty, !line.contains(cause) else { return line }
        return "\(line) (cause: \(cause))"
    }

    /// Just the cause and the fix, for a line that already says what failed
    /// ("Research run failed: <this>"). The raw error is logged here.
    static func cause(_ error: Error, action: String) -> String {
        logger.error("\(action, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        return advice(for: error)
    }

    /// The same line for a failure that arrives as text rather than an Error
    /// (a service's own reason string). The text goes to the log only.
    static func message(detail: String, action: String) -> String {
        logger.error("\(action, privacy: .public) failed: \(detail, privacy: .public)")
        return "Couldn't \(action). " + fallback
    }

    private static let fallback = "Something went wrong. Try again; if it keeps happening, the details are in the log."

    #if canImport(CloudKit)
    /// An iCloud account status in words, never the enum case name.
    static func iCloudAccount(_ status: CKAccountStatus) -> String {
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
    static let iCloudSignedIn = "Signed in to iCloud"
    static let iCloudNoAnswer = "iCloud didn't answer in time"

    /// A sentence the app wrote itself, shown as is: a Swift error type from
    /// our own modules that describes itself (LocalizedError), or an NSError
    /// in a NativeAgent domain that wraps nothing. System errors bridge to
    /// NSError at runtime (URLError, CocoaError, CKError), so they never match
    /// the first test; an NSError wrapping an underlying error carries raw text.
    static func ownSentence(_ error: Error) -> String? {
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

    /// Swift modules that are not ours (the toolchain and package dependencies).
    private static let foreignModules = [
        "Swift.", "Foundation.", "_", "GRDB.", "Sparkle.", "Yams.", "GRPC", "NIO", "Crypto.", "X509.", "SwiftASN1.",
        "Logging.", "SwiftProtobuf.", "Algorithms.", "AsyncAlgorithms.", "Collections.",
    ]

    /// The cause and the fix, without the leading "Couldn't …".
    static func advice(for error: Error) -> String {
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
            switch Int32(ns.code) {
            case ENOSPC, EDQUOT:
                return "This Mac is out of disk space. Free some space, then try again."
            case EACCES, EPERM:
                return "NativeAgent doesn't have permission to do that. Check its access in System Settings > Privacy & Security."
            default:
                break
            }
        }
        return fallback
    }
}
