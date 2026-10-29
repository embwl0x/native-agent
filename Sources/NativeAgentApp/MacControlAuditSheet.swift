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
// Blueprint: | `MacControlAuditSheet.swift` | Mac control audit rows, read failures and loading feedback through the existing bindings |
internal struct MacControlAuditSheet: View {
    @Binding var entries: [MacControlAuditEntry]
    @Binding var isLoading: Bool
    @Binding var readProblem: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Mac Control Audit Log")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()
            if isLoading {
                ProgressView("Loading audit log…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    if let readProblem {
                        Label(readProblem, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    if entries.isEmpty {
                        ContentUnavailableView(
                            readProblem == nil ? "No Entries" : "Audit Log Needs Attention",
                            systemImage: readProblem == nil ? "doc.text" : "exclamationmark.triangle",
                            description: Text(readProblem == nil
                                ? "No mac_control_audit.jsonl entries found."
                                : "The audit source could not provide readable entries.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(entries) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(entry.action)
                                        .font(.caption.weight(.semibold))
                                    Spacer()
                                    if let ok = entry.allowed {
                                        Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            .foregroundStyle(ok ? .green : .red)
                                            .font(.caption)
                                    }
                                }
                                Text(entry.ts)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let detail = entry.detail {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .frame(width: 520, height: 400)
    }
}
