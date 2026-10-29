import Foundation
import Observation
@_exported import NativeAgentShared
import Connectors
import DeviceSync
import PersistenceCore
import NativeAgentCore
import ProviderRouting
import CloudKit
import DoctorChecks
import MemoryV2
import StandingBots
import Cognition
import ChatToolRuntime
import ChatTurnRuntime
import ChatSessionWork
import ChatToolParsing
import SlackBot
import TelegramBot
import TriggerScheduler
import WorkshopExecution
import BackgroundLoops
import AppToolRuntime
import TrustCenter
import MacControl
import ApprovalTransactions
import AttentionRouting
import ApprovalInbox
import Desk
import NotificationInbox
import ToolRegistry
import Transcripts
import ChatTurnContracts
import BackgroundWork
import DreamREMCycle
import AuthoredCapabilities
@preconcurrency import EventKit
import MacIntegration
import ToolExecution
import Senses
import Browser
import PersonaEngine
import AgentWorkspace
import Synchronization
import Studio
import Agents
import AgentConversations
import ChromeControl
import CognitiveSubstrate
import Context
import ContextFlow
import TurnTrace
import os
import TrustPersistence
import SwarmRuns
import Onboarding
import Privacy
import Experiences
import CryptoKit
import ActivityWatch
import OSLog
import Procedures
import SchedulerExecution
import Darwin
import Combine
import UserNotifications
import Research
import ImageIO
import UniformTypeIdentifiers
import AppKit
import Dispatcher
import SystemOps
import CoreGraphics
// Blueprint: | `ConversationAttention.swift` | `MacChatUnreadSessions`: phone activity remains unread until its conversation opens; persisted unread IDs exclude the active conversation |

/// Phone activity in a background chat stays unread until that chat opens.
@MainActor @Observable
public final class MacChatUnreadSessions {
    public static let shared = MacChatUnreadSessions()
    private static let key = "NativeAgent.unreadPhoneChatSessions"
    public private(set) var ids = Set(UserDefaults.standard.stringArray(forKey: MacChatUnreadSessions.key) ?? [])

    public func received(in sessionID: String) {
        guard sessionID != UserDefaults.standard.string(forKey: "activeChatSessionId") else { return }
        ids.insert(sessionID)
        UserDefaults.standard.set(Array(ids), forKey: Self.key)
    }

    public func markRead(_ sessionID: String) {
        guard ids.remove(sessionID) != nil else { return }
        UserDefaults.standard.set(Array(ids), forKey: Self.key)
    }
}
