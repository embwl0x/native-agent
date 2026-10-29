import AppToolRuntime
import SwiftUI
import NativeAgentShared
// Blueprint: | `OnboardingTourOverlay.swift` | Tour progress uses stable stop identity and reconciles rail changes from the engine layout passed by ContentView; only in-overlay progress is local |

// MARK: - Tour Step Model

struct OnboardingTourStep: Identifiable, Equatable, Sendable {
    var id: SidebarItem { item }
    let item: SidebarItem
    var title: String { item.shellRailTitle }
    let body: String
}

// One stop per word on the rail, in rail order, each with one plain sentence.
// The title is the rail's own word (`SidebarItem.shellRailTitle`), so a stop can
// never name a page that is no longer there.
private let onboardingTourStops: [OnboardingTourStep] = [
    OnboardingTourStep(
        item: .chat,
        body: "This is where we talk, and the row under the field sets the model, the thinking and what I'm allowed to do."
    ),
    OnboardingTourStep(
        item: .activity,
        body: "I show you what I did today, what's ahead, and anything waiting on you."
    ),
    OnboardingTourStep(
        item: .memories,
        body: "I keep everything I've learned here, so you can read it, correct it or throw it out."
    ),
    OnboardingTourStep(
        item: .desk,
        body: "I line up the projects and tasks here, and I show you what came of them."
    ),
    OnboardingTourStep(
        item: .inboxPolicy,
        body: "I decide here what to bring you and what to keep quiet."
    ),
    OnboardingTourStep(
        item: .bots,
        body: "I run small jobs on my own here, on a schedule you set."
    ),
    OnboardingTourStep(
        item: .personality,
        body: "This is who I am here — my name, my voice, and the documents behind them."
    ),
    OnboardingTourStep(
        item: .providers,
        body: "I think with the model accounts you connect here, and you pick which one does which job."
    ),
    OnboardingTourStep(
        item: .trust,
        body: "This is what I'm allowed to do on this Mac without asking you first."
    ),
    OnboardingTourStep(
        item: .connectors,
        body: "I reach your other apps and services here, including your iPhone and Telegram."
    ),
    OnboardingTourStep(
        item: .capabilities,
        body: "This is what I can do and what's installed."
    ),
    OnboardingTourStep(
        item: .diagnostics,
        body: "This is how I'm running, with my skills, my tools and the logs when something looks wrong."
    ),
    OnboardingTourStep(
        item: .settings,
        body: "You set the appearance, the shortcut that opens me and updates here, and you can take this tour again."
    ),
]

// MARK: - Tour interaction state

/// The view-free tour state machine. It owns only in-overlay progress and the
/// exact effect each visible control requests; ContentView remains the owner
/// of persisted overlay visibility.
enum OnboardingTourAction: Equatable, Sendable {
    case advance
    case retreat
    case select(stepID: SidebarItem)
    case skip
}

enum OnboardingTourEffect: Equatable, Sendable {
    case none
    case route(SidebarItem)
    case complete
}

@MainActor struct OnboardingTourState: Equatable, Sendable {
    private(set) var steps: [OnboardingTourStep]
    private(set) var currentStopID: SidebarItem?
    init(layout: SurfaceLayout) {
        steps = Self.steps(in: layout)
        currentStopID = steps.first?.id
    }
    private static func steps(in layout: SurfaceLayout) -> [OnboardingTourStep] {
        SidebarItem.rail(layout).compactMap { item in onboardingTourStops.first { $0.item == item } }
    }
    var stepIndex: Int { steps.firstIndex { $0.id == currentStopID } ?? 0 }
    private(set) var didComplete = false

    var step: OnboardingTourStep? { steps.first { $0.id == currentStopID } ?? steps.first }

    /// Applies one visible control action. Completion is idempotent so a
    /// duplicate Skip/Return event cannot ask ContentView to persist a second
    /// presentation transition.
    mutating func apply(_ action: OnboardingTourAction) -> OnboardingTourEffect {
        guard !didComplete else { return .none }
        switch action {
        case .advance:
            guard let next = steps.dropFirst(stepIndex + 1).first else {
                didComplete = true
                return .complete
            }
            currentStopID = next.id
            return .route(next.item)
        case .retreat:
            guard let previous = steps.prefix(stepIndex).last else { return .none }
            currentStopID = previous.id
            return .route(previous.item)
        case let .select(stepID):
            guard let selected = steps.first(where: { $0.id == stepID }) else {
                return .none
            }
            currentStopID = selected.id
            return .route(selected.item)
        case .skip:
            didComplete = true
            return .complete
        }
    }

    mutating func reconcile(layout: SurfaceLayout) -> OnboardingTourEffect {
        steps = Self.steps(in: layout)
        guard let step else { return apply(.skip) }
        currentStopID = step.id
        return .route(step.item)
    }
}

/// All user-visible tour chrome derived from the same state that routes the
/// sidebar. Keeping this projection pure prevents the label, disabled Back
/// state, and action target from drifting into separate SwiftUI branches.
@MainActor struct OnboardingTourPresentation: Equatable, Sendable {
    let progressText: String
    let advanceLabel: String
    let backEnabled: Bool

    init?(state: OnboardingTourState) {
        guard state.step != nil else { return nil }
        progressText = "Step \(state.stepIndex + 1) of \(state.steps.count)"
        advanceLabel = state.stepIndex == state.steps.count - 1 ? "Got it" : "Continue"
        backEnabled = state.stepIndex > 0
    }
}

// MARK: - Tour Overlay

struct OnboardingTourOverlay: View {
    let layout: SurfaceLayout
    let onComplete: () -> Void
    let onSelectTab: (SidebarItem) -> Void

    @State private var tour: OnboardingTourState
    init(layout: SurfaceLayout, onComplete: @escaping () -> Void, onSelectTab: @escaping (SidebarItem) -> Void) {
        self.layout = layout
        _tour = State(initialValue: OnboardingTourState(layout: layout))
        self.onComplete = onComplete
        self.onSelectTab = onSelectTab
    }
    @AppStorage(SimpleViewMode.key) private var viewMode = ""
    @State private var previousViewMode: String?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// A rail the layout left empty has no stop to show: the tour ends.
    var body: some View {
        if let step = tour.step, let presentation = OnboardingTourPresentation(state: tour) {
            tourBody(step: step, presentation: presentation)
                .onChange(of: layout) { _, _ in
                    switch tour.reconcile(layout: layout) {
                    case .route(let item): onSelectTab(item)
                    case .complete: onComplete()
                    case .none: break
                    }
                }
        } else {
            Color.clear.onAppear(perform: onComplete)
        }
    }

    private func tourBody(step: OnboardingTourStep, presentation: OnboardingTourPresentation) -> some View {
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
                    .id(step.id)

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
            onSelectTab(step.item)
        }
        .onDisappear {
            if let previousViewMode { viewMode = previousViewMode }
        }
        // Keep VoiceOver focused on the overlay.
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("onboarding-tour.overlay")
    }

    /// The stops as the rail draws its places: words at one left edge, and the
    /// 2pt bar beside the one you are on.
    private var tabRail: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(tour.steps) { tabStep in
                let isSelected = tabStep.id == tour.currentStopID
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
