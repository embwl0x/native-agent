import Foundation
import NativeAgentCore
import PersistenceCore
import Senses
import TrustCenter
#if canImport(Darwin)
import Darwin
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(AppKit)
import AppKit
import Carbon
import OSAKit
import os
#endif

// Blueprint: | `MacNotificationDelivery.swift` | `NotificationPostReceipt` and `NotificationPosting`: notification acceptance and authorization evidence, without claiming delivery or observation |

public enum NotificationAuthorizationDisposition: String, Sendable, Equatable {
    case authorized
    case provisional
}

/// Submission acknowledges delivery acceptance, without proving it was seen,
/// heard or acted on.
public struct NotificationPostReceipt: Sendable, Equatable {
    public let authorization: NotificationAuthorizationDisposition
    public let requestIdentifier: String?

    public init(
        authorization: NotificationAuthorizationDisposition,
        requestIdentifier: String? = nil
    ) {
        self.authorization = authorization
        self.requestIdentifier = requestIdentifier
    }
}

public protocol NotificationPosting: Sendable {
    func postNotificationReceipt(
        title: String,
        message: String,
        soundName: String?
    ) async throws -> NotificationPostReceipt
}
