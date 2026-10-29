import AppKit
import Foundation
import NativeAgentShared
import MacControl
import NativeAgentCore
import PersistenceCore
import Desk
import StandingBots
import ChatSessionWork
import Transcripts
import ChatToolParsing
import Darwin
// Blueprint: | `WorkspaceMacCall.swift` | Workspace-owned Mac calls refuse reading the agent's own app |

/// Workspace calls refuse the agent's own app pages at execution time.
public enum WorkspaceMacCall {
    public static var active: Bool { AgentWorkspaceArrivals.insideWorkspaceDispatch }

    public static let refusal: JSONValue = .object(["ok": .bool(false), "status": .string("unavailable"), "error": .string("own_app"),
        "detail": .string("That's my own app; home does not read it or its chat. Name another app: mac.look <app>.")])
}
