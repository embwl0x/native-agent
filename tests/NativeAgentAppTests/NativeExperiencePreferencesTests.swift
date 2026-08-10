import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Native experience rollback")
struct NativeExperiencePreferencesTests {
    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let name = "NativeExperiencePreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    @Test("classic presentation is the fresh-install default")
    func classicByDefault() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        for feature in NativeExperienceFeature.allCases {
            #expect(!NativeExperiencePreferences.isEnabled(feature, defaults: defaults))
        }
    }

    @Test("enabling Journey enables every presentation section")
    func enableAll() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        NativeExperiencePreferences.enableAll(defaults: defaults)

        #expect(defaults.bool(forKey: NativeExperiencePreferences.masterKey))
        for feature in NativeExperienceFeature.allCases {
            #expect(NativeExperiencePreferences.isEnabled(feature, defaults: defaults))
        }
    }

    @Test("return to classic hides additions and clears section overrides")
    func rollback() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        NativeExperiencePreferences.enableAll(defaults: defaults)
        defaults.set(false, forKey: NativeExperiencePreferences.contextKey)
        NativeExperiencePreferences.returnToClassic(defaults: defaults)

        #expect(!defaults.bool(forKey: NativeExperiencePreferences.masterKey))
        for feature in NativeExperienceFeature.allCases {
            #expect(defaults.object(forKey: NativeExperiencePreferences.key(for: feature)) == nil)
            #expect(!NativeExperiencePreferences.isEnabled(feature, defaults: defaults))
        }
    }

    @Test("one section can be hidden without affecting sibling sections")
    func sectionOverride() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        NativeExperiencePreferences.enableAll(defaults: defaults)
        defaults.set(false, forKey: NativeExperiencePreferences.projectsKey)

        #expect(!NativeExperiencePreferences.isEnabled(.projects, defaults: defaults))
        #expect(NativeExperiencePreferences.isEnabled(.context, defaults: defaults))
        #expect(NativeExperiencePreferences.isEnabled(.journey, defaults: defaults))
    }

    @Test("Journey preferences cannot call or configure living runtime owners")
    func preferencesArePresentationOnly() throws {
        let preferences = try AppSourceScraping.appSource("NativeExperiencePreferences.swift")
        let view = try AppSourceScraping.appSource("NativeExperienceView.swift")
        let forbiddenRuntimeControls = [
            "NativeContextFlowRuntime.shared",
            "NativeCognitionRuntime.shared",
            "cognitiveSubstrateEnabled",
            "organismKernelEnabled",
            "setMode(",
        ]

        for forbidden in forbiddenRuntimeControls {
            #expect(!preferences.contains(forbidden))
            #expect(!view.contains(forbidden))
        }

        let preferenceKeys = NativeExperienceFeature.allCases.map {
            NativeExperiencePreferences.key(for: $0)
        } + [NativeExperiencePreferences.masterKey]
        #expect(preferenceKeys.allSatisfy { $0.hasPrefix("nativeagent.experience.") })
    }
}
