import Context

/// Maps a persona SLOT id (ContextFlow/PersonaEngine vocabulary: "canonical"
/// or a custom persona subdirectory name) to the persona filter MemoryV2
/// understands (RECORD persona ids — agent names like
/// `MemoryV2Defaults.personaID`). Every ChatOrchestration site that feeds a
/// slot id into a MemoryV2 persona filter MUST route through this helper.
///
/// PRODUCT POLICY (User approved, 2026-07-24): **a persona slot id is
/// PRESENTATION-ONLY.** Every slot — resident *and* custom — reads the ONE
/// shared memory store, unfiltered. This function therefore always answers
/// "no persona filter". That is a deliberate, named mapping, not a value that
/// happens to match nothing. The reasoning, so nobody "restores" the old
/// behavior later:
///
///   * The live store's `personaId` vocabulary is ONLY configured agent names
///     (36 active rows) and "NativeAgent" (85 active). VERIFIED 2026-07-24. No
///     production writer ever stamps a persona SLOT id into `personaId`.
///   * So passing a custom slot id through was never isolation — it was an
///     id-vocabulary mismatch wearing isolation's clothes. A custom persona's
///     "own scope" is UNMINTABLE: no writer can put a record in it. It
///     protected an empty set forever while costing the entire memory feature
///     (zero context atoms AND zero recall hits) for every custom persona.
///   * NativeAgent is deliberately ONE agent (User, 2026-07-24) that may spawn
///     subagents but is NOT a multi-agent system. Persona docs change how she
///     SOUNDS, not who she IS; memory is the continuity. Sharding memory per
///     persona mask would be a quiet step toward a fleet and contradicts the
///     northstar's "one mind, no theater".
///   * If genuine compartmentalization is ever wanted (say a demo persona that
///     must not see personal memories), its home is the per-record DISCLOSURE
///     layer — `MemoryRecordDisclosurePolicy.classify(_:)` /
///     `.permits(surface:personaID:)`, already surface- and persona-aware —
///     NOT a storage-level persona filter. Add the rule there; do not
///     reintroduce a slot-id filter here.
package func memoryRecallPersonaFilter(_ slotID: String?) -> String? {
    guard let slotID, slotID != ContextPersonaID.resident.rawValue else {
        // No slot in play, or the resident default slot: unfiltered.
        return nil
    }
    // CUSTOM PERSONA SLOT (a persona subdirectory name). Also unfiltered, by
    // the policy above: the mask changes the voice, not the memory store.
    return nil
}
