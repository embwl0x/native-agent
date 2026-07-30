import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

// MARK: - Swift-native MacControl
//
// This module owns the in-process Mac control surface. Implemented actions run
// directly in Swift after gate pre-flight. Actions not yet implemented return a
// Swift 501-style result. There is no daemon HTTP fallback path.
