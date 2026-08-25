import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Desk inbox source badge behavior")
struct DeskInboxSourceBadgeLabelBehaviorEvalTests {
    private func item(_ json: String) throws -> InboxItemRecord {
        try JSONDecoder().decode(InboxItemRecord.self, from: try #require(json.data(using: .utf8)))
    }

    // app.desk / desk.inbox.sourceBadgeLabel
    @Test("known durable sources retain their canonical badges and approval provenance wins")
    func knownSourcesAndApprovalUseCanonicalLabels() throws {
        let proactive = try item(#"""
        {"id":"proactive","source":"  PROACTIVE_AUTONOMY:inbox_digest:op-1  "}
        """#)
        let scheduled = try item(#"""
        {"id":"scheduled","source":"scheduled_proactive_scan"}
        """#)
        let approval = try item(#"""
        {"id":"approval","source":false,"related_approval_id":"approval-1"}
        """#)

        #expect(proactive.sourceBadgeLabel == "IDEA")
        #expect(scheduled.sourceBadgeLabel == "PROACTIVE SCAN")
        #expect(approval.sourceReadState == .malformed)
        #expect(approval.sourceBadgeLabel == "APPROVAL")
    }

    // app.desk / desk.inbox.sourceBadgeLabel
    @Test("missing, blank, malformed, and unsafe durable source values remain visible adverse states")
    func adverseSourcesDoNotBecomeBlankOrInventedCategories() throws {
        let missing = try item(#"""
        {"id":"missing"}
        """#)
        let blank = try item(#"""
        {"id":"blank","source":"   "}
        """#)
        let malformed = try item(#"""
        {"id":"malformed","source":null}
        """#)
        let unsafe = try item(#"""
        {"id":"unsafe","source":"../../private-state"}
        """#)

        #expect(missing.sourceReadState == .missing)
        #expect(missing.sourceBadgeLabel == "SOURCE MISSING")
        #expect(blank.sourceReadState == .present)
        #expect(blank.sourceBadgeLabel == "SOURCE UNKNOWN")
        #expect(malformed.sourceReadState == .malformed)
        #expect(malformed.sourceBadgeLabel == "SOURCE INVALID")
        #expect(unsafe.sourceBadgeLabel == "SOURCE INVALID")
    }

    // app.desk / desk.inbox.sourceBadgeLabel
    @Test("unclassified safe provenance stays readable and bounded without a false category")
    func unknownSafeSourceGetsABoundedHumanLabel() throws {
        let unknown = try item(#"""
        {"id":"connector","source":"connector_action:mail"}
        """#)
        let misleadingPrefix = try item(#"""
        {"id":"near-proactive","source":"proactive_autonomy_backup"}
        """#)

        #expect(unknown.sourceBadgeLabel == "CONNECTOR ACTION")
        #expect(misleadingPrefix.sourceBadgeLabel == "PROACTIVE")
        #expect(misleadingPrefix.sourceBadgeLabel != "IDEA")
    }
}
