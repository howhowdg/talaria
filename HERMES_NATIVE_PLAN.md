# Talaria — native Mac and iOS implementation plan

Prepared 17 September 2026. Source baseline: [NousResearch/hermes-agent at a566d20d226a8e2ef0747639dc8a3fc1c43f9dba](https://github.com/NousResearch/hermes-agent/tree/a566d20d226a8e2ef0747639dc8a3fc1c43f9dba/apps/desktop).

**Recommendation:** build a SwiftUI/AppKit Mac application around the existing Hermes Python runtime and gateway, with a shared Swift client package that also builds for iOS from the first milestone. Deliver the full Mac experience through direct download. Then ship iOS as a native client of a Mac or remote Hermes host.

The native rewrite should replace Electron's interface and machine integrations while preserving Hermes's agent behavior, tools, memory, profiles, skills, sessions and configuration through the existing backend. Rewriting the Python agent in Swift would multiply the scope, create behavior drift, and make upstream updates harder.

This document records the original source-based implementation plan. A working Talaria prototype now exists; see [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) for current implementation and validation. The audit described below predates that implementation. The repository was cloned and inspected, including renderer workflows, Electron integrations, generated contracts, Python handlers, and existing tests. I did not launch Electron, install the agent, exercise live providers, or run the full upstream test suites.

## 1. Scope and assumptions

The target is **feature parity with the pinned desktop revision**, including optional shipped features. A usable chat alpha is an early milestone; it is not completion of the requested application.

Planning defaults, pending product choices:

| Decision | Recommended default | Alternative and consequence |
| --- | --- | --- |
| Mac distribution | Developer ID-signed, notarized direct download | Mac App Store requires a separately scoped, sandbox-compatible product, most naturally a remote client |
| Meaning of native | SwiftUI/AppKit shell, chat, settings and bundled features; WebKit for actual web content and selected compatibility surfaces | Requiring every plugin interface to be native means existing React plugins need ports |
| Agent execution | Existing Python Hermes on the Mac or a remote host | Rewriting the engine or running its full host toolset inside iOS is a separate project |
| iOS execution | Native client of an always-available Hermes host | Limited on-device inference could be a later product, without implying local shell/plugin parity |
| OS support | Provisional macOS 14+ and iOS/iPadOS 17+; validate dependency minimums in M0 | Newer-only deployment simplifies APIs; older support increases testing and fallback work |
| Mac hardware | Apple silicon development first; explicitly test Intel before advertising support | Apple-silicon-only release is possible, but is a distribution scope choice |
| Upstream strategy | Independent Apple client, pinned compatible runtime; small upstreamable backend extensions | A permanent full backend fork has a larger maintenance burden |

These are recommendations, not recorded user approvals. The architecture supports changing them. Browser-control fidelity and arbitrary React plugin compatibility require feasibility work before claiming complete parity.

## 2. What the current codebase actually contains

There are three primary boundaries:

1. **Electron owns the machine.** It discovers/installs Python, starts and supervises backend processes, manages connection credentials and SSH tunnels, and supplies filesystem, git, PTY, browser, window, update and OS integrations through a typed preload bridge.
2. **React owns the application experience.** It uses nanostores for coordination, React Query for server data, an assistant-ui transcript, a contribution-based pane system, CodeMirror, xterm, and runtime React plugins.
3. **Python owns agent execution and durable product state.** The headless serve command shares HTTP infrastructure with the dashboard and exposes tui_gateway JSON-RPC over WebSocket. The desktop does not depend on the dashboard frontend.

The current source is much broader than the introductory README feature list. At the pinned revision the generated OpenRPC has **218 client RPC methods, 12 server-to-client request types and 69 notification types**. There are **12 static route entries, a session route, and contributed surfaces**. The renderer source/test tree contains 2,184 JS/TS files; Electron contains 384 source/test files. Counts are a scale indicator, not production-only line counts or an effort estimate.

| Source area | What to preserve or replace |
| --- | --- |
| apps/desktop/electron/main.ts and topical siblings | Replace machine orchestration with native services; retain policies and regression cases |
| apps/desktop/electron/preload.ts and src/global.d.ts | Inventory of native host operations to replace |
| apps/desktop/src/app, components, store | Port user workflows and state invariants, not the component tree mechanically |
| apps/shared/src/json-rpc-channel.ts and json-rpc-gateway.ts | Port transport semantics, request correlation, replay and reconnect behavior |
| apps/shared/src/gateway-contract.openrpc.json | Starting point for generated Swift wire models |
| tui_gateway/contracts and methods_*.py | Backend contract and implementation, reused |
| hermes_cli/web_server* and web_routers | HTTP feature APIs, authentication and file/terminal routes, reused |
| hermes_state*; agent; tools; gateway; cron; plugins | Preserve runtime behavior and persistence; change only for proven native/mobile gaps |

Detailed supporting audits:

- [Desktop feature and interaction audit](research/desktop-features.md)
- [Gateway, transport and mobile contract audit](research/gateway-contract.md)
- [Electron and native integration audit](research/native-shell.md)
- [Native feasibility, plugins, browser and Apple platform notes](research/native-feasibility.md)
- [Machine-derived source baseline](research/source-baseline.json)

Source anchors: [desktop architecture](https://github.com/NousResearch/hermes-agent/blob/a566d20d226a8e2ef0747639dc8a3fc1c43f9dba/apps/desktop/AGENTS.md), [routes](https://github.com/NousResearch/hermes-agent/blob/a566d20d226a8e2ef0747639dc8a3fc1c43f9dba/apps/desktop/src/app/routes.ts#L10), [wire schema](https://github.com/NousResearch/hermes-agent/blob/a566d20d226a8e2ef0747639dc8a3fc1c43f9dba/apps/shared/src/gateway-contract.openrpc.json), [contract generator](https://github.com/NousResearch/hermes-agent/blob/a566d20d226a8e2ef0747639dc8a3fc1c43f9dba/scripts/gen_gateway_contracts.py).

## 3. Feature parity ledger

Every row below is required for Mac parity unless it is explicitly marked as a platform adaptation or compatibility decision. In implementation, expand the rows into individual acceptance cases from the source audits, with owner, test and pass/fail status. Do not treat a screen being present as proof that its mutations and recovery behavior work.

Milestones M0–M7 are defined in section 9. “Host” in the iOS column means operations occur on the selected Hermes host, never implicitly on the phone.

| ID | Existing capability and important behavior | Native Mac implementation | iOS treatment | Milestone |
| --- | --- | --- | --- | --- |
| F01 | First run, free-tier state, provider setup, connect-existing, local install, progress/recovery and flag-gated guided onboarding | Native setup flow backed by existing status/setup APIs and RuntimeManager; preserve onboarding gates | Pair/connect first; provider setup targets host | M1–M2 |
| F02 | Local, URL/token, native OAuth/legacy cookie login, Cloud, SSH connections; HTTP+WS tests; managed/update-all flows | ConnectionRegistry, Keychain, auth broker, SSH adapter; explicit owner scope and update recovery | Remote-only registry; HTTPS/WSS first; SSH optional separate adapter | M1–M2 |
| F03 | Profiles, clone/rename/delete/default, live switching, profile windows, remote-owned agents | Native roster and profile editors; pooled gateways; migrate renamed local state | Same identities and profile routing | M2–M4 |
| F04 | Streaming text/reasoning, tool call lifecycle, structured outputs, context/usage and MoA/delegation progress | Incremental per-session reducer and virtualized native transcript | Shared reducer and adapted transcript | M1–M3 |
| F05 | Composer drafts, attachments, paste/drop, image/PDF/file context, mentions, prompt queue, slash/skill commands | Native text input with IME, picker and autocomplete integrations | Photos/Files/share inputs; durable queued work on host | M3 |
| F06 | Stop/interrupt, steer, retry/edit, rewind/rollback and session control | Typed actions preserving exact backend semantics and file rollback scope | Same remote controls with stale-action handling | M3 |
| F07 | Clarifications, batched answers, approvals, sudo, secrets, vault requests and cancellation | Request-ID-scoped native cards/sheets; exact response enum and expiry | Native approval inbox; secure entry; foreground reconciliation | M1–M3 |
| F08 | Search/history pagination, rename, pin, archive/restore/permanent delete, export/import and source metadata | Native lists/search with server-authoritative history and stable IDs | Search and cached reading; same remote mutations | M3 |
| F09 | Import external Claude/Codex conversations | Native import/review flow through existing backend capabilities | Host-side source import where exposed | M4 |
| F10 | Projects, cwd selection, recent workspaces, worktrees, session ownership and handoff | Native project sidebar and git/worktree service; explicit host paths | Host projects; phone Files selection uploads content | M4 |
| F11 | Multiple chats/tiles, split/tabbed/floating panes, saved layouts and retained hidden tools | Swift layout tree plus AppKit split/panel hosts and scene restoration | NavigationStack on iPhone; adaptive multi-column iPad | M3–M5 |
| F12 | File tree, search, read/write, new/rename/move/delete, watchers, file previews and editor | FileService protocol with local/remote adapters; native editor and Quick Look | Remote browser/editor plus document import/export | M4 |
| F13 | Git status/diff, staging/reverting, commits/push/PR flows, review summaries and inline feedback | GitService and native diff/review interface; respect original confirmation boundaries | Host review/actions; compact diff UI | M4 |
| F14 | Interactive terminals, multiple tabs, resize, hyperlinks, buffers, search and retained sessions | SwiftTerm plus local PTY and existing SSH-terminal behavior; proposed remote-shell WS adapter if needed | Remote shell through new host PTY service or separately scoped SSH adapter | M4 |
| F15 | Read-only agent terminal streaming, process output, stop/close semantics | Separate agent-output and interactive-terminal models | Host output and process controls | M3–M4 |
| F16 | Browser/HTML preview, navigation, local-port reachability, console, downloads, find and isolation | WKWebView with scoped data stores, navigation policy, auth-aware transport/tunnels | WebKit previews; host browser for background automation | M0, M4 |
| F17 | Agent preview read/act, annotations, screenshots, tours, pane/layout commands and window context | Native surface request dispatcher; browser input and semantic UI feasibility gates | Advertise only supported foreground capabilities; host alternatives | M0, M4–M5 |
| F18 | Artifact gallery and in-chat previews, versions/source modes, generated HTML/SVG, images/files/code, math/Mermaid and rich media/embed consent | Native artifact catalog, media/Quick Look and isolated WebKit where needed; preserve ask/always/off embed consent | Shared artifact models; touch-oriented preview/share | M3–M4 |
| F19 | Voice dictation/conversation, STT/TTS, interruption/playback, wake-word modes and provider configuration | AVFoundation device layer; preserve backend voice/wake semantics and endpoints | Mobile audio lifecycle, interruptions and foreground UX; no always-on wake promise | M5 |
| F20 | Skills inventory/edit/archive, hub search/install, toolsets, MCP catalog/config/auth and plugins | Native Capabilities workspace, driven by backend catalog/config; retain CLI recovery guidance for archived learning items | Host capability management | M4–M5 |
| F21 | Messaging platforms, connect/pair/status and gateway controls | Native messaging setup and diagnostics | Manage host integrations | M5 |
| F22 | Cron create/edit/delete/run/enable, job details/history and execution sessions | Native scheduling screens; host scheduler remains authoritative | Monitor/manage jobs; notifications after mobile service work | M5 |
| F23 | Webhook service enable/restart, list/create, events/delivery/prompt/skills configuration, toggle/delete and URL/secret display | Native webhook management with secret redaction | Host management | M5 |
| F24 | Agents/subagent tree, orchestration status, progress/interruption and delegation | Native agent activity views and scoped control requests | Compact activity tree and approvals | M3–M5 |
| F25 | Learning/memory and Starmap, node inspect/edit/archive, relationships/learned skills, timeline playback and share/import codes | Native graph/list with accessible alternative; backend mutations and CLI restore guidance preserved | List/detail first, optional graph on iPad | M5 |
| F26 | Command Center diagnostics, doctor/audit, logs, backup, curator/reset and debug sharing | Native operations screens using current APIs; explicit destructive actions; backup restore UI would be an addition | Host diagnostics; lifecycle operations permission-scoped | M5 |
| F27 | Models/providers, OAuth/accounts/API keys, fallback models, reasoning/personality and custom endpoints | Native settings with schema-backed fields and scope selector | Same host settings; client secrets remain device-local | M2–M5 |
| F28 | Local model management currently gated by local-mode flag | Preserve gate and native UI for backend model lifecycle | Host-local models only | M5 |
| F29 | Tool/environment settings, memory providers, browser real-profile consent, computer use and vault | Native contextual editors; preserve next-session/cache semantics | Host settings; no phone permission implied by host permission | M5 |
| F30 | Billing/account/free-tier/usage, payments, subscription changes/undo, step-up and auto reload | Native account UI through existing backend contracts; idempotent charge flow | Storefront/product decision; do not copy desktop purchase flow blindly | M5 |
| F31 | Bots: canonical forever chat, roster, groups, membership/mentions, side chats, routines and cross-connection relay | Native bundled feature; canonical identity resolved by profile + exact Bot Chat title | Shared models; host-owned orchestration while suspended | M5–M6 |
| F32 | Kanban: boards/cards/status movement, agent-run tasks, model override, imports/transfers and completion notices | Native bundled opt-in board/detail feature | Native compact board/list; host tasks | M5–M6 |
| F33 | Radio: opt-in stations/search/favorites, player/waveform and cross-window ownership | AVPlayer and native controls; single playback owner | Optional native feature, mobile audio policy tested | M6 |
| F34 | Runtime desktop plugins, hot reload, enable/disable, scoped storage, contributed UI and host SDK | Dedicated compatibility track with SDK conformance gates | Bundled native features first; runtime extensions separate product decision | M0, M6 |
| F35 | Themes/skins, custom themes and VS Code theme marketplace import, fonts, localization, shortcuts, command palette, accessibility and reduced motion | Semantic native tokens, String Catalogs and shared ActionRegistry | Dynamic Type, VoiceOver, touch and hardware keyboard adaptation | All |
| F36 | Native notifications/actions, menu/dock behavior, HUD floating chat, quick entry/global shortcuts, screenshot gesture and clipboard | UNUserNotificationCenter, AppKit menu/panels, ScreenCaptureKit and pasteboard | APNs/local notifications, share extension and app shortcuts as appropriate | M5–M7 |
| F37 | Desktop pet, pet generation/editing, overlay placement and interaction | Native overlay/animation service with source settings and asset flows | In-app companion presentation; no system-wide desktop overlay | M6 |
| F38 | Multiwindow restore, sleep/wake, battery/keep-awake, deep links, external Terminal session handoff, crash/retry, app/runtime/fleet updates, repair and uninstall | App lifecycle coordinator, versioned installers, scoped managed SSH updates and diagnostics | Reconnect/reconcile, App Store distribution lifecycle | M2, M7 |
| F39 | Todos/goals, goal criteria/resume, loop and heartbeat control, background questions and process/subagent steer/stop | Native composer status stack and session-control actions; hidden kickoff prompts retain queue behavior | Shared host controls and concise activity views | M3–M5 |

The detailed audits provide source anchors and subflows for these rows. Distinguish the Python agent plugin system, desktop React extension SDK and web dashboard plugin SDK; they are not interchangeable. No current tray/menu-bar status app or login-item implementation was found; adding one would be new scope. Radio contributes status-bar playback rather than a separate route.

## 4. Proposed application architecture

~~~mermaid
flowchart TB
    Mac["Hermes Mac: SwiftUI + AppKit"] --> Features["Shared feature models and reducers"]
    IOS["Hermes iOS: SwiftUI + UIKit"] --> Features
    Features --> Core["HermesCore: identities, requests, sessions, artifacts"]
    Core --> Transport["HermesTransport: HTTP + bidirectional JSON-RPC WebSocket"]
    Mac --> MacServices["MacServices: runtime, SSH, PTY, files, git, panels, permissions"]
    MacServices --> Local["Local Python Hermes: serve"]
    Transport --> Local
    Transport --> Remote["Remote / Cloud Hermes host"]
    Local --> Engine["Existing agent, tools, memory, profiles, skills and session DB"]
    Remote --> RemoteEngine["Same Hermes services on the host"]
    IOS --> MobileServices["iOS services: audio, Files, Photos, share, notifications"]
    Mac --> WebContent["Isolated WebKit: pages, artifacts, plugin compatibility"]
~~~

There is one product model and protocol implementation, with separate platform composition. Do not force every desktop layout into a shared view. Share identities, reducers, typed clients, validation, feature actions, design tokens and appropriate small SwiftUI components. Keep process spawning, filesystem host access, PTY ownership, global shortcuts and AppKit imports out of packages required by iOS.

Proposed project layout:

~~~text
HermesNative/
  HermesNative.xcworkspace
  Apps/
    macOS/                 App composition, menus, windows, panels
    iOS/                   App composition, navigation, share entry points
  Packages/
    HermesProtocol/        Generated Codable wire types and JSON value support
    HermesCore/            Identity, domain state, reducers, feature use cases
    HermesTransport/       HTTP, RPC, auth, replay, routing, uploads
    HermesFeatures/        Shared models and portable native views
    HermesDesign/          Semantic tokens, strings, icons and accessibility
    HermesMacServices/     Runtime, SSH, local PTY/files/git, capture, updater
    HermesIOSServices/     Mobile lifecycle, Files/Photos/audio/notifications
    HermesWebContent/      Preview/artifact and compatibility web boundaries
  Contracts/
    upstream-revision.json
    gateway-contract.openrpc.json
    Fixtures/              Sanitized protocol and lifecycle recordings
  BackendChanges/          Tracked upstream patches and contract proposals
  Tests/
    Contract/
    Integration/
    macOSUI/
    iOSUI/
    Performance/
~~~

Avoid introducing more framework layers before concrete consumers need them. HermesCore can contain narrowly named feature modules rather than a universal plugin or action engine.

### Technology decisions

| Concern | Proposed choice | Verification needed |
| --- | --- | --- |
| Native UI | SwiftUI, with AppKit/UIKit bridges where behavior requires them | Long transcript selection, IME, split resizing, focus and accessibility |
| State/concurrency | Main-actor observable view models; transport/runtime/session actors | Cancellation, scoped routing, reentrancy and bounded memory |
| HTTP/WS | Foundation URLSession / URLSessionWebSocketTask | Large frames, auth headers/tickets, backpressure and reconnect ordering |
| Secrets | Keychain for client tokens/refresh tokens/connection secrets | Access policy, migration, logout/revoke and no secret logging |
| Sign-in | AuthenticationServices plus supported callback strategy | Existing gateway's loopback-only callback constraint |
| Terminal | Evaluate SwiftTerm AppKit/UIKit views | Escape sequences, selection, Unicode, resize, lifecycle and accessibility |
| Markdown | swift-markdown parser candidate plus native block rendering | Partial streaming, tables, code, math, diagrams, copy/selection |
| File/code editor | Native text system with syntax layer; Quick Look/media previews | Large files, encodings, unsaved edits, remote write conflict |
| Web content | WKWebView with explicit navigation, message and content policies | Trusted browser input, cookies, file access and guest isolation |
| Audio | AVFoundation capture/playback bridged to existing host endpoints | Formats, sample rates, device changes, interruption and cancellation |
| Updates | Evaluate Sparkle for native app; separate Hermes runtime manager | Signature/notarization, upgrade interruption and version compatibility |
| UI persistence | Versioned local client store; cache server truth, store drafts/layouts explicitly | Scope keys, migrations, crash recovery and cache invalidation |

SwiftTerm provides native Apple frontends but does not supply SSH transport. Swift Markdown is a parser, not a complete transcript renderer. MarkdownUI is currently in maintenance mode; evaluate dependencies on current behavior rather than adopting a familiar name by default. Sources: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), [Swift Markdown](https://github.com/swiftlang/swift-markdown), [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui), [Sparkle](https://sparkle-project.org/documentation/).

## 5. Load-bearing contracts to preserve

### Ownership and identity

Use distinct Swift types for ConnectionID, BackendInstallID, ProfileName, StoredSessionID, RuntimeSessionID, LineageRootID, TurnID, RequestID, ProjectID, WindowID and PaneID. A raw string passed to an arbitrary method is too easy to misroute.

- Backend-owned state includes transcripts, session metadata, models/configuration, skills/memory, jobs and agent execution.
- Mac services own runtime facts, owned processes, machine permissions and device integrations.
- The client owns navigation, drafts, pane layouts and local cached projections.
- Connection + profile is the minimum scope for backend caches. Durable session identity and compression lineage are separate from live stream identity.
- Preserve rename migration for profile-scoped drafts, panes, session hints and caches.
- A background turn can update its own cache or badge without selecting it, moving focus or replacing another transcript.
- Treat a connection change, runtime-home reload and same-window live profile swap as three different transitions.
- The canonical Bots conversation is resolved by profile plus exact title Bot Chat, including hidden rows and compression lineage. Do not restore the removed persisted session-ID pointer design.
- For group chats, respect existing hosted-room authority and fences rather than inventing a parallel native authority.

Settings drafts belong to their captured connection/profile. Seed from a loaded baseline, submit sparse changes, serialize autosaves, and cancel/reseed on scope switches. Never replace a whole mirrored configuration in a way that overwrites untouched concurrent CLI edits. Clear transient vault/secret fields when their owner changes.

Preserve session source = desktop for the Mac once its advertised desktop read/act bridges are implemented. Backend GUI tool availability follows that session source, including on remote hosts. The launch-time HERMES_DESKTOP flag has a different purpose. For an early partial client or iOS, extend capability/source mapping deliberately rather than impersonating all desktop abilities or sending an unrecognized source and losing tools. Source: [GUI toolset gate](https://github.com/NousResearch/hermes-agent/blob/a566d20d226a8e2ef0747639dc8a3fc1c43f9dba/tui_gateway/server.py#L1776).

### Transport and reconnection

Implement HTTP and WebSocket together. Many settings/files/operations use HTTP even though chat uses JSON-RPC; a WS-only port will be incomplete.

The shared Swift transport must:

1. Resolve the intended connection and profile before every request, including plugin, file, voice and terminal traffic.
2. Perform readiness/auth discovery and verify HTTP plus WebSocket.
3. Correlate bidirectional requests and responses; support string/numeric IDs where required by the wire contract.
4. Handle all 12 server request types, preserve pending requests by identity, and remove them on cancellation/expiry/resolution.
5. Apply events through an ordered per-session reducer. Coalesce high-frequency visual deltas but flush completion, error and input-required transitions immediately.
6. Track the server replay epoch and per-session sequence. Request missing events when appropriate and deduplicate replay/live overlap.
7. On truncated replay, changed epoch or inconsistent cached state, reconcile from authoritative session snapshots/history and open requests.
8. Reconnect with bounded jittered backoff, cancel stale work on owner changes, and separate connectivity failures from confirmed authentication rejection.
9. Acquire a fresh one-time WS ticket for every OAuth dial; never recycle the previous ticket URL.
10. Keep timeout classes distinct for liveness, startup reads, ordinary RPCs and long prompt acknowledgements.
11. Preserve stream/turn completion semantics; a prompt RPC response is not the only signal that work is done.
12. Do not blindly retry prompt submission or destructive actions after an uncertain acknowledgement.

Generate the 12 server-request dispatch cases as well as the 218 outbound method models. Preserve absent versus explicit null values and reject sending new parameters to older backends that disallow unknown keys. REST transcript rows and projected RPC message rows need deliberate adapters. Unknown notifications can be ignored with diagnostics; unknown server requests must receive a protocol error instead of leaving the agent waiting.

Existing Hermes already implements replay, resumed in-flight snapshots, multi-client fanout and durable initial user-message persistence. The replay ring is bounded and in memory, currently 512 events and 4 MiB per session, with a process cap; it is not a durable event journal. Port the current replay/snapshot contract first. Add durable journaling only for a concrete mobile requirement that snapshots cannot satisfy.

Sources: [shared gateway](https://github.com/NousResearch/hermes-agent/blob/a566d20d226a8e2ef0747639dc8a3fc1c43f9dba/apps/shared/src/json-rpc-gateway.ts), [event replay](https://github.com/NousResearch/hermes-agent/blob/a566d20d226a8e2ef0747639dc8a3fc1c43f9dba/tui_gateway/event_replay.py#L1), [request contracts](https://github.com/NousResearch/hermes-agent/blob/a566d20d226a8e2ef0747639dc8a3fc1c43f9dba/tui_gateway/contracts/server_requests.py), [desktop state invariants](https://github.com/NousResearch/hermes-agent/blob/a566d20d226a8e2ef0747639dc8a3fc1c43f9dba/apps/desktop/AGENTS.md).

### Typical send, approval and reconnect flow

~~~mermaid
sequenceDiagram
    participant UI as Native client
    participant WS as Gateway
    participant DB as Hermes state
    participant Agent as Agent runtime
    UI->>WS: session.create / resume (owner scope)
    UI->>WS: prompt.submit
    WS->>DB: Persist initial user row
    WS->>Agent: Start or queue turn
    Agent-->>UI: message / reasoning / tool events
    WS->>UI: approval or clarify request (request ID)
    UI->>WS: Exact request response
    Agent-->>UI: Tool/result and completion events
    Note over UI,WS: Network interruption or mobile suspension
    UI->>WS: Reconnect with valid fresh authentication
    UI->>WS: Attach/resume and replay from epoch + sequence
    WS-->>UI: Events or truncation / epoch change
    UI->>WS: Reconcile snapshot, transcript and open requests if needed
~~~

The implementation must follow the actual ordering constraints in the existing shared client. This diagram shows responsibilities, not a replacement wire protocol.

### Runtime and host lifecycle

Port the ordered runtime-resolution ladder, validation probes and narrow serve-to-dashboard fallback. Handle existing CLI installs, managed installs, old/broken runtimes, paths with spaces, shell environment discovery and clean recovery.

Start local backends on dynamically assigned loopback ports with protected authentication. Preserve the selected HERMES_HOME, profile argument, cwd, token, parent identity/spawn nonce and HERMES_DESKTOP=1 launch semantics, including desktop cron behavior. Register stdout/stderr and both current/historical READY sentinel handlers before awaiting asynchronous probes. Maintain a bounded backend pool per connection/profile, including foreground reservation, active turn retention, retirement and idle eviction semantics. Own process handles and process-group cleanup; do not kill unrelated Hermes processes.

Separate three lifetimes:

- Native window/pane lifetime.
- Desktop-owned serve process lifetime.
- Independently managed messaging gateway or an explicitly enabled always-on mobile host.

The existing serve process is app-owned and normally dies on actual application quit, while closing the last Mac window can leave the app alive. Gateway actions may spawn OS-detached processes, but a recorded desktop-managed gateway-restart child is explicitly terminated during serve shutdown. Independently installed/service-managed gateways have their own lifetime. For iOS access to a Mac, choose an explicitly enabled host service with clear quit/sleep/restart behavior. Merely keeping a WebSocket URL from a child process does not create an always-available server. This distinction follows the implementation even though some source guides describe detachment more broadly. Sources: [serve cleanup](https://github.com/NousResearch/hermes-agent/blob/a566d20d226a8e2ef0747639dc8a3fc1c43f9dba/hermes_cli/web_server.py#L279), [managed gateway cleanup](https://github.com/NousResearch/hermes-agent/blob/a566d20d226a8e2ef0747639dc8a3fc1c43f9dba/hermes_cli/web_server_gateway.py#L282).

Managed runtime installations should be versioned, verified and repairable. Reuse externally managed CLI runtimes after probing, but do not silently upgrade them under the user. Runtime code location and HERMES_HOME data location are separate concepts. Keep launch data/profile selection compatible with the CLI.

For the first implementation, adapt the existing pinned staged installer and its manifest/stage/non-interactive/JSON progress protocol, excluding its desktop/Electron build stage. Evaluate a prebuilt runtime only after that baseline works. Removing Electron does not remove Node/browser/TUI dependencies that the agent itself may still need. Test an install that excludes the Electron workspaces while retaining enabled runtime capabilities.

Mac SSH support includes the user's OpenSSH configuration, agent/hardware keys, jump hosts, host-key policy, ControlMaster lifetime, remote bootstrap and managed updates, including supported Windows hosts. Cloud discovery is a separate portal-cookie/org/agent authentication plane from gateway PKCE and needs its own compatibility spike. Provider login and MCP OAuth are additional workflows, not aliases of gateway login.

Keep a legacy/password gateway login path where native PKCE is unavailable; isolate its cookie store and renewal lifecycle. Mac auth acceptance includes legacy login and Cloud discovery → organization choice → agent sign-in → application restart → token/cookie renewal. AuthenticationServices alone is not proof that these existing flows work.

The current /api/pty WebSocket runs the Hermes Ink TUI. It is not a general remote shell. Preserve Mac local PTY and SSH shell behavior first. If gateway-based shell access is needed for iOS or URL/Cloud connections, add a separately authenticated, profile-scoped terminal service with create/attach/input/resize/exit/close, bounded output replay/backpressure and explicit lifetime policy. Do not present that endpoint as already implemented. Sources: [PTY routes](https://github.com/NousResearch/hermes-agent/blob/a566d20d226a8e2ef0747639dc8a3fc1c43f9dba/hermes_cli/web_routers/chat_ws.py#L432), [desktop terminal](https://github.com/NousResearch/hermes-agent/blob/a566d20d226a8e2ef0747639dc8a3fc1c43f9dba/apps/desktop/electron/terminal-ipc.ts#L302).

## 6. Native design and compatibility decisions

### Mac interaction model

Preserve the app's major product nouns and capabilities while adopting Mac conventions: native menus and key equivalents, window restoration, responder-chain focus, context menus, Services/clipboard, selectable text, proper dialogs and accessible controls.

Use a native sidebar for sessions/projects/profiles and an explicit workspace layout model for chat, file, preview, review and terminal panes. Navigation and layout should invoke shared feature actions. Retain expensive terminal/browser surfaces while hidden when their underlying session is meant to continue.

The composer needs attributed chips, rich paste/drop, terminal selections, input-method marked text, undo/history and per-session draft restoration. Start by evaluating NSTextView/UITextView bridges rather than assuming a basic TextEditor can meet the contract. HUD and Quick Entry reuse this domain and ordinary submit path. Preserve the existing screenshot gesture's opt-in, request expiry and captured-window/destination scope; a generic full-screen capture button is not equivalent.

HUD is a full floating chat: preserve session handback, profile ownership, snap/geometry, click passthrough, frosted appearance, fullscreen-app behavior and visibility while the main app is inactive. Test AppKit panel activation/hides-on-deactivate behavior directly. It is separate from Quick Entry and ordinary floating workspace panes.

Use a common transcript renderer built around stable message and block IDs. Parse completed Markdown blocks once; update only the active streaming tail. Virtualize history and preserve scroll position across pagination, font changes, pane resizing and tool expansion. Validate cross-message text selection and copy behavior before settling on pure SwiftUI versus an AppKit collection/text host.

Keep current localization coverage, including right-to-left behavior. Port semantic appearance settings, custom theme import and relevant typography controls; do not replicate CSS implementation details or browser-only animations.

### Browser fidelity gate

WKWebView is appropriate for browsing and generated HTML. It has JavaScript execution, separate content worlds and snapshots. Electron's sendInputEvent contract is an additional requirement: trusted input and hover behavior cannot be replaced with a claim that JavaScript click is equivalent.

M0 must prove the representative read/act/annotate/tour cases on a supported native implementation. If the Mac cannot meet the exact in-app action contract with public APIs, evaluate an explicit external/host-browser mode. Document the visible browser, cookie context, tool destination and any changed interaction. This is a release-blocking parity decision, not hidden scope reduction.

Untrusted content must not inherit the privileged native bridge. Separate preview content from plugin-host content; constrain scheme handlers, filesystem grants, navigation, downloads and external opening. Preserve user-gesture requirements from the existing guest policy.

### Plugin compatibility gate

There are three different plugin concerns:

| Plugin type | Native treatment |
| --- | --- |
| Python agent plugins, tools, skills and MCP servers | Continue on the backend; port management UI |
| Bundled Bots, Kanban and Radio interfaces | Rebuild native interfaces; reuse server operations and data |
| User/agent-authored React desktop plugins | Compatibility host or native port; requires explicit SDK migration strategy |

Recommended Mac approach: native bundled features plus a contained WebKit compatibility host for existing React plugin UI. Map declarative contributions into native navigation/commands and host web-rendered contributions in appropriate regions. Bridge scoped gateway calls, storage, events, readonly host state and lifecycle explicitly.

However, the current SDK exports synchronous stores, core React components, composer middleware and arbitrary callbacks. A single web panel is insufficient. The compatibility spike must cover the documented SDK, identify Chromium/DOM assumptions, and test independent contributions across multiple regions.

If exact compatibility needs a legacy React workspace, label that boundary clearly. If strict native UI is chosen instead, supply a migration SDK and treat unported extensions as an explicitly agreed exception. Full parity cannot be claimed while this question is silently unresolved.

See [native feasibility notes](research/native-feasibility.md) and [current runtime loader](https://github.com/NousResearch/hermes-agent/blob/a566d20d226a8e2ef0747639dc8a3fc1c43f9dba/apps/desktop/src/contrib/runtime-loader.ts#L1).

## 7. Data migration, security and distribution

### Preserve agent state; migrate client state deliberately

The Python backend remains authoritative for existing config, secrets, session DB, memory, skills and profiles. The native client should use supported APIs rather than independently writing the Hermes SQLite schema or copying a live DB.

Provide an onboarding migration report:

1. Discover usable runtime and data homes, including nondefault profiles and custom HERMES_HOME.
2. Offer to use the existing Hermes state or create an isolated new home.
3. Import connection descriptors, project metadata and selected appearance/shortcut settings where formats are understood.
4. Import client-only layout/draft/plugin preferences through a versioned export adapter when feasible. Electron localStorage is not a native preferences file.
5. Reauthenticate credentials that cannot be safely migrated. Existing credential envelopes may use plaintext or Electron safeStorage; direct Keychain decryption is not a universal migration path.
6. Validate restored sessions, profile names, Bot Chats, connections and cwd ownership before marking migration complete.
7. Keep a reversible migration record and preserve the old app's state. Use separate bundle ID/client storage during the beta.

Use native Keychain for connection/OAuth credentials owned by the native client. Keep provider keys and host vault credentials under backend ownership for CLI interoperability; do not copy them into an unrelated client-only store and break other Hermes surfaces. Do not sync sudo responses, transient secrets or approvals into general cached transcripts.

Use an Electron-side export/migration helper if needed for protected credentials and localStorage, or request sign-in again. Never rely on scraping private browser database internals as the default supported migration path.

### Host and capability boundaries

Local files, remote files and phone attachments must have explicit location semantics. A local upload is transferred to the selected host; a remote path must never be passed to NSWorkspace as though it were a local file.

Authenticated media needs streaming/range/HEAD handling and owner-scoped downloads; avoid loading every video or large file as a base64 string. Preserve size limits, sensitive-file and symlink checks from the source read paths. Use a distinct native development URL scheme during coexistence, and queue supported deep links until the owning window is ready.

Keep a narrow NativeServices interface for file dialogs, clipboard, notifications, process operations and browser actions. Audit every bridge operation for owner scope and user action context. Use argument arrays for subprocess invocation, bounded output, cancellation and redacted diagnostics.

Request microphone, Input Monitoring, Screen Recording, accessibility and automation permissions at the relevant feature entry. Input Monitoring for the physical screenshot gesture and Screen Recording for capture are separate permission states; preserve opt-in and the five-second, owner-bound single-window capture grant. Plan TCC attribution for the signed app/helper/runtime combination and test on a clean Mac; an Electron usage string or previous permission grant does not transfer automatically.

The present gateway's multi-client support is not proof of multi-tenant isolation. Session attachment currently has a trusted-gateway assumption, including a path that logs a different authenticated user instead of rejecting it. A public multi-account service needs an explicit authorization model and enforcement. Connecting the user's devices to the same trusted personal host is a narrower scope.

### Release packaging

Ship the Mac app with Developer ID signing, hardened runtime, notarization and stapling. Sign distributed helpers and validate installation on a clean machine without a development environment. Use separate channels/manifests for native application and runtime updates, with compatibility bounds and interrupted-update recovery.

Do not carry forward Electron's rebuild-the-JavaScript-app update process. Use a native updater and a separately verified runtime update flow. Uninstall distinguishes the app, an app-managed runtime, caches and user agent data; deleting user data is never implicit.

Direct distribution is the recommended engineering fit for full local Hermes capability. Apple requires App Sandbox for Mac App Store distribution; outside-store notarized software requires hardened runtime and can optionally use sandboxing. Sources: [distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution), [notarization](https://developer.apple.com/documentation/Security/notarizing-macos-software-before-distribution).

Preserve the upstream MIT notices and bundled third-party notices. Review distribution rights for dependencies, artwork and branding separately.

## 8. iOS architecture and prerequisites

The iPhone/iPad app should share the protocol/domain stack and own its native mobile experience. It should connect to a remote Hermes gateway or an explicitly enabled Mac host. It should not require the Mac UI to remain open or imply that an asleep Mac is reachable.

The iOS connection registry has no mandatory local-runtime entry. Do not carry over the Electron registry's exactly-one-local invariant as a fake phone-local backend.

Build the iOS package target and a minimal test harness in M1 so AppKit/process dependencies cannot leak into shared code. Product implementation can follow the full Mac milestones.

### What already exists versus what must change

| Area | Current implementation | Work for a dependable mobile product |
| --- | --- | --- |
| Typed protocol | Generated OpenRPC, RPC methods, server requests and events | Generate/validate Swift models; cover open/dynamic payloads |
| Reconnect | Sequence/epoch replay and resumed in-flight snapshots/open requests | Correct suspend/resume, expired replay and server-restart UX |
| Multiple clients | Session fanout and reconnect attachment | Define owning device for UI actions and first-response races; preserve existing browser owner controls |
| Durable user messages | Initial user row persisted at submit | Add submission idempotency/reconciliation for uncertain acknowledgements |
| Prompt queue | Composer queue and some draining currently in renderer | Host-owned queue/order/cancel with idempotent client IDs |
| Bots/groups | Durable groups APIs and hosted-room authority exist; some relay/orchestration still renderer-driven | Adopt hosted service authority; move only remaining UI-lifetime orchestration needed for unattended mobile behavior |
| Authentication | PKCE/native token flows, refresh and WS tickets exist | Registered mobile callback strategy; current authorize route accepts loopback HTTP redirects only |
| Client capabilities | General server_requests opt-in | Per-method/surface availability and owner routing; withdrawn when phone cannot serve requests |
| Disconnected execution | Last-client orphan policy with grace/activity rules | Make detached/mobile lifetime policy explicit and test long waits, approvals and host restarts |
| Pending human input | Request replay and existing approval infrastructure | Explicit timeout/recovery and cross-device resolution, without replaying stale approval |
| Notifications | Desktop native notifications and gateway events | Device registration/revocation, APNs delivery path and deep-link reconciliation |
| Authorization | Trusted personal-gateway assumptions | Scope device credentials; implement stronger session ownership if introducing multi-user hosting |
| Remote shell | Mac local/SSH terminals; gateway /api/pty is Hermes TUI | New authenticated general-shell host contract or explicit mobile SSH implementation |

Current general prompt submission does not expose a dedicated idempotency key. Other areas, including group-send and billing, have their own idempotency/authority mechanisms; reuse those patterns rather than labeling the whole backend stateless.

Generic server requests currently fan out and accept the first response. Add explicit settlement/status reconciliation so answering on Mac clears a still-visible iPhone approval. Device-bound preview/window actions also need a selected owner/lease so two clients cannot execute the action. Reuse the separate browser.controller broker's existing ownership where applicable. Submission deduplication does not make arbitrary external tool side effects exactly-once after a host crash; expose uncertain outcomes and reconcile them.

### Mobile user experience

- iPhone: sessions/bots, chat, pending approvals, jobs/activity and settings, with Files/artifacts as detail sheets.
- iPad: adaptive sidebar and chat with optional file/preview/review panes; preserve keyboard commands.
- Use PhotosPicker/document picker/share extension for phone content, with explicit upload progress to the selected host.
- Support voice with audio interruptions, permission recovery and headset/device changes.
- Cache recent readable content and drafts locally. Mark stale/offline data clearly. Do not queue destructive tool approvals offline.
- On foreground return, reconnect, resolve authentication, reconcile current turn/request state and update cached history before enabling stale actions.
- Persist uncertain sends as pending verification; do not resend until the host can deduplicate or verify acceptance.
- A phone suspended in the background cannot reliably service preview.read, preview.act, terminal.read or interactive tours. Bind unattended tools to the host and advertise the actual surface capability.
- Notifications contain minimal metadata and a stable resource route; fetch authenticated state on opening. Do not put passwords, tool outputs or full sensitive prompts in push payloads.
- APNs requires a reachable provider component. For self-hosting, define user-managed provider or an opt-in relay with scoped registration; do not assume arbitrary private hosts can deliver pushes without infrastructure.
- Start with existing HTTPS/WSS gateways or documented private-network access. A polished QR pairing/reachability service is a separate delivery item. Do not expose an unauthenticated local serve port to the internet.

Apple's background strategies and newer continued-processing tasks support specific bounded work; they do not justify keeping a general-purpose agent/WebSocket process continuously alive in the phone. Sources: [background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app), [continued processing](https://developer.apple.com/documentation/BackgroundTasks/performing-long-running-tasks-on-ios-and-ipados).

Desktop billing purchases and downloaded React extensions require separate mobile product decisions under the current App Review rules. Preserve account/usage visibility first; determine the appropriate purchase and extension model for the selected storefronts before implementation. Source: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

## 9. Implementation milestones and dependency order

Milestones are acceptance gates, not a promise that the current Electron feature set fits a short chat-app schedule. Workstreams can overlap after shared contracts stabilize.

### M0 — Baseline and feasibility

Deliver:

- Pin upstream source and backend compatibility baseline.
- Expand this feature ledger into acceptance cases tied to source/tests.
- Exercise a disposable Electron installation and collect representative UI/protocol fixtures.
- Prototype native transcript streaming/selection with long history.
- Prototype local runtime start/stop and a signed minimal helper on a clean Mac.
- Prototype WebKit browser read/act/annotation behavior and the plugin SDK compatibility boundary.
- Verify native OAuth on Mac and document the mobile callback change.
- Decide minimum OS, Intel support, extension compatibility and release channels.

Exit: the highest-risk native substitutions have evidence, named limitations and a chosen implementation. Do not begin a broad interface port while browser/plugin feasibility is unresolved.

### M1 — Shared client and vertical slice

Deliver HermesProtocol, scoped transport/auth, session reducer, pending request model and native Mac shell.

Acceptance: connect to an existing backend, create/resume a session, send text, stream reasoning/tools, approve/clarify, interrupt and reconnect without duplicating messages. Exercise the same core code in an iOS target. Validate loopback and at least one authenticated remote gateway.

### M2 — Local runtime, connections and onboarding

Deliver the resolver/probe ladder, installer/recovery, pooled backend supervisor, connection registry, SSH path, OAuth/cloud login, profile routing and native credential store.

Acceptance: a clean Mac with no Hermes setup reaches a real conversation; an existing CLI user retains sessions/configuration; A → B → A profile/connection switching routes all REST/WS/files correctly; failed auth, missing dependencies, stale runtime, cancellation and process crashes recover visibly.

### M3 — Conversation and workspace parity

Deliver full composer/attachments/slash commands, transcript renderers, session history/search/mutations, approvals/vault requests, queue/steer/rewind behavior, session tiles and layout restoration.

Acceptance: all chat/session rows in the ledger pass against the real backend, including compression identity changes, stale events, concurrent streams, long history, IME, copy/selection, detached views and background completion without focus theft.

### M4 — Files, projects, terminal, review and preview

Deliver local/remote file services, native editor, workspace/project/worktree flows, git review and PR operations, SwiftTerm local/SSH terminal variants, previews/artifacts and client-surface tools. Specify and test the proposed host shell API separately if choosing gateway-based mobile terminals; it is not supplied by /api/pty.

Acceptance: complete a coding workflow across both a local project and a remote project, including edit conflict, tool output, terminal resize/reconnect, diff/stage/commit, preview read/act, artifact export and browser security cases. A remote path never targets the local machine by accident.

### M5 — Management and operational features

Deliver Capabilities/skills/MCP/plugins management, providers/models/config, messaging, cron, webhooks, agents/delegation, learning/Starmap, Command Center, billing, voice and native notifications/quick entry.

Acceptance: every displayed configuration field writes and rereads the correct scope; scheduled and background work continues according to documented lifecycle; voice survives interruption; sensitive requests and billing mutations preserve existing idempotency/step-up behavior.

### M6 — Bundled experiences and extension parity

Deliver native Bots/groups/routines, Kanban, Radio, pet/generation/overlay, theme/shortcut/localization completeness and the chosen desktop plugin compatibility path.

Acceptance: canonical Bot Chat identity survives rename/compression/restart; cross-host groups and routines keep correct authority; Kanban tasks complete without UI focus; optional features respect enablement; plugin load/reload/unload disposes requests/listeners and passes the agreed SDK conformance suite.

### M7 — Migration and release qualification

Deliver migration/export tooling, update/repair/uninstall, signing/notarization, privacy/permission behavior, diagnostics, accessibility and performance qualification.

Acceptance: every Mac ledger row has a passed test/evidence or an explicitly accepted compatibility exception. Install on a clean supported Mac, upgrade from the previous beta, interrupt an update, recover a runtime failure, migrate an Electron user, and uninstall without deleting user data by default. Ship only after critical identity, auth and data-loss cases pass.

### iOS delivery after the shared foundation

- **I0, during Mac work:** shared packages compile for iOS; mobile auth, idempotent submission, request settlement/device ownership and detached-turn requirements are specified and tested against backend changes. Before promising unattended queues or cross-gateway bot delivery, prove the host-owned queue/relay with every client UI suspended.
- **I1:** native mobile connections, sessions, bots, chat, streaming, attachments, voice and approval inbox with suspension recovery.
- **I2:** artifacts/files/review, remote terminal after its new host-service or SSH gate passes, capability/settings/job management, groups/routines and iPad layout.
- **I3:** push infrastructure, explicit Mac-host service/pairing, share extension, accessibility, storefront-specific account flows and TestFlight/App Store qualification.
- Features requiring unsupported phone-local execution get an explicit host-backed interaction, not a nonfunctional desktop button.

### Staffing and schedule

A reasonable initial planning scenario is two experienced Apple engineers, shared backend support, and dedicated QA/design help during qualification. Treat **roughly 6–9 months for full Mac parity and a further 2–4 months for a substantial iOS product** as a provisional planning range, not a measured estimate or commitment. A smaller focused alpha can arrive much earlier. A solo implementation and exact arbitrary-plugin compatibility can take materially longer.

Re-estimate after M0 using measured vertical-slice throughput and the expanded acceptance ledger. The long poles are transcript quality, runtime/distribution, browser fidelity, extension compatibility and cross-context state correctness. Calendar targets should not remove required features silently.

## 10. Verification strategy

Reuse upstream regression tests as behavioral specifications. Python/TypeScript tests do not directly verify Swift, so build a cross-client fixture and integration suite rather than claiming they transfer automatically.

### Contract and integration coverage

- Generated Swift schema drift check against the pinned OpenRPC and Python contracts.
- Decode real sanitized messages/events/server requests, including null/missing/open fields and unknown enum values.
- Disposable HERMES_HOME fixtures and local backend processes; a second distinct profile/home and a second remote-like backend.
- Real HTTP/WS authentication and profile propagation tests; use provider stubs for deterministic agent output where appropriate.
- Compare Electron and native normalized transcripts and user-visible outcomes for the same fixture scenarios.
- Explicit handling of unsupported backend features and older-runtime fallbacks; no broad catch-and-silently-degrade paths.

### Release-blocking scenarios

1. Force quit during first agent build: initial user message is recoverable exactly once.
2. Disconnect before send acknowledgement: uncertain send is not duplicated automatically.
3. Reconnect during streaming with duplicated events, replay eviction and server epoch reset.
4. Compression/rewind changes runtime session identity without losing durable route/history.
5. Two connections with identical profile names; verify chat, files, settings, voice, plugin and cron ownership.
6. A → B → A profile switch, profile rename, multiple windows and a live background turn.
7. Approval/clarify arrives while a different chat is focused; correct request survives restore and resolves once across two clients.
8. Backend fails during a file write, git action, payment or config mutation; outcome is reconciled rather than assumed.
9. Remote files, preview localhost URLs and terminal cwd resolve on the intended host.
10. Hidden terminal survives layout changes; closing a view and stopping its process remain distinct.
11. Web content attempts unsolicited external navigation or privileged bridge access.
12. Plugin reload/disposal, disabled unified plugin, broken plugin, cross-profile storage and scoped backend calls.
13. Bot canonical chat survives hidden state, compression, simultaneous opening, profile rename and restart; group stop/authority behaves consistently.
14. Native install without developer tools; old CLI runtime; bad managed install; interrupted app/runtime updates and clean recovery.
15. Sleep/wake and network path change; expired credentials; canceled microphone/screen permissions.
16. iOS suspension/termination during turn, pending approval and upload; foreground state converges without duplicate sends.

### Proposed performance and quality targets

Targets must be measured in M0 and ratified on a named reference Mac/iPhone; they are not current benchmark results.

| Metric | Initial target |
| --- | --- |
| Warm native shell usable | Within 1 second, independent of slow backend/provider readiness |
| Composer typing/interaction | p95 response under 50 ms during active streaming |
| Scroll/resize | Smooth 60 Hz interaction on reference hardware; no repeated long main-thread stalls |
| History fixture | At least 10,000 messages with paging/virtualization and bounded rendered blocks |
| Concurrency fixture | Multiple streaming sessions and terminals; background updates do not repaint the whole app |
| Reconnect correctness | No client-caused duplicate submissions/approval actions; uncertain non-idempotent external effects stay visible and are reconciled |
| Resource usage | Measure app, helper, WebKit and Python separately; compare like-for-like Electron scenarios |
| Accessibility | VoiceOver, keyboard-only use, focus order, Dynamic Type on iOS, contrast and reduced motion pass |

Do not advertise a RAM or battery improvement until it is measured with the same backend, conversation, plugins and browser pages. Python, models and web content may dominate resource usage even after Electron is removed.

## 11. Main risks and decision gates

| Risk | Why it matters | Mitigation / decision |
| --- | --- | --- |
| Full scope underestimated | Current desktop includes operations, billing, groups, plugins and OS helpers | Source-backed parity ledger; milestone exits |
| React SDK incompatibility | Existing plugins render arbitrary React throughout the shell | Early compatibility prototype; explicit conformance and exception policy |
| Browser input mismatch | Electron uses trusted Chromium input | Public-API native spike; explicit host-browser alternative if needed |
| Transcript quality/performance | Streaming, selection, tools and huge history are the primary experience | Native renderer spike before view architecture freezes |
| Profile/session identity errors | Wrong backend or disappearing history is a high-impact regression | Typed IDs, scoped actors, cross-home tests and authoritative reconciliation |
| Runtime packaging/permissions | Fresh installs and updates encounter code signing, paths and TCC | Signed clean-machine spike, versioned manifests and repair paths |
| Mobile suspension | Client-owned queues/relays and UI requests can stall unattended work | Host authority, capability ownership and detached-run policy |
| Upstream drift | Backend and desktop change rapidly | Pin schema/runtime, compatibility manifest, scheduled engineering review of upstream changes |
| Auth/tenant assumptions | Multi-client fanout is not multi-user authorization | Personal-host boundary or explicit per-user/session enforcement |
| Credential migration | Electron envelopes/localStorage are not native stores | Supported export or reauthentication; preserve backend key ownership |
| Commercial account integration | Cloud discovery and billing depend on external service contracts | Validate client identity/callback availability; do not assume another app's credentials |
| Store distribution differences | Local runtime/plugin and purchase flows differ by platform/channel | Direct Mac first; separate mobile storefront requirements |

The immediately actionable starting point is **M0 plus the M1 shared client vertical slice**: pin the contracts, connect natively to an existing Hermes backend, stream a real turn, answer an approval, interrupt, reconnect, and prove the same package works in an iOS target. In parallel, resolve the browser and plugin compatibility gates. Then expand through the complete ledger rather than replacing the scope with a chat-only application.


## Implementation progress — 17 September 2026

Talaria now has working Mac and iOS targets and the M1 conversation foundation. The next slice adds existing-profile switching, session-only model/provider and reasoning selection, bounded native file/image uploads, persistent scoped text drafts, and a durable image-send recovery journal. These are parts of M2/M3; neither milestone is complete. Provider provisioning, full profile management, richer transcript rendering, composer commands/queue controls, terminal/browser bridges and the remaining feature ledger are still required. See [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) for current verification and constraints.
