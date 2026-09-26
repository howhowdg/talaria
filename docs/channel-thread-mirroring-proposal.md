# Channel thread mirroring proposal

Status: approved and implemented in the working tree September 26, 2026. Not published or installed as a release.

Validation: 233 Swift tests pass; unsigned Mac and iOS app builds pass; three contract tests pass against the real Hermes ASGI app using disposable profiles. Independent review findings CM-01 through CM-06 were fixed and the final delta review was clean. External channel delivery and physical-device networking were not exercised. The proposal below records the approved scope.

## Finding

Talaria does not offer the desktop app's automatic, source-grouped channel browser with continuously refreshed transcripts. However, it already retrieves channel-origin sessions through an unfiltered `session.list` request. Those can appear under Other conversations. It also has an optional Telegram topic importer that assigns selected topics to Home or Workspaces.

The practical gaps are discoverability, complete listing, and keeping open transcripts current—not an absence of all channel history support. The current list is capped at 100, retains source without displaying platform groups, and can reopen a cached transcript without fetching new external messages. The Telegram importer excludes ordinary DMs and does not periodically synchronize.

Here, “mirroring” means displaying conversations already recorded by the connected Hermes installation. It does not mean importing an entire Telegram, Slack, or Discord account's history.

## Desktop behavior to reproduce

| Capability | Hermes desktop source | Proposed Talaria behavior |
|---|---|---|
| Automatic channel discovery | Separate messaging session query; groups by source | Discover recorded channel sessions on connection without an import step |
| Platform sections | Telegram, Discord, Slack, API and other recognized sources | Collapsible platform sections with icons; only populated sections appear |
| Useful ordering | Groups and rows ordered by activity | Store backend activity time; do not label creation time as last activity |
| Long histories | Separate platform paging and message history reads | Load more per platform and older messages within a thread |
| Live refresh | Change events plus visible polling/backstops | Refresh lists and the visible external transcript, including incoming user turns |
| Organization | Pinned rows, collapsed sections, platform-aware search, owner groups | Pin, search, collapse and archive using explicit local preferences; retain source badges |
| Connection/profile ownership | Rows retain their connection and profile | Scope every request, cache, preference and selection to its actual owner |
| Continue a conversation | Resume and prompt operations are distinct from REST history reads | Treat viewing and writing as separate actions; verify channel delivery semantics before enabling replies |

The desktop source recognizes more than Telegram: Discord, Slack, Mattermost, Matrix, Signal, WhatsApp, iMessage adapters, email, SMS, webhook, API, Home Assistant and several other adapters. Talaria should use a small source-label/icon table with a readable fallback, not implement each platform's API. Classify Talaria's own `native` source as local explicitly.

## Design

Preserve Talaria's Home, Activity, Workspaces and Automations. Add populated platform sections alongside Other conversations on Mac and the corresponding conversation navigation on iPhone. Use concise labels such as “Telegram” and “API”; no explanatory text beneath each section.

Rows show the conversation title, activity time and unread state. Keep conversation titles separate from Telegram topic names. A pinned conversation appears in Pinned with its platform icon. An explicitly assigned Home/Workspace conversation remains there; channel browsing references the same canonical record and never creates a duplicate transcript. Keep assigned threads discoverable in their platform section as references to that same record; exclude pinned rows from platform lists and counts, matching desktop behavior.

Search should match titles and platform names immediately. Add server transcript search where supported. Retain local archive choices; do not imply that archiving in Talaria deletes a Telegram thread. Native continuation or external delivery must use an unambiguous action label once its behavior is verified.

## Implementation

### 1. Channel discovery and navigation

Extend the existing authenticated `GatewayReader` with the Hermes REST session-list route. The desktop uses `/api/profiles/sessions` with explicit profile, source, recent ordering and bounded list windows, but that aggregate route caps each profile at 500 rows. For Talaria's selected-profile browser, use `/api/sessions?profile=<selected>&source=<platform>&order=recent` with `limit` at most 100 and real `offset` paging, including beyond row 500. Do not accidentally inherit the desktop's all-profile default. Reuse existing token handling, proxy-prefix handling and response limits.

Fetch a messaging slice independently of local recents so 100 recent local conversations cannot hide an older Telegram thread. Load additional rows by platform with server-reported totals/truncation. The desktop's batched `/api/profiles/sessions/sidebar` is an optional optimization, not a prerequisite.

Extend `SessionSummary` only with fields needed for activity, ownership, paging and handoff provenance. Keep canonical rows keyed by connection, profile and stored session ID. Merge refreshed listings with explicit topic bindings and selected/pinned records; do not let a list replacement discard imported sessions outside the initial window.

For an older host without these REST routes, preserve existing `session.list` access and identify its limited results. Do not silently claim complete channel discovery. The pinned WebSocket `SessionListParams` does not accept source or offset; adding invented parameters is not a solution.

### 2. Passive transcript mirroring

Use the existing session-message reader and renderer for channel viewing, extending them for older-history paging. A channel row should be viewable without creating an agent or sending a prompt. Reopening a cached thread must refresh authoritative history.

On `sessions.changed`, coalesce list refreshes and refresh the selected external transcript. Read the host's `change_events` capability. Match desktop's visible fallback cadence initially: 10 seconds for channel lists and 5 seconds for the active transcript on older hosts; a 30-second active-transcript backstop when change events are available. Refresh on reconnect and foreground entry; stop timers on disconnect or app backgrounding.

Merge persisted messages by stable IDs and preserve live output, draft text, scroll position and loaded older pages. Replace the current `history-<index>` fallback for paged history with authoritative row identity; indices reused across pages will collide. Test incoming user messages as well as assistant output. A stale request from another profile, connection or selected thread must never overwrite current state. Keep existing generation guards and cancellation rather than introduce a second synchronization framework.

For Telegram topic resets, reuse the existing explicit chat/thread/routing identity and current-session pointer. Keep old history accessible; do not infer replacement threads from titles or recency. Missing bindings retain saved history and disable writing until resolved.

### 3. Desktop interaction parity

Add platform-aware search, pinning, collapse persistence, unread markers, title changes and deliberate archive behavior. Reuse existing hierarchy storage where suitable, but keep channel provenance independent of Home/Workspace membership. Make unsupported actions unavailable on older hosts.

The inspected desktop opens ordinary stored sessions with both REST history and `session.resume`; passive viewing is a deliberate Talaria design choice, not a claim that desktop never resumes. Its ordinary `prompt.submit` runs the resumed agent and streams results to the client; it does not automatically deliver a Telegram reply. Reuse that continuation path behind “Continue in Talaria”, preserving source provenance and refreshing history before sending. Hermes also exposes `handoff.request`, which targets the platform's configured home channel: reproduce it where supported, show that destination, track queued/completed/failed state, and verify routing in a test channel. Do not equate handoff to an exact reply to the originating Telegram topic. Preserve busy-session handling, approvals, attachment behavior and session ownership.

Broad multi-connection aggregation can follow the selected-profile implementation, using the same owner keys. It should not delay channel visibility for the connected host.

## Delivery plan

Use three reviewable changes: (1) discovery, models and navigation; (2) passive history and synchronization; (3) organization and continuation/delivery parity. A sidebar-only change is not completion of this proposal. The first two together deliver automatic channel mirroring; the third completes the channel-related desktop interactions supported by the host.

Likely touchpoints: `Sources/HermesTransport/GatewayReader.swift`, `Sources/HermesCore/Conversation.swift`, `Sources/HermesCore/HermesAppModel.swift`, hierarchy preferences, Mac/iOS conversation navigation and focused existing test targets. No new third-party dependency or universal channel host extension is expected. Retain the current optional Telegram extension for topic-routing metadata and labels.

## Acceptance checks

1. Recorded Telegram DMs, group topics and API sessions appear automatically, without topic import; local/native and cron sessions retain their intended sections.
2. More than 500 sessions in one platform, more than 100 mixed sessions, uneven platform sizes and pinned/assigned rows do not hide older channel conversations or produce endless Load more controls.
3. An incoming Telegram user message and Hermes reply appear in an already-open Talaria transcript without reopening it; cached selection, reconnect and foreground recovery behave the same way.
4. Live output plus later persisted history produces one copy of each message and retains older loaded pages, draft text and scroll position.
5. Two profiles or connections with identical session IDs stay isolated, including delayed responses and reconnects. Authentication failures never become empty-success results or route fallbacks. Offline, missing-session and failed-refresh states preserve last valid content with an explicit stale/error state; unknown sources and reverse-proxy prefixes remain usable.
6. Topic reset/compression follows verified routing or lineage metadata, preserves previous history and custom workspace names, and never sends to an inferred destination.
7. Viewing, searching, pinning and expanding a channel never submits a prompt, takes over a running conversation or sends a platform message.
8. Continuation tests establish the actual destination, busy-session behavior and attachment/approval handling before enabling those controls. Test delivery only in a designated test channel.
9. Mac and iPhone support accessible navigation, stable selection, background suspension and graceful unsupported-host behavior.

Use synthetic transport fixtures for deterministic checks, then a designated Hermes test profile for end-to-end verification. The implemented behavior is covered by channel parser/model/transport tests and `scripts/tests/test_channel_mirroring_contract.py`; validation results are recorded above.

## Evidence and limits

Reviewed Talaria commit `874d5bfdf77762939873bf5f3a2c3343c97c8324` and local Hermes source commit `cda237464a51739e55ab13946a00272e548443e5`. Talaria's pinned contract is older (`a566d20d226a8e2ef0747639dc8a3fc1c43f9dba`), so runtime capability checks matter. This is source verification, not a live assertion about the connected server's version, stored conversations or delivery behavior.

- Talaria: `HermesAppModel.swift:292` (list), `:322` (resume/cache), `:758` (list event refresh), `:827` (Telegram discovery); `Conversation.swift:20` (summary); `GatewayReader.swift:72` (history route); `docs/telegram-topics.md:39` (import limits).
- Hermes desktop: `apps/desktop/src/lib/session-source.ts:54` (source classification); `app/session/hooks/use-session-list-actions.ts:48` (separate lists); `api/sessions.ts:135` (filtered listing), `:300` (optional batch); `app/chat/sidebar/index.tsx:1333` (platform grouping); `app/contrib/hooks/use-background-sync.ts:547` and `:1241` (refresh cadence).
- Hermes continuation: `apps/desktop/src/app/session/hooks/use-session-actions/index.ts:1875` (resume alongside history); `tui_gateway/methods_prompt.py:685` → `prompt_turn.py:739` (agent turn); `tui_gateway/methods_session.py:1220` (separate channel handoff).
- Hermes REST pagination: `hermes_cli/web_routers/profiles.py:439` (aggregate 500-row ceiling); `hermes_cli/web_routers/sessions.py:173` (profile-scoped offset paging). The latter GET also invokes existing host auto-archive maintenance; passive browsing adds no Talaria archive action but cannot promise the host itself performs zero writes.
- The screenshot corroborates platform sections. It does not establish reply delivery or transcript synchronization behavior by itself.
