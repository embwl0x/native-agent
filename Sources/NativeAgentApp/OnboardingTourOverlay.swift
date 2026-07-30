// PATCH-2026-05-08: polish-wave — primary sidebar coach-mark onboarding tour
import SwiftUI

// MARK: - Tour Step Model

private struct TourStep: Identifiable {
    let id: Int
    let item: SidebarItem
    let title: String
    let body: String
    let buttonLabel: String
}

private let tourSteps: [TourStep] = [
    TourStep(
        id: 0,
        item: .chat,
        title: "Chat",
        body: "The main conversation surface. Chat, attach files, and use provider/model controls. Drag sessions from the left session list into the chat area to pin them as tabs.",
        buttonLabel: "Continue"
    ),
    TourStep(
        id: 1,
        item: .activity,
        title: "Activity",
        body: "The action inbox. Approvals, proactive cards, memory proposals, and self-improvement items that need review collect here.",
        buttonLabel: "Continue"
    ),
    TourStep(
        id: 2,
        item: .memories,
        title: "Memories",
        body: "The long-term memory view. Inspect, correct, delete, and verify what the agent thinks it knows.",
        buttonLabel: "Continue"
    ),
    TourStep(
        id: 3,
        item: .skills,
        title: "Skills & Tools",
        body: "One place for learned playbooks and executable tools. Use the switch at the top to move between their separate pages; both stay lazy-loaded until needed.",
        buttonLabel: "Continue"
    ),
    TourStep(
        id: 4,
        item: .workshop,
        title: "Workshop",
        body: "The agent's work bench. Create a task with the New Task button, then track it across the Bench, Schedule, and Research views.",
        buttonLabel: "Continue"
    ),
    TourStep(
        id: 5,
        item: .providers,
        title: "Providers",
        body: "Model and provider setup lives here. Connect accounts, choose active providers, and run provider self-tests.",
        buttonLabel: "Continue"
    ),
    TourStep(
        id: 6,
        item: .settings,
        title: "Settings",
        body: "Device pairing, Telegram, appearance, memory backend setup, data limits, and replaying this tour live here.",
        buttonLabel: "Continue"
    ),
    TourStep(
        id: 7,
        item: .activity,
        title: "Self-Improvement",
        body: "From Activity, the harness reviews real runs, proposes small fixes, tests them, and records useful receipts. Good lessons become lazy skills or code changes; risky changes still go through review.",
        buttonLabel: "Got it"
    ),
]

// MARK: - Tour Overlay

struct OnboardingTourOverlay: View {
    let onComplete: () -> Void
    let onSelectTab: (SidebarItem) -> Void

    @State private var stepIndex = 0

    private var step: TourStep { tourSteps[stepIndex] }
    private var isLast: Bool { stepIndex == tourSteps.count - 1 }

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
                        Text("Step \(stepIndex + 1) of \(tourSteps.count)")
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
                            onComplete()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.55))
                        .font(.system(.callout, design: .rounded))

                        Spacer()

                        Button("Back") {
                            retreat()
                        }
                        .buttonStyle(.bordered)
                        .disabled(stepIndex == 0)

                        Button(step.buttonLabel) {
                            advance()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(.blue)
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
            .id(stepIndex) // force transition on step change
            .animation(.easeInOut(duration: 0.25), value: stepIndex)
        }
        .onAppear(perform: selectCurrentTab)
        // S.4: mark overlay as accessibility modal so VoiceOver focuses only overlay content
        .accessibilityAddTraits(.isModal)
    }

    private var tabRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tour stops")
                .font(NativeAgentFont.label)
                .foregroundStyle(.white.opacity(0.62))
                .padding(.horizontal, 10)

            ForEach(tourSteps) { tabStep in
                let isSelected = tabStep.id == step.id
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        stepIndex = tabStep.id
                    }
                    onSelectTab(tabStep.item)
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
        if isLast {
            onComplete()
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                stepIndex += 1
            }
            selectCurrentTab()
        }
    }

    private func retreat() {
        guard stepIndex > 0 else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            stepIndex -= 1
        }
        selectCurrentTab()
    }

    private func selectCurrentTab() {
        onSelectTab(tourSteps[stepIndex].item)
    }
}
