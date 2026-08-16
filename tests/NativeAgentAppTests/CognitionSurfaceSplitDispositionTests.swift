import Foundation
import Testing
@testable import NativeAgentApp

// B2.4 + B2.6 (prerelease campaign): the Cognition Observatory's 19 panels were
// split — the standing-view approval panel and read-only REM replay lineage to
// Activity, read-only internals to Diagnostics ▸ Cognition, the inert Identity
// Proposals panel deleted — and Turn Inspector +
// DeskView's debug disclosures folded into Diagnostics. These source-scraping
// pins guard the LOSSLESS-disposition contract: every panel lands exactly one
// place (or its deletion is justified), and nothing is double-rendered.
//
// Source scraping is the established pattern here (see
// OperationalSettingsPresentationTests): these surfaces are inline SwiftUI with
// no testable panel registry, so the disposition is asserted structurally.
struct CognitionSurfaceSplitDispositionTests {

    // MARK: - Approval panels moved OUT of the observatory, INTO Activity

    @Test func approvalPanelsLeftTheObservatory() throws {
        let observatory = try AppSourceScraping.appSource("CognitionObservatoryView.swift")
        // The two approval-shaped collapsibles no longer render here.
        #expect(!observatory.contains("collapsible(\"standingViews\""))
        #expect(!observatory.contains("collapsible(\"schemaProposals\""))
        // Read-only observational core stays.
        #expect(observatory.contains("collapsible(\"loop\""))
        #expect(observatory.contains("collapsible(\"affect\""))
        #expect(observatory.contains("collapsible(\"capsule\""))
    }

    @Test func inertIdentityProposalsPanelDeleted() throws {
        let observatory = try AppSourceScraping.appSource("CognitionObservatoryView.swift")
        let proposals = try AppSourceScraping.appSource("CognitionObservatoryView+Proposals.swift")
        // Panel gone from the body AND its builder removed from the extension.
        #expect(!observatory.contains("collapsible(\"identityProposals\""))
        #expect(!proposals.contains("func identityProposals("))
        // The moved builders no longer live in the observatory extension either.
        #expect(!proposals.contains("func standingViews("))
        #expect(!proposals.contains("func schemaProposals("))
    }

    @Test func retiredCognitionExperimentsHaveNoProductionRuntimePath() throws {
        let repositoryRoot = try AppSourceScraping.repositoryRoot()
        let appSources = try AppSourceScraping.swiftSourceContents(
            under: try AppSourceScraping.appSourcesRoot()
        )
        let cognitionSources = try AppSourceScraping.swiftSourceContents(
            under: repositoryRoot.appendingPathComponent(
                "Modules/NativeAgentCore/Sources/CognitiveSubstrate",
                isDirectory: true
            )
        )
        let production = (appSources + cognitionSources).map(\.source).joined(separator: "\n")

        #expect(!production.contains("func groundWithMemoryAndKnowledgeGraph("))
        #expect(!production.contains("func groundExternalContext("))
        #expect(!production.contains("func stageMemoryProposalCandidate("))
        #expect(!production.contains("func proposeIdentity("))
        #expect(!production.contains("func resolveIdentityProposal("))
        #expect(!production.contains("private var identityProposals"))
        #expect(!FileManager.default.fileExists(atPath: repositoryRoot
            .appendingPathComponent("Sources/NativeAgentApp/NativeCognitionRuntime+ExternalGrounding.swift")
            .path))
    }

    @Test func activitySurfaceOwnsStandingViewApprovalsAndReadOnlyREMLineage() throws {
        let activity = try AppSourceScraping.appSource("ActivityView.swift")
        let proposalsView = try AppSourceScraping.appSource("CognitionProposalsView.swift")
        // Activity has the new section + destination.
        #expect(activity.contains("case cognitionProposals"))
        #expect(activity.contains("CognitionProposalsView()"))
        #expect(activity.contains("CognitionProposalsFeed.pending()"))
        // Standing views remain the only cognition-owned approval path.
        #expect(proposalsView.contains("resolveStandingView(id:"))
        #expect(proposalsView.contains("Standing Views"))
        // Replay schemas remain visible for provenance, but REM is their canonical
        // owner: this surface has no schema resolver or hidden approve/reject path.
        #expect(proposalsView.contains("REM Replay Lineage"))
        #expect(proposalsView.contains("canonical Dream/REM approval path"))
        #expect(!proposalsView.contains("resolveSchemaProposal(id:"))

        let schemaStart = try #require(proposalsView.range(of: "private func schemaProposalsBody"))
        let schemaTail = proposalsView[schemaStart.lowerBound...]
        let inlineCardsStart = try #require(schemaTail.range(of: "// MARK: - Inline preview card"))
        let schemaSection = schemaTail[..<inlineCardsStart.lowerBound]
        #expect(!schemaSection.contains("Button("))
        #expect(!schemaSection.contains("resolve"))
    }

    // MARK: - Read-only internals + Inspector become Diagnostics segments

    @Test func diagnosticsGainsCognitionAndInspectorSegments() throws {
        let diagnostics = try AppSourceScraping.appSource("DiagnosticsView.swift")
        #expect(diagnostics.contains("case cognition = \"Cognition\""))
        #expect(diagnostics.contains("case inspector = \"Inspector\""))
        #expect(diagnostics.contains("case .cognition: CognitionObservatoryView()"))
        #expect(diagnostics.contains("case .inspector: InspectorView()"))
        // Aliases can land on their own segment (fence-A routing wires this).
        #expect(diagnostics.contains("init(initialMode: DiagnosticsMode = .doctor)"))
    }

    @Test func observatoryDroppedStandaloneChromeForEmbedding() throws {
        let observatory = try AppSourceScraping.appSource("CognitionObservatoryView.swift")
        // No standalone nav chrome — Diagnostics owns it when embedded.
        #expect(!observatory.contains(".navigationTitle(\"Cognition\")"))
    }

    // MARK: - DeskView debug disclosures moved to Diagnostics ▸ Cognition

    @Test func deskViewKeepsZeroDebugChrome() throws {
        let desk = try AppSourceScraping.appSource("DeskView.swift")
        // Both disclosures and their state gone from the Workshop surface.
        #expect(!desk.contains("agentViewDisclosure"))
        #expect(!desk.contains("allItemsDisclosure"))
        #expect(!desk.contains("@State private var showAllItems"))
    }

    @Test func deskDebugPanelsRenderInsideTheCognitionSegment() throws {
        let observatory = try AppSourceScraping.appSource("CognitionObservatoryView.swift")
        let deskDebug = try AppSourceScraping.appSource("DeskDebugPanels.swift")
        // The observatory (Cognition segment) embeds the moved debug panels.
        #expect(observatory.contains("DeskDebugPanels()"))
        // And they carry the moved disclosure content losslessly.
        #expect(deskDebug.contains("All items (debug — raw records with numbers)"))
        #expect(deskDebug.contains("the compact projection used in context"))
    }
}
