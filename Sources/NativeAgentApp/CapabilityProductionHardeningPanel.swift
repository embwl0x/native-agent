import SwiftUI

/// The hardening report is an externalized runtime authority, not a local
/// inference. Keep its missing and unavailable states explicit so an export
/// can be used to diagnose the latter without claiming the former is healthy.
enum CapabilityProductionExportButtonsPresentation {
    struct Notice: Equatable {
        let detail: String
        let status: String
    }

    static func notice(for outcome: ProductionExportCreationOutcome) -> Notice {
        switch outcome {
        case .verified(let export):
            let kind = export.kind?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = kind?.isEmpty == false ? kind!.capitalized : "Export"
            let bytes = export.sizeBytes ?? 0
            return Notice(
                detail: "\(label) created and verified: \(export.path) (\(bytes) bytes).",
                status: "ok"
            )
        case .failed(let support, let detail):
            let label = support ? "Support bundle" : "Export"
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return Notice(
                detail: "\(label) was not verified: \(trimmed.isEmpty ? "no error detail was returned" : trimmed)",
                status: "failed"
            )
        }
    }
}

struct CapabilityProductionHardeningPanel: View {
    @Environment(AppModel.self) private var appModel
    @State private var exportNotice: CapabilityProductionExportButtonsPresentation.Notice?
    @State private var isCreatingExport = false

    var body: some View {
        AdvancedSection(title: "Production hardening") {
            if let hardening = appModel.productionHardening {
                HStack(spacing: 8) {
                    AdvancedStatusWord(status: hardening.status)
                    if let doctor = hardening.doctorStatus?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !doctor.isEmpty {
                        AdvancedStatusWord(status: doctor, text: "Doctor \(doctor)")
                    }
                    Spacer()
                    Button(isCreatingExport ? "Creating export…" : "Export") {
                        Task { await createExport(support: false) }
                    }
                    .controlSize(.small)
                    .disabled(isCreatingExport)
                    .accessibilityIdentifier("capabilities.hardening.export")
                    Button(isCreatingExport ? "Creating bundle…" : "Support bundle") {
                        Task { await createExport(support: true) }
                    }
                    .controlSize(.small)
                    .disabled(isCreatingExport)
                    .accessibilityIdentifier("capabilities.hardening.support-bundle")
                }

                if let detail = hardening.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !detail.isEmpty {
                    Text(detail)
                        .font(ShellType.label)
                        .foregroundStyle(AdvancedStatusWords.color(hardening.status))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("capabilities.hardening.detail")
                }

                if let exportNotice {
                    Text(exportNotice.detail)
                        .font(ShellType.label)
                        .foregroundStyle(AdvancedStatusWords.color(exportNotice.status))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("capabilities.hardening.export-receipt")
                }

                if let latest = appModel.productionExports.first {
                    CapabilityDetailRow(
                        title: (latest.kind ?? "export").capitalized,
                        detail: "\(latest.path) · \(latest.sizeBytes ?? 0) bytes",
                        status: "ok"
                    )
                }

                if let release = hardening.release {
                    VStack(alignment: .leading, spacing: 12) {
                        if !release.status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            AdvancedStatusWord(
                                status: release.status,
                                text: "Release: \(AdvancedStatusWords.label(release.status))"
                            )
                        }
                        if release.items.isEmpty {
                            Text("The release checklist has no recorded checks.")
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                        } else {
                            ForEach(release.items.prefix(8)) { item in
                                CapabilityDetailRow(
                                    title: item.title,
                                    detail: item.detail,
                                    status: item.status
                                )
                            }
                        }
                    }
                } else {
                    Text("This report did not include a release checklist.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
            } else {
                Text("Production summary has not loaded yet.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
        }
        .accessibilityIdentifier("capabilities.production-hardening")
    }

    @MainActor
    private func createExport(support: Bool) async {
        guard !isCreatingExport else { return }
        isCreatingExport = true
        defer { isCreatingExport = false }
        exportNotice = CapabilityProductionExportButtonsPresentation.notice(
            for: await appModel.createProductionExport(support: support)
        )
    }
}
