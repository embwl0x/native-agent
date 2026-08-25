import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Capabilities.foundryIndexPanel

@Suite("Capabilities Foundry Index")
struct CapabilitiesFoundryIndexPanelEvalTests {
    @Test("a coherent native catalog exposes its real rows and counts")
    func verifiedCatalogIsDisplayed() {
        let summary = catalog(
            records: [
                record(id: "chat", kind: "tool", status: "ready", autoload: true),
                record(id: "draft", kind: "workflow", status: "review", autoload: false),
            ],
            active: 1,
            review: 1,
            autoloaded: 1,
            byKind: ["tool": 1, "workflow": 1]
        )

        #expect(CapabilitiesFoundryIndexPresentation.state(summary: summary) == .populated(summary))
    }

    @Test("missing and actually empty catalogs are visibly different")
    func absentCatalogDoesNotBecomeAZeroInventory() {
        let empty = catalog(records: [], active: 0, review: 0, autoloaded: 0, byKind: [:])

        #expect(CapabilitiesFoundryIndexPresentation.state(summary: nil) == .unavailable)
        #expect(CapabilitiesFoundryIndexPresentation.state(summary: empty) == .empty)
        #expect(CapabilitiesFoundryIndexPresentation.unavailableDetail.contains("has not loaded"))
        #expect(CapabilitiesFoundryIndexPresentation.emptyDetail.contains("returned no indexed"))
    }

    @Test("inconsistent aggregate receipts suppress capability rows instead of claiming a healthy index")
    func malformedOrStaleCountsFailHonestly() {
        let staleCounts = catalog(
            records: [record(id: "chat", kind: "tool", status: "ready", autoload: false)],
            active: 0,
            review: 0,
            autoloaded: 0,
            byKind: ["tool": 1]
        )
        let duplicateIDs = catalog(
            records: [
                record(id: "same", kind: "tool", status: "ready", autoload: false),
                record(id: "same", kind: "tool", status: "ready", autoload: false),
            ],
            active: 2,
            review: 0,
            autoloaded: 0,
            byKind: ["tool": 2]
        )

        guard case .inconsistent(let staleReason) = CapabilitiesFoundryIndexPresentation.state(summary: staleCounts) else {
            Issue.record("stale aggregate counts were rendered as a usable catalog")
            return
        }
        guard case .inconsistent(let duplicateReason) = CapabilitiesFoundryIndexPresentation.state(summary: duplicateIDs) else {
            Issue.record("duplicate catalog identifiers were rendered as a usable catalog")
            return
        }
        #expect(staleReason.contains("status counts"))
        #expect(duplicateReason.contains("duplicate identifiers"))
        #expect(CapabilitiesFoundryIndexPresentation.inconsistentDetail(staleReason).contains("Refresh"))
    }

    private func catalog(
        records: [CapabilityRecord],
        active: Int,
        review: Int,
        autoloaded: Int,
        byKind: [String: Int]
    ) -> CapabilitySummaryResponse {
        .init(
            records: records,
            summary: .init(
                total: records.count,
                active: active,
                review: review,
                autoloaded: autoloaded,
                byKind: byKind
            ),
            createdAt: "2026-08-24T00:00:00Z"
        )
    }

    private func record(id: String, kind: String, status: String, autoload: Bool) -> CapabilityRecord {
        .init(
            id: id,
            sourceId: "native",
            name: id,
            kind: kind,
            status: status,
            description: nil,
            triggers: nil,
            permissions: nil,
            riskClass: nil,
            autoload: autoload,
            useCount: nil,
            lastUsedAt: nil,
            updatedAt: nil
        )
    }
}
