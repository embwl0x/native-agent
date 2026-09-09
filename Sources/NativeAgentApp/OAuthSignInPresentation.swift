import Foundation

/// The persisted-credential outcome shown by every OAuth sign-in control.
/// It is intentionally derived from the same root-aware read as the runtime,
/// rather than from a mounted SwiftUI control or an optimistic write result.
enum OAuthSignInPresentation {
    enum State: Equatable {
        case idle
        case running
        case complete
    }

    struct Status: Equatable {
        let state: State
        let detail: String?
        let error: String?
    }

    struct ButtonControl: Equatable {
        let title: String
        let isDisabled: Bool
        var showsCancel: Bool = false
        var guidance: String? = nil
    }

    static func status(providerID: String, dataRoot: URL) -> Status {
        if providerID == "anthropic_oauth_direct" {
            switch NativeOAuthFlow.anthropicOAuthCredentialState(dataRoot: dataRoot) {
            case .missing:
                return Status(state: .idle, detail: nil, error: nil)
            case .unavailable(let detail):
                return Status(
                    state: .idle,
                    detail: nil,
                    error: "Anthropic OAuth credentials unavailable: \(detail)"
                )
            case .ready:
                break
            }
        }

        guard NativeOAuthFlow.isSignedIn(providerId: providerID, dataRoot: dataRoot) else {
            return Status(state: .idle, detail: nil, error: nil)
        }
        return Status(
            state: .complete,
            detail: NativeOAuthFlow.signInStatusDetail(providerId: providerID, dataRoot: dataRoot)
                ?? "Signed in",
            error: nil
        )
    }

    static func buttonControl(providerDisplayShort: String, state: State) -> ButtonControl {
        switch state {
        case .running:
            return ButtonControl(
                title: "Signing in…", isDisabled: true,
                showsCancel: true, guidance: "Finish signing in in your browser"
            )
        case .complete:
            return ButtonControl(
                title: "Re-authenticate \(providerDisplayShort)",
                isDisabled: false
            )
        case .idle:
            return ButtonControl(title: "Sign in with \(providerDisplayShort)", isDisabled: false)
        }
    }
}
