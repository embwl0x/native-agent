# A2A 1.0 gRPC decision report

Researched 2026-09-19. The binding is now implemented; see
[integration and proof](a2a-grpc-integration.md) for the actual NativeAgent
measurements. The dependency research and standalone probe below predate that
implementation and are retained with their original measurement boundaries.

## Implementation required

Use the official [gRPC Swift 2 stack](https://github.com/grpc/grpc-swift-2), not the legacy `grpc-swift` 1.x package. The compatible top-level releases inspected were:

| Package | Exact version | Runtime product |
| --- | --- | --- |
| [grpc-swift-2](https://github.com/grpc/grpc-swift-2/tree/2.4.3) | 2.4.3 | `GRPCCore` |
| [grpc-swift-nio-transport](https://github.com/grpc/grpc-swift-nio-transport/tree/2.10.0) | 2.10.0 | `GRPCNIOTransportHTTP2TransportServices` for this macOS app |
| [grpc-swift-protobuf](https://github.com/grpc/grpc-swift-protobuf/tree/2.4.1) | 2.4.1 | `GRPCProtobuf` |

These manifests require Swift tools 6.1; NativeAgent's manifest currently declares 6.0, while the installed compiler used for this investigation is Apple Swift 6.4 targeting arm64 macOS 26. NativeAgent's macOS 26 minimum exceeds the stack's macOS 15 availability floor.

1. Pin the [A2A v1.0.0 protobuf schema](https://github.com/a2aproject/A2A/blob/v1.0.0/specification/a2a.proto), commit `173695755607e884aa9acf8ce4feed90e32727a1`, plus its Google API annotation imports. Generate Swift protobuf messages with `protoc-gen-swift` and client/server interfaces with `protoc-gen-grpc-swift-2`. `protoc` and these generators are development tools; generated Swift can be checked in so consumers do not need to run the generators.
2. Add small protobuf adapters to the existing canonical A2A message/task/card/config model. Generated wire types must not become a second task store. Implement the same eleven operations: SendMessage, SendStreamingMessage, GetTask, ListTasks, CancelTask, SubscribeToTask, CreateTaskPushNotificationConfig, GetTaskPushNotificationConfig, ListTaskPushNotificationConfigs, DeleteTaskPushNotificationConfig, and GetExtendedAgentCard.
3. Run an app-owned HTTP/2 gRPC server transport on a separate **loopback-only** port with explicit app-lifetime startup/shutdown. The existing bridge manually parses/writes HTTP/1.1 (`BridgeCore.swift`, `NativeAgentA2AWire+Runtime.swift`); adding a route alone cannot supply HTTP/2 framing, stream multiplexing, flow control, or gRPC trailers. Replacing that bridge to share its port would be a materially larger alternative.
4. Authenticate gRPC `authorization: Bearer …` metadata before dispatch, use the same caller ownership checks, map protocol failures to the A2A-specified gRPC status/details, and propagate deadline/cancellation and backpressure through both streaming operations. Preserve the same bounded task/history behavior and outbound webhook policy.
5. Add client transport selection for cards advertising `GRPC`, outbound TLS peer verification, bearer metadata, deadlines, retries where semantically safe, and the existing streaming/polling recovery. Advertise the new endpoint only after it is actually serving; retain JSON-RPC and HTTP+JSON fallback.
6. Prove the generated Swift server and client against the official Python SDK's gRPC binding, including unary calls, both server streams, auth failures, status details, cancellation, and graceful shutdown. The integration report records this proof.

## Dependency and size impact

NativeAgent's current lockfiles have only Sparkle 2.9.4, GRDB.swift 7.11.0, and Yams 5.1.3 as external pins. All of this gRPC graph would be additional.

The [transport manifest](https://github.com/grpc/grpc-swift-nio-transport/blob/2.10.0/Package.swift) declares SwiftNIO, NIOHTTP2, NIOTransportServices, NIOSSL, NIOExtras, SwiftCertificates, and SwiftASN1. Core adds SwiftCollections, and serialization adds SwiftProtobuf. Their transitive manifests additionally bring SwiftAtomics, SwiftSystem, SwiftCrypto, SwiftHTTPTypes, SwiftHTTPStructuredHeaders, SwiftAlgorithms, SwiftNumerics, SwiftServiceLifecycle, SwiftAsyncAlgorithms, and SwiftLog. The full resolved package graph is larger than the subset of products linked into the executable.

For macOS, select the TransportServices product and its `HTTP2ClientTransport.TransportServices` / `HTTP2ServerTransport.TransportServices` implementations. They use Apple's Network framework. The umbrella `GRPCNIOTransportHTTP2` product also includes the POSIX transport, NIOSSL's vendored BoringSSL, and certificate/ASN.1 handling. Those extra targets are unnecessary for an Apple-only transport. SwiftPM can still fetch/resolve packages declared by the manifest even when their targets are not selected.

Measured GitHub release source downloads (gzip tarballs, not linked code). A temporary SwiftPM resolution using archive-backed local Git mirrors accepted this exact compatible graph; the local mirror commits are measurement infrastructure, not upstream commit pins:

| Package | Version | Compressed archive bytes |
| --- | --- | ---: |
| grpc-swift-2 | 2.4.3 | 311,732 |
| grpc-swift-nio-transport | 2.10.0 | 314,647 |
| grpc-swift-protobuf | 2.4.1 | 89,716 |
| swift-algorithms | 1.2.1 | 256,577 |
| swift-asn1 | 1.7.3 | 331,563 |
| swift-async-algorithms | 1.1.5 | 245,125 |
| swift-atomics | 1.3.1 | 189,191 |
| swift-certificates | 1.20.0 | 627,696 |
| swift-collections | 1.6.0 | 5,906,194 |
| swift-crypto | 4.5.2 | 10,289,736 |
| swift-http-structured-headers | 1.7.0 | 95,776 |
| swift-http-types | 1.8.0 | 65,348 |
| swift-log | 1.15.1 | 111,431 |
| swift-nio | 2.103.0 | 1,478,416 |
| swift-nio-extras | 1.35.1 | 522,561 |
| swift-nio-http2 | 1.46.0 | 6,116,495 |
| swift-nio-ssl | 2.37.5 | 2,704,718 |
| swift-nio-transport-services | 1.28.0 | 88,351 |
| swift-numerics | 1.1.1 | 71,203 |
| swift-protobuf | 1.38.1 | 6,857,050 |
| swift-service-lifecycle | 2.12.0 | 45,630 |
| swift-system | 1.8.1 | 152,460 |
| **22-package total** | | **36,871,616 (35.16 MiB)** |

Extracted regular-file total, including dotfiles, examples and tests but excluding `.git`, was **216,863,322 bytes (206.82 MiB)**. The three direct packages alone are 716,095 compressed bytes. Reproduce downloads using `https://codeload.github.com/<organization>/<package>/tar.gz/refs/tags/<version>`; organizations are `grpc`, `apple`, and `swift-server` (swift-service-lifecycle). SwiftCrypto 4.5.2 was chosen because the resolved graph excludes 5.x. These source/download numbers are not an app-size estimate.

## Build and shipped bundle

An isolated release benchmark on this **Apple M5 Max, 128 GiB RAM, Apple Swift 6.4, arm64** host used four build jobs, the versions above, and a macOS 15 deployment floor. All sources, local mirrors, SwiftPM cache/config/security directories and artifacts stayed under `/tmp/nativeagent-grpc-impact.VpRUVL`; every SwiftPM command used `--disable-keychain`. No app listener was started. The probe instantiated both TransportServices client and server transports and printed their types, so it actually linked transport implementation rather than only importing modules.

| Measurement | Result |
| --- | ---: |
| Cold release build, dependencies already supplied as local source mirrors | 63.21 s wall clock |
| SwiftPM-reported compilation/build phase within that command | 40.55 s |
| Warm unchanged build command | 8.73 s wall clock; SwiftPM build phase 0.77 s |
| Matching dependency-free hello-world release build | 2.14 s wall clock; build phase 1.22 s |
| Stripped arm64 transport probe executable | 8,062,992 bytes |
| Stripped arm64 hello-world executable | 50,384 bytes |
| **Measured minimal probe executable difference** | **8,012,608 bytes (7.64 MiB)** |
| Generated SwiftProtobuf resource bundle regular files | 1,523 bytes |
| Generated NIOPosix resource bundle regular files | 1,730 bytes |

The initial ordinary remote resolution was stopped after **365.31 seconds** while still fetching SwiftCollections Git history; that is download time, not compile time. Archive-backed mirrors removed that bottleneck. The 63.21-second result excludes downloading and creating those mirrors. This was one sample with concurrent app work on the host, not a statistically isolated performance study.

The probe source was:

```swift
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import GRPCProtobuf
let server = HTTP2ServerTransport.TransportServices(
    address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext)
let client = try HTTP2ClientTransport.TransportServices(
    target: .ipv4(address: "127.0.0.1", port: 1), transportSecurity: .plaintext)
print(type(of: server), type(of: client))
```

Command shape: `swift build --disable-keychain --package-path <temporary-package> --cache-path <temporary-cache> --config-path <temporary-config> --security-path <temporary-security> -c release -j 4`, timed with `/usr/bin/time -p`. Executable sizes used `strip` on copied executables and `stat -f %z`. Source mirror manifests were unchanged; mirrors contained the named upstream release archives with local commits/tags. Resource bundle bytes exclude filesystem allocation and signing overhead.

**The 7.64 MiB and build timings are a minimal standalone transport measurement, not a measured NativeAgent delta.** The probe does not contain generated A2A messages, serialization calls, registered services, TLS use, or RPC dispatch. Unreferenced protobuf/gRPC code can be dead-stripped. Conversely, NativeAgent may already link some Swift runtime/support code. Its macOS 26 deployment floor and release packaging differ from this probe. A precise production delta still requires an integration branch with generated A2A code and real service calls.

The expected mechanism is additional Swift/C compilation on clean builds, additional generated protobuf compilation, and longer final linking. Incremental builds normally reuse unchanged dependencies. Dependency resolution/download time is separate from compilation and can dominate a cold machine. Pre-generated protobuf source avoids running code generators during normal app builds.

The selected Swift package products are source libraries, not downloaded app frameworks. Their reachable machine code is normally linked into the NativeAgent executable; package Git repositories, tests, documentation, `protoc`, and generator executables are not shipped. macOS supplies Network.framework. Include applicable third-party notices and the SwiftPM resource bundles required by selected products. The probe built no BoringSSL, NIOSSL, X509, or Crypto targets. `otool -L` showed system libraries/frameworks and Swift runtime libraries, including an `@rpath/libswiftCompatibilitySpan.dylib` reference: packaging must account for any toolchain runtime back-deployment support still needed at the final deployment target, rather than assume every runtime library is already present. Universal arm64/x86_64 distribution, debug symbols, linker dead stripping, and the generated service methods all affect final bytes, so a compressed source archive cannot predict DMG size.

The integration report measures clean release compilation and stripped executable
bytes against the pre-gRPC NativeAgent revision. No `.app`/DMG size is inferred
from these source archives or the standalone probe.
