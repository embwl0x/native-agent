import SwiftUI
import Foundation
import NativeAgentShared
import EngineRuntime
import SwarmRuns
import Agents
import ChatSessionWork
import AgentWorkspace
import NativeAgentCore
import PersistenceCore
import StandingBots
import ProviderRouting
import AppKit
import AppToolRuntime
// Blueprint: | `ProviderCards.swift` | Shared provider cards, notes, titles and account status words |

struct ProviderCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .settingsCardSurface()
    }
}

struct ProviderCardTitle: View {
    let title: String
    let line: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(ShellType.bodySemibold)
                .foregroundStyle(NativeAgentShell.text)
            Text(line)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProviderNote: View {
    let text: String
    var color: Color = NativeAgentShell.secondary

    var body: some View {
        Text(text)
            .font(ShellType.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

struct ProviderStatusWord: View {
    let text: String
    let kind: String

    var body: some View {
        Text(text)
            .font(ShellType.captionSemibold)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    /// Unconfigured accounts need Set up rather than a status claim.
    static func word(for state: String) -> (text: String, kind: String)? {
        switch state {
        case "ready": ("Ready", "ok")
        case "saved": ("Saved, not yet checked", "warn")
        case "failed": ("Could not check", "warn")
        case "rejected": ("Key rejected", "error")
        default: nil
        }
    }

    private var color: Color {
        switch kind {
        case "ok": NativeAgentShell.calm
        // Words distinguish warnings from failures without adding competing colours.
        case "warn", "error": NativeAgentShell.trouble
        default: NativeAgentShell.secondary
        }
    }
}
