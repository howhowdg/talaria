# Talaria — implementation status

17 September 2026. The native conversation build now includes settings, attachments and persistent drafts. Full Hermes Desktop feature parity remains in progress.

## Working foundation

Talaria has separate Mac and iOS app targets with shared SwiftUI views, conversation state, protocol models and a Foundation WebSocket client. The Mac app additionally discovers and supervises an existing Hermes Python installation. No Electron, embedded React renderer, web chat view, or third-party Swift packages are used.

The interface supports gateway/profile connection, Keychain-backed token storage, the latest 100 sessions, search, new/resumed conversations, persistent text drafts, streamed text/reasoning, native Markdown/code, expandable tool results, interruption and reconnect hydration. Native request forms cover approvals, clarification and masked secret/vault input. Unsupported UI bridges return an explicit protocol error.

The transport negotiates readiness and server-request support, routes profiles explicitly, handles heartbeat and bounded pending requests, fences old connection generations, preserves snapshot/event ordering and refuses to silently drop overflowing event streams. It never automatically replays an uncertain prompt.

The supervisor detects metadata without executing arbitrary probes, generates an ephemeral gateway token, parses readiness across partial output, redacts bounded logs, and stops only its owned process. The app does not yet install or bundle Hermes/Python.

## Added in this iteration

- Restrained Liquid Glass pass: native navigation/toolbars, floating glass composer, glass actions, semantic typography and adaptive green accents. Compact iPhone empty states offer a direct connection action; larger windows keep the detail welcome separate from a quiet sidebar. iPhone Send/Stop use accessible icon controls to stay compact at larger text sizes. Custom glass falls back to an opaque surface for Reduce Transparency / Increase Contrast, and older OS releases use native material/button fallbacks.
- Original volt-green wing logo and shared Icon Composer app icon with a graphite background. Xcode compiles dynamic light/dark/tinted icon stacks and fallback images for both targets. [Brand assets and generation details](Design/Brand/README.md).
- Existing-profile selection reconnects with explicit routing and restores that profile's selected session and draft. Switching waits for active work and requests to settle, and for resumed snapshots to finish restoring before loading settings; it never activates a global Hermes profile.
- Provider/model catalog, custom model IDs, supported reasoning levels, refresh and explicit host cost-confirmation handling. Changes use the host's validated session-only model command. Provider account provisioning and profile creation remain future work; unsafe standalone reasoning/fast setters are not exposed.
- Native file picker on both targets, per-composer upload state/removal, 20 MB per file, eight files/64 MB per message. Documents are uploaded inside the captured workspace; images are staged separately and queued only on Send.
- A durable send journal handles canonical image paths, lost acknowledgements, startup failure, queued ownership, voice-stop responses, idle reconciliation and stored-session ID changes. Definitively unsent text returns to the draft; ambiguous sends are locked for history review and never replayed automatically.
- Persistent text drafts and selected conversations are keyed by connection, profile and stored session. iOS flushes drafts on backgrounding and rehydrates when returning from the background.

## Verified

| Check | Result |
| --- | --- |
| Generated contract drift | Pass: pinned schema, 218 RPCs, 12 server requests, 69 events |
| Swift tests | 84 passed: 9 protocol, 18 transport/upload, 49 core/state/settings/draft/attachment, 8 process-lifecycle |
| Mac build | Pass, TalariaMac, macOS 14 deployment target, Xcode 27 / Swift 6.4 |
| iOS simulator build | Pass, TalariaIOS, iOS 17 deployment target |
| iOS launch | Installed and launched on iPhone 18 Pro / iOS 27 simulator; captured and inspected light/dark welcome screens. Interactive phone navigation was not verified by the available UI tool |
| Real Hermes integration | Pass against pinned upstream Python, isolated home and synthetic local inference; session-only model switch, stale-session rejection, preserved profile defaults, profile isolation and actual document/image delivery |
| Native runtime integration | Pass: Swift supervisor starts real Hermes, authenticates, chats, reconnects, restores history and stops its listener |
| Native Mac UI | Pass: changed models via catalog/custom ID, switched default → secondary → default with draft restoration, picked/uploaded a real synthetic document and PNG, sent them and observed inference confirmation; post-turn composer unlocked normally |
| Design pass verification | Final Mac and iOS builds pass. Inspected Mac welcome, settings and floating composer; sent a fresh synthetic turn through the redesigned Mac controls and observed completed text/tool output. iOS light/dark welcome screenshots inspected. Accessibility contrast/transparency and older-OS paths reviewed in code, not runtime-tested |
| Branding | Talaria title, sidebar, app/menu names, bundle identifiers, Xcode targets, shared wing mark and layered app icon; compiled icon metadata confirms three appearances with separate background/foreground layers |

The original backend checks observed streamed text/reasoning, a real `todo_list` call and result, final completion and restored history. The extended check also exercised all three synthetic models, confirmed the exact document marker and PNG bytes arrived at inference, verified the image queue was consumed, and independently checked that both persisted profile model defaults remained unchanged. All inference came from the fixture; no real provider credentials, user configuration, or paid model calls were used. The temporary UI fixture and its credential file were cleaned up. Talaria was relaunched at its connection screen; disposable credentials were not saved in Keychain.

Build products are written under `/tmp` because the workspace's synced Documents directory adds metadata that can prevent ad hoc code signing. The full project and sources remain in this workspace. The app is a local development build, not a signed/notarized distribution release.

The initial [public source repository](https://github.com/howhowdg/talaria) uses the MIT license and includes contributor and private security-reporting instructions. A clean copy of the publication source passed all 84 Swift tests, both native platform builds, contract checks and the extended isolated real-gateway/native-runtime integration. Both apps bundle Talaria's license and the upstream third-party notice. No signed binary release is included.

## Still open

The full scope remains in [HERMES_NATIVE_PLAN.md](HERMES_NATIVE_PLAN.md). Upcoming implementation includes richer transcript rendering, attachment previews/paste/drop, composer commands and queue controls; provider provisioning and onboarding; full profiles/settings; projects, git and terminal workspaces; browser/controller bridges; skills, plugins and MCP management; cron/voice; and distribution/update infrastructure.

Reliability work still includes full replay/cursor recovery, multi-client settlement/attachment leases, offline storage, long-history performance, offline conversation storage, background/push behavior on iOS, OAuth/Cloud login and compatibility testing across upstream versions. Current reconnect explicitly restores snapshots; it does not provide complete replay continuity. Use one active sending client per session during this preview: the pinned host has a shared image queue and no atomic attach-and-submit API. Uploads remain on the host after removal from a draft; attachment selections themselves do not survive relaunch. HEIC conversion and physical-device file-provider behavior are not yet verified.

Secret/approval forms are implemented against the pinned wire contract. The real-backend smoke exercises a harmless todo tool, not all approval/vault/provider flows. Keychain persistence, production OAuth and physical-device networking were not exercised during these isolated checks. The deployment targets compile, but macOS 14 and iOS 17 runtimes have not been tested on devices.

## Repeat the checks

```sh
python3 scripts/generate-contracts.py --check
swift test --scratch-path /tmp/hermes-native-swift-build
python3 scripts/smoke-real-gateway.py \
  --smoke /tmp/hermes-native-swift-build/debug/hermes-smoke --timeout 120
python3 scripts/smoke-real-gateway.py \
  --smoke /tmp/hermes-native-swift-build/debug/hermes-smoke --native-runtime --extended --timeout 180
```

The Python integration requires the pinned upstream checkout and a Python environment with its dependencies. Both paths can be supplied with `--repo` and `--python`; the test never modifies that environment. See [fixture notes](scripts/fixtures/README.md).
