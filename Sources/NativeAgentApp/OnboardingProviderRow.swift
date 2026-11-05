import NativeAgentShared
import SwiftUI
// Blueprint: | `OnboardingProviderRow.swift` | Onboarding's account setup row; the Providers page is drawn from its face |

struct ProviderRowView: View {
    let provider: ProviderInfo
    let onConfigure: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: providerIcon(provider.provider_id))
                .font(ShellType.body)
                .foregroundStyle(NativeAgentShell.tertiary)
                .frame(width: 24)
            Text(provider.display_name)
                .font(ShellType.bodySemibold)
                .foregroundStyle(NativeAgentShell.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let status = ProviderStatusWord.word(for: provider.auth_status.state) {
                ProviderStatusWord(text: status.text, kind: status.kind)
            }
            Button("Set up", action: onConfigure)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(ShellType.labelMedium)
        }
        .frame(height: 48)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func providerIcon(_ id: String) -> String {
        switch id {
        case "codex": return "sparkles"
        case "anthropic", "anthropic_oauth_direct": return "brain"
        case "xai_oauth_direct": return "sparkles"
        case "openrouter": return "shuffle"
        case "moonshot": return "moon.stars.fill"
        case "kimi-code": return "curlybraces"
        case "openai": return "cpu"
        default: return "server.rack"
        }
    }
}
