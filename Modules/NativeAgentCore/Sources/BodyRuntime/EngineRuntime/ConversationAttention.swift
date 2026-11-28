import Foundation
import Observation
import PersistenceCore
import NativeAgentCore
import ProviderRouting
import CloudKit
import MindCore
import MacNerves
import DeskCore
import SenseCore
import Synchronization
import os
import OSLog
import Darwin
import Combine
import UserNotifications
import ImageIO
import UniformTypeIdentifiers
import AppKit
import CoreGraphics
@_exported import NativeAgentShared
// Blueprint: | `ConversationAttention.swift` | `MacChatUnreadSessions`; Phone activity remains unread until its chat opens |

/// Phone activity in a background chat stays unread until that chat opens.
@MainActor
public final class MacChatUnreadSessions {
    public static let shared = MacChatUnreadSessions()
    private static let key = "NativeAgent.unreadPhoneChatSessions"
    struct DidChange: BodySignal {}
    public private(set) var ids = Set(UserDefaults.standard.stringArray(forKey: MacChatUnreadSessions.key) ?? [])

    public func received(in sessionID: String) {
        guard sessionID != UserDefaults.standard.string(forKey: "activeChatSessionId") else { return }
        guard ids.insert(sessionID).inserted else { return }
        UserDefaults.standard.set(Array(ids), forKey: Self.key)
        NotificationCenter.default.post(DidChange())
    }

    public func markRead(_ sessionID: String) {
        guard ids.remove(sessionID) != nil else { return }
        UserDefaults.standard.set(Array(ids), forKey: Self.key)
        NotificationCenter.default.post(DidChange())
    }
}
