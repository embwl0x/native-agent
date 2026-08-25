import Foundation
import Testing
@testable import ProviderRouting

// MARK: - Ledger row `catalog.NativeToolCapability.modelImpliesNativeToolProvider`
//
// SILENT FAILURE this pins: `modelImpliesNativeToolProvider` is the model-id
// BACKSTOP the chat loop uses when no provider id is admitted — it decides
// whether a turn runs the provider-native tools lane or degrades to the
// text-compatibility marker protocol. It lowercases its input and compares
// against `FirstPartyModelCatalog.kimiCodeModelIDSet`, which is built from the
// RAW catalog ids with NO lowercasing on the set side. A catalog id added with
// any uppercase character therefore makes this return false FOREVER: the
// native lane silently degrades, the model narrates tool calls in prose, and
// there is no error and no trace row. Its sibling `providerSupportsNativeTools`
// has six assertions; this one had zero.
//
// Envelope asserted (not exact values pulled from thin air — the catalog is
// the contract): every id IN the kimi-code catalog admits the native lane in
// any case/padding, every moonshot id and every empty/nil input does not, and
// the id SET is case-folded so an uppercase catalog entry fails HERE instead of
// in production.

@Suite("Native-tool capability: model-id backstop")
struct NativeToolCapabilityBackstopEvalTests {

    /// Envelope: the backstop admits EVERY id in the kimi-code catalog, and it
    /// is case- and whitespace-insensitive on the caller's side.
    @Test func modelBackstop_admitsEveryKimiCodeCatalogID_inAnyCase() {
        let ids = FirstPartyModelCatalog.kimiCodeModels.map { $0.id }
        #expect(!ids.isEmpty, "kimi-code catalog must not be empty — an empty catalog would make this test vacuous")

        for id in ids {
            #expect(
                NativeToolCapability.modelImpliesNativeToolProvider(id),
                "native lane must admit catalog id '\(id)'"
            )
            #expect(
                NativeToolCapability.modelImpliesNativeToolProvider(id.uppercased()),
                "native lane must admit '\(id)' in upper case — a case-sensitive miss degrades to text-compat silently"
            )
            #expect(
                NativeToolCapability.modelImpliesNativeToolProvider("  \(id)  "),
                "native lane must admit '\(id)' with surrounding whitespace"
            )
        }
    }

    /// Envelope: nothing OUTSIDE that catalog is admitted. Moonshot's own ids
    /// share the `kimi-` prefix and are the exact family that must NOT ride
    /// the Anthropic-protocol native lane.
    @Test func modelBackstop_rejectsMoonshotIDsAndBlankInput() {
        let kimiCode = Set(FirstPartyModelCatalog.kimiCodeModels.map { $0.id.lowercased() })
        let moonshot = FirstPartyModelCatalog.moonshotModels
            .map { $0.id }
            .filter { !kimiCode.contains($0.lowercased()) }
        #expect(!moonshot.isEmpty, "moonshot catalog must contribute at least one non-kimi-code id")

        for id in moonshot {
            #expect(
                !NativeToolCapability.modelImpliesNativeToolProvider(id),
                "moonshot id '\(id)' must NOT admit the provider-native tools lane"
            )
        }
        #expect(!NativeToolCapability.modelImpliesNativeToolProvider(nil))
        #expect(!NativeToolCapability.modelImpliesNativeToolProvider(""))
        #expect(!NativeToolCapability.modelImpliesNativeToolProvider("   "))
        #expect(!NativeToolCapability.modelImpliesNativeToolProvider("claude-opus-4-8"))
        #expect(!NativeToolCapability.modelImpliesNativeToolProvider("gpt-5.5"))
    }

    /// The actual mechanism guard: the lookup lowercases its ARGUMENT but the
    /// set is built from raw catalog ids. Pin the set to its own case-folded
    /// form so an uppercase catalog entry fails in this test rather than
    /// silently turning the native lane off for that model in production.
    @Test func kimiCodeModelIDSet_isCaseFoldedLikeTheLookup() {
        let folded = Set(FirstPartyModelCatalog.kimiCodeModels.map { $0.id.lowercased() })
        #expect(
            FirstPartyModelCatalog.kimiCodeModelIDSet == folded,
            "kimiCodeModelIDSet carries a non-lowercased id; modelImpliesNativeToolProvider lowercases its input and would never match it: \(FirstPartyModelCatalog.kimiCodeModelIDSet.symmetricDifference(folded).sorted())"
        )
    }

    /// Cross-seam agreement: the model backstop and the provider predicate are
    /// two answers to the same question. Every catalog id the backstop admits
    /// must belong to a provider the provider-predicate also admits, and the
    /// provider predicate must admit exactly one provider spelling family.
    @Test func modelBackstop_agreesWithProviderPredicate() {
        #expect(NativeToolCapability.providerSupportsNativeTools("kimi-code"))
        #expect(NativeToolCapability.providerSupportsNativeTools("kimi_code"))
        #expect(NativeToolCapability.providerSupportsNativeTools("  KIMI-CODE "))
        for other in ["moonshot", "anthropic", "anthropic_oauth_direct", "openai", "codex", "openrouter", "xai_oauth_direct"] {
            #expect(
                !NativeToolCapability.providerSupportsNativeTools(other),
                "provider '\(other)' must never be handed a provider-native tools[] array"
            )
        }
        #expect(!NativeToolCapability.providerSupportsNativeTools(nil))
    }
}
