import Context
import Foundation
import Testing

/// Evidenced-value pins for the four Context configuration structs that ship
/// with defaults PRODUCTION constructs and no test ever asserts.
///
/// Why this file exists (coverage-ledger fence `core.context`): every existing
/// test that touches these knobs passes explicit overrides — small character
/// limits, tiny atom caps, hand-picked compiler bounds — because each of those
/// tests is about a MECHANISM (does the cap cut? does the reject fire?) and
/// needs a cheap boundary to drive it. The consequence is that the numbers the
/// app actually runs on were asserted nowhere: halve `maximumDynamicAtoms` and
/// every production packet silently shrinks while the whole suite stays green.
///
/// These are exact-value assertions on purpose. They are the same contract as
/// `ContextSelectionTests.defaultScoreWeightsMatchTheEvidencedValues`: a
/// default here is a shipped decision, so changing one has to be deliberate and
/// has to come with evidence, not arrive as a drive-by edit.
@Suite("Fluid Context shipped defaults")
struct ContextShippedDefaultsTests {
    /// Selection shape. `maximumPointers = 8` is load-bearing today — live
    /// selection receipts sit exactly at the cap, i.e. every turn offers the
    /// full pointer budget — so a quiet reduction directly removes reach.
    /// `maximumDynamicAtoms = 12` is the packet's dynamic half.
    @Test
    func shippedSelectionConfigurationDefaultsArePinned() {
        let configuration = ContextSelectionConfiguration()
        #expect(configuration.maximumCandidates == 256)
        #expect(configuration.maximumDynamicAtoms == 12)
        #expect(configuration.maximumPointers == 8)
        #expect(configuration.maximumAtomsPerSource == 2)
        #expect(configuration.maximumAtomsPerKind == 4)
        #expect(configuration.minimumRelevance == 0.05)
        // The nested weights carry their own pin in ContextSelectionTests; what
        // matters here is that a bare configuration still routes to it rather
        // than to some other default set.
        #expect(configuration.weights == ContextScoreWeights())
    }

    /// The ceiling on what `context_expand` can hand back to the model. Every
    /// ContextExpansionTests case builds an expander with a deliberately tiny
    /// limit (8, 20, 0) to drive the truncation path, so the shipped 12,000 was
    /// never asserted. Halve it and answers truncate mid-section with
    /// `truncated: true` riding in a receipt nobody reads.
    @Test
    func shippedExpansionCharacterLimitIsPinned() {
        #expect(ContextExpansionConfiguration().maximumCharacters == 12_000)
    }

    /// How fast selection learns from outcomes, and how fast that learning
    /// decays. ContextFeedbackTests asserts the SHAPE (capping, decay ordering,
    /// order independence) and would stay green through any of these values.
    /// `activationRetentionPerBucket` is the dangerous one: nudge 0.82 toward
    /// 1.0 and temporary activation becomes effectively permanent — ranking
    /// ossifies around whatever was selected first.
    @Test
    func shippedFeedbackConfigurationDefaultsArePinned() {
        let configuration = ContextFeedbackConfiguration()
        #expect(configuration.minimumUtility == -1)
        #expect(configuration.maximumUtility == 1)
        #expect(configuration.retrievalUtilityCap == 0.18)
        #expect(configuration.selectionUtilityDelta == 0.01)
        #expect(configuration.expansionUtilityDelta == 0.025)
        #expect(configuration.utilityRetentionPerBucket == 0.995)
        #expect(configuration.activationRetentionPerBucket == 0.82)
        #expect(configuration.decayRetentionPerBucket == 0.997)
    }

    /// The admission gates: what content is allowed to become context at all.
    /// Production builds the compiler with no limits argument
    /// (NativeContextFlowRuntime), and both ContextMarkdownCompilerTests
    /// construction sites pass explicit overrides, so the shipped bounds had no
    /// assertion anywhere. Shrink `maxAtomUTF8Bytes` and atoms start being
    /// rejected as oversized; shrink `maxTriggersPerAtom` and trigger matching
    /// quietly loses reach — in both cases the rejection-mechanism tests keep
    /// passing, because they test rejection at limits of their own choosing.
    @Test
    func shippedMarkdownCompilerLimitsArePinned() {
        let limits = ContextMarkdownCompilerLimits()
        #expect(limits.maxSourceUTF8Bytes == 2 * 1_024 * 1_024)
        #expect(limits.maxAtomUTF8Bytes == 64 * 1_024)
        #expect(limits.maxSummaryUTF8Bytes == 320)
        #expect(limits.maxTriggerUTF8Bytes == 64)
        #expect(limits.maxTriggersPerAtom == 12)
    }
}
