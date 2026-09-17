# Native client feasibility notes

Reviewed 2026-09-17 against Hermes commit a566d20d226a8e2ef0747639dc8a3fc1c43f9dba. These notes complement the three source audits. Findings are static source analysis; no native prototype or live application benchmark was run.

## Plugin compatibility is a product decision

The current desktop extension model exports React components and synchronous live stores, not just JSON commands. A Contribution has a render callback returning ReactNode, arbitrary data, and dynamic visibility (apps/desktop/src/contrib/types.ts:25). Plugins register panes, pages, sidebar navigation, title/status bars, command palette entries, shortcuts, themes, and composer hooks. The SDK exports core React UI components, React Query, nanostores and Streamdown as well as host methods (apps/desktop/src/sdk/index.ts:639,1542).

Runtime plugins are loaded as JavaScript ESM using blob imports and rewritten SDK/React imports (apps/desktop/src/contrib/runtime-loader.ts:114). They can be discovered from desktop-plugins and unified agent-plugin desktop directories, with reload/disposal and enable/disable inventory. The source explicitly says this is full renderer authority and error isolation, not a security sandbox (same file:17). Integrity checking is optional byte verification, not isolation.

Consequences:

- Python agent plugins, MCP tools, and skills remain backend capabilities and do not need Swift rewrites.
- Bundled Bots, Kanban and Radio can be reimplemented as native feature modules with the same backend semantics.
- Arbitrary existing React plugins cannot become SwiftUI by recompiling their source.
- A WKWebView compatibility host can run the web UI portions, but a simple web panel cannot implement the whole SDK. Synchronous host.state, callbacks, multiple contribution areas, composer middleware, exported UI components, lifecycle disposal and scoped REST/socket routing need an explicit bridge.
- Proposed Mac route: native application and bundled surfaces, with contained compatibility surfaces for existing plugins. Prototype a pane plugin, chrome contribution, composer extension and scoped backend plugin before claiming compatibility. Define a conformance matrix across every documented SDK export.
- Exact unrestricted renderer/DOM behavior cannot be promised in a native host. Either retain an explicitly identified legacy compatibility workspace for such plugins, or list and agree the incompatibilities before claiming full parity. An unsupported plugin is a parity gap, not a completed feature.
- Strictly native plugin interfaces instead require ports or a new declarative extension API. This is a valid alternative, but changes extension compatibility and has a larger ecosystem migration cost.
- iOS should initially ship reviewed native feature modules plus backend plugins. Downloaded UI code and digital purchases need a separate App Store product review; do not copy the desktop loader by default.

Primary sources: [Contribution contract](https://github.com/NousResearch/hermes-agent/blob/a566d20d226a8e2ef0747639dc8a3fc1c43f9dba/apps/desktop/src/contrib/types.ts#L25), [runtime loader](https://github.com/NousResearch/hermes-agent/blob/a566d20d226a8e2ef0747639dc8a3fc1c43f9dba/apps/desktop/src/contrib/runtime-loader.ts#L1), [SDK](https://github.com/NousResearch/hermes-agent/blob/a566d20d226a8e2ef0747639dc8a3fc1c43f9dba/apps/desktop/src/sdk/index.ts#L639), [SDK documentation](https://github.com/NousResearch/hermes-agent/blob/a566d20d226a8e2ef0747639dc8a3fc1c43f9dba/website/docs/developer-guide/desktop-plugin-sdk.md).

## A web preview is also an agent-controlled browser

The Electron preview supports page text extraction, injected read/act scripts, annotations and cropped snapshots, tours, console output, navigation, and browser state. It also uses Chromium's sendInputEvent for real pointer movement, hover, scrolling and keystrokes. The source specifically distinguishes those events from synthetic JavaScript clicks: synthetic events do not move the browser hover target and do not produce trusted input.

WKWebView supplies JavaScript evaluation, content worlds and snapshots, which map well to previews and DOM reading. That does not establish equivalent trusted input behavior. A native Mac prototype must exercise hover-only menus, trusted-event controls, drag/drop, keyboard input, cross-origin frames, redirects, and hidden/inactive panes using supported APIs. No private WebKit API should become a shipping dependency.

If parity cannot be demonstrated, the alternative is Hermes's existing external/host browser automation with explicit browser identity and visible handoff. That changes the interaction contract and must be accepted as such. Never report that an action happened in the visible preview when it happened in a different browser cookie jar. On iOS, background agent work must target host-owned surfaces; a suspended phone cannot answer live preview.read/act or terminal read requests.

The native shell also needs semantic element identifiers for agent-driven in-app tours and tips: existing DOM selectors pointing into the Electron application cannot refer to SwiftUI/AppKit controls. Translate these client-surface actions and capability advertisement rather than exposing a fake DOM. Keep this separate from window.read, whose contract identifies the native window below the app.

Primary sources: [preview input contract](https://github.com/NousResearch/hermes-agent/blob/a566d20d226a8e2ef0747639dc8a3fc1c43f9dba/apps/desktop/src/app/chat/right-rail/preview-input.ts#L1), [pointer driving](https://github.com/NousResearch/hermes-agent/blob/a566d20d226a8e2ef0747639dc8a3fc1c43f9dba/apps/desktop/src/app/chat/right-rail/preview-drive.ts#L1), [server request handlers](https://github.com/NousResearch/hermes-agent/blob/a566d20d226a8e2ef0747639dc8a3fc1c43f9dba/apps/desktop/src/app/session/hooks/use-message-stream/gateway-event/server-requests.ts), [WebKit API](https://developer.apple.com/documentation/webkit/wkwebview/).

## Native technology choices

- SwiftUI for application structure and most screens; AppKit for Mac windows/panels, responder routing, complex selection, and high-volume transcript/editor integration. UIKit equivalents remain platform adapters.
- Swift concurrency actors for gateway transport, connection/profile ownership, per-session reduction, and runtime supervision. Keep view state on the main actor.
- Generate Swift Codable wire types from the existing OpenRPC schema; retain unknown JSON fields where contracts intentionally permit extensions. The source includes 218 client RPC definitions as well as server requests and events.
- Foundation URLSession for HTTP and WebSocket, Keychain for native client credentials, AuthenticationServices for browser sign-in, AVFoundation for microphone/audio.
- Evaluate SwiftTerm for terminal emulation: its own repository provides AppKit and UIKit frontends and local process support on Mac. It is not an SSH implementation.
- Use swift-markdown as a parser candidate; rendering needs separate native blocks, selection, syntax highlighting, tables, streamed/incomplete Markdown, math and diagrams. Avoid assuming SwiftUI Text(markdown) matches the existing transcript. MarkdownUI's upstream now describes it as maintenance mode, so do not choose it unquestioningly.
- Evaluate Sparkle for direct-download Mac app updates. Keep Python runtime updates and native app updates separate.
- Use WKWebView only for actual web content, generated HTML, and explicitly chosen compatibility content. Native chat, navigation and settings should not depend on a React application.

Primary sources: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), [Swift Markdown](https://github.com/swiftlang/swift-markdown), [MarkdownUI status](https://github.com/gonzalezreal/swift-markdown-ui), [Sparkle](https://sparkle-project.org/documentation/), [AuthenticationServices](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession). Dependency versions and platform minimums are to be pinned and verified during the feasibility milestone.

## Distribution and mobile execution

Recommend Developer ID-signed, notarized direct distribution for the full Mac product. Apple requires sandboxing for Mac App Store distribution, while direct distribution requires hardened runtime and allows optional sandboxing. Hermes's local installer, shell tooling, arbitrary host files and dynamically installed plugins make direct distribution the closer fit. An App Store Mac client is a separate remote-oriented product scope, not the same packaging checkbox. See [Apple distribution requirements](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution) and [notarization](https://developer.apple.com/documentation/Security/notarizing-macos-software-before-distribution).

Recommend iOS as a native controller for a Mac or remote Hermes host. Apple's background APIs permit bounded or scheduled work, and newer continued-processing APIs support specific user-started work; none should be the basis for an always-running generic agent host. The host must own long-running turns, queues, schedules and group relays. Use background URLSession for transfers and APNs for wake-up hints, with foreground reconciliation as the source of truth. See [background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app) and [continued processing](https://developer.apple.com/documentation/BackgroundTasks/performing-long-running-tasks-on-ios-and-ipados).

Apple's rules for downloaded executable functionality and purchases mean desktop extension installation and billing flows need deliberate iOS treatment. Do not assume either a blanket ban on every web plugin or blanket permission to reuse the desktop system. Review the actual proposed product and storefronts against [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), especially 2.5.2, 3.1 and 4.7.

## Source baseline

The local source inventory is in source-baseline.json. It counts source and test files together, not production size or migration effort. There are 2,184 JS/TS source/test files under desktop/src, 384 under desktop/electron, and 70 desktop e2e files at the pinned commit. The scale is evidence that a chat prototype is a small first milestone, not full desktop parity.

The root and bundled Bots licenses inspected are MIT. Preserve required notices and audit third-party dependencies/assets separately; do not infer rights to names, marks or every dependency from the root license.
