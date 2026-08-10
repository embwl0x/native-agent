import SwiftUI
import PersistenceCore

struct NativeExperienceContextPage: View {
    @Environment(AppModel.self) private var appModel
    let showDiagnostics: Bool
    @State private var events: [TurnTraceEvent] = []
    @State private var live: [ExperienceDiagnosticEvent] = []
    @State private var filter: ExperienceDiagnosticKind?

    var body: some View {
        NativeExperiencePage(
            title: "Context Economics",
            subtitle: "See what entered the prompt, what was omitted, the provider route, cache behavior, and cost—without entering or rebuilding Fluid Context."
        ) {
            NativeExperienceCard(title: "Latest turn", icon: "gauge.with.dots.needle.67percent") {
                let value = economics
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    row("Provider / model", [value.provider, value.model].compactMap { $0 }.joined(separator: " · ").ifEmpty("Unknown"))
                    row("Input / output", "\(formatted(value.inputTokens)) / \(formatted(value.outputTokens)) tokens")
                    row("Cache", "read \(formatted(value.cacheReadTokens)) · write \(formatted(value.cacheWriteTokens))")
                    row("Estimated cost", value.estimatedCostUSD.map { $0.formatted(.currency(code: "USD").precision(.fractionLength(4))) } ?? "Pricing unavailable")
                    row("Context", "\(formatted(value.contextCharacters)) of \(formatted(value.contextBudget)) characters")
                    row("Tool schemas", "\(formatted(value.toolSchemaCount)) · \(formatted(value.toolSchemaBytes)) bytes")
                    row("Selected", "\(value.selectedMemoryCount) memories · \(value.selectedSkillCount) skills · \(value.selectedToolCount) tools")
                }
                if value.sources.isEmpty {
                    Text("Send a chat turn to create a context receipt.").foregroundStyle(.secondary)
                } else {
                    Divider()
                    ForEach(value.sources) { source in
                        HStack {
                            Label(source.title, systemImage: "doc.text")
                            Spacer()
                            Text("\(source.characters.formatted()) chars")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                if !value.omittedReasons.isEmpty {
                    DisclosureGroup("Omissions and budget decisions") {
                        ForEach(value.omittedReasons, id: \.self) { Text($0).font(.caption) }
                    }
                }
                Button("Open canonical Turn Inspector") {
                    NativeAgentAppCoordinator.shared.request(.sidebar(.inspector))
                }
            }

            if showDiagnostics {
                NativeExperienceCard(title: "Read-only diagnostic observer", icon: "waveform.path.ecg.rectangle") {
                    HStack {
                        Picker("Kind", selection: $filter) {
                            Text("All").tag(ExperienceDiagnosticKind?.none)
                            ForEach(ExperienceDiagnosticKind.allCases, id: \.self) { kind in
                                Text(kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .tag(Optional(kind))
                            }
                        }
                        .pickerStyle(.menu).frame(maxWidth: 220)
                        Spacer()
                        Text("\(visibleDiagnostics.count) bounded events").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(visibleDiagnostics.prefix(80)) { event in
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(color(event.status)).frame(width: 7, height: 7).padding(.top, 6)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(event.title).font(.callout.weight(.medium))
                                    Text(event.phase).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(event.date, style: .time).font(.caption2).foregroundStyle(.tertiary)
                                }
                                Text("\(event.sourceKind) · turn \(compact(event.turnId))")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                    }
                    Text("Observer access is projection-only: no prompts, tool arguments, approvals, or dispatch controls.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .task {
            events = NativeExperienceReadModels.recentTurnEvents()
            guard showDiagnostics else { return }
            let subscription = await NativeDiagnosticObserver.shared.subscribe()
            for await event in subscription.stream {
                live.insert(event, at: 0)
                if live.count > 256 { live.removeLast(live.count - 256) }
            }
        }
    }

    private var economics: ExperienceContextEconomics {
        .project(receipt: appModel.latestContextReceipt, sessionId: appModel.activeChatSessionId,
                 events: events, providers: appModel.providersList)
    }

    private var visibleDiagnostics: [ExperienceDiagnosticEvent] {
        let historical = NativeExperienceReadModels.diagnosticEvents(from: events)
        let all = live + historical
        return filter.map { selected in all.filter { $0.kind == selected } } ?? all
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundStyle(.secondary); Text(value).textSelection(.enabled) }
    }
    private func formatted(_ value: Int?) -> String { value?.formatted() ?? "—" }
    private func compact(_ value: String) -> String { value.count > 12 ? "\(value.prefix(8))…" : value }
    private func color(_ status: String) -> Color {
        let value = status.lowercased()
        if value.contains("fail") || value.contains("error") || value.contains("denied") { return .red }
        if value.contains("warn") || value.contains("degrad") { return .orange }
        return .green
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
