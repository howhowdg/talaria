# Talaria

<img src="Design/Brand/talaria-app-icon.png" width="112" alt="Talaria app icon">

A SwiftUI Mac application and an iOS companion, backed by the existing Hermes Python agent.
This is an independent native client prototype. It is not an official Nous Research release.

Mac and iOS share one codebase, available under the [MIT license](LICENSE). See [contributor setup](CONTRIBUTING.md), [source release scope](PUBLIC_RELEASE.md), and [security reporting](SECURITY.md).

The latest source organises your Hermes conversations into **Home, Workspaces, Automations and Activity** on Mac and iOS. Home is explicitly chosen; Workspaces contain conversations you assign; each Automation has result-first Runs; Activity separates **Needs you** from unread results. Native model selection, profiles, attachments and persistent drafts remain available. Talaria is **not yet a full replacement for Hermes Desktop**. See the [hierarchy implementation and limits](IMPLEMENTATION_STATUS.md#current-hierarchy-implementation) and [full roadmap](HERMES_NATIVE_PLAN.md).

[Current hierarchy screenshots and verification](Design/verification/hierarchy/README.md) show native development builds with synthetic fixture data. The earlier [Mac v0.1.1 workspace](research/screenshots/talaria-mac-compact-workspace-2x.png) and [five-tab iPhone design](research/screenshots/talaria-ios-handoff-chat.png) are retained as historical evidence.

## Download the Mac preview

Download **[Talaria 0.1.2 for macOS](https://github.com/howhowdg/talaria/releases/download/v0.1.2/Talaria-0.1.2-macOS-universal.zip)**, a universal app for Apple silicon and Intel. It requires macOS 14 or later and an existing Hermes installation or reachable compatible gateway. Unzip it, move `Talaria.app` to Applications, and open it.

This preview is Developer ID signed, notarized by Apple, and includes a stapled notarization ticket. The final archive passes Gatekeeper after extraction. [Release notes and checksums](https://github.com/howhowdg/talaria/releases/tag/v0.1.2) include the current hierarchy, gateway compatibility fixes, Telegram topic import and Mac transcript bubbles. The iOS source is available, but an installable iPhone release is not yet published.

For maintainers, the [Mac distribution guide](research/MAC_DISTRIBUTION.md) covers the Xcode and command-line packaging workflows. Build products and signing credentials are excluded from version control.

## Run the Mac app

```sh
git clone https://github.com/howhowdg/talaria.git
cd talaria
open Talaria.xcodeproj
```

Open `Talaria.xcodeproj` in Xcode, choose **TalariaMac**, and run. The checked-in project is generated from `project.yml`; regenerate it with `xcodegen generate` after changing targets.

Runtime targets: macOS 14+ and iOS 17+. Development uses Xcode 27 / Swift 6.4 for the current Liquid Glass UI and Icon Composer assets; this Xcode version requires a newer Mac host (the tested installation requires macOS 26.6+). No external Swift package dependencies are required. See [contributor setup](CONTRIBUTING.md) and [implementation status](IMPLEMENTATION_STATUS.md) for build requirements and verification limits.

```sh
xcodebuild -project Talaria.xcodeproj -scheme TalariaMac \
  -configuration Debug -derivedDataPath /tmp/talaria-native-build \
  CODE_SIGN_IDENTITY=- build
```

The app is at `/tmp/talaria-native-build/Build/Products/Debug/Talaria.app`. Build output lives outside the synced Documents folder because file-provider metadata can prevent code signing there.

Choose **Start local Hermes** to launch an existing Hermes installation using its default profile and provider configuration. Sending prompts uses that installation's configured provider. The app manages only the process it starts and stops it when you quit; closing the window leaves the app running. It does not install Python or Hermes yet.

Alternatively choose **Connect to a gateway** and enter a URL, profile, and gateway session token. Loopback HTTP and remote HTTPS are supported. Remote OAuth / Hermes Cloud login is not implemented yet. Tokens can be saved in the system Keychain; endpoint metadata is kept in the native app's own preferences. Agent/provider credentials stay on the host.

For an SSH tunnel, forward to a Hermes endpoint bound to `127.0.0.1` on the remote host. Forwarding a public-address dashboard can fail its hostname check and still require browser sign-in. Talaria explains that rejection without changing the Host header or bypassing authentication. SSH tunnel startup and restart are not managed by the app yet.

The latest source also supports older gateways that use event-based approval, clarification, sudo and secret requests. Answers retain the original request ID and permission scope and are never retried automatically. Those gateways cannot restore a pending sudo/secret prompt after reconnect; Talaria explains how to resolve it in the original client. Use the backend's launch profile with older versions: their settings inventory may not isolate other profiles correctly.

## iPhone and iPad

Choose the **TalariaIOS** scheme and an iOS simulator, or configure your development team to run on a device. The deployment target is iOS 17. The iOS app shares the actual client and native views with macOS and connects to a Hermes host; it does not run the Python agent on the phone. Use a reachable HTTPS endpoint on a physical device. The host continues the work when iOS suspends, and the app rehydrates session history on return. Background delivery and push notifications are future work.

The iOS app follows the [hierarchy handoff](Design/handoff/hierarchy/README.md) with four tabs: **Home · Workspaces · Automations · Activity**. Each tab keeps its navigation stack; Skills and Settings are in the profile menu, and Files belongs to the selected workspace or conversation. The same hierarchy shell is currently used at regular width; a separate iPad layout has not been redesigned or verified in this pass. Typography follows Dynamic Type, with light/dark and accessibility fallbacks.

Automations reads actual host instructions and run history, exposes Enabled/Paused and Run now/Retry, and opens the final assistant result before optional execution details. Enable a Paused automation explicitly before running it; the pinned host trigger would otherwise change its standing schedule. Unknown or incomplete history is shown as unavailable, never invented as Completed. Skills remains a read-only list of installed names/categories; Files shows recorded tool evidence rather than a live host filesystem. Approval controls preserve the host's exact option values and permission restrictions. Drafting during a request is allowed; supported clarification requests also accept a free-text answer. Sending a new prompt during a running turn, live steering, voice and push delivery remain future work.

## Home and organisation

Choose Home from an existing conversation or start fresh. Talaria never chooses Home or creates a Workspace from a title, recency, Telegram source or backend parent ID. If the chosen Home is confirmed missing, its bounded cached transcript remains visible with Choose another/Start fresh controls and a disabled composer.

Workspace names, purposes, colours, explicit conversation assignments, archive state, Home choice, read tracking and places are saved **on this device**, scoped to connection and profile. iCloud KVS and server-based cross-device organisation are not implemented. Session `source` is retained as provenance; it does not establish a Telegram topic binding. A Workspace started explicitly from Home records a branch after its conversation is created. A branch is never labelled a Delegated task.

**Discuss this result** lets you choose a destination and context. Result and back-link start selected; sources and execution transcript do not. Only chosen context is placed in that destination's draft; review it and press **Send** yourself. This is a client quotation and local deep link, not a host-guaranteed provenance reference.

## Implemented

- Native Liquid Glass controls and floating composer on current systems, adaptive light/dark accents, and a shared layered Talaria app icon. Older systems receive native material/button fallbacks. [Identity, assets and generation prompt](Design/Brand/README.md).
- Three-column Mac hierarchy with sidebar navigation and Context/Files/Terminal inspector; four-tab iOS hierarchy with owning-tab navigation, grouped search, create/resume, per-conversation drafts and scroll places. The former Sidebar/Tabs preference is removed.
- Explicit Home and local Workspaces, result-first Automations/Runs, unread updates and Needs-you requests in Activity, amber attention assets, and visible partial-load/unavailable states.
- Host-backed Automation pause/resume and trigger actions; recorded tools/sources/instructions are disclosed separately from results. Installed Skills remains read-only.
- Conversation-scoped model/provider selection, supported reasoning levels, provider catalog refresh and existing-profile switching.
- Native file picker, bounded file/image uploads, attachment progress/removal and interruption recovery.
- Token authentication, scoped profile routing, WebSocket JSON-RPC, readiness negotiation, heartbeat, cancellation/timeouts, bounded event delivery, explicit reconnect.
- Streaming assistant text and reasoning, tool cards, authoritative final text, backend interruption, restored conversation history.
- Native server-request controls for approval, clarification, secret entry, sudo and vault input.
- Keychain token storage and a Mac-only local runtime supervisor with readiness parsing and bounded shutdown.
- Pinned upstream OpenRPC contract with a generated exhaustive method/event catalog and focused Codable models.

Mac and iOS support explicit Telegram topic import when the authenticated [optional gateway extension](research/TELEGRAM_TOPIC_INTEGRATION.md) is available. Choose one topic as Home and selected topics as Workspaces; choices remain local to the connection and profile. Talaria follows stable chat/thread/routing identities to Hermes's current session when refreshed or opened, without choosing Home from titles or recency. Saved topic names can be recovered from explicit Hermes configuration or recorded Telegram creation/edit results; these are last-observed labels, not a live Telegram title lookup. Numbered imported defaults update when names become available, while custom Workspace names stay intact. Missing topic names appear as **Topic &lt;ID&gt;**, with the conversation title labelled separately. Missing or unverifiable bindings retain the saved organisation and disable the composer. Discovery reads Hermes's persisted routing metadata; it does not scrape Telegram names or history, and periodic real-time synchronisation is not implemented.

Other backend-dependent hierarchy integrations remain off by default: delegated-task lifecycle/goal/progress, automation instruction editing, general reset/compression continuity and canonical result references. Receiving an already-supported host request never hides it behind a feature flag.

Native Markdown supports inline formatting, headings, lists, quotes and fenced code while streaming. Tables, rich media, syntax highlighting, provider provisioning/accounts, broad preferences, projects/git, interactive terminals, browser control, plugins, skill/MCP management, schedule editing, voice and the other desktop subsystems remain on the roadmap. Session listing currently loads the latest 100 sessions. Existing profiles can be selected from the host; creating, editing and deleting profiles is not implemented.

New sessions use `source: "native"` until the client implements the desktop UI bridges. Unsupported UI server requests receive a method-not-supported error. Merely generating all RPC names does not implement their features.

Reconnect restores authoritative snapshots. It never automatically resends an uncertain prompt. Full replay-gap recovery, attachment leases, multi-client request settlement, long-history virtualization, offline storage and resilient background lifecycle still need the later roadmap work. Keep this preview to one active native client per session.

## Attachments and drafts

Use the paperclip in an idle conversation to choose files. This preview allows up to eight files, 20 MB each and 64 MB total. PNG, JPEG, GIF, WebP and BMP are supported as images; HEIC conversion, drag/drop and Photos import are future work. Document extraction depends on the Hermes host's installed readers.

Files are copied to `.hermes/native-attachments/<unique-id>/` inside the selected conversation's working directory on the host. Image bytes are staged in the host's image storage and added to the conversation only when you press Send. Removing a composer attachment does not delete its uploaded host file, so stored transcript references remain usable. Talaria shows the destination and rejects stale document references when the workspace changes.

Text drafts and the selected conversation survive relaunch in Talaria's private application-support directory, scoped by connection, profile and stored conversation ID. Attachments remain in memory and must be selected again after relaunch. A separate send journal records host image paths for recovery, without credentials or file bytes. An uncertain send is never replayed automatically. The pinned backend has a session-wide image queue, so use one active client per session until an atomic attachment-submit API is available.

## Verify

```sh
python3 scripts/generate-contracts.py --check
swift test --scratch-path /tmp/talaria-swift-build
```

Current hierarchy verification: **189 Swift tests pass**, generated contract drift passes, and final Mac Debug/Release plus iOS simulator Debug/generic-device Release builds pass. Native Mac checks include the complete approval-to-receipt interaction, dark appearance and unavailable Home with a cached transcript and disabled composer. See [implementation status](IMPLEMENTATION_STATUS.md#current-hierarchy-verification) for interaction evidence, prior real-gateway checks and visual-verification limits.

`scripts/smoke-real-gateway.py` launches the pinned upstream Python server in a disposable home with a synthetic loopback OpenAI-compatible provider. It uses no real provider keys, runs a harmless todo tool cycle, and checks native-client reconnect and history. It requires the Hermes Python dependencies to already be installed; run `python3 scripts/smoke-real-gateway.py --help` for paths/options. Use `--native-runtime` to additionally verify that the Swift runtime manager starts and stops the real backend. Add `--extended` to verify session-only model changes, profile isolation and actual document/image delivery to the synthetic provider. The fixture blocks outbound Python networking and whitelists the subprocess environment. It is a test harness, not a replacement agent backend.

The standalone `hermes-smoke` executable can also exercise a configured gateway. It creates a session and sends a real prompt; set `HERMES_GATEWAY_TOKEN` in the environment rather than placing tokens in command arguments.

For repeatable phone design previews, the [synthetic iPhone fixture instructions](IMPLEMENTATION_STATUS.md#repeat-the-iphone-design-preview) use `scripts/fixtures/mobile_design_gateway.py` and `scripts/preview_ios_design.py`. This Debug-only path supplies sample data without real provider calls; it is separate from real Hermes integration testing.

## Layout

| Module | Responsibility |
| --- | --- |
| HermesProtocol | JSON-RPC wire types and pinned generated schema models |
| HermesTransport | Authenticated HTTP / WebSocket gateway client |
| HermesCore | Conversation/settings state, local hierarchy classification, run results, drafts, attachment transactions, app coordination, Keychain |
| HermesUI | Shared native SwiftUI interface |
| HermesMacServices | Mac-only runtime discovery and process ownership |
| Apps/macOS, Apps/iOS | Platform app entry points |
| Tests, scripts/fixtures | Protocol, transport, state, process and integration checks |

The source audit targets upstream commit `a566d20d226a8e2ef0747639dc8a3fc1c43f9dba`. The downloaded upstream checkout is ignored by Git; the pinned contract is included for reproducible generation. Preserve `ThirdPartyNotices.md` when distributing that schema or generated code.

## License and attribution

Talaria's original code and included artwork are distributed under the [MIT license](LICENSE). The Hermes gateway schema and generated code retain Nous Research's MIT notice in [ThirdPartyNotices.md](ThirdPartyNotices.md). Both notices are also bundled in the native apps. The backend remains the separate [Hermes Agent project](https://github.com/NousResearch/hermes-agent).
