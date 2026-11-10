import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `ComposerContextReceipt.swift` | Shared receipt rows and demand-read context disclosure from the body |

struct ComposerContextReceiptBody: View {
    let receipt: ContextReceiptFace?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch receipt?.state {
            case .ready?:
                if let receipt {
                    summary(receipt)
                    composition(receipt)
                    partRows(receipt)
                    footer(receipt)
                }
            case .noTurn?, .outsideSearch?:
                if let receipt {
                    ForEach(receipt.rows) { row in Text(row.title).fixedSize(horizontal: false, vertical: true) }
                }
            case .unavailable(let failure)?: Text(failure.localizedDescription).textSelection(.enabled)
            case .waiting(let on)?: Text("Waiting on " + on + "…")
            case nil: Text("Waiting on the last turn's context…")
            }
        }
        .font(ShellType.label)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("chat.composer.context.card")
        .accessibilityLabel("Context receipt")
    }

    private func summary(_ receipt: ContextReceiptFace) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last request").font(ShellType.caption).foregroundStyle(NativeAgentShell.secondary)
            HStack(alignment: .firstTextBaseline) {
                if let total = receipt.totalTokens {
                    (Text(exact(total)).font(ShellType.title) + Text(" tokens").font(ShellType.label))
                        .monospacedDigit()
                } else {
                    Text("Token count unknown").font(ShellType.labelSemibold)
                }
                Spacer(minLength: 8)
                if let total = receipt.totalTokens, let window = receipt.windowTokens, window > 0 {
                    Text(share(total, of: window)).font(ShellType.labelSemibold).monospacedDigit()
                }
            }
            if let window = receipt.windowTokens, window > 0 {
                Text("of \(exact(window)) tokens in the selected model's window")
                    .font(ShellType.caption).foregroundStyle(NativeAgentShell.secondary)
            } else {
                Text("Window size unknown").font(ShellType.caption).foregroundStyle(NativeAgentShell.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func composition(_ receipt: ContextReceiptFace) -> some View {
        if let total = receipt.totalTokens, let window = receipt.windowTokens, window > 0 {
            let parts = tokenParts(receipt)
            let complete = parts.allSatisfy { $0.tokens != nil }
            let scale = max(total, window)
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(NativeAgentShell.softFill)
                        if complete {
                            HStack(spacing: 0) {
                                ForEach(parts) { part in
                                    if let tokens = part.tokens {
                                        Rectangle().fill(color(part.id))
                                            .frame(width: geometry.size.width * Double(tokens) / Double(scale))
                                    }
                                }
                            }
                        } else {
                            Capsule().fill(NativeAgentShell.secondary.opacity(0.4))
                                .frame(width: geometry.size.width * Double(total) / Double(scale))
                        }
                    }
                    .clipShape(Capsule())
                    if total > window {
                        Rectangle().fill(NativeAgentShell.text).frame(width: 1, height: 14)
                            .offset(x: geometry.size.width * Double(window) / Double(scale), y: -2)
                    }
                }
                .frame(height: 10)
                .accessibilityHidden(true)
                Text(complete ? "≈ Part sizes estimated from the opening request; tool-round growth is measured."
                              : "Part token sizes unavailable; the bar shows the provider total.")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if total > window {
                    Text("The marker shows the model window; this request exceeds it.")
                        .font(ShellType.caption).foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func partRows(_ receipt: ContextReceiptFace) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    Text("Input")
                    Text("Tokens").gridColumnAlignment(.trailing)
                    Text("Share").gridColumnAlignment(.trailing).help("Share of the last request")
                }
                .font(ShellType.caption)
                .foregroundStyle(NativeAgentShell.secondary)
                ForEach(tokenParts(receipt)) { part in
                    GridRow(alignment: .firstTextBaseline) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(color(part.id))
                                .frame(width: 8, height: 8).accessibilityHidden(true)
                            Text(part.name).fixedSize(horizontal: false, vertical: true)
                        }
                        Text(tokenLabel(part))
                            .monospacedDigit().fixedSize()
                        Text(partShare(part, total: receipt.totalTokens))
                            .monospacedDigit().fixedSize().foregroundStyle(NativeAgentShell.secondary)
                    }
                    .help(part.detail ?? part.name)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(part.name + ", " + tokenLabel(part) + " tokens, "
                        + partShare(part, total: receipt.totalTokens) + " of the last request")
                }
            }
            ForEach(receipt.parts.filter { $0.id == .memory && $0.tokens == nil }) { part in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(part.name)
                    Spacer(minLength: 8)
                    if let count = part.count {
                        Text(count == 1 ? "1 memory" : "\(exact(count)) memories").monospacedDigit()
                    } else {
                        Text(part.detail ?? "Count unknown").foregroundStyle(NativeAgentShell.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .help(part.detail ?? part.name)
            }
        }
    }

    private func footer(_ receipt: ContextReceiptFace) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let model = receipt.model { Text(model) }
            if receipt.model != nil, receipt.ranAt != nil { Text("·") }
            if let ranAt = receipt.ranAt { Text(ranAt, format: .relative(presentation: .named)) }
        }
        .font(ShellType.caption)
        .foregroundStyle(NativeAgentShell.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tokenParts(_ receipt: ContextReceiptFace) -> [ContextReceiptFace.Part] {
        receipt.parts.filter { $0.id != .memory || $0.tokens != nil }
    }

    private func tokenLabel(_ part: ContextReceiptFace.Part) -> String {
        guard let tokens = part.tokens else { return "Unknown" }
        return (part.measurement == .estimated ? "≈ " : "") + exact(tokens)
    }

    private func partShare(_ part: ContextReceiptFace.Part, total: Int?) -> String {
        guard let tokens = part.tokens, let total, total > 0 else { return "—" }
        return share(tokens, of: total)
    }

    private func exact(_ count: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
    }

    private func share(_ tokens: Int, of total: Int) -> String {
        let percent = Double(tokens) / Double(total) * 100
        if tokens > 0, percent < 0.1 { return "<0.1%" }
        return String(format: percent > 0 && percent < 10 ? "%.1f%%" : "%.0f%%", percent)
    }

    private func color(_ id: ContextReceiptFace.Part.ID) -> Color {
        let color: Color = switch id {
        case .system: .indigo
        case .fed: .purple
        case .memory: .green
        case .tools: .brown
        case .history: .blue
        case .message: .orange
        case .images: .pink
        case .toolRounds: .gray
        }
        return color.opacity(0.75)
    }
}

struct ComposerContextReceiptCard: View {
    let sessionId: String
    let shell: ComposerShellState
    @Environment(AppModel.self) private var appModel
    @State private var disclosed = false
    private var receipt: ContextReceiptFace? {
        appModel.face.slot(.contextReceipt(session: sessionId)).value(as: ContextReceiptFace.self)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ComposerContextReceiptBody(receipt: receipt)
            if let state = receipt?.state, state == .ready || state == .noTurn || state == .outsideSearch {
                Button(disclosed ? "Hide what I was given" : "Show what I was given") { disclosed.toggle() }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.composer.context.fed.toggle")
                if disclosed {
                    FaceDocumentReader(identity: [sessionId, receipt?.turnId], presentation: { _ in
                        try await appModel.documentPresentation(.context(session: sessionId))
                    }).frame(height: 300)
                }
            }
        }
        .modifier(FaceObservation(demand: sessionId.isEmpty ? nil : .key(.contextReceipt(session: sessionId))))
        .onChange(of: sessionId, initial: true) { _, session in shell.bindContext(session: session, appModel: appModel) }
    }
}
