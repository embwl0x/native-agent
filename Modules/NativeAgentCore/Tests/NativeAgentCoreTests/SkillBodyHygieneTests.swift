import Testing
@testable import NativeAgentCore

@Test func skillBodyHygiene_acceptsCleanMarkdownGuidance() {
    let body = """
    # Clean Skill

    Use this when Agent needs a focused, reusable procedure.
    """
    #expect(SkillBodyHygiene.violations(in: body).isEmpty)
    #expect(SkillBodyHygiene.firstUsefulLine(in: body) == "Use this when Agent needs a focused, reusable procedure.")
}

@Test func skillBodyHygiene_rejectsMissingHeadingMissingBodyAndStaleTerms() {
    let body = """
    Use this when the python daemon needs the old route at /v1/tools/propose.
    """
    let violations = SkillBodyHygiene.violations(in: body)
    let labels = Set(violations.map(\.label))
    #expect(labels.contains("heading"))
    #expect(labels.contains("python"))
    #expect(labels.contains("daemon"))
    #expect(labels.contains("old tool proposal route"))
    #expect(SkillBodyHygiene.failureMessage(for: violations).contains("line 1"))

    let headingOnly = "# Heading Only\n"
    #expect(SkillBodyHygiene.violations(in: headingOnly).contains { $0.label == "body" })
}
