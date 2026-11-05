import Foundation
import SwiftUI
import NativeAgentShared
import NativeAgentCore
import EngineRuntime
import Transcripts
import TurnTrace
import ChatTurnRuntime
import ChatSessionWork
import ToolExecution
import MemoryV2
import AppToolRuntime
import ApprovalTransactions
import PersistenceCore
import ToolRegistry
import ProviderRouting
import DoctorChecks
import Research
import TelegramBot
import Connectors
import AttentionRouting
import WidgetKit
import AppIntents
import Observation
import BackgroundLoops
import PersonaEngine
import TrustCenter
import MultimodalTTS
import SystemOps
import DeviceSync
import BackgroundWork
import ChatToolRuntime
import StandingBots
import ApprovalInbox
import AppKit
import MacControl
import ChatToolParsing
import UniformTypeIdentifiers
import Desk
// Blueprint: | `MessageBubbleActions.swift` | Bubble hover controls, canonical message JSON sheet and advanced text editor |

struct BubbleHoverBar: View {
    var message: ChatMessage
    var isLastAssistant: Bool
    var onCopy: () -> Void
    var onRegenerate: () -> Void
    var onReadAloud: () -> Void

    private var isAssistant: Bool { message.role == "assistant" }

    var body: some View {
        HStack(spacing: NativeAgentSpacing.xs) {
            BubbleAction(icon: "doc.on.doc", help: "Copy text", action: onCopy)

            if isAssistant && isLastAssistant {
                BubbleAction(icon: "arrow.clockwise", help: "Regenerate", action: onRegenerate)
            }

            if isAssistant {
                BubbleAction(icon: "speaker.wave.2", help: "Read aloud", action: onReadAloud)
            }
        }
        .padding(.horizontal, NativeAgentSpacing.sm)
        .padding(.vertical, 4)
        .houseSurface(in: RoundedRectangle(cornerRadius: NativeAgentRadius.control))
    }
}

private struct BubbleAction: View {
    var icon: String
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(NativeAgentFont.tag)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

enum ChatMessageDebugJSON {
    static func text(for message: ChatMessage) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(message)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return string
    }
}

struct MessageJSONSheet: View {
    let message: ChatMessage
    @Environment(\.dismiss) private var dismiss

    @State private var jsonText = ""
    @State private var encodingError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Message data")
                    .font(NativeAgentFont.section)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            ScrollView {
                Text(encodingError.map { "Message data unavailable: \($0). Resolve the encoding problem before inspecting this message again." } ?? jsonText)
                    .font(NativeAgentFont.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .padding(NativeAgentSpacing.xl)
        .frame(width: 540, height: 420)
        .houseSheet()
        .task(id: message) {
            let result = await Task.detached(priority: .userInitiated) { [message] in
                Result { try ChatMessageDebugJSON.text(for: message) }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let text): jsonText = text; encodingError = nil
            case .failure(let error): jsonText = ""; encodingError = error.localizedDescription
            }
        }
    }
}

struct AdvancedTextEditor: View {
    var title: String
    @Binding var text: String
    var minHeight: CGFloat = 82
    var isReadOnly: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .disabled(isReadOnly)
                .frame(minHeight: minHeight, maxHeight: minHeight + 44)
                .scrollContentBackground(.hidden)
                .padding(6)
        }
    }
}
