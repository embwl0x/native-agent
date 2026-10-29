import MacIntegration
import NativeAgentCore
import AppToolRuntime
import ChatToolParsing
import PersistenceCore
import AppKit
import MacControl
import NativeAgentShared
import SwiftUI
import TrustCenter
// Blueprint: | `MacControlWorkbenchView.swift` | Concrete Mac control workbench, retained drafts, action commands and result feedback |
private enum MacControlWorkbenchMode: String, CaseIterable, Identifiable {
    case shell = "Shell"
    case files = "Files"
    case notification = "Notify"
    var id: String { rawValue }
}
struct MacControlWorkbenchView: View {
    private struct Draft: Equatable {
        var shellCommand = "pwd"
        var shellCWD = NSHomeDirectory()
        var filePath = NSHomeDirectory()
        var fileContent = ""
        var fileAppend = false
        var notificationTitle = "NativeAgent"
        var notificationMessage = "Mac Control workbench test"
    }
    @Environment(AppModel.self) private var appModel
    var policy: MacControlPolicyWireSnapshot
    var policySaved: Bool = true
    @State private var mode: MacControlWorkbenchMode = .shell
    private var draftSubject: String { "mac-control/workbench/\(mode.rawValue)" }
    private var input: Binding<Draft> { appModel.editBinding(draftSubject, seed: Draft()) }
    @State private var isRunning = false
    @State private var resultTitle = "Idle"
    @State private var resultBody = "Try an action to see its results, any errors, and whether it needs your approval."
    var body: some View {
        // Alive glass: an eyebrow over one group card — the notes, the action
        // and its inputs, then the result, each a row.
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            AliveEyebrow("Workbench")
            AliveGroupCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Try one Mac control action by hand and see what happens. Shortcuts and system actions are not in this version.")
                    .font(ShellType.rowDetail)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !policySaved {
                    // Waiting on him (an unsaved edit), so teal, not trouble.
                    Label("Save your Mac control settings before trying an action.", systemImage: "lock.fill")
                        .font(ShellType.rowDetail)
                        .foregroundStyle(NativeAgentShell.needsYou)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Picker("Action", selection: $mode) {
                    ForEach(MacControlWorkbenchMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .hazeTinted(.segments)
                switch mode {
                case .shell:
                    let availability = MacControlWorkbenchAction.shell.availability(
                        policy: policy,
                        policySaved: policySaved,
                        hasRequiredInput: !input.wrappedValue.shellCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    TextField("Working directory", text: input.shellCWD)
                        .textFieldStyle(.roundedBorder)
                    TextField("Command", text: input.shellCommand, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                    workbenchButton(.shell, availability: availability) {
                        await run(action: .shell, body: [
                            "command": .string(input.wrappedValue.shellCommand),
                            "cwd": .string(input.wrappedValue.shellCWD),
                            "timeout": .int(60),
                            "trigger": .string("user")
                        ])
                    }
                    availabilityHint(availability)
                case .files:
                    let readAvailability = MacControlWorkbenchAction.fileRead.availability(
                        policy: policy,
                        policySaved: policySaved,
                        hasRequiredInput: !input.wrappedValue.filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    let writeAvailability = MacControlWorkbenchAction.fileWrite.availability(
                        policy: policy,
                        policySaved: policySaved,
                        hasRequiredInput: !input.wrappedValue.filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !input.wrappedValue.fileContent.isEmpty
                    )
                    TextField("Path", text: input.filePath)
                        .textFieldStyle(.roundedBorder)
                    TextField("Write content", text: input.fileContent, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Append instead of replace", isOn: input.fileAppend)
                        .toggleStyle(.switch)
                        .hazeTinted()
                        .controlSize(.small)
                        .font(ShellType.label)
                    HStack {
                        workbenchButton(.fileRead, availability: readAvailability) {
                            await run(action: .fileRead, body: [
                                "path": .string(input.wrappedValue.filePath),
                                "max_bytes": .int(200_000),
                                "trigger": .string("user")
                            ])
                        }
                        workbenchButton(.fileWrite, availability: writeAvailability) {
                            await run(action: .fileWrite, body: [
                                "path": .string(input.wrappedValue.filePath),
                                "content": .string(input.wrappedValue.fileContent),
                                "append": .bool(input.wrappedValue.fileAppend),
                                "trigger": .string("user")
                            ])
                        }
                    }
                    availabilityHint(readAvailability)
                    if writeAvailability.message != readAvailability.message {
                        availabilityHint(writeAvailability)
                    }
                case .notification:
                    let availability = MacControlWorkbenchAction.notify.availability(
                        policy: policy,
                        policySaved: policySaved,
                        hasRequiredInput: !input.wrappedValue.notificationMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    TextField("Notification title", text: input.notificationTitle)
                        .textFieldStyle(.roundedBorder)
                    TextField("Notification message", text: input.notificationMessage)
                        .textFieldStyle(.roundedBorder)
                    workbenchButton(.notify, availability: availability) {
                        await run(action: .notify, body: [
                            "title": .string(input.wrappedValue.notificationTitle),
                            "message": .string(input.wrappedValue.notificationMessage),
                            "trigger": .string("user")
                        ])
                    }
                    availabilityHint(availability)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: isRunning ? "hourglass" : "terminal")
                        .foregroundStyle(resultColor)
                    Text(resultTitle)
                        .font(ShellType.rowTitle)
                        .foregroundStyle(resultColor)
                    Spacer()
                    if isRunning {
                        ProgressView().controlSize(.small)
                    }
                }
                ScrollView {
                    Text(resultBody)
                        .font(NativeAgentFont.mono)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 90, maxHeight: 180)
                .padding(10)
                .background(NativeAgentShell.softFill, in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous))
            }
            }
        }
        .accessibilityElement(children: .contain)
    }
    /// Failed is trouble; waiting for approval waits on him; the rest is quiet.
    private var resultColor: Color {
        switch resultTitle {
        case "Failed": NativeAgentShell.trouble
        case "Pending Approval": NativeAgentShell.needsYou
        default: NativeAgentShell.secondary
        }
    }
    private func workbenchButton(_ actionTarget: MacControlWorkbenchAction, availability: MacControlWorkbenchAvailability, action: @escaping () async -> Void) -> some View {
        Button(actionTarget.title, systemImage: actionTarget.systemImage) {
            Task { await action() }
        }
        .buttonStyle(.bordered)
        .disabled(!availability.isEnabled || isRunning)
    }
    @ViewBuilder
    private func availabilityHint(_ availability: MacControlWorkbenchAvailability) -> some View {
        if let message = availability.message {
            Label(message, systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(NativeAgentShell.secondary)
        }
    }
    private func run(action: MacControlWorkbenchAction, body: [String: JSONValue]) async {
        let subject = draftSubject
        let submitted = input.wrappedValue
        isRunning = true
        resultTitle = "Running"
        resultBody = action.path
        defer { isRunning = false }
        do {
            let result = try await appModel.macControlRun(action: action, body: body)
            let receipt = result.toJSON()
            resultBody = String(decoding: try receipt.serializedData(pretty: true), as: UTF8.self)
            switch ChatToolOutcome.exactResultClass(receipt) {
            case .succeeded:
                if action != .fileRead,
                   appModel.editDraft(subject, seed: Draft()) == submitted {
                    appModel.clearEditDraft(subject)
                }
                resultTitle = "Done"
            case .unknown:
                resultTitle = "Outcome unconfirmed"
                if result.httpStatus == 202 || result.output.objectValue?["status"] == .string("pending_approval") {
                    resultTitle = "Pending Approval"
                    NotificationCenter.default.post(name: .openApprovalsRequest, object: nil)
                }
            case .failed, .refused, .cancelled, .timeout:
                resultTitle = "Failed"
            }
        } catch {
            resultTitle = "Failed"
            resultBody = error.localizedDescription
        }
    }
}
extension MacControlWorkbenchAction {
    var title: String {
        switch self {
        case .shell: "Run Shell"
        case .fileRead: "Read File"
        case .fileWrite: "Write File"
        case .notify: "Notify"
        }
    }
    var systemImage: String {
        switch self {
        case .shell: "terminal"
        case .fileRead: "doc.text.magnifyingglass"
        case .fileWrite: "square.and.pencil"
        case .notify: "bell"
        }
    }
}
