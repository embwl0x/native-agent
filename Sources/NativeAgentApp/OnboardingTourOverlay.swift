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

// One stop per word on the rail, in rail order, each with one plain sentence.
// The title is the rail's own word (`SidebarItem.shellRailTitle`), so a stop can
// never name a page that is no longer there.
private let onboardingTourStops: [OnboardingTourStep] = [
    OnboardingTourStep(
        id: 0,
        item: .chat,
        title: SidebarItem.chat.shellRailTitle,
        body: "This is where we talk, and the row under the field sets the model, the thinking and what I'm allowed to do.",
        buttonLabel: "Continue"
    ),
    OnboardingTourStep(
        id: 1,
        item: .activity,
        title: SidebarItem.activity.shellRailTitle,
        body: "I show you what I did today, what's ahead, and anything waiting on you.",
        buttonLabel: "Continue"
    ),
    OnboardingTourStep(
        id: 2,
        item: .memories,
        title: SidebarItem.memories.shellRailTitle,
        body: "I keep everything I've learned here, so you can read it, correct it or throw it out.",
        buttonLabel: "Continue"
    ),
    OnboardingTourStep(
        id: 3,
        item: .desk,
        title: SidebarItem.desk.shellRailTitle,
        body: "I line up the projects and tasks here, and I show you what came of them.",
        buttonLabel: "Continue"
    ),
    OnboardingTourStep(
        id: 4,
        item: .inboxPolicy,
        title: SidebarItem.inboxPolicy.shellRailTitle,
        body: "I decide here what to bring you and what to keep quiet.",
        buttonLabel: "Continue"
    ),
    OnboardingTourStep(
        id: 5,
        item: .bots,
        title: SidebarItem.bots.shellRailTitle,
        body: "I run small jobs on my own here, on a schedule you set.",
        buttonLabel: "Continue"
    ),
    OnboardingTourStep(
        id: 6,
        item: .personality,
        title: SidebarItem.personality.shellRailTitle,
        body: "This is who I am here — my name, my voice, and the documents behind them.",
        buttonLabel: "Continue"
    ),
    OnboardingTourStep(
        id: 7,
        item: .providers,
        title: SidebarItem.providers.shellRailTitle,
        body: "I think with the model accounts you connect here, and you pick which one does which job.",
        buttonLabel: "Continue"
    ),
    OnboardingTourStep(
        id: 8,
        item: .trust,
        title: SidebarItem.trust.shellRailTitle,
        body: "This is what I'm allowed to do on this Mac without asking you first.",
        buttonLabel: "Continue"
    ),
    OnboardingTourStep(
        id: 9,
        item: .connectors,
        title: SidebarItem.connectors.shellRailTitle,
        body: "I reach your other apps and services here, including your iPhone and Telegram.",
        buttonLabel: "Continue"
    ),
    OnboardingTourStep(
        id: 10,
        item: .capabilities,
        title: SidebarItem.capabilities.shellRailTitle,
        body: "This is what I can do, what's installed, and what needs a look.",
        buttonLabel: "Continue"
    ),
    OnboardingTourStep(
        id: 11,
        item: .diagnostics,
        title: SidebarItem.diagnostics.shellRailTitle,
        body: "This is how I'm running, with my skills, my tools and the logs when something looks wrong.",
        buttonLabel: "Continue"
    ),
    OnboardingTourStep(
        id: 12,
        item: .settings,
        title: SidebarItem.settings.shellRailTitle,
        body: "You set the appearance, the shortcut that opens me and updates here, and you can take this tour again.",
        buttonLabel: "Got it"
    ),
]

/// The stops the rail actually has words for. Bots is on the rail only while
/// the Bots preview is on (`ShellSidebarRail`), so the tour reads the same
/// preference and drops that stop with it. Stop ids stay fixed, so a stop
/// keeps its identity whether or not Bots is showing.
var onboardingTourSteps: [OnboardingTourStep] {
    guard !BotsShelfPreference.isEnabled() else { return onboardingTourStops }
    return onboardingTourStops.filter { $0.item != .bots }
}

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
                        Label(step.item.shellRailTitle, systemImage: step.item.systemImage)
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
            .transition(NativeAgentMotion.reveal())
            .id(tour.stepIndex) // force transition on step change
            .animation(NativeAgentMotion.standard, value: tour.stepIndex)
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
                        Text(tabStep.item.shellRailTitle)
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
