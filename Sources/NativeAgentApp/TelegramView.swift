import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScreenVision
import Speech
import AVFoundation
import UniformTypeIdentifiers
import NativeAgentShared
import MemoryV2
import PersistenceCore
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
#endif

struct TelegramView: View {
    @Environment(AppModel.self) private var appModel
    @State private var showDisconnectConfirm = false

    private var allowlistConfigured: Bool {
        !appModel.telegramAllowedChats.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !appModel.telegramAllowedUsers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var telegramModelOptions: [ModelCatalogItem] {
        modelOptions(from: appModel.modelCatalog, current: appModel.telegramModel, limit: 40)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            NativePanel(title: "Telegram Status", systemImage: "paperplane", tint: appModel.telegramTokenConfigured ? .green : .orange) {
                Label(
                    appModel.telegramTokenConfigured ? "Bot token configured" : "Bot token missing",
                    systemImage: appModel.telegramTokenConfigured ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(appModel.telegramTokenConfigured ? .green : .orange)

                Label(
                    allowlistConfigured ? "Allowlist configured" : "Add at least one allowed chat or user ID",
                    systemImage: allowlistConfigured ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.exclamationmark"
                )
                .foregroundStyle(allowlistConfigured ? .green : .orange)

                if let status = appModel.telegramStatus {
                    LabeledContent("Poller", value: status.pollerEnabled ? "Running" : "Disabled")
                    LabeledContent("Last update", value: status.lastSeenUpdateId.map(String.init) ?? "None")
                    LabeledContent("Last reply", value: status.lastReplyAt.map(UserDisplayFormatters.humanizeISOTimestamp) ?? "None")
                    if let voice = status.voiceTranscription {
                        LabeledContent("Voice", value: voice.enabled ? "\(voice.model) via \(voice.backend)" : "Disabled")
                        if voice.enabled && !voice.backendSupported {
                            Text("Voice backend \(voice.backend) is not supported by the Swift Telegram runtime.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        } else if voice.enabled && voice.requiresAPIKey == true && !voice.keyConfigured {
                            Text("Voice transcription needs an OpenAI platform key.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                    }
                    if status.isTransientPollInterruption {
                        Text("The poller is active and retrying after a transient interruption.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else if let error = status.actionableError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }

            NativePanel(title: "Bot", systemImage: "key", tint: appModel.telegramTokenConfigured ? .green : .secondary) {
                SecureField("Bot token", text: Bindable(appModel).telegramToken)
                    .textFieldStyle(.roundedBorder)
                Text(appModel.telegramTokenConfigured ? "Paste a new token only when replacing the saved bot token. The field clears after saving." : "Paste a BotFather token here. The field clears after saving.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if appModel.telegramTokenConfigured {
                    Button("Disconnect Telegram", systemImage: "xmark.circle") {
                        showDisconnectConfirm = true
                    }
                    .disabled(appModel.isSavingTelegram)
                }
            }

            NativePanel(title: "Authorization", systemImage: "person.crop.circle.badge.checkmark") {
                Toggle("Telegram enabled", isOn: Bindable(appModel).telegramEnabled)
                TextField("Allowed chat IDs", text: Bindable(appModel).telegramAllowedChats)
                    .textFieldStyle(.roundedBorder)
                TextField("Allowed user IDs", text: Bindable(appModel).telegramAllowedUsers)
                    .textFieldStyle(.roundedBorder)
                Toggle("Require mention in groups", isOn: Bindable(appModel).telegramRequireMention)
            }

            NativePanel(title: "Brain", systemImage: "brain") {
                Picker("Model", selection: Bindable(appModel).telegramModel) {
                    ForEach(telegramModelOptions) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                TextField("Custom model ID", text: Bindable(appModel).telegramModel)
                    .textFieldStyle(.roundedBorder)
                Text("The picker stays compact for responsiveness; paste any provider model ID here if it is not listed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Think level", selection: Bindable(appModel).telegramReasoningEffort) {
                    ForEach(reasoningOptions(from: appModel.modelCatalog, model: appModel.telegramModel)) { effort in
                        Text(effort.label).tag(effort.id)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent("Telegram commands", value: "/model, /think, /fast, /brain")
            }

            NativePanel(title: "Actions", systemImage: "slider.horizontal.3") {
                HStack {
                    Button {
                        Task { await appModel.saveTelegram() }
                    } label: {
                        if appModel.isSavingTelegram {
                            Label("Saving Telegram Settings", systemImage: "hourglass")
                        } else {
                            Label("Save Telegram Settings", systemImage: "paperplane")
                        }
                    }
                    .disabled(appModel.isSavingTelegram)

                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await appModel.refreshTelegram() }
                    }
                    Button("Clear Logs", systemImage: "trash") {
                        Task { await appModel.clearTelegramLogs() }
                    }
                    Button {
                        Task { await appModel.testTelegram() }
                    } label: {
                        if appModel.isTestingTelegram {
                            Label("Sending Test", systemImage: "hourglass")
                        } else {
                            Label("Test Reply", systemImage: "paperplane.circle")
                        }
                    }
                    .disabled(appModel.isTestingTelegram || !appModel.telegramTokenConfigured || !allowlistConfigured)
                }
                .buttonStyle(.bordered)
            }

            if let status = appModel.telegramStatus {
                NativePanel(title: "Recent Replies", systemImage: "bubble.left.and.bubble.right") {
                    if status.receipts.isEmpty {
                        Text("No reply receipts yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(status.receipts.prefix(6)) { receipt in
                            TelegramEventRow(
                                title: "\(receipt.kind ?? "reply") · chat \(receipt.chatId ?? "?")",
                                detail: [receipt.replyPreview ?? receipt.textPreview ?? "", receipt.model.map { "\($0) / \(receipt.reasoningEffort ?? "?")" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"),
                                metadata: receipt.at
                            )
                        }
                    }
                }

                NativePanel(title: "Blocked / Ignored", systemImage: "hand.raised") {
                    if status.blocked.isEmpty {
                        Text("No blocked messages")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(status.blocked.prefix(6)) { event in
                            TelegramEventRow(
                                title: "\(event.reason ?? "blocked") · chat \(event.chatId ?? "?")",
                                detail: event.textPreview ?? "",
                                metadata: event.at
                            )
                        }
                    }
                }

                if !status.errors.isEmpty {
                    NativePanel(title: "Recent Errors", systemImage: "exclamationmark.triangle", tint: .red) {
                        ForEach(status.errors.prefix(4)) { event in
                            TelegramEventRow(
                                title: event.context ?? "telegram",
                                detail: event.error,
                                metadata: event.at
                            )
                        }
                    }
                }
            }

            Text(appModel.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            .padding()
        }
        .navigationTitle("Telegram")
        .confirmationDialog(
            "Disconnect Telegram?",
            isPresented: $showDisconnectConfirm,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                Task { await appModel.clearTelegramToken() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved bot token and disables Telegram until new credentials are saved.")
        }
    }
}

struct TelegramEventRow: View {
    var title: String
    var detail: String
    var metadata: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if !detail.isEmpty {
                Text(detail)
                    .lineLimit(2)
            }
            Text(metadata)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
    }
}
