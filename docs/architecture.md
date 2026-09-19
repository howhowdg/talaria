# Architecture

Talaria keeps Hermes as the authority for sessions, execution, tools, schedules
and provider credentials. Swift supplies the native client without a web renderer
or third-party Swift packages. [Package.swift](../Package.swift) defines shared
modules; [project.yml](../project.yml) defines the Mac and iOS app targets.

## Modules

| Location | Responsibility |
| --- | --- |
| `Sources/HermesProtocol` | JSON-RPC envelopes, JSON values and generated gateway contract types |
| `Sources/HermesTransport` | Authenticated HTTP/WebSocket access, uploads, readiness, requests and legacy gateway adaptation |
| `Sources/HermesCore` | Conversation state, app coordination, settings, hierarchy, drafts, attachment transactions and Keychain access |
| `Sources/HermesUI` | Shared SwiftUI presentation and platform-specific navigation/composers |
| `Sources/HermesMacServices` | Metadata-only runtime discovery and ownership of locally launched processes |
| `Apps/macOS`, `Apps/iOS` | Platform entry points and lifecycle integration |
| `Contracts` | Reviewed upstream schema and its provenance/hash pin |
| `Tests`, `scripts/tests`, `scripts/fixtures` | Unit checks, gateway-extension checks and synthetic integration fixtures |
| `Sources/HermesSmoke`, `scripts/smoke-real-gateway.py` | Native gateway exercise and isolated real-backend integration harness |

The blue winged-sandal identity uses `Apps/Shared/Talaria.icon` for app icons and
`Sources/HermesUI/Resources/TalariaAssets.xcassets` for native UI assets.

## Ownership and persistence

`HermesAppModel` coordinates UI state on the main actor. `GatewayClient` owns
socket state in an actor. Requests and conversations belong to a connection and
profile; durable `StoredSessionID` and live `RuntimeSessionID` are distinct types.
Persisted drafts and selections use durable IDs, not live IDs or ephemeral ports.

Reconnect hydrates authoritative host history; old connection generations cannot
update a new one. Requests, event buffers and recovery tracking are bounded.
Uncertain mutations are never automatically replayed; unsupported UI bridges
return a protocol error. New sessions advertise `source: "native"`.

Device preferences hold endpoint metadata and Home/Workspace classification.
App support holds text drafts and an attachment-send journal, without credentials
or file bytes; the journal can retain host image paths. Organisation, read state
and transcript places are connection/profile scoped and do not sync across devices.

## Runtime and security boundaries

- The Mac supervisor discovers executable metadata without running probes or
  reading provider credentials. It launches a loopback Hermes child with an
  ephemeral token, reads readiness, keeps bounded redacted logs and stops only
  its own child. Existing gateways and unrelated Hermes processes remain owned
  by their original launcher. Hermes/Python installation and SSH management are
  separate from the app; iOS has no local runtime supervisor.
- Gateway tokens may be saved in device-only Keychain entries. Provider and agent
  credentials remain on the host. Persistable endpoint URLs reject embedded
  credentials, queries and fragments; remote transport requires HTTPS. See
  [security reporting](../SECURITY.md).
- Profile routing remains explicit. Selecting a profile does not globally
  activate it on the host. Capability negotiation and legacy fallbacks do not
  bypass authentication, hostname checks or request restrictions.
- Device file selection crosses into the host only through uploads. Inspector
  previews use recorded tool content, not local reads of host paths. Approval
  choices retain their host values and scopes; displaying a result never answers
  a pending request.
- The optional [Telegram extension](telegram-topics.md) reads profile-owned
  routing metadata through authenticated HTTP and read-only SQLite access. Its
  local classifications do not become server-authoritative provenance.

## Updating the gateway contract

[Contracts/pin.json](../Contracts/pin.json) identifies the reviewed upstream commit,
schema path and SHA-256. Replace the schema only from a reviewed upstream revision,
update the pin, then run from the repository root:

```sh
python3 scripts/generate-contracts.py
python3 scripts/generate-contracts.py --check
```

Review the generated diff and affected transport/domain adapters together; never
hand-edit `GatewayContract.generated.swift`. Preserve omitted/null/value semantics
and unknown wire values. A generated RPC name does not imply an implemented UI
feature or runtime compatibility. Keep [upstream attribution](../ThirdPartyNotices.md)
with redistributed schema/generated code. [Contract notes](../Contracts/README.md)
describe the model-generation rules; [current limits](status.md) describe coverage.
