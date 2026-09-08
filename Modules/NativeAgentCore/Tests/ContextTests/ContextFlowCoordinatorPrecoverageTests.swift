import Foundation
import NativeAgentCore
import Testing
@testable import Context

extension ContextFlowCoordinatorTests {
    @Test
    func generatedUSERProjectionIsPrecoveredOnlyWithExactHealthyMemoryParity() throws {
        let firstFact = "User chooses jasmine tea after lunch."
        let secondFact = "Quiet morning work should never make noise."
        let generatedUSER = """
        <!-- USER_MD_AUTOGEN_START -->
        # User Facts (auto-generated from memory SQLite)

        - \(firstFact)
        - \(secondFact)

        <!-- USER_MD_AUTOGEN_END -->
        """
        let user = compiledSource(
            id: "user-generated",
            owner: "nativeagent.persona",
            locator: "persona/Agent/USER.md",
            kind: .relationship,
            body: "\(firstFact)\n\(secondFact)",
            authority: .explicitCorrection,
            policy: .adaptive
        )
        let firstMemory = compiledSource(
            id: "memory-first",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/records/first",
            kind: .memory,
            body: firstFact,
            authority: .canonical,
            policy: .adaptive
        )
        let secondMemory = compiledSource(
            id: "memory-second",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/records/second",
            kind: .memory,
            body: secondFact,
            authority: .canonical,
            policy: .adaptive
        )
        let generation = storedGeneration([user, firstMemory, secondMemory])
        let mirror = try projectionMirror(userText: generatedUSER)
        let precovered = ContextFlowCoordinator.generatedUserProjectionPrecoverage(
            mirror: mirror,
            kernel: try chatKernel(of: mirror),
            selectedSources: generation.sources,
            generation: generation
        )
        let userSourceID = try #require(user.atoms.first?.sourceID)
        #expect(precovered == [userSourceID])

        let authorization = ContextSelectionAuthorization(
            allowedOrigins: [.localAuthenticated],
            allowedPrivacy: [.localPrivate],
            allowedSourceIDs: Set(generation.sources.map(\.descriptor.id))
        )
        let baselineNeed = NeedSignal(
            message: "jasmine tea and quiet morning work",
            surface: .chat,
            origin: .localAuthenticated,
            authorization: authorization,
            availableGenerationID: generation.generation.id,
            characterBudget: 1_000,
            now: Date(timeIntervalSince1970: 1_100)
        )
        let candidateNeed = NeedSignal(
            message: baselineNeed.message,
            surface: baselineNeed.surface,
            origin: baselineNeed.origin,
            authorization: authorization,
            precoveredSourceIDs: precovered,
            availableGenerationID: generation.generation.id,
            characterBudget: 1_000,
            now: Date(timeIntervalSince1970: 1_100)
        )
        let baseline = try ContextSelector().select(baselineNeed, from: generation)
        let candidate = try ContextSelector().select(candidateNeed, from: generation)

        #expect(baseline.selectedItems.contains { $0.pointer.sourceID == userSourceID })
        #expect(candidate.selectedItems.allSatisfy { $0.pointer.sourceID != userSourceID })
        #expect(candidate.characterCount < baseline.characterCount)
        #expect(candidate.selectedItems.map(\.text).contains(firstFact))
        #expect(candidate.selectedItems.map(\.text).contains(secondFact))
        print(
            "[memory-quality-metric] duplicate-projection baseline="
                + "\(baseline.characterCount)chars candidate=\(candidate.characterCount)chars"
        )

        // The SAME generation under the live `ContextFlowMode.active` kernel
        // (SOUL only) must NOT suppress: there the packet is USER.md's only
        // carrier. Facts and atoms are held fixed and only the kernel varies,
        // so the kernel is provably what drives the outcome.
        let activeModeMirror = try projectionMirror(
            userText: generatedUSER,
            kernelCarriesUser: false
        )
        let activeModePrecovered = ContextFlowCoordinator.generatedUserProjectionPrecoverage(
            mirror: activeModeMirror,
            kernel: try chatKernel(of: activeModeMirror),
            selectedSources: generation.sources,
            generation: generation
        )
        #expect(activeModePrecovered.isEmpty)
        let activeModeNeed = NeedSignal(
            message: baselineNeed.message,
            surface: baselineNeed.surface,
            origin: baselineNeed.origin,
            authorization: authorization,
            precoveredSourceIDs: activeModePrecovered,
            availableGenerationID: generation.generation.id,
            characterBudget: 1_000,
            now: Date(timeIntervalSince1970: 1_100)
        )
        let activeModePacket = try ContextSelector().select(activeModeNeed, from: generation)
        // The harm this gate prevents: under the active-mode kernel USER.md's
        // atom must stay in the packet, because nothing else is carrying it.
        #expect(activeModePacket.selectedItems.contains { $0.pointer.sourceID == userSourceID })

        let incomplete = storedGeneration([user, firstMemory])
        #expect(ContextFlowCoordinator.generatedUserProjectionPrecoverage(
            mirror: mirror,
            kernel: try chatKernel(of: mirror),
            selectedSources: incomplete.sources,
            generation: incomplete
        ).isEmpty)
        let manualMirror = try projectionMirror(userText: """
        <!-- USER_PREAMBLE_START -->
        A manual instruction that must remain visible.
        <!-- USER_PREAMBLE_END -->

        \(generatedUSER)
        """)
        #expect(ContextFlowCoordinator.generatedUserProjectionPrecoverage(
            mirror: manualMirror,
            kernel: try chatKernel(of: manualMirror),
            selectedSources: generation.sources,
            generation: generation
        ).isEmpty)
    }

    /// The join compares a USER.md line (already through the display renderer)
    /// against a memory atom body (raw stored text). For any row whose stored
    /// text carries a leading timestamp those two strings DIFFER, and the
    /// all-or-nothing join then killed precoverage for the entire document.
    ///
    /// Every pair below is deliberately two DIFFERENT literals — a test that
    /// binds one literal to both sides can never observe this break, which is
    /// exactly how the bug shipped.
    @Test
    func precoverageJoinsTimestampedRecordBodiesAgainstStrippedUSERLines() throws {
        // (fact as USER.md renders it, body as the projection stores it)
        let pairs: [(fact: String, body: String)] = [
            (
                "User keeps the espresso machine on the left counter.",
                "[2026-07-24T09:15:00Z] User keeps the espresso machine on the left counter."
            ),
            (
                "Quiet morning work should never make noise.",
                "2026-07-19 · Quiet morning work should never make noise."
            ),
            (
                "User reviews the release checklist before every ship.",
                "createdAt: 2026-07-20 User reviews the release checklist before every ship."
            ),
            // Date-critical rows are the ONE shape where the two sides are
            // legitimately the same literal: the kind-aware display renderer
            // strips nothing from them, and the atom body is the same stored
            // text, so both sides carry the stamp verbatim. The join must not
            // "fix" that by reducing them — that reduction merged distinct
            // dated records. Distinguishability has its own test with teeth:
            // `dateCriticalFactsDifferingOnlyByDateAreNotCoveredByOneAtom`.
            (
                "2026-08-01 09:00 Dentist appointment downtown.",
                "2026-08-01 09:00 Dentist appointment downtown."
            ),
        ]
        // Guard the guard: three of four pairs must genuinely differ, or the
        // test has quietly degenerated into the single-literal blind spot.
        #expect(pairs.filter { $0.fact != $0.body }.count == 3)

        let generatedUSER = """
        <!-- USER_MD_AUTOGEN_START -->
        # User Facts (auto-generated from memory SQLite)

        \(pairs.map { "- \($0.fact)" }.joined(separator: "\n"))

        <!-- USER_MD_AUTOGEN_END -->
        """
        let user = compiledSource(
            id: "user-generated",
            owner: "nativeagent.persona",
            locator: "persona/Agent/USER.md",
            kind: .relationship,
            body: pairs.map(\.fact).joined(separator: "\n"),
            authority: .explicitCorrection,
            policy: .adaptive
        )
        let memories = pairs.enumerated().map { index, pair in
            compiledSource(
                id: "memory-\(index)",
                owner: "nativeagent.memory-v2",
                locator: "memory-v2/records/\(index)",
                kind: .memory,
                body: pair.body,
                authority: .canonical,
                policy: .adaptive
            )
        }
        let generation = storedGeneration([user] + memories)
        let mirror = try projectionMirror(userText: generatedUSER)
        let outcome = ContextFlowCoordinator.generatedUserProjectionOutcome(
            mirror: mirror,
            kernel: try chatKernel(of: mirror),
            selectedSources: generation.sources,
            generation: generation
        )
        let userSourceID = try #require(user.atoms.first?.sourceID)
        #expect(outcome.precoveredSourceIDs == [userSourceID])

        // The atom bodies themselves are untouched — the shared helper is a
        // comparison key, not a rewrite of what the model reads.
        let storedBodies = Set(generation.atoms.map(\.draft.body))
        #expect(pairs.allSatisfy { storedBodies.contains($0.body) })
    }

    /// A join key that converges the two renderers by DESTROYING leading date
    /// stamps also merges two records that differ only by their date. Both
    /// USER.md lines then reduce to one entry, one admitted atom "covers" the
    /// pair, precoverage suppresses USER.md — and the fact whose atom was NOT
    /// admitted is silently deleted from the turn. Silent context loss.
    ///
    /// Live shape, deliberately mismatched on both axes at once: an ordinary
    /// row whose atom body still carries a storage timestamp the USER.md line
    /// dropped (the convergence the key exists for) sits alongside two
    /// date-critical rows that differ ONLY in their stamp (the distinction the
    /// key must preserve). Passing both at once is the whole requirement.
    @Test
    func dateCriticalFactsDifferingOnlyByDateAreNotCoveredByOneAtom() throws {
        let augustFact = "2026-08-01 09:00 Dentist appointment downtown."
        let septemberFact = "2026-09-01 09:00 Dentist appointment downtown."
        let ordinaryFact = "User keeps the espresso machine on the left counter."
        let ordinaryBody = "[2026-07-24T09:15:00Z] User keeps the espresso machine on the left counter."
        #expect(augustFact != septemberFact)
        #expect(ordinaryFact != ordinaryBody)

        let generatedUSER = """
        <!-- USER_MD_AUTOGEN_START -->
        # User Facts (auto-generated from memory SQLite)

        - \(ordinaryFact)
        - \(augustFact)
        - \(septemberFact)

        <!-- USER_MD_AUTOGEN_END -->
        """
        let user = compiledSource(
            id: "user-generated",
            owner: "nativeagent.persona",
            locator: "persona/Agent/USER.md",
            kind: .relationship,
            body: [ordinaryFact, augustFact, septemberFact].joined(separator: "\n"),
            authority: .explicitCorrection,
            policy: .adaptive
        )
        func memoryAtom(_ id: String, _ body: String) -> ContextCompiledSource {
            compiledSource(
                id: "memory-\(id)",
                owner: "nativeagent.memory-v2",
                locator: "memory-v2/records/\(id)",
                kind: .memory,
                body: body,
                authority: .canonical,
                policy: .adaptive
            )
        }
        let ordinaryMemory = memoryAtom("ordinary", ordinaryBody)
        let augustMemory = memoryAtom("august", augustFact)
        let septemberMemory = memoryAtom("september", septemberFact)
        let mirror = try projectionMirror(userText: generatedUSER)

        // Only the AUGUST atom is admitted. The September fact lives nowhere
        // else in the turn, so USER.md must stay injected and say why.
        let partial = storedGeneration([user, ordinaryMemory, augustMemory])
        let partialOutcome = ContextFlowCoordinator.generatedUserProjectionOutcome(
            mirror: mirror,
            kernel: try chatKernel(of: mirror),
            selectedSources: partial.sources,
            generation: partial
        )
        #expect(partialOutcome == .uncoveredFact(
            fact: septemberFact,
            reason: .admissionAsymmetry
        ))
        #expect(ContextFlowCoordinator.generatedUserProjectionPrecoverage(
            mirror: mirror,
            kernel: try chatKernel(of: mirror),
            selectedSources: partial.sources,
            generation: partial
        ).isEmpty)

        // Mirror image: admitting only SEPTEMBER must strand August, not
        // silently pass because "some dentist atom exists".
        let mirrored = storedGeneration([user, ordinaryMemory, septemberMemory])
        #expect(ContextFlowCoordinator.generatedUserProjectionOutcome(
            mirror: mirror,
            kernel: try chatKernel(of: mirror),
            selectedSources: mirrored.sources,
            generation: mirrored
        ) == .uncoveredFact(fact: augustFact, reason: .admissionAsymmetry))

        // And the key still CONVERGES: with every atom admitted — including the
        // ordinary row whose body carries a stamp its USER.md line dropped —
        // the whole document precovers.
        let complete = storedGeneration([user, ordinaryMemory, augustMemory, septemberMemory])
        let userSourceID = try #require(user.atoms.first?.sourceID)
        #expect(ContextFlowCoordinator.generatedUserProjectionOutcome(
            mirror: mirror,
            kernel: try chatKernel(of: mirror),
            selectedSources: complete.sources,
            generation: complete
        ).precoveredSourceIDs == [userSourceID])
    }

    /// USER.md can carry a fact whose record the memory projection refused
    /// (lifecycle `corrected`, non-durable text, secret shape, size). No atom
    /// carries it, so suppressing USER.md would DELETE that fact from the turn.
    /// The honest behavior is to keep USER.md injected — and to say so, loudly
    /// and once, naming the fact and the reason class.
    @Test
    func projectionRejectedFactKeepsUSERInjectedAndIsNamedInOneDiagnostic() throws {
        let coveredFact = "User reviews the release checklist before every ship."
        // A live shape: the superseded half of a corrected pair. Its record is
        // lifecycle=corrected, so the projection compiles no atom for it.
        let rejectedFact = "User keeps nocturnal hours — 3 AM check-ins observed."
        let generatedUSER = """
        <!-- USER_MD_AUTOGEN_START -->
        # User Facts (auto-generated from memory SQLite)

        - \(coveredFact)
        - \(rejectedFact)

        <!-- USER_MD_AUTOGEN_END -->
        """
        let user = compiledSource(
            id: "user-generated",
            owner: "nativeagent.persona",
            locator: "persona/Agent/USER.md",
            kind: .relationship,
            body: "\(coveredFact)\n\(rejectedFact)",
            authority: .explicitCorrection,
            policy: .adaptive
        )
        let coveredMemory = compiledSource(
            id: "memory-covered",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/records/covered",
            kind: .memory,
            body: "[2026-07-20] \(coveredFact)",
            authority: .canonical,
            policy: .adaptive
        )
        let generation = storedGeneration([user, coveredMemory])
        let mirror = try projectionMirror(userText: generatedUSER)
        let outcome = ContextFlowCoordinator.generatedUserProjectionOutcome(
            mirror: mirror,
            kernel: try chatKernel(of: mirror),
            selectedSources: generation.sources,
            generation: generation
        )

        // Fail SAFE: nothing suppressed, so the uncovered fact still reaches
        // the turn through USER.md.
        #expect(outcome.precoveredSourceIDs.isEmpty)
        #expect(outcome == .uncoveredFact(
            fact: rejectedFact,
            reason: .admissionAsymmetry
        ))

        // ...and it is reported: once, naming the fact and the reason class.
        var reporter = ContextFlowCoordinator.PrecoverageOutcomeReporter()
        let firstMessage = reporter.message(for: outcome)
        let first = try #require(firstMessage)
        #expect(first.contains(rejectedFact))
        #expect(first.contains("admission-asymmetry"))
        let repeatMessage = reporter.message(for: outcome)
        #expect(repeatMessage == nil)

        // A DIFFERENT uncovered fact is a different state and reports again —
        // the dedupe is per-state, not a global mute.
        let otherOutcome = ContextFlowCoordinator.GeneratedUserPrecoverageOutcome.uncoveredFact(
            fact: coveredFact,
            reason: .admissionAsymmetry
        )
        let otherRaw = reporter.message(for: otherOutcome)
        let otherMessage = try #require(otherRaw)
        #expect(otherMessage.contains(coveredFact))
    }

    @Test
    func precoverageDiagnosticSeparatesRendererDivergenceFromAdmissionAsymmetry() throws {
        let fact = "User reviews the release checklist before every ship."
        let generatedUSER = """
        <!-- USER_MD_AUTOGEN_START -->
        # User Facts (auto-generated from memory SQLite)

        - \(fact)

        <!-- USER_MD_AUTOGEN_END -->
        """
        // An atom whose text CONTAINS the fact but does not canonicalize to it
        // — the residual-normalization shape. If a renderer ever drifts again
        // this is the class the log must name, distinct from "no atom at all".
        let nearMiss = compiledSource(
            id: "memory-near",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/records/near",
            kind: .memory,
            body: "note — \(fact)",
            authority: .canonical,
            policy: .adaptive
        )
        let user = compiledSource(
            id: "user-generated",
            owner: "nativeagent.persona",
            locator: "persona/Agent/USER.md",
            kind: .relationship,
            body: fact,
            authority: .explicitCorrection,
            policy: .adaptive
        )
        let generation = storedGeneration([user, nearMiss])
        let outcome = ContextFlowCoordinator.generatedUserProjectionOutcome(
            mirror: try projectionMirror(userText: generatedUSER),
            kernel: try chatKernel(of: try projectionMirror(userText: generatedUSER)),
            selectedSources: generation.sources,
            generation: generation
        )
        #expect(outcome == .uncoveredFact(fact: fact, reason: .rendererDivergence))

        var reporter = ContextFlowCoordinator.PrecoverageOutcomeReporter()
        let message = reporter.message(for: outcome)
        let line = try #require(message)
        #expect(line.contains("renderer-divergence"))
    }

    /// The state this batch's investigation actually landed in (2026-07-24):
    /// on User's LIVE data precoverage SUCCEEDS — 43/43 generated facts carried
    /// by memory atoms — and said nothing at all. Working suppression and
    /// never-ran were the same observation from outside the app; establishing
    /// which one it was took a read of the live SQLite generation.
    ///
    /// Success must therefore be a receipt, and it must name what it bought.
    /// The USER.md line and its atom body are deliberately DIFFERENT literals
    /// (the live shape: stored text keeps a stamp the rendered line dropped),
    /// so a renderer regression cannot pass this by tautology.
    @Test
    func precoverageSuccessReportsWhatItSuppressedOncePerState() throws {
        let firstFact = "User reviews the release checklist before every ship."
        let firstBody = "[2026-07-20T11:02:00Z] User reviews the release checklist before every ship."
        let secondFact = "User's quiet hours end around 03:00."
        let secondBody = "2026-07-18 User's quiet hours end around 03:00."
        #expect(firstFact != firstBody)
        #expect(secondFact != secondBody)

        let generatedUSER = """
        <!-- USER_MD_AUTOGEN_START -->
        # User Facts (auto-generated from memory SQLite)

        - \(firstFact)
        - \(secondFact)

        <!-- USER_MD_AUTOGEN_END -->
        """
        let userBody = "\(firstFact)\n\(secondFact)"
        let user = compiledSource(
            id: "user-generated",
            owner: "nativeagent.persona",
            locator: "persona/canonical/USER.md",
            kind: .relationship,
            body: userBody,
            authority: .explicitCorrection,
            policy: .adaptive
        )
        let memories = [firstBody, secondBody].enumerated().map { index, body in
            compiledSource(
                id: "memory-\(index)",
                owner: "nativeagent.memory-v2",
                locator: "memory-v2/records/\(index)",
                kind: .memory,
                body: body,
                authority: .canonical,
                policy: .adaptive
            )
        }
        let generation = storedGeneration([user] + memories)
        let outcome = ContextFlowCoordinator.generatedUserProjectionOutcome(
            mirror: try projectionMirror(userText: generatedUSER),
            kernel: try chatKernel(of: try projectionMirror(userText: generatedUSER)),
            selectedSources: generation.sources,
            generation: generation
        )
        let summary = try #require({ () -> ContextFlowCoordinator
            .GeneratedUserPrecoverageOutcome.Precovered? in
            guard case .precovered(let summary) = outcome else { return nil }
            return summary
        }())
        #expect(summary.factCount == 2)
        #expect(summary.suppressedAtomCount == 1)
        #expect(summary.suppressedChars == userBody.count)

        var reporter = ContextFlowCoordinator.PrecoverageOutcomeReporter()
        let successMessage = reporter.message(for: outcome)
        // A successful precoverage must leave a receipt; silence is the defect.
        let line = try #require(successMessage)
        // All three summary fields must survive into the line — a receipt
        // missing one of them is a receipt that cannot be reconciled against
        // the packet.
        #expect(line.contains("all 2 generated fact(s)"))
        #expect(line.contains("1 USER.md context atom(s)"))
        #expect(line.contains("\(userBody.count) chars"))
        // The line must state the CONDITION that makes suppression safe — that
        // the stable prompt kernel independently carries USER.md. The previous
        // wording instead asserted the persona lane "injects USER.md
        // separately" unconditionally, which is false in active mode and is
        // precisely the claim that licensed a fact-loss path.
        #expect(line.lowercased().contains("stable prompt kernel"))
        #expect(!line.contains("deliberately untouched by precoverage"))
        // Bounded: the same state does not reprint every turn.
        let repeatMessage = reporter.message(for: outcome)
        #expect(repeatMessage == nil)
    }

    /// `.notApplicable` used to be one opaque case reached by four different
    /// guards, and it emitted nothing — so "precoverage declined" and
    /// "precoverage is broken" produced identical logs. Each guard now names
    /// itself, and each distinct reason reports once.
    @Test
    func precoverageNotApplicableNamesTheGuardThatDeclined() throws {
        let fact = "User reviews the release checklist before every ship."
        let body = "[2026-07-20T11:02:00Z] User reviews the release checklist before every ship."
        #expect(fact != body)
        let generatedUSER = """
        <!-- USER_MD_AUTOGEN_START -->
        # User Facts (auto-generated from memory SQLite)

        - \(fact)

        <!-- USER_MD_AUTOGEN_END -->
        """
        let user = compiledSource(
            id: "user-generated",
            owner: "nativeagent.persona",
            locator: "persona/canonical/USER.md",
            kind: .relationship,
            body: fact,
            authority: .explicitCorrection,
            policy: .adaptive
        )
        let memory = compiledSource(
            id: "memory-0",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/records/0",
            kind: .memory,
            body: body,
            authority: .canonical,
            policy: .adaptive
        )
        let generation = storedGeneration([user, memory])

        func outcome(
            mirrorText: String? = generatedUSER,
            sources: [ContextStoredSource]? = nil
        ) throws -> ContextFlowCoordinator.GeneratedUserPrecoverageOutcome {
            let mirror = try mirrorText.map { try projectionMirror(userText: $0) }
                ?? projectionMirrorWithoutUserDocument()
            return ContextFlowCoordinator.generatedUserProjectionOutcome(
                mirror: mirror,
                kernel: try chatKernel(of: mirror),
                selectedSources: sources ?? generation.sources,
                generation: generation
            )
        }

        // The mirror carries no USER.md at all.
        #expect(try outcome(mirrorText: nil) == .notApplicable(.noUserDocument))

        // A manual preamble — User's hand-written instruction must never be
        // suppressed by a projection argument.
        #expect(try outcome(mirrorText: """
        <!-- USER_PREAMBLE_START -->
        Never schedule anything before 09:00.
        <!-- USER_PREAMBLE_END -->

        \(generatedUSER)
        """) == .notApplicable(.notGeneratedProjection))

        // Well-formed markers, no bullets between them.
        #expect(try outcome(mirrorText: """
        <!-- USER_MD_AUTOGEN_START -->
        # User Facts (auto-generated from memory SQLite)

        <!-- USER_MD_AUTOGEN_END -->
        """) == .notApplicable(.noGeneratedFacts))

        // USER.md source present but degraded — precoverage must decline, and
        // say that it declined for THIS reason rather than a coverage one.
        let degradedUser = generation.sources.map { source in
            source.descriptor.canonicalLocator.hasSuffix("/USER.md")
                ? ContextStoredSource(
                    descriptor: source.descriptor,
                    sourceHash: source.sourceHash,
                    health: .degraded,
                    lastError: "read failed",
                    validFromGeneration: source.validFromGeneration,
                    validToGeneration: source.validToGeneration
                )
                : source
        }
        #expect(try outcome(sources: degradedUser) == .notApplicable(.noHealthyUserSource))

        // No memory sources selected at all — nothing could carry a fact.
        #expect(try outcome(sources: generation.sources.filter {
            $0.descriptor.owner != "nativeagent.memory-v2"
        }) == .notApplicable(.noHealthyMemorySource))

        // Each distinct reason reports once, and the reason class is IN the
        // line — a bare "not applicable" would be the silence this replaced.
        var reporter = ContextFlowCoordinator.PrecoverageOutcomeReporter()
        let userMessage = reporter.message(for: .notApplicable(.noUserDocument))
        let userLine = try #require(userMessage)
        #expect(userLine.contains("no-user-document"))
        let repeatMessage = reporter.message(for: .notApplicable(.noUserDocument))
        #expect(repeatMessage == nil)
        let memoryMessage = reporter.message(for: .notApplicable(.noHealthyMemorySource))
        let memoryLine = try #require(memoryMessage)
        #expect(memoryLine.contains("no-healthy-memory-source"))
    }

    /// The live `ContextFlowMode.active` kernel renders SOUL and VOICE only, so
    /// USER.md is NOT in the stable prompt and the context packet is its only
    /// carrier. Suppressing it there deletes user facts outright.
    ///
    /// Measured on 1053 live context-flow turns (2026-07-24): `stableChars`
    /// held at ~10,564 — below USER.md's own 15,006 bytes, so it was provably
    /// never in the stable segment — while 757 turns (72%) selected ZERO memory
    /// atoms. Precoverage fired on the strength of fact parity alone, and
    /// `precoveredSourceIDs` hard-drops a source from the ranked candidates
    /// (`ContextSelection.select`), so those facts reached no lane at all.
    ///
    /// Every value below is a DISTINCT literal: the fact text differs from the
    /// stored body (leading stamp), and the two kernels differ in which
    /// documents they carry. Nothing is compared against itself.
    @Test
    func precoverageDeclinesWhenStablePromptDoesNotCarryUserDocument() throws {
        let fact = "User's quiet hours end around 03:00 — a 3 AM message means he woke up."
        let body = "[2026-07-24T03:04:00Z] User's quiet hours end around 03:00 "
            + "— a 3 AM message means he woke up."
        // Mismatched by construction: if these were one literal the join could
        // not distinguish a working renderer from a broken one.
        #expect(fact != body)
        let generatedUSER = """
        <!-- USER_MD_AUTOGEN_START -->
        # User Facts (auto-generated from memory SQLite)

        - \(fact)

        <!-- USER_MD_AUTOGEN_END -->
        """
        let user = compiledSource(
            id: "user-generated",
            owner: "nativeagent.persona",
            locator: "persona/canonical/USER.md",
            kind: .relationship,
            body: fact,
            authority: .explicitCorrection,
            policy: .adaptive
        )
        let memory = compiledSource(
            id: "memory-0",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/records/0",
            kind: .memory,
            body: body,
            authority: .canonical,
            policy: .adaptive
        )
        let generation = storedGeneration([user, memory])

        // Coverage parity HOLDS on both sides — the memory atom really does
        // carry the fact. Only the kernel differs, so any behavior difference
        // is attributable to the carrier gate and nothing else.
        let fullMirror = try projectionMirror(userText: generatedUSER, kernelCarriesUser: true)
        let activeMirror = try projectionMirror(userText: generatedUSER, kernelCarriesUser: false)
        #expect(try chatKernel(of: fullMirror).renderedPrompt.contains(fact))
        #expect(!(try chatKernel(of: activeMirror).renderedPrompt.contains(fact)))

        // Stable prompt carries USER.md → suppression is genuine de-duplication.
        let fullOutcome = ContextFlowCoordinator.generatedUserProjectionOutcome(
            mirror: fullMirror,
            kernel: try chatKernel(of: fullMirror),
            selectedSources: generation.sources,
            generation: generation
        )
        let summary = try #require({ () -> ContextFlowCoordinator
            .GeneratedUserPrecoverageOutcome.Precovered? in
            guard case .precovered(let summary) = fullOutcome else { return nil }
            return summary
        }())
        #expect(summary.factCount == 1)
        #expect(summary.suppressedAtomCount == 1)

        // Stable prompt does NOT carry USER.md → must decline, naming the gate.
        let activeOutcome = ContextFlowCoordinator.generatedUserProjectionOutcome(
            mirror: activeMirror,
            kernel: try chatKernel(of: activeMirror),
            selectedSources: generation.sources,
            generation: generation
        )
        #expect(activeOutcome == .notApplicable(.userDocumentNotInStablePrompt))
        #expect(activeOutcome.precoveredSourceIDs.isEmpty)

        // End-to-end: the fact must survive into the packet on the active-mode
        // shape. This is the assertion that would have caught the live loss.
        let authorization = ContextSelectionAuthorization(
            allowedOrigins: [.localAuthenticated],
            allowedPrivacy: [.localPrivate],
            allowedSourceIDs: Set(generation.sources.map(\.descriptor.id))
        )
        let need = NeedSignal(
            message: "when does User's quiet time end",
            surface: .chat,
            origin: .localAuthenticated,
            authorization: authorization,
            precoveredSourceIDs: activeOutcome.precoveredSourceIDs,
            availableGenerationID: generation.generation.id,
            characterBudget: 1_000,
            now: Date(timeIntervalSince1970: 1_100)
        )
        let packet = try ContextSelector().select(need, from: generation)
        let userSourceID = try #require(user.atoms.first?.sourceID)
        #expect(packet.selectedItems.contains { $0.pointer.sourceID == userSourceID })

        // The receipt must name the gate, so this state is diagnosable from
        // logs alone rather than by reading the user's SQLite store.
        var reporter = ContextFlowCoordinator.PrecoverageOutcomeReporter()
        let gateMessage = reporter.message(for: activeOutcome)
        let line = try #require(gateMessage)
        #expect(line.contains("user-document-not-in-stable-prompt"))
        #expect(line.contains("only carrier"))
        let repeatGateMessage = reporter.message(for: activeOutcome)
        #expect(repeatGateMessage == nil)
    }

    /// "Bounded" has to survive CHURN, not just repetition. A memo that evicts
    /// or clears on overflow bounds memory while leaving emission unbounded —
    /// a rotating state would then print on every turn forever, which is the
    /// per-turn printer the memo exists to prevent. Past the cap the reporter
    /// mutes itself, and says once that it did.
    @Test
    func precoverageReporterMutesItselfAloudInsteadOfPrintingForever() throws {
        var reporter = ContextFlowCoordinator.PrecoverageOutcomeReporter()
        let cap = ContextFlowCoordinator.PrecoverageOutcomeReporter.signatureCap
        let states = (0..<(cap + 4)).map { index in
            ContextFlowCoordinator.GeneratedUserPrecoverageOutcome.uncoveredFact(
                fact: "Churning fact number \(index).",
                reason: .admissionAsymmetry
            )
        }
        var lines: [String] = []
        // Two full passes: the second would double the output if the memo
        // cleared instead of muting.
        for _ in 0..<2 {
            for state in states {
                if let line = reporter.message(for: state) { lines.append(line) }
            }
        }
        #expect(lines.count == cap + 1)
        let mutedLine = try #require(lines.last)
        #expect(mutedLine.contains("muted"))
        // Even a brand-new state stays quiet once muted.
        let afterMute = reporter.message(for: .notApplicable(.noUserDocument))
        #expect(afterMute == nil)
    }

}
