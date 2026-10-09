import AppToolRuntime
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
        body: "This is what I can do and what's installed.",
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
    @AppStorage(SimpleViewMode.key) private var viewMode = ""
    @State private var previousViewMode: String?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
                    .plate(reduceTransparency: reduceTransparency)

                VStack(spacing: NativeAgentSpacing.xl) {
                    Text(presentation.progressText)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Only the stop's words change; the plate and the buttons
                    // stay put, and each stop arrives once.
                    VStack(spacing: NativeAgentSpacing.sm) {
                        Text(step.title)
                            .font(ShellType.display)
                            .foregroundStyle(NativeAgentShell.text)
                            .multilineTextAlignment(.center)

                        Text(step.body)
                            .font(ShellType.body)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 420)
                    }
                    .motionArrival()
                    .id(tour.stepIndex)

                    HStack(spacing: NativeAgentSpacing.md) {
                        Button("Skip") {
                            completeTour()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .font(ShellType.label)
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
                        .accessibilityIdentifier("onboarding-tour.advance")
                    }
                    .frame(maxWidth: 420)
                }
                .padding(NativeAgentSpacing.xl)
                .plate(reduceTransparency: reduceTransparency)
                .frame(maxWidth: 520)
            }
            .padding(NativeAgentSpacing.xl)
            // The overlay sits on a dimmed room, so its words read as they do
            // in the dark room whatever the appearance.
            .environment(\.colorScheme, .dark)
        }
        .onAppear {
            if previousViewMode == nil { previousViewMode = viewMode }
            viewMode = SimpleViewMode.advanced
            onSelectTab(tour.route)
        }
        .onDisappear {
            if let previousViewMode { viewMode = previousViewMode }
        }
        // S.4: mark overlay as accessibility modal so VoiceOver focuses only overlay content
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("onboarding-tour.overlay")
    }

    /// The stops as the rail draws its places: words at one left edge, and the
    /// 2pt bar beside the one you are on.
    private var tabRail: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(onboardingTourSteps) { tabStep in
                let isSelected = tabStep.id == step.id
                Button {
                    apply(.select(stepID: tabStep.id))
                } label: {
                    Text(tabStep.item.shellRailTitle)
                        .font(ShellType.rail)
                        .foregroundStyle(isSelected ? NativeAgentShell.text : NativeAgentShell.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, NativeAgentShellLayout.railWordInset)
                        .frame(height: 30)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .fill(NativeAgentShell.text)
                                .frame(width: 2, height: 20)
                                .padding(.leading, NativeAgentShellLayout.barInset)
                                .opacity(isSelected ? 1 : 0)
                                .animation(NativeAgentMotion.crossfade, value: isSelected)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("onboarding-tour.step.\(tabStep.id)")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, 10)
        .frame(width: 180)
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
            viewMode = SimpleViewMode.advanced
            onSelectTab(item)
        case .complete:
            if let previousViewMode { viewMode = previousViewMode }
            onComplete()
        }
    }
}

private extension View {
    /// The rail's own plate: clear glass with the dark tint, no drawn border.
    /// Reduce Transparency gets the flat rail colour instead.
    func plate(reduceTransparency: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: NativeAgentShellLayout.railPlateRadius, style: .continuous)
        return background { if reduceTransparency { shape.fill(NativeAgentShell.rail) } }
            .glassEffect(reduceTransparency ? .identity : HouseGlass.plate, in: shape)
    }
}
