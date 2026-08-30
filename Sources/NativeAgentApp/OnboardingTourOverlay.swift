// PATCH-2026-05-08: polish-wave — primary sidebar coach-mark onboarding tour
import SwiftUI

// MARK: - Tour Step Model

struct OnboardingTourStep: Identifiable, Sendable {
    let id: Int
    let item: SidebarItem
    let title: String
    let body: String
    let buttonLabel: String
}

let onboardingTourSteps: [OnboardingTourStep] = [
    OnboardingTourStep(
        id: 0,
        item: .chat,
        title: "Chat",
        body: "The main conversation surface. Chat, attach files, and use provider/model controls. Drag sessions from the left session list into the chat area to pin them as tabs.",
        buttonLabel: "Continue"
    ),
    OnboardingTourStep(
        id: 1,
        item: .activity,
        title: "Activity",
        body: "The action inbox. Approvals, proactive cards, memory proposals, and self-improvement items that need review collect here.",
        buttonLabel: "Continue"
    ),
    OnboardingTourStep(
        id: 2,
        item: .memories,
        title: "Memories",
        body: "The long-term memory view. Inspect, correct, delete, and verify what the agent thinks it knows.",
        buttonLabel: "Continue"
    ),
    OnboardingTourStep(
        id: 3,
        item: .skills,
        title: "Skills & Tools",
        body: "One place for learned playbooks and executable tools. Use the switch at the top to move between their separate pages; both stay lazy-loaded until needed.",
        buttonLabel: "Continue"
    ),
    OnboardingTourStep(
        id: 4,
        item: .desk,
        title: "Desk",
        body: "The agent's durable work system. Large projects, dependencies, bridge work, scheduled tasks, research, and verified results stay lined up here.",
        buttonLabel: "Continue"
    ),
    OnboardingTourStep(
        id: 5,
        item: .providers,
        title: "Providers",
        body: "Model and provider setup lives here. Connect accounts, choose active providers, and run provider self-tests.",
        buttonLabel: "Continue"
    ),
    OnboardingTourStep(
        id: 6,
        item: .settings,
        title: "Settings",
        body: "Everything you can adjust. Connect your iPhone, link Telegram, switch to dark appearance, pick the keyboard shortcut that opens the app, choose how long a chat runs before it is shortened, check for updates, and replay this tour.",
        buttonLabel: "Continue"
    ),
    OnboardingTourStep(
        id: 7,
        item: .activity,
        title: "Self-Improvement",
        body: "From Activity, the harness reviews real runs, proposes small fixes, tests them, and records useful receipts. Good lessons become lazy skills or code changes; risky changes still go through review.",
        buttonLabel: "Got it"
    ),
]

// MARK: - Tour interaction state

/// The view-free tour state machine. It owns only in-overlay progress and the
/// exact effect each visible control requests; ContentView remains the owner
/// of persisted overlay visibility.
enum OnboardingTourAction: Equatable, Sendable {
    case advance
    case retreat
    case select(stepID: Int)
    case skip
}

enum OnboardingTourEffect: Equatable, Sendable {
    case none
    case route(SidebarItem)
    case complete
}

struct OnboardingTourState: Equatable, Sendable {
    private(set) var stepIndex = 0
    private(set) var didComplete = false

    var step: OnboardingTourStep { onboardingTourSteps[stepIndex] }
    var isLast: Bool { stepIndex == onboardingTourSteps.count - 1 }
    var route: SidebarItem { step.item }

    /// Applies one visible control action. Completion is idempotent so a
    /// duplicate Skip/Return event cannot ask ContentView to persist a second
    /// presentation transition.
    mutating func apply(_ action: OnboardingTourAction) -> OnboardingTourEffect {
        guard !didComplete else { return .none }
        switch action {
        case .advance:
            guard !isLast else {
                didComplete = true
                return .complete
            }
            stepIndex += 1
            return .route(route)
        case .retreat:
            guard stepIndex > 0 else { return .none }
            stepIndex -= 1
            return .route(route)
        case let .select(stepID):
            guard let index = onboardingTourSteps.firstIndex(where: { $0.id == stepID }) else {
                return .none
            }
            stepIndex = index
            return .route(route)
        case .skip:
            didComplete = true
            return .complete
        }
    }
}

/// All user-visible tour chrome derived from the same state that routes the
/// sidebar. Keeping this projection pure prevents the label, disabled Back
/// state, and action target from drifting into separate SwiftUI branches.
struct OnboardingTourPresentation: Equatable, Sendable {
    let progressText: String
    let title: String
    let sidebarItem: SidebarItem
    let advanceLabel: String
    let backEnabled: Bool

    init(state: OnboardingTourState) {
        progressText = "Step \(state.stepIndex + 1) of \(onboardingTourSteps.count)"
        title = state.step.title
        sidebarItem = state.step.item
        advanceLabel = state.step.buttonLabel
        backEnabled = state.stepIndex > 0
    }
}

// MARK: - Tour Overlay

struct OnboardingTourOverlay: View {
    let onComplete: () -> Void
    let onSelectTab: (SidebarItem) -> Void

    @State private var tour = OnboardingTourState()

    private var step: OnboardingTourStep { tour.step }
    private var presentation: OnboardingTourPresentation { .init(state: tour) }

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { } // absorb taps

            HStack(spacing: NativeAgentSpacing.xl) {
                tabRail

                VStack(spacing: NativeAgentSpacing.xl) {
                    HStack {
                        Text(presentation.progressText)
                            .font(NativeAgentFont.label)
                            .foregroundStyle(.white.opacity(0.62))
                        Spacer()
                        Label(step.item.displayName, systemImage: step.item.systemImage)
                            .font(NativeAgentFont.label)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.14), in: Capsule())
                    }

                    Image(systemName: step.item.systemImage)
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(colors: [NativeAgentBrand.accent, NativeAgentBrand.accentCool], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .accessibilityLabel(step.title)

                    VStack(spacing: NativeAgentSpacing.sm) {
                        Text(step.title)
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)

                        Text(step.body)
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(.white.opacity(0.82))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }

                    HStack(spacing: NativeAgentSpacing.md) {
                        Button("Skip") {
                            completeTour()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.55))
                        .font(.system(.callout, design: .rounded))
                        .accessibilityIdentifier("onboarding-tour.skip")

                        Spacer()

                        Button("Back") {
                            retreat()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!presentation.backEnabled)
                        .accessibilityIdentifier("onboarding-tour.back")

                        Button(presentation.advanceLabel) {
                            advance()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(.blue)
                        .accessibilityIdentifier("onboarding-tour.advance")
                    }
                    .frame(maxWidth: 420)
                }
                .padding(NativeAgentSpacing.xl)
                .background {
                    RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                        }
                }
                .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
                .frame(maxWidth: 520)
            }
            .padding(NativeAgentSpacing.xl)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .id(tour.stepIndex) // force transition on step change
            .animation(.easeInOut(duration: 0.25), value: tour.stepIndex)
        }
        .onAppear { onSelectTab(tour.route) }
        // S.4: mark overlay as accessibility modal so VoiceOver focuses only overlay content
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("onboarding-tour.overlay")
    }

    private var tabRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tour stops")
                .font(NativeAgentFont.label)
                .foregroundStyle(.white.opacity(0.62))
                .padding(.horizontal, 10)

            ForEach(onboardingTourSteps) { tabStep in
                let isSelected = tabStep.id == step.id
                Button {
                    apply(.select(stepID: tabStep.id))
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tabStep.item.systemImage)
                            .frame(width: 18)
                        Text(tabStep.item.displayName)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                    }
                    .font(NativeAgentFont.body)
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.68))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(isSelected ? Color.white.opacity(0.18) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .leading) {
                        if isSelected {
                            Capsule()
                                .fill(Color.blue)
                                .frame(width: 4)
                                .padding(.vertical, 8)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("onboarding-tour.step.\(tabStep.id)")
            }
        }
        .padding(12)
        .frame(width: 230)
        .background {
            RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                }
        }
    }

    private func advance() {
        apply(.advance)
    }

    private func retreat() {
        apply(.retreat)
    }

    private func completeTour() {
        apply(.skip)
    }

    private func apply(_ action: OnboardingTourAction) {
        switch tour.apply(action) {
        case .none:
            break
        case let .route(item):
            onSelectTab(item)
        case .complete:
            onComplete()
        }
    }
}
