import Context
import Foundation

enum NativeMarkdownContextSourceCatalogError: Error, Equatable, Sendable {
    case nonFilePersonaRoot(String)
    case nonCanonicalPersonaRoot(supplied: String, canonical: String)
    case personaRootNotDirectory(String)
    case skillBodiesRootNotDirectory(String)
    case symbolicLinkNotAllowed(String)
    case symbolicLinkEscape(path: String, target: String)
    case caseCollidingNames(String, String)
}

struct NativeMarkdownContextSourceCatalog: Sendable, Equatable {
    static let maximumSourceCount = 128
    static let maximumSourceUTF8Bytes = 256 * 1_024

    let allowedRoots: [URL]
    let registrations: [ContextSourceRegistration]

    private static let owner = "nativeagent.markdown.skill-bodies"
    private static let permittedSurfaces: Set<ContextSurface> = [
        .chat, .telegram, .ios, .slack, .workshop, .bridge,
    ]
    private static let resourceKeys: Set<URLResourceKey> = [
        .fileSizeKey,
        .isDirectoryKey,
        .isHiddenKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
    ]

    init(
        personaRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        self = try Self.build(personaRoot: personaRoot, fileManager: fileManager)
    }

    static func build(
        personaRoot: URL,
        fileManager: FileManager = .default
    ) throws -> Self {
        let canonicalPersonaRoot = try validateCanonicalPersonaRoot(
            personaRoot,
            fileManager: fileManager
        )
        let bodiesRoot = canonicalPersonaRoot
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("bodies", isDirectory: true)
            .standardizedFileURL

        guard fileManager.fileExists(atPath: bodiesRoot.path) else {
            return Self(allowedRoots: [canonicalPersonaRoot], registrations: [])
        }

        let bodiesValues = try bodiesRoot.resourceValues(forKeys: resourceKeys)
        guard bodiesValues.isSymbolicLink != true else {
            let target = bodiesRoot.resolvingSymlinksInPath().standardizedFileURL
            guard isDescendant(target, of: canonicalPersonaRoot) else {
                throw NativeMarkdownContextSourceCatalogError.symbolicLinkEscape(
                    path: bodiesRoot.path,
                    target: target.path
                )
            }
            throw NativeMarkdownContextSourceCatalogError.symbolicLinkNotAllowed(
                bodiesRoot.path
            )
        }
        guard bodiesValues.isDirectory == true else {
            throw NativeMarkdownContextSourceCatalogError.skillBodiesRootNotDirectory(
                bodiesRoot.path
            )
        }

        let resolvedBodiesRoot = bodiesRoot.resolvingSymlinksInPath().standardizedFileURL
        guard isDescendant(resolvedBodiesRoot, of: canonicalPersonaRoot) else {
            throw NativeMarkdownContextSourceCatalogError.symbolicLinkEscape(
                path: bodiesRoot.path,
                target: resolvedBodiesRoot.path
            )
        }

        let entries = try fileManager.contentsOfDirectory(
            at: bodiesRoot,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        var candidates: [(url: URL, name: String, key: String, bytes: Int?)] = []

        for entry in entries {
            let values = try entry.resourceValues(forKeys: resourceKeys)
            if values.isSymbolicLink == true {
                let target = entry.resolvingSymlinksInPath().standardizedFileURL
                guard isDescendant(target, of: resolvedBodiesRoot) else {
                    throw NativeMarkdownContextSourceCatalogError.symbolicLinkEscape(
                        path: entry.path,
                        target: target.path
                    )
                }
                continue
            }
            guard values.isRegularFile == true,
                  values.isHidden != true,
                  entry.pathExtension == "md" else {
                continue
            }

            let name = entry.lastPathComponent
            guard !isCredentialFileName(name) else {
                continue
            }
            candidates.append((
                url: entry.standardizedFileURL,
                name: name,
                key: collisionKey(for: name),
                bytes: values.fileSize
            ))
        }

        try validateUniqueNames(candidates.map(\.name))
        candidates.sort {
            if $0.key != $1.key { return $0.key < $1.key }
            return $0.name < $1.name
        }

        let registrations = Array(candidates.lazy
            .filter { candidate in
                guard let bytes = candidate.bytes else { return false }
                return bytes <= maximumSourceUTF8Bytes
            }
            .prefix(maximumSourceCount)
            .map { candidate in
                let locator = "skills/bodies/\(candidate.key)"
                let descriptor = ContextSourceDescriptor(
                    id: ContextStableID.source(owner: owner, locator: locator),
                    owner: owner,
                    kind: .skill,
                    canonicalLocator: locator,
                    authority: .approved,
                    privacy: .localPrivate,
                    permittedSurfaces: permittedSurfaces,
                    injectionPolicy: .onDemand
                )
                return ContextSourceRegistration(
                    descriptor: descriptor,
                    fileURL: candidate.url,
                    allowedRoot: canonicalPersonaRoot,
                    maximumUTF8Bytes: maximumSourceUTF8Bytes
                )
            })

        return Self(
            allowedRoots: [canonicalPersonaRoot],
            registrations: registrations
        )
    }

    static func make(
        personaRoot: URL,
        fileManager: FileManager = .default
    ) throws -> Self {
        try build(personaRoot: personaRoot, fileManager: fileManager)
    }

    static func validateUniqueNames(_ names: [String]) throws {
        var namesByKey: [String: String] = [:]
        for name in names {
            let key = collisionKey(for: name)
            if let existing = namesByKey[key] {
                throw NativeMarkdownContextSourceCatalogError.caseCollidingNames(
                    existing,
                    name
                )
            }
            namesByKey[key] = name
        }
    }

    static func collisionKey(for name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private init(
        allowedRoots: [URL],
        registrations: [ContextSourceRegistration]
    ) {
        self.allowedRoots = allowedRoots
        self.registrations = registrations
    }

    private static func validateCanonicalPersonaRoot(
        _ personaRoot: URL,
        fileManager: FileManager
    ) throws -> URL {
        guard personaRoot.isFileURL else {
            throw NativeMarkdownContextSourceCatalogError.nonFilePersonaRoot(
                personaRoot.absoluteString
            )
        }
        let supplied = personaRoot.standardizedFileURL
        let canonical = supplied.resolvingSymlinksInPath().standardizedFileURL
        guard supplied.path == canonical.path else {
            throw NativeMarkdownContextSourceCatalogError.nonCanonicalPersonaRoot(
                supplied: supplied.path,
                canonical: canonical.path
            )
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw NativeMarkdownContextSourceCatalogError.personaRootNotDirectory(
                canonical.path
            )
        }
        let values = try canonical.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw NativeMarkdownContextSourceCatalogError.symbolicLinkNotAllowed(
                canonical.path
            )
        }
        return canonical
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func isCredentialFileName(_ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension
        let normalized = collisionKey(for: stem)
        if normalized == ".env" || normalized.hasPrefix(".env.") {
            return true
        }
        let exactSensitiveNames: Set<String> = [
            "apikey", "apikeys", "auth", "credential", "credentials", "key", "keys",
            "oauth", "passwd", "password", "passwords", "privatekey", "privatekeys",
            "secret", "secrets", "token", "tokens",
        ]
        if exactSensitiveNames.contains(normalized) { return true }

        let components = normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let sensitiveComponents: Set<Substring> = [
            "apikey", "apikeys", "credential", "credentials", "passwd", "password",
            "passwords", "privatekey", "privatekeys", "secret", "secrets", "token",
            "tokens",
        ]
        if !sensitiveComponents.isDisjoint(with: components) { return true }
        return (components.contains("api") || components.contains("private"))
            && (components.contains("key") || components.contains("keys"))
    }
}
