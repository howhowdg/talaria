# Talaria — implementation status

18 September 2026. The latest source implements the Home / Workspaces / Automations hierarchy on Mac and iOS. The v0.1.2 Mac preview contains this hierarchy, gateway compatibility fixes, Telegram import and the round-five transcript bubbles. Its universal download is Developer ID signed and notarized, with a stapled ticket and Gatekeeper verification. Full Hermes Desktop feature parity remains in progress.

## Current hierarchy implementation

The current design source of truth is [hierarchy/README.md](Design/handoff/hierarchy/README.md), its platform specifications and terminology table. It supersedes the former Mac Sidebar/Tabs preference and five-tab phone navigation. Earlier round-three/four refinements and the Settings Kit still apply where the hierarchy does not replace them.

**Mac:** Home and Activity are pinned above Workspaces, Automations and Other conversations in the 240pt sidebar. The 290pt inspector uses Context / Files / Terminal. Runs retain their Automation selection and show the result before the execution disclosure. **iOS:** Home / Workspaces / Automations / Activity each have a navigation stack, with destination-aware floating chrome. Skills and Settings move to the profile menu; Files belongs to its workspace/conversation. The same shell now runs at regular width; a distinct iPad redesign and runtime validation remain open.

### Bucket A — implemented against the existing contract

- Automation list/detail, actual job-specific Run history, Enabled/Paused and Run now/Rerun/Retry. A Paused automation must be explicitly enabled first because the pinned host trigger would otherwise enable its standing schedule. A Run's final assistant result is displayed first; recorded tools, sources and instructions stay inside a collapsed execution disclosure. Failed, Waiting for input, No output and unavailable history have distinct states. An inactive session alone never proves completion; hidden display projections and silent output are not promoted into a result.
- Explicit Home selection/start fresh, retained session `source`, and a confirmed-missing Home state with a bounded cached transcript and disabled composer. Missing rows in a bounded list and transient network errors are not treated as deletion. Known Run session IDs are excluded from the Home picker, which stays scrollable when many candidates exist.
- Activity combines supported host requests and unread terminal Run results. Needs-you count tracks decisions; marking results read does not answer or clear a request. Request options retain the host's values and restrictions. Existing supported clarification/secret/vault requests remain reachable even while future hierarchy integrations are disabled.
- Grouped local search, per-conversation drafts and stable message-place restoration, request-origin navigation, and attention assets: `#B8640A` light / `#E8A24A` dark. Appearance and accessibility fallbacks use native controls and semantic text colours.

### Bucket B — implemented with a local classification store

- Named Workspaces with purpose, swatch and explicit conversation membership; Make it a workspace / Add to / Archive / Restore. Other conversations remain visible until explicitly classified. Neither title, recency, source nor backend parent ID assigns Home or a Workspace.
- Home choice, workspace organisation, read tracking, recorded lineage and conversation places persist by connection/profile. **The store is local-only. iCloud KVS and other cross-device synchronisation are not implemented.** A corrupt store is reported rather than silently replaced.
- A Workspace explicitly created from Home records a branch only after successful conversation creation. Home reference cards and Started from Home links render from those client records. Branches are not called Delegated tasks. Unknown goals, progress, results and lifecycle states are not fabricated.
- Workspace files are conservative references from completed tool evidence under that session's known working directory. Existing previews remain recorded content; no local-device filesystem access is used to inspect a host path.
- Discuss this result selects a destination and exactly which context to include. Result and back-link are selected initially; sources and execution transcript are optional. Chosen context is staged in the existing destination draft, and normal Send remains a separate user action. The local deep link is scoped to connection/profile; canonical host provenance is not claimed.

### Bucket C — optional Telegram import; remaining integrations off

Telegram bindings become available after the authenticated [optional gateway extension](research/TELEGRAM_TOPIC_INTEGRATION.md) returns a validated snapshot. Mac and iOS expose explicit import: choose a topic as Home and selected topics as Workspaces. Assignments persist locally by connection/profile and stable chat/thread/routing identity; refreshing or opening an assigned destination follows its current Hermes session pointer, including an explicit replacement after reset. No title or recency selects Home. Saved topic names can be recovered from explicit Hermes configuration or recorded Telegram creation/edit results; these are last-observed labels, not a live Telegram title lookup. Numbered imported defaults update when names become available, while custom Workspace names stay intact. Missing topic names use **Topic &lt;ID&gt;**, and existing conversation titles appear separately as conversation labels. Missing or unverifiable bindings preserve saved assignments and disable the destination's composer. This reads Hermes's persisted routing metadata, not Telegram names or history through scraping; periodic real-time synchronisation is not implemented.

Delegated-task lifecycle, automation editing, general Home reset/compression continuity and canonical result-reference switches still default to false. No invented live delegated progress/goal, instruction editor or server-provenance promise is exposed. Existing native host clarification support remains usable; this does not implement the proposed future delegated-task API. Cross-device organisation is also outstanding.

The prototype's sample workspaces, permission metadata, times and worker results are used only by the explicit Debug fixture. Production views use host data and explicit local assignments.

## Current hierarchy verification

| Check | Result |
| --- | --- |
| Swift test suite | Release rerun passes all 219: 116 Core, 47 UI, 39 Transport, 9 Protocol, 8 MacServices; `swift test --scratch-path /tmp/talaria-swift-build` |
| Mac builds | Final Debug and Release pass, including dark-appearance polish and disabling model fields when no conversation is in scope |
| iOS builds | Simulator Debug and generic-device Release pass after the receipt fix; generic-device verification uses signing disabled |
| Generated contract drift | Pass: 218 RPCs, 12 server requests, 69 events |
| Native Mac interactions | Explicit Home picker, keyboard navigation to all four roots, Activity navigation to the exact approval origin with all host choices, and Mark all read retaining Needs you verified. Run result appears before collapsed execution. Discuss defaults to result and back-link and stages a draft without sending |
| Native hierarchy appearance | Ten inspected Mac captures and 16 inspected iPhone captures are saved under [Design/verification/hierarchy](Design/verification/hierarchy/README.md). Mac dark Home has legible model controls; unavailable Home retains its cached transcript with a disabled composer |
| Approval receipt | In the rebuilt Mac app, choosing the host's once option removes the pending card, shows “You chose once”, receives the synthetic final message and clears the Needs-you badge |

The v0.1.2 artifact is `build/releases/0.1.2/Talaria-0.1.2-macOS-universal.zip` (gitignored), accompanied by `SHA256SUMS`. The final ZIP contains only `Talaria.app`; a fresh extraction passes Developer ID, hardened-runtime, secure-timestamp, stapled-ticket and Gatekeeper checks. Local build-path symbols and filesystem metadata are removed. [The public release](https://github.com/howhowdg/talaria/releases/tag/v0.1.2) supersedes the older ad hoc hierarchy and round-five development archives.

Round-five transcript renders cover light/dark, opaque and narrow layouts at 2×. See [their verification notes](Design/verification/round5/README.md) for the explicit avatar-offset choice and live-interaction limitations. The UI feature pass and distribution validation do not imply full older-OS or clean-machine runtime coverage.

Current screenshots are native SwiftUI output with synthetic local data. Mac window captures are 2× PNGs; the Discuss modal is a native 1× 440×517 JPEG because the window exporter excludes child windows. iPhone simulator screenshots retain their native 3× resolution rather than being resampled to the handoff's 2× files. Compare logical point sizes. Capture provenance, covered states and interaction limits are documented beside the images.

The iPhone evidence includes light/dark appearance, larger accessibility text, unavailable Home, failed/no-output Runs and the approval origin with all four host options. Installation, launch and captures used `simctl`; DeviceHub/CUA was unavailable for phone interaction. These renders do not establish tap/swipe behaviour, physical-device networking, older-OS runtime support, background delivery or full Hermes Desktop parity. The current pass does not repeat the earlier real-gateway integration checks documented below.

## Earlier gateway connection compatibility verification

The latest local source recognizes Hermes's exact hostname-rejection response and provides SSH forwarding guidance. It does not override Host validation or gated authentication. Initial connection failures no longer suggest restoring a conversation when none exists.

When `client.capabilities` returns JSON-RPC method-not-found, the transport adapts legacy approval/clarify/sudo/secret events and reply methods. Other negotiation failures remain errors. Approval choices stay scoped to their session and request; expiration, bounded replay tracking, concurrent queue refresh and uncertain-response handling prevent silent approval or automatic answer retries. Legacy snapshots that cannot restore a waiting input fail with actionable guidance.

Verification at the gateway-fix baseline: all 159 Swift tests passed (37 transport, 63 core, 42 UI, 9 protocol, 8 Mac services), and the Mac Debug build succeeds. The actual Mac connection sheet connected to a remote Hermes `7d6db4ef` backend through a separately owned loopback SSH endpoint and loaded the session list. No live agent prompt or permission answer was submitted in this check. The user's existing remote services were preserved. The temporary SSH helper is external to the app and must be restarted after it exits or the Mac restarts; managed SSH connections remain future work. These fixes are not in the published v0.1.1 binary.

## Working foundation

Talaria has separate Mac and iOS app targets with shared SwiftUI views, conversation state, protocol models and a Foundation WebSocket client. The Mac app additionally discovers and supervises an existing Hermes Python installation. No Electron, embedded React renderer, web chat view, or third-party Swift packages are used.

The interface supports gateway/profile connection, Keychain-backed token storage, the latest 100 sessions, search, new/resumed conversations, persistent text drafts, streamed text/reasoning, native Markdown/code, expandable tool results, interruption and reconnect hydration. Native request forms cover approvals, clarification and masked secret/vault input. Unsupported UI bridges return an explicit protocol error.

The transport negotiates readiness and server-request support, routes profiles explicitly, handles heartbeat and bounded pending requests, fences old connection generations, preserves snapshot/event ordering and refuses to silently drop overflowing event streams. It never automatically replays an uncertain prompt.

The supervisor detects metadata without executing arbitrary probes, generates an ephemeral gateway token, parses readiness across partial output, redacts bounded logs, and stops only its owned process. The app does not yet install or bundle Hermes/Python.

## Historical foundation — identity, conversations and attachments

- Handoff v2 identity: the supplied vector sandal mark, New York wordmark, adaptive blue link/mark colors and prominent blue controls. [Source handoff and screenshots](Design/handoff/README.md) and [brand notes](Design/Brand/README.md) are retained locally in the repository. The existing green launcher icon is unchanged; the in-app brand now uses blue.
- Mac screen 4a: a fixed 240-point sidebar and 290-point inspector around a flexible chat column, a 52-point header, compact session rows grouped by actual gateway session start date, profile/connection footer, composer model control, and a persistent Sidebar/Tabs preference. Closing a tab preserves its conversation and draft; failed opens and host stored-ID rotations reconcile with the authoritative model selection. Native window dimensions now accommodate the three panes.
- Inspector Files/Sources/Terminal tabs reflect recorded conversation evidence and current attachments. File previews use tool-provided content; host paths are never read through the Mac filesystem. Source links allow only HTTP(S), and the list retains the most recent 100 URLs. Terminal is a read-only tool-output record. These are not a live directory listing, live file watcher or interactive PTY.
- Shared stacked tool cards, confirmed todo status, running indicators and streaming cursor. Todo parsing is cached by completed result data and connection/profile/session scope, so text deltas do not repeatedly parse history. Reduce Motion disables the pulses; custom glass retains opaque accessibility and older-system material fallbacks.
- Existing-profile selection reconnects with explicit routing and restores that profile's selected session and draft. Switching waits for active work and requests to settle, and for resumed snapshots to finish restoring before loading settings; it never activates a global Hermes profile.
- Provider/model catalog, custom model IDs, supported reasoning levels, refresh and explicit host cost-confirmation handling. Changes use the host's validated session-only model command. Provider account provisioning and profile creation remain future work; unsafe standalone reasoning/fast setters are not exposed.
- Native file picker on both targets, per-composer upload state/removal, 20 MB per file, eight files/64 MB per message. Documents are uploaded inside the captured workspace; images are staged separately and queued only on Send.
- A durable send journal handles canonical image paths, lost acknowledgements, startup failure, queued ownership, voice-stop responses, idle reconciliation and stored-session ID changes. Definitively unsent text returns to the draft; ambiguous sends are locked for history review and never replayed automatically.
- Persistent text drafts and selected conversations are keyed by connection, profile and stored session. iOS flushes drafts on backgrounding and rehydrates when returning from the background.

## Historical iPhone handoff — five-tab baseline

Before the hierarchy pass, compact-width iOS used a floating workspace with Chat, Sessions, Updates, Skills and Files tabs, the overlapping mark/identity pill, round glass controls and a keyboard-aware composer. Chat uses native bubbles, grouped tool cards and the existing request flow. Sessions has date groups, search, selected/running/request states, folders from hydrated conversations and a connection card. That pass retained the older regular-width iPad split shell; the current hierarchy shell replaces it. The published [v0.1.1 universal preview](https://github.com/howhowdg/talaria/releases/tag/v0.1.1) are preserved.

Updates loads actual schedules and run history through authenticated, profile-scoped reads; summaries come from assistant output, not the run’s first user prompt. The feed includes pending requests and opens known stored sessions for review. Skills shows the host’s installed names/categories. Loads are bounded, partial failures remain visible, and seen-run state is scoped to the connection and profile. Activity refreshes on connection, foreground return and pull-to-refresh. Files retains the recorded inspector; no host paths are read through the phone’s filesystem.

Approval cards keep the backend’s allowed once/session/always/deny choices and restrictions. A draft stays editable while approval is pending, but the app cannot send or queue another prompt during a running turn. Live steering, voice, schedule creation/editing, skill management, background delivery and push notifications remain future work. Design-reference sample data and path-specific permission labels are not treated as real host capabilities.

Failed conversation opens and creation requests show a dismissible notice on Sessions and Updates, including when the list is scrolled. The iOS Release target also compiles for a generic physical device with signing disabled; this is compile verification, not an installable signed device build. Debug fixture connection hooks are absent from that binary.

## Historical iPhone verification

| Check | Result |
| --- | --- |
| Swift tests | 142 passed: 9 protocol, 21 transport, 62 core, 42 UI presentation/navigation, 8 Mac services |
| Native builds | TalariaMac and TalariaIOS Debug builds pass; iOS build targets the simulator |
| Generated contract drift | Pass: 218 RPCs, 12 server requests, 69 events |
| Real mobile reads | Pass against pinned Hermes: cron jobs/runs, latest messages in chronological order with actual assistant summaries, header authentication, `skills.manage`, `projects.list` and secondary-profile isolation |
| Existing integration | Extended isolated real-Hermes smoke also passes, including model/profile behavior and document/image delivery through synthetic inference |
| Native visual inspection | iPhone 18 Pro / iOS 27 in normal and dark appearance; smaller iPhone 17e at Accessibility Medium text size. Approval capture includes the native keyboard and an unsent sample draft |

Historical five-tab native simulator captures: [Chat](research/screenshots/talaria-ios-handoff-chat.png), [Sessions](research/screenshots/talaria-ios-handoff-sessions.png), [Updates](research/screenshots/talaria-ios-handoff-updates.png), [approval and keyboard](research/screenshots/talaria-ios-handoff-approval.png), [dark appearance](research/screenshots/talaria-ios-handoff-dark.png) and [larger text](research/screenshots/talaria-ios-handoff-larger-text.png). These render the real SwiftUI app with synthetic fixture data; they are not HTML mockups.

Simulator installation, launch and captures used `simctl`. DeviceHub/CUA timed out, so automated tapping, tab navigation and approval interaction are not claimed as verified. Functional evidence comes from the Swift tests and real-backend smoke checks; the screenshots establish rendered layout. Physical-device, older-OS and background-delivery validation remain open.

## Verified baseline — Mac v0.1.1

The checks below describe the completed Mac release and earlier iOS shell. These baseline screenshots do not verify the current hierarchy.

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

Build products are written under `/tmp` because the workspace's synced Documents directory adds metadata that can prevent ad hoc code signing. The full project and sources remain in this workspace. These earlier artifacts were local development builds; the v0.1.2 distribution above is now signed and notarized.

The initial [public source repository](https://github.com/howhowdg/talaria) uses the MIT license and includes contributor and private security-reporting instructions. A clean copy of the publication source passed all 84 Swift tests, both native platform builds, contract checks and the extended isolated real-gateway/native-runtime integration. Both apps bundle Talaria's license and the upstream third-party notice. The subsequent 0.1.1 Mac preview adds an ad hoc signed universal download; it is not notarized.

## Still open

The full scope remains in [HERMES_NATIVE_PLAN.md](HERMES_NATIVE_PLAN.md). Upcoming implementation includes richer transcript rendering, attachment previews/paste/drop, composer commands and queue controls; provider provisioning and onboarding; full profiles/settings; projects, git and terminal workspaces; browser/controller bridges; skills, plugins and MCP management; schedule creation/editing and voice; and distribution/update infrastructure.

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

## Repeat the iPhone design preview

Run these commands from the repository root. The visual fixture needs FastAPI and Uvicorn with WebSocket support, but no Hermes installation or provider credentials. In one terminal, create a dedicated environment and leave the fixture running:

```sh
python3 -m venv /tmp/talaria-preview-venv
/tmp/talaria-preview-venv/bin/python -m pip install fastapi 'uvicorn[standard]'
/tmp/talaria-preview-venv/bin/python scripts/fixtures/mobile_design_gateway.py \
  --handoff /tmp/talaria-hierarchy-design-fixture.json
```

In a second terminal, build the Debug simulator app. Boot an iPhone in Simulator, find its UDID below, and replace the placeholder before installing:

```sh
xcodebuild -project Talaria.xcodeproj -scheme TalariaIOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/talaria-ios-build CODE_SIGNING_ALLOWED=NO build
xcrun simctl list devices booted
TALARIA_PREVIEW_DEVICE='paste-the-booted-iPhone-UDID'
xcrun simctl install "$TALARIA_PREVIEW_DEVICE" \
  /tmp/talaria-ios-build/Build/Products/Debug-iphonesimulator/Talaria.app
python3 scripts/preview_ios_design.py --device "$TALARIA_PREVIEW_DEVICE" \
  --handoff /tmp/talaria-hierarchy-design-fixture.json --tab Home
```

The runner replaces Talaria’s process on that simulator. Choose `Home`, `Workspaces`, `Automations` or `Activity` with `--tab`. Use `--destination` for details and `--home` for Home states:

```sh
python3 scripts/preview_ios_design.py --device "$TALARIA_PREVIEW_DEVICE" \
  --handoff /tmp/talaria-hierarchy-design-fixture.json \
  --tab Workspaces --destination approval --keyboard
python3 scripts/preview_ios_design.py --device "$TALARIA_PREVIEW_DEVICE" \
  --handoff /tmp/talaria-hierarchy-design-fixture.json \
  --tab Automations --destination run
python3 scripts/preview_ios_design.py --device "$TALARIA_PREVIEW_DEVICE" \
  --handoff /tmp/talaria-hierarchy-design-fixture.json --tab Home --home unselected
xcrun simctl io "$TALARIA_PREVIEW_DEVICE" screenshot /tmp/talaria-iphone-preview.png
```

Preview routing is compiled only in Debug. The fixture is synthetic: no real agent, command execution, provider calls or user files. Its generated token lives in a private `0600` handoff at the explicitly selected `/tmp/talaria-hierarchy-design-fixture.json`; the runner validates that file and passes credentials through the simulator child environment, not command arguments or logs. The preview connection is not saved in Keychain. Stop the fixture with Ctrl-C, or let its 30-minute lifetime expire; it shuts down and removes its handoff. This workflow verifies presentation, while the real-gateway smoke above verifies the backend contract.

## Repeat the Mac hierarchy design preview

Start the same fixture with `--handoff /tmp/talaria-hierarchy-design-fixture.json` as above, build and run **TalariaMac Debug**, then choose **Window → Open Hierarchy Design Fixture**. This Debug command expects that exact private handoff path; a fixture started at the older default iPhone path will not be found. It loads synthetic data into an isolated preview connection and does not connect to the user's live agent.

Use **Window → Design Reference Size (1180 × 760)** and **Export 2× Design Snapshot…** for comparable native captures. Stop the fixture with Ctrl-C or let its 30-minute lifetime expire. The fixture removes its own handoff on shutdown; do not publish that credential file.

## Historical Mac handoff v2 verification

The v2 workspace used a plain `HStack` with fixed 240/290-point side columns, per the revised exact Mac specification. Custom 52-point headers and a 28-point search field avoid injected split-view toolbar and search geometry.
Native interaction checks used an isolated real Hermes gateway with synthetic inference: selected/restored a conversation, changed Sidebar → Tabs, closed and reopened a tab with its draft intact, opened a second conversation, sent a successful test turn, inspected recorded Files/Sources/Terminal states, and opened model settings from the composer. No real provider keys or paid model calls were used. Historical sessions may contain only tool summaries; the status stack presents full tasks only when the gateway actually supplied a confirmed result.

The source-level checks cover invalid timestamps, failed tab navigation, stored-ID rotation, scoped inspector/task data, bounded source retention, safe URLs, opaque host paths, task clears/revisions and streaming cache behavior. Live host filesystem/terminal features and the Mac Skills/Schedules/Kanban destinations remain future work. The later iPhone pass adds read-only activity and installed-skills views described above.

The earlier [exact Mac correction spec](Design/handoff/SWIFTUI_SPEC_MAC.md) supersedes the earlier semantic-font version. `TalariaTheme.swift` supplies the fixed light palette, point typography and explicit glass treatments. Following the latest visual feedback, Mac body text is 12.5pt; sidebar rows are 12pt; tool rows are 11pt; buttons remain 36pt tall. The 26pt composer has a white top highlight and a navy shadow at radius 15/y 10. iOS retains Dynamic Type and its existing system glass controls. Compact tool summaries contain parsed paths, commands or queries, never raw JSON; full payloads remain expandable. Pulses respect Reduce Motion and the composer retains an opaque Reduce Transparency fallback.

Debug builds include **Window → Design Reference Size (1180 × 760)** and **Export 2× Design Snapshot…** for repeatable native window captures on macOS 14.4 or later. The capture is restricted to Talaria’s own process and preserves the display color profile. Older systems explicitly label their fallback as a view render.

Previous-pass native captures: [Sidebar workspace](research/screenshots/talaria-mac-handoff-v2-sidebar.png) and [Tabs workspace](research/screenshots/talaria-mac-handoff-v2-tabs.png). These use synthetic integration-test data with an unsent draft. Both final platform builds succeeded and all 126 tests passed. The disposable UI draft was cleared, the app was quit and the isolated gateway resources were cleaned up; test credentials were not saved.

The exact-spec pass passed both platform builds and all 130 tests. Live Mac checks covered the 1180×760 window, visible connection footer, creating/sending a conversation, expanding exact tool payloads, and switching sessions with a single selected row. The 2360×1520 [2× content render](research/screenshots/talaria-mac-exact-spec-2x.png) verifies native layout dimensions; the [window capture](research/screenshots/talaria-mac-exact-spec-window.jpg) records desktop-composited materials and system window controls. The content render is produced by AppKit, not by upscaling a screenshot.

The Mac composer uses a transparent native NSTextView bridge so its 36–140pt measured height does not display an empty scroller. Live checks covered multiline growth, editor focus, native undo via its delegate-provided undo manager, and ⌘Return send. Programmatic draft replacement clears undo; session changes recreate the editor. The temporary gateway and unsent UI draft were removed after capture, and no test token was saved.

[Round-three finishing corrections](Design/handoff/SWIFTUI_FIXES_ROUND3.md) pin the Mac root to medium Dynamic Type, replace native gray divider underlays with 1pt white column edges and 6% black internal separators, make the 12pt search prompt explicit, retain white text on the disabled 40%-blue send fill, and refine recorded-preview spacing and secondary copy. The subsequent visual review reduced Mac workspace text by 1pt, removed the compounded 14pt leading lockup padding, and replaced the boxed compose glyph with the standalone pencil from the visual reference. Control frames remain unchanged. The single-selection correction remains in place.

Historical compact Mac verification: both platform builds pass; all six focused Mac navigation tests pass. The native app was relaunched and checked for the corrected lockup position, standalone pencil, smaller text, new-conversation creation, sending and stable single-row selection. Historical 2360×1520 native window captures: [compact workspace](research/screenshots/talaria-mac-compact-workspace-2x.png) and [recorded-file inspector](research/screenshots/talaria-mac-compact-files-2x.png). These replace the earlier AppKit content render for material/appearance comparisons. Synthetic test data only; the disposable gateway was stopped and its credential file removed.
