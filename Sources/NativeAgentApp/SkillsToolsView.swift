import SwiftUI

/// One navigation destination for Agent's reusable knowledge and executable
/// capabilities. Skills and tools keep their own page bodies and refresh
/// owners; this view owns only the visible page selection.
struct SkillsToolsView: View {
    @Binding var selection: SkillsToolsSection

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Picker("Skills and Tools page", selection: $selection) {
                    ForEach(SkillsToolsSection.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                .accessibilityIdentifier("skills-tools-section-picker")
                Spacer()
            }
            .padding(.horizontal, NativeAgentSpacing.xl)
            .padding(.vertical, NativeAgentSpacing.md)

            Divider()

            switch selection {
            case .skills:
                SkillLifecycleView()
            case .tools:
                ToolsView()
            }
        }
        .navigationTitle("Skills & Tools")
    }
}
