# Talaria — implementation status

17 September 2026. The native conversation build now includes settings, attachments, persistent drafts and the v2 Mac workspace redesign. Full Hermes Desktop feature parity remains in progress.

## Working foundation

Talaria has separate Mac and iOS app targets with shared SwiftUI views, conversation state, protocol models and a Foundation WebSocket client. The Mac app additionally discovers and supervises an existing Hermes Python installation. No Electron, embedded React renderer, web chat view, or third-party Swift packages are used.

The interface supports gateway/profile connection, Keychain-backed token storage, the latest 100 sessions, search, new/resumed conversations, persistent text drafts, streamed text/reasoning, native Markdown/code, expandable tool results, interruption and reconnect hydration. Native request forms cover approvals, clarification and masked secret/vault input. Unsupported UI bridges return an explicit protocol error.

The transport negotiates readiness and server-request support, routes profiles explicitly, handles heartbeat and bounded pending requests, fences old connection generations, preserves snapshot/event ordering and refuses to silently drop overflowing event streams. It never automatically replays an uncertain prompt.

The supervisor detects metadata without executing arbitrary probes, generates an ephemeral gateway token, parses readiness across partial output, redacts bounded logs, and stops only its owned process. The app does not yet install or bundle Hermes/Python.

## Added in this iteration

- Handoff v2 identity: the supplied vector sandal mark, New York wordmark, adaptive blue link/mark colors and prominent blue controls. [Source handoff and screenshots](Design/handoff/README.md) and [brand notes](Design/Brand/README.md) are retained locally in the repository. The existing green launcher icon is unchanged; the in-app brand now uses blue.
- Mac screen 4a: a fixed 240-point sidebar and 290-point inspector around a flexible chat column, a 52-point header, compact session rows grouped by actual gateway session start date, profile/connection footer, composer model control, and a persistent Sidebar/Tabs preference. Closing a tab preserves its conversation and draft; failed opens and host stored-ID rotations reconcile with the authoritative model selection. Native window dimensions now accommodate the three panes.
- Inspector Files/Sources/Terminal tabs reflect recorded conversation evidence and current attachments. File previews use tool-provided content; host paths are never read through the Mac filesystem. Source links allow only HTTP(S), and the list retains the most recent 100 URLs. Terminal is a read-only tool-output record. These are not a live directory listing, live file watcher or interactive PTY.
- Shared stacked tool cards, confirmed todo status, running indicators and streaming cursor. Todo parsing is cached by completed result data and connection/profile/session scope, so text deltas do not repeatedly parse history. Reduce Motion disables the pulses; custom glass retains opaque accessibility and older-system material fallbacks. iPhone floating chrome is the next handoff stage, not part of this Mac implementation.
- Existing-profile selection reconnects with explicit routing and restores that profile's selected session and draft. Switching waits for active work and requests to settle, and for resumed snapshots to finish restoring before loading settings; it never activates a global Hermes profile.
- Provider/model catalog, custom model IDs, supported reasoning levels, refresh and explicit host cost-confirmation handling. Changes use the host's validated session-only model command. Provider account provisioning and profile creation remain future work; unsafe standalone reasoning/fast setters are not exposed.
- Native file picker on both targets, per-composer upload state/removal, 20 MB per file, eight files/64 MB per message. Documents are uploaded inside the captured workspace; images are staged separately and queued only on Send.
- A durable send journal handles canonical image paths, lost acknowledgements, startup failure, queued ownership, voice-stop responses, idle reconciliation and stored-session ID changes. Definitively unsent text returns to the draft; ambiguous sends are locked for history review and never replayed automatically.
- Persistent text drafts and selected conversations are keyed by connection, profile and stored session. iOS flushes drafts on backgrounding and rehydrates when returning from the background.

## Verified

| Check | Result |
| --- | --- |
| Generated contract drift | Pass: pinned schema, 218 RPCs, 12 server requests, 69 events |
| Swift tests | 130 passed: 9 protocol, 18 transport/upload, 53 core/state, 42 workspace presentation/navigation, 8 process-lifecycle |
| Mac build | Pass, TalariaMac, macOS 14 deployment target, Xcode 27 / Swift 6.4 |
| iOS simulator build | Pass, TalariaIOS, iOS 17 deployment target |
| iOS launch | Installed and launched on iPhone 18 Pro / iOS 27 simulator; captured and inspected light/dark welcome screens. Interactive phone navigation was not verified by the available UI tool |
| Real Hermes integration | Pass against pinned upstream Python, isolated home and synthetic local inference; session-only model switch, stale-session rejection, preserved profile defaults, profile isolation and actual document/image delivery |
| Native runtime integration | Pass: Swift supervisor starts real Hermes, authenticates, chats, reconnects, restores history and stops its listener |
| Native Mac UI | Pass: changed models via catalog/custom ID, switched default → secondary → default with draft restoration, picked/uploaded a real synthetic document and PNG, sent them and observed inference confirmation; post-turn composer unlocked normally |
| Design pass verification | Final Mac and iOS builds pass. Inspected Mac welcome, settings and floating composer; sent a fresh synthetic turn through the redesigned Mac controls and observed completed text/tool output. iOS light/dark welcome screenshots inspected. Accessibility contrast/transparency and older-OS paths reviewed in code, not runtime-tested |
| Branding | Talaria title, app/menu names, bundle identifiers and Xcode targets. V2 in-app SVG template and blue color variants compile on both platforms. Layered launcher icon still uses the earlier artwork |

The original backend checks observed streamed text/reasoning, a real `todo_list` call and result, final completion and restored history. The extended check also exercised all three synthetic models, confirmed the exact document marker and PNG bytes arrived at inference, verified the image queue was consumed, and independently checked that both persisted profile model defaults remained unchanged. All inference came from the fixture; no real provider credentials, user configuration, or paid model calls were used. The temporary UI fixture and its credential file were cleaned up. Talaria was relaunched at its connection screen; disposable credentials were not saved in Keychain.

Build products are written under `/tmp` because the workspace's synced Documents directory adds metadata that can prevent ad hoc code signing. The full project and sources remain in this workspace. The app is a local development build, not a signed/notarized distribution release.

The initial [public source repository](https://github.com/howhowdg/talaria) uses the MIT license and includes contributor and private security-reporting instructions. A clean copy of the publication source passed all 84 Swift tests, both native platform builds, contract checks and the extended isolated real-gateway/native-runtime integration. Both apps bundle Talaria's license and the upstream third-party notice. The subsequent 0.1.1 Mac preview adds an ad hoc signed universal download; it is not notarized.

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

## Mac handoff v2 verification

The workspace uses a plain `HStack` with fixed 240/290-point side columns, per the revised exact Mac specification. Custom 52-point headers and a 28-point search field avoid injected split-view toolbar and search geometry.
Native interaction checks used an isolated real Hermes gateway with synthetic inference: selected/restored a conversation, changed Sidebar → Tabs, closed and reopened a tab with its draft intact, opened a second conversation, sent a successful test turn, inspected recorded Files/Sources/Terminal states, and opened model settings from the composer. No real provider keys or paid model calls were used. Historical sessions may contain only tool summaries; the status stack presents full tasks only when the gateway actually supplied a confirmed result.

The source-level checks cover invalid timestamps, failed tab navigation, stored-ID rotation, scoped inspector/task data, bounded source retention, safe URLs, opaque host paths, task clears/revisions and streaming cache behavior. The full iPhone handoff, live host filesystem/terminal features, and Skills/Schedules/Kanban destinations remain future work.

The latest [exact Mac correction spec](Design/handoff/SWIFTUI_SPEC_MAC.md) supersedes the earlier semantic-font version. `TalariaTheme.swift` supplies the fixed light palette, point typography and explicit glass treatments. Following the latest visual feedback, Mac body text is 12.5pt; sidebar rows are 12pt; tool rows are 11pt; buttons remain 36pt tall. The 26pt composer has a white top highlight and a navy shadow at radius 15/y 10. iOS retains Dynamic Type and its existing system glass controls. Compact tool summaries contain parsed paths, commands or queries, never raw JSON; full payloads remain expandable. Pulses respect Reduce Motion and the composer retains an opaque Reduce Transparency fallback.

Debug builds include **Window → Design Reference Size (1180 × 760)** and **Export 2× Design Snapshot…** for repeatable native window captures on macOS 14.4 or later. The capture is restricted to Talaria’s own process and preserves the display color profile. Older systems explicitly label their fallback as a view render.

Previous-pass native captures: [Sidebar workspace](research/screenshots/talaria-mac-handoff-v2-sidebar.png) and [Tabs workspace](research/screenshots/talaria-mac-handoff-v2-tabs.png). These use synthetic integration-test data with an unsent draft. Both final platform builds succeeded and all 126 tests passed. The disposable UI draft was cleared, the app was quit and the isolated gateway resources were cleaned up; test credentials were not saved.

The exact-spec pass passed both platform builds and all 130 tests. Live Mac checks covered the 1180×760 window, visible connection footer, creating/sending a conversation, expanding exact tool payloads, and switching sessions with a single selected row. The 2360×1520 [2× content render](research/screenshots/talaria-mac-exact-spec-2x.png) verifies native layout dimensions; the [window capture](research/screenshots/talaria-mac-exact-spec-window.jpg) records desktop-composited materials and system window controls. The content render is produced by AppKit, not by upscaling a screenshot.

The Mac composer uses a transparent native NSTextView bridge so its 36–140pt measured height does not display an empty scroller. Live checks covered multiline growth, editor focus, native undo via its delegate-provided undo manager, and ⌘Return send. Programmatic draft replacement clears undo; session changes recreate the editor. The temporary gateway and unsent UI draft were removed after capture, and no test token was saved.

[Round-three finishing corrections](Design/handoff/SWIFTUI_FIXES_ROUND3.md) pin the Mac root to medium Dynamic Type, replace native gray divider underlays with 1pt white column edges and 6% black internal separators, make the 12pt search prompt explicit, retain white text on the disabled 40%-blue send fill, and refine recorded-preview spacing and secondary copy. The subsequent visual review reduced Mac workspace text by 1pt, removed the compounded 14pt leading lockup padding, and replaced the boxed compose glyph with the standalone pencil from the visual reference. Control frames remain unchanged. The single-selection correction remains in place.

Latest compact Mac verification: both platform builds pass; all six focused Mac navigation tests pass. The native app was relaunched and checked for the corrected lockup position, standalone pencil, smaller text, new-conversation creation, sending and stable single-row selection. Current 2360×1520 native window captures: [compact workspace](research/screenshots/talaria-mac-compact-workspace-2x.png) and [recorded-file inspector](research/screenshots/talaria-mac-compact-files-2x.png). These replace the earlier AppKit content render for material/appearance comparisons. Synthetic test data only; the disposable gateway was stopped and its credential file removed.
