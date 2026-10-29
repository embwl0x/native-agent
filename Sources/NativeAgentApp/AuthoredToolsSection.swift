import SwiftUI
import AppKit
import ChatToolRuntime
import ToolRegistry
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter

// Blueprint: | `AuthoredToolsSection.swift` | Authored tool lifecycle labels, controls and confirmation through AppModel commands |
/// Values consumed by the mounted authored-tool controls.
enum AuthoredToolPresentation {
    static func canQuarantine(_ tool: ToolRecord) -> Bool { tool.status != "disabled" }
    /// Authored rows are durable registry records, not live dispatcher
    /// receipts. Keep their distinct lifecycle labels explicit rather than
    /// borrowing the catalog's availability wording.
    static func statusBadge(for tool: ToolRecord) -> (title: String, systemImage: String, tone: ToolCatalogStatus.Tone) {
        let status = tool.status
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch status {
        case "active":
            return (title: "active", systemImage: "circle.fill", tone: .positive)
        case "draft":
            return (title: "draft", systemImage: "clock", tone: .warning)
        case "proposed":
            return (title: "proposed", systemImage: "clock", tone: .warning)
        case "disabled":
            return (title: "off", systemImage: "pause.circle", tone: .warning)
        default:
            return (title: "status unavailable", systemImage: "questionmark.circle", tone: .warning)
        }
    }
}
internal struct AuthoredToolsSection: View {
    let tools: [ToolRecord]
    let appModel: AppModel
    @State private var quarantineCandidate: ToolRecord?
    var body: some View {
        AdvancedSection(title: "Tools I wrote", card: .single) {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(tools) { tool in
                    authoredRow(tool)
                }
            }
        }
        .confirmationDialog(
            "Turn off \(quarantineCandidate?.name ?? "tool")?",
            isPresented: Binding(
                get: { quarantineCandidate != nil },
                set: { if !$0 { quarantineCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Turn off", role: .destructive) {
                guard let tool = quarantineCandidate else { return }
                quarantineCandidate = nil
                Task { await appModel.quarantineTool(tool) }
            }
            Button("Cancel", role: .cancel) { quarantineCandidate = nil }
        } message: {
            Text("The tool will stop being available to \(appModel.agentDisplayName) until you turn it back on.")
        }
    }
    @ViewBuilder
    private func authoredRow(_ tool: ToolRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(tool.name)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Spacer(minLength: 8)
                let badge = AuthoredToolPresentation.statusBadge(for: tool)
                Text(badge.title)
                    .font(ShellType.captionSemibold)
                    .foregroundStyle(ToolsStatusTone.color(badge.tone))
            }
            Text(tool.description)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !tool.triggers.isEmpty {
                Text(tool.triggers.joined(separator: ", "))
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if tool.autoCreated == true {
                    Text("Written by me")
                }
                if tool.autoRun == true {
                    Text("Legacy auto-run flag (unused)")
                }
                Text(tool.validationStatus ?? "untested")
                Text("Used \(tool.useCount ?? 0) times")
            }
            .font(ShellType.caption)
            .foregroundStyle(NativeAgentShell.secondary)
            if let evidence = try? JSONValue.object(tool.fields.filter { ["validation_evidence", "candidate_validation_evidence", "learned"].contains($0.key) }).serialize(pretty: true) {
                DisclosureGroup("Evidence and learned use") {
                    Text(evidence).font(ShellType.code).textSelection(.enabled)
                }
            }
            if let permissions = tool.permissions, !permissions.isEmpty {
                Text("Permissions: \(permissions.joined(separator: ", "))")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let errors = tool.validationErrors, !errors.isEmpty {
                Text(errors.joined(separator: " "))
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let path = tool.activePath ?? tool.proposalPath {
                Text(UserDisplayFormatters.tildifyPath(path))
                    .font(ShellType.code)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let review = ToolApprovalPresentation.review(for: tool),
               case .string(let version)? = review["version"],
               case .string(let code)? = review["code"],
               let reach = try? review["reach"]?.serialize(pretty: true) {
                Text(tool.candidateDigest == nil ? "Version to turn on" : "Waiting version").font(ShellType.labelSemibold)
                if case .string(let description)? = review["description"] {
                    Text(description).font(ShellType.label).textSelection(.enabled)
                }
                Text("Version: \(version)").font(ShellType.code).textSelection(.enabled)
                Text("Reach: \(reach)").font(ShellType.code).textSelection(.enabled)
                DisclosureGroup("Code") {
                    Text(code).font(ShellType.code).textSelection(.enabled)
                }
                if let declarations = try? JSONValue.object(review.filter { !["code", "description", "reach", "version"].contains($0.key) }).serialize(pretty: true) {
                    DisclosureGroup("Declarations and fixtures") {
                        Text(declarations).font(ShellType.code).textSelection(.enabled)
                    }
                }
            }
            HStack(spacing: 8) {
                if tool.status != "active" || tool.candidateDigest != nil {
                    let approval = ToolApprovalPresentation.control(for: tool, keepRefusal: appModel.engine.tools.keepRefusal(tool))
                    Button("Approve") {
                        Task { await appModel.promoteTool(tool) }
                    }
                    .disabled(!approval.isEnabled)
                    .accessibilityIdentifier(approval.accessibilityIdentifier)
                    .help(approval.help)
                    if let refusal = approval.refusal {
                        Text(refusal)
                            .font(ShellType.caption)
                            .foregroundStyle(NativeAgentShell.secondary)
                    }
                }
                Button("Turn off") {
                    quarantineCandidate = tool
                }
                .disabled(!AuthoredToolPresentation.canQuarantine(tool))
            }
            .buttonStyle(.borderless)
            .font(ShellType.label)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
