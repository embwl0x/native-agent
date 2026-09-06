import SwiftUI

/// One navigation destination for Agent's reusable knowledge and executable
/// capabilities. Skills and tools keep their own page bodies and refresh
/// owners; this view owns only the visible page selection.
struct SkillsToolsView: View {
    @Binding var selection: SkillsToolsSection

    var body: some View {
        // 2026-09-03 Advanced refinement: the picker was centred over a full
        // width rule, which read as a toolbar bolted above the page. It sits
        // on the page's own left edge now, and the rule is gone — the pages
        // below it already tell themselves apart.
        VStack(alignment: .leading, spacing: 16) {
            Picker("Skills and tools page", selection: $selection) {
                ForEach(SkillsToolsSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .accessibilityIdentifier("skills-tools-section-picker")

            switch selection {
            case .skills:
                SkillLifecycleView()
            case .tools:
                ToolsView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .navigationTitle("Skills and tools")
    }
}
