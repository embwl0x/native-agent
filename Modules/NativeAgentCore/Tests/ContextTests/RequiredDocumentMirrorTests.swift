import Foundation
import Testing
@testable import Context

private func makeRequiredDocument(
    _ id: String,
    order: Int,
    text: String,
    hash: String? = nil,
    tokens: Int = 1
) throws -> RequiredDocument {
    try RequiredDocument(
        id: RequiredDocumentID(rawValue: id),
        canonicalOrder: order,
        sourceHash: hash ?? "hash-\(id)",
        text: text,
        tokenCount: tokens
    )
}

private func makeStandardDocument(_ kind: RequiredPersonaDocumentKind) throws -> RequiredDocument {
    try RequiredDocument(
        kind: kind,
        sourceHash: "hash-\(kind.rawValue)",
        text: "text-\(kind.rawValue)",
        tokenCount: 1
    )
}

@Test func defaultRequiredDocumentsMatchLivePersonaCompilerOrderWithOptionalMemory() throws {
    let withoutMemory = RequiredPersonaDocumentKind.defaultOrder(includeMemory: false)
    let withMemory = RequiredPersonaDocumentKind.defaultOrder(includeMemory: true)

    #expect(withoutMemory == [.soul, .voice, .user, .growth, .agents])
    #expect(withMemory == [.soul, .voice, .user, .growth, .memory, .agents])
    #expect(RequiredPersonaDocumentKind.memory.isOptional)
    #expect(!RequiredPersonaDocumentKind.agents.isOptional)

    let documents = try withMemory.reversed().map(makeStandardDocument)
    let persona = ContextPersonaID(rawValue: "standard-persona")
    let fingerprint = "standard-fingerprint"
    let kernel = try StablePromptKernel(
        key: StablePromptKernelKey(
            personaID: persona,
            surfaceVariant: ContextSurfaceVariant(rawValue: "mac"),
            sourceFingerprint: fingerprint
        ),
        renderedPrompt: "stable standard prompt",
        includedDocumentIDs: withMemory.map(\.id),
        tokenCount: 6
    )
    let mirror = try RequiredDocumentMirror(
        personaID: persona,
        sourceFingerprint: fingerprint,
        documents: documents,
        kernels: [kernel]
    )

    #expect(mirror.documents.map(\.id) == withMemory.map(\.id))
    #expect(mirror.document(id: RequiredPersonaDocumentKind.memory.id)?.text == "text-MEMORY.md")
}

@Test func requiredDocumentMirrorPreservesExactTextAndCanonicalOrder() throws {
    let soulText = "Identity\n\nExact trailing space: \n"
    let userText = "User and cafe\u{301}"
    let soul = try makeRequiredDocument("SOUL.md", order: 0, text: soulText, tokens: 7)
    let user = try makeRequiredDocument("USER.md", order: 1, text: userText, tokens: 4)
    let persona = ContextPersonaID(rawValue: "custom-agent")
    let surface = ContextSurfaceVariant(rawValue: "mac-local")
    let fingerprint = "persona-fingerprint-v1"
    let key = try StablePromptKernelKey(
        personaID: persona,
        surfaceVariant: surface,
        sourceFingerprint: fingerprint
    )
    let kernel = try StablePromptKernel(
        key: key,
        renderedPrompt: soulText + "\n" + userText,
        includedDocumentIDs: [soul.id, user.id],
        tokenCount: 11
    )

    let mirror = try RequiredDocumentMirror(
        personaID: persona,
        sourceFingerprint: fingerprint,
        documents: [user, soul],
        kernels: [kernel]
    )

    #expect(mirror.documents.map(\.id) == [soul.id, user.id])
    #expect(mirror.document(id: soul.id)?.text == soulText)
    #expect(mirror.document(id: user.id)?.text == userText)
    #expect(mirror.characterCount == soulText.count + userText.count)
    #expect(mirror.tokenCount == 11)
    #expect(mirror.kernel(for: surface) == kernel)
    #expect(soul.utf8ByteCount == soulText.utf8.count)
    #expect(user.utf8ByteCount == userText.utf8.count)
}

@Test func stableKernelKeysSeparatePersonaSurfaceAndFingerprint() throws {
    let document = try makeRequiredDocument("IDENTITY.md", order: 0, text: "identity")
    let personaA = ContextPersonaID(rawValue: "persona-a")
    let personaB = ContextPersonaID(rawValue: "persona-b")
    let mac = ContextSurfaceVariant(rawValue: "mac")
    let phone = ContextSurfaceVariant(rawValue: "phone")
    let fingerprint = "fp-1"

    let macKernel = try StablePromptKernel(
        key: StablePromptKernelKey(
            personaID: personaA,
            surfaceVariant: mac,
            sourceFingerprint: fingerprint
        ),
        renderedPrompt: "mac identity",
        includedDocumentIDs: [document.id],
        tokenCount: 2
    )
    let phoneKernel = try StablePromptKernel(
        key: StablePromptKernelKey(
            personaID: personaA,
            surfaceVariant: phone,
            sourceFingerprint: fingerprint
        ),
        renderedPrompt: "phone identity",
        includedDocumentIDs: [document.id],
        tokenCount: 2
    )
    let mirror = try RequiredDocumentMirror(
        personaID: personaA,
        sourceFingerprint: fingerprint,
        documents: [document],
        kernels: [phoneKernel, macKernel]
    )

    #expect(mirror.kernel(for: mac)?.renderedPrompt == "mac identity")
    #expect(mirror.kernel(for: phone)?.renderedPrompt == "phone identity")
    #expect(
        try StablePromptKernelKey(
            personaID: personaB,
            surfaceVariant: mac,
            sourceFingerprint: fingerprint
        ) != macKernel.key
    )
    #expect(
        try StablePromptKernelKey(
            personaID: personaA,
            surfaceVariant: mac,
            sourceFingerprint: "fp-2"
        ) != macKernel.key
    )
}

@Test func mirrorAllowsCanonicalKernelSubsetButRejectsReorderingOrCrossPersonaKernel() throws {
    let first = try makeRequiredDocument("FIRST.md", order: 0, text: "first")
    let second = try makeRequiredDocument("SECOND.md", order: 1, text: "second")
    let persona = ContextPersonaID(rawValue: "persona")
    let otherPersona = ContextPersonaID(rawValue: "other")
    let surface = ContextSurfaceVariant(rawValue: "mac")
    let incomplete = try StablePromptKernel(
        key: StablePromptKernelKey(
            personaID: persona,
            surfaceVariant: surface,
            sourceFingerprint: "fp"
        ),
        renderedPrompt: "first",
        includedDocumentIDs: [first.id],
        tokenCount: 1
    )

    let subsetMirror = try RequiredDocumentMirror(
        personaID: persona,
        sourceFingerprint: "fp",
        documents: [first, second],
        kernels: [incomplete]
    )
    #expect(subsetMirror.kernel(for: surface)?.includedDocumentIDs == [first.id])

    let reordered = try StablePromptKernel(
        key: incomplete.key,
        renderedPrompt: "second\nfirst",
        includedDocumentIDs: [second.id, first.id],
        tokenCount: 2
    )
    #expect(throws: RequiredDocumentMirrorError.self) {
        try RequiredDocumentMirror(
            personaID: persona,
            sourceFingerprint: "fp",
            documents: [first, second],
            kernels: [reordered]
        )
    }

    let wrongPersona = try StablePromptKernel(
        key: StablePromptKernelKey(
            personaID: otherPersona,
            surfaceVariant: surface,
            sourceFingerprint: "fp"
        ),
        renderedPrompt: "first\nsecond",
        includedDocumentIDs: [first.id, second.id],
        tokenCount: 2
    )
    #expect(throws: RequiredDocumentMirrorError.self) {
        try RequiredDocumentMirror(
            personaID: persona,
            sourceFingerprint: "fp",
            documents: [first, second],
            kernels: [wrongPersona]
        )
    }
}

@Test func requiredDocumentLogicalBytesAreDeterministic() throws {
    let text = "A\u{00E9}\u{1F642}"
    let document = try makeRequiredDocument("VOICE.md", order: 0, text: text, hash: "abc", tokens: 3)
    let expected = 48
        + "VOICE.md".utf8.count
        + "abc".utf8.count
        + text.utf8.count

    #expect(document.logicalByteCount == expected)
    #expect(document.characterCount == text.count)
    #expect(document.utf8ByteCount == text.utf8.count)
}
