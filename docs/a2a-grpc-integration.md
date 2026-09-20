# A2A 1.0 gRPC integration

The app serves and consumes all eleven A2A 1.0 operations over gRPC:
SendMessage, SendStreamingMessage, GetTask, ListTasks, CancelTask,
SubscribeToTask, CreateTaskPushNotificationConfig, GetTaskPushNotificationConfig,
ListTaskPushNotificationConfigs, DeleteTaskPushNotificationConfig, and
GetExtendedAgentCard. JSON-RPC, HTTP+JSON, and 0.3 compatibility remain available.

The app's gRPC service converts generated protobuf messages through the same
canonical endpoint and task actor. Bearer metadata uses the existing contact
authorization and ownership checks before dispatch. Protocol errors carry
google.rpc.Status and ErrorInfo. Cancelling or timing out an RPC releases its
waiter/subscription; cancellation of the task itself remains an explicit
CancelTask operation. Streaming writes await transport backpressure, while the
existing bounded task subscription closes on overflow for recovery by GetTask.

The app opens an ephemeral `127.0.0.1` HTTP/2 port beside its existing bridge.
After binding, the agent card advertises its `GRPC` interface and
`a2a-grpc.json` records its address beside `bridge.json`. App shutdown removes
the descriptor and begins graceful transport shutdown. No feature flag or new
task implementation is involved.

The client selects the first supported interface in the card's declared order.
It uses system-verified TLS for HTTPS, permits plaintext only under the existing
loopback URL policy, includes bearer metadata and deadlines, and preserves
partial stream evidence for canonical recovery. Sends are not automatically
retried. A card may advertise a sibling gRPC port on the same host and scheme;
it cannot redirect credentials to another host or downgrade TLS.

## Schema and packages

The unmodified normative schema comes from A2A v1.0.0, commit
`173695755607e884aa9acf8ce4feed90e32727a1`, where its path is
`specification/a2a.proto`. The schema, Google API annotation imports and generator
versions are documented under `script/proto/a2a-v1.0.0`. Run
`script/regenerate_a2a_grpc.sh` to refresh the checked-in public Swift messages
and service/client interfaces. Normal builds do not require protoc.

Exactly the report's three direct packages were added to the app and
ChatOrchestration targets: grpc-swift-2 2.4.3, grpc-swift-nio-transport 2.10.0,
and grpc-swift-protobuf 2.4.1. Both lockfiles retain upstream commit revisions;
no local source-mirror revisions are committed. The TransportServices product
uses Apple's Network framework. Third-party notices are staged by both build
and release scripts, alongside their existing SwiftPM resource-bundle staging.

## Proof and measurements

The SDK runner uses a2a-sdk 1.0.0 in a temporary uv environment. Swift calls the
SDK's gRPC server; the SDK's gRPC client calls the real app service and canonical
task actor in a temporary Swift test process. HTTP bindings run in the same pass.
It includes both streams, all unary methods, denied authorization on all eleven
operations, contact isolation, rich errors, deadline recovery, cancellation,
and graceful server shutdown. Credentials, peer processes, webhooks and app
state are synthetic and confined to system temporary directories.

Both requested builds passed, always with `--disable-keychain`. The SDK pass
passed 36 Core tests and 17 of 18 app tests. The new deadline fixture initially
invented a context ID, which the canonical runtime correctly rejected. Reusing
a server-issued context fixed that fixture; the single failed app test passed
on focused retry, including the complete reverse-direction operation proof.
No further suites were repeated. Generated Swift reproduced byte-for-byte;
the three shell scripts passed syntax checks and `git diff --check` passed.

### NativeAgent release measurement

Apple M5 Max, 128 GiB RAM, Apple Swift 6.4, arm64 macOS 26 deployment target.
Baseline was an archive of `672a94ad9`; the integrated runtime is in
`191cf973f`. Both used fresh scratch build directories, `-c release -j 4
--product NativeAgentApp`, the same upstream dependency cache, and temporary
SwiftPM config/security directories. No app process was launched.

| Measurement | Before | With gRPC | Observed change |
| --- | ---: | ---: | ---: |
| Release executable, as built | 137,366,960 bytes | 159,014,608 bytes | +21,647,648 bytes (+20.64 MiB) |
| Stripped copies of those executables | 62,555,136 bytes | 71,117,248 bytes | +8,562,112 bytes (+8.17 MiB) |
| SwiftPM-reported clean build phase | 462.09 s | 428.31 s | -33.78 s |
| Entire command, including resolution/setup | 515.22 s | 439.66 s | -75.56 s |

These are single samples on a shared host, not isolated performance estimates.
The baseline overlapped debug builds; the integrated sample overlapped SDK test
compilation. Upstream fetch/cache state also differed. **The observed negative
time delta does not establish that gRPC makes builds faster or quantify its
isolated build-time overhead.** The executable size differences are direct
measurements. The shipped scripts copy the as-built executable, so the stripped
row is a separate comparison, not a claim about a distributed `.app` or DMG.
An earlier integrated timing run was stopped after correcting error status
mappings; its incomplete numbers are excluded.

Commands and logs are under `/tmp/nativeagent-grpc-work/`: `baseline-build.log`,
`final-release.log`, `core-build.log`, `app-verified-build.log`, `sdk-proof.log`,
`sdk-retry.log`, and `signing.log`. Release command shape:

```sh
/usr/bin/time -p swift build --disable-keychain \
  --package-path SOURCE --scratch-path FRESH_SCRATCH \
  --cache-path TEMP_CACHE --config-path TEMP_CONFIG --security-path TEMP_SECURITY \
  -c release -j 4 --product NativeAgentApp
```

`otool -L` showed only two additional dynamic dependencies: system `libz` and
weak-linked system `libswiftSynchronization`. No gRPC/NIO/protobuf framework,
BoringSSL, or Swift compatibility dylib needs to be bundled. The additional
SwiftPM privacy bundles are SwiftProtobuf (1,523 regular-file bytes) and NIOPosix
(1,730 bytes); both are covered by existing resource-copy loops. A temporary
bundle containing the final release executable, these bundles, notices and
Sparkle passed ad-hoc signing and `codesign --verify --deep --strict`. No
Developer ID signing, notarization, installation, full release pipeline or DMG
build was performed. Existing app signing seals the statically linked gRPC code
and resource files; no additional code-signing step is needed for a new framework.

For a separately running installed app, supply the bridge URL and contact bearer:

```sh
A2A_BASE_URL='http://127.0.0.1:BRIDGE_PORT' A2A_BEARER_TOKEN='CONTACT_BEARER' \
  uv run --no-project tests/a2a_sdk/call_live_server.py
```

The script discovers gRPC from the card and exercises all eleven operations.
It creates tasks, cancels its pending task, and runs a temporary webhook. It
does not read credentials/configs from disk or install/restart the app. The
installed app and real data are not used by the isolated proof above.
