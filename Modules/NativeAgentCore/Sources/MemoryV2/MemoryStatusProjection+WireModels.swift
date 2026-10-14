import Foundation

// Swift-native embeddings backend status payload. The field names preserve
// the former daemon wire shape so existing UI/state decoding stays stable.
// The active runtime is one of: CoreML MiniLM, explicit mock (config or env
// opt-in), or fail-closed (CoreML resources missing / load failed).

public struct EmbeddingsStatus: Codable, Hashable, Sendable {
    public var libraryAvailable: Bool
    public var modelLoadable: Bool?
    public var configBackend: String         // "coreml-minilm" | "mock" | legacy "local"
    public var envEnabled: Bool
    // effectiveBackend is the runtime terminal state for THIS panel:
    //   "local"       -> CoreML MiniLM serving real semantic vectors
    //   "hash"        -> mock vectors (explicit user opt-out OR env opt-in)
    //   "unavailable" -> fail-closed (resources missing / load failed and
    //                    no env opt-in; embed() throws)
    public var effectiveBackend: String      // "local" | "hash" | "unavailable"
    public var modelName: String
    public var requestedEnabled: Bool
    public var memoryMode: String?
    public var memoryModeDetail: EmbeddingsMemoryModeDetail?
    public var idleUnloadSeconds: Int?
    public var modelState: EmbeddingsModelState?
    public var installState: EmbeddingsInstallState?
    public var reindexState: EmbeddingsInstallState?
    public var extrasPath: String?

    public init(libraryAvailable: Bool, modelLoadable: Bool?, configBackend: String, envEnabled: Bool, effectiveBackend: String, modelName: String, requestedEnabled: Bool, memoryMode: String?, memoryModeDetail: EmbeddingsMemoryModeDetail?, idleUnloadSeconds: Int?, modelState: EmbeddingsModelState?, installState: EmbeddingsInstallState?, reindexState: EmbeddingsInstallState?, extrasPath: String?) {
        self.libraryAvailable = libraryAvailable; self.modelLoadable = modelLoadable; self.configBackend = configBackend
        self.envEnabled = envEnabled; self.effectiveBackend = effectiveBackend; self.modelName = modelName
        self.requestedEnabled = requestedEnabled; self.memoryMode = memoryMode; self.memoryModeDetail = memoryModeDetail
        self.idleUnloadSeconds = idleUnloadSeconds; self.modelState = modelState; self.installState = installState
        self.reindexState = reindexState; self.extrasPath = extrasPath
    }
}

public struct EmbeddingsMemoryModeDetail: Codable, Hashable, Sendable {
    public var mode: String?
    public var title: String?
    public var detail: String?
    public var idleUnloadSeconds: Int?

    public init(mode: String?, title: String?, detail: String?, idleUnloadSeconds: Int?) {
        self.mode = mode; self.title = title; self.detail = detail
        self.idleUnloadSeconds = idleUnloadSeconds
    }
}

public struct EmbeddingsModelState: Codable, Hashable, Sendable {
    public var mode: String?
    public var loaded: Bool?
    public var parentLoaded: Bool?
    public var workerRunning: Bool?
    public var workerPid: Int?
    public var lastUsedAt: String?
    public var lastLoadedAt: String?
    public var lastUnloadedAt: String?
    public var unloadReason: String?
    public var loadCount: Int?
    public var unloadCount: Int?
    public var cacheSize: Int?
    public var cacheMaxSize: Int?

    public init(mode: String?, loaded: Bool?, parentLoaded: Bool?, workerRunning: Bool?, workerPid: Int?, lastUsedAt: String?, lastLoadedAt: String?, lastUnloadedAt: String?, unloadReason: String?, loadCount: Int?, unloadCount: Int?, cacheSize: Int?, cacheMaxSize: Int?) {
        self.mode = mode; self.loaded = loaded; self.parentLoaded = parentLoaded
        self.workerRunning = workerRunning; self.workerPid = workerPid; self.lastUsedAt = lastUsedAt
        self.lastLoadedAt = lastLoadedAt; self.lastUnloadedAt = lastUnloadedAt; self.unloadReason = unloadReason
        self.loadCount = loadCount; self.unloadCount = unloadCount; self.cacheSize = cacheSize
        self.cacheMaxSize = cacheMaxSize
    }
}

// Result envelope for embedding settings changes.
public struct EmbeddingsToggleResult: Codable, Hashable, Sendable {
    public var ok: Bool?
    public var error: String?
    public var detail: String?
    public var status: EmbeddingsStatus

    public init(ok: Bool?, error: String?, detail: String?, status: EmbeddingsStatus) {
        self.ok = ok; self.error = error; self.detail = detail
        self.status = status
    }
}

// Progress payload embedded inside EmbeddingsStatus (installState /
// reindexState). Retained for model-prep/indexing status and legacy decode
// compatibility.
// state: "idle" | "installing" | "running" | "complete" | "failed".
public struct EmbeddingsInstallState: Codable, Hashable, Sendable {
    public var state: String
    public var currentStep: String?
    public var progress: Int?
    public var error: String?
    public var detail: String?
    public var startedAt: String?
    public var failedAt: String?
    public var completedAt: String?
    public var extrasPath: String?
    public var hfCachePath: String?
    public var total: Int?
    public var candidates: Int?
    public var embedded: Int?
    public var skipped: Int?
    public var failed: Int?
    public var reason: String?
    public var lastUpdatedAt: String?

    public init(state: String, currentStep: String?, progress: Int?, error: String?, detail: String?, startedAt: String?, failedAt: String?, completedAt: String?, extrasPath: String?, hfCachePath: String?, total: Int?, candidates: Int?, embedded: Int?, skipped: Int?, failed: Int?, reason: String?, lastUpdatedAt: String?) {
        self.state = state; self.currentStep = currentStep; self.progress = progress
        self.error = error; self.detail = detail; self.startedAt = startedAt
        self.failedAt = failedAt; self.completedAt = completedAt; self.extrasPath = extrasPath
        self.hfCachePath = hfCachePath; self.total = total; self.candidates = candidates
        self.embedded = embedded; self.skipped = skipped; self.failed = failed
        self.reason = reason; self.lastUpdatedAt = lastUpdatedAt
    }
}
