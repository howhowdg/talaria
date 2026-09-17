# Hermes gateway contract audit for native macOS and iOS

Audit baseline: upstream commit `a566d20d226a8e2ef0747639dc8a3fc1c43f9dba` (read-only checkout under `upstream/hermes-agent`). This is a source audit, not a live service or end-to-end runtime test. Paths and line numbers below are relative to that checkout.

## Architecture conclusion

Keep the Python Hermes agent, session database, configuration, plugins, tools and `hermes serve` backend. Replace Electron's client, process management and OS adapters with Swift. The native application should be another client of the existing JSON-RPC/WebSocket and HTTP surfaces. An iOS application should reuse the Swift protocol/domain layer and connect to a running Hermes backend; it should not rely on a local Python subprocess.

The backend is considerably more ready than a superficial Electron migration suggests: the current contract declares **218 client-to-server RPCs, 12 server-to-client request methods and 69 backend event types**. Session resume, bounded event replay, request replay, multiple simultaneous clients, native OAuth brokerage, attachments uploaded as bytes, paged history and remote files/Git already exist. Do not schedule their wholesale reinvention.

## Authoritative contracts and transport

- `tui_gateway/contracts/base.py:1–19`: Pydantic models are the wire authority. `scripts/gen_gateway_contracts.py` generates `apps/shared/src/gateway-contract.generated.ts` and `gateway-contract.openrpc.json`; `tests/tui_gateway/contracts/test_generated.py` checks drift.
- `tui_gateway/contracts/base.py:32–48`: request parameters reject unknown keys; optional vs explicit null matters. Swift generation must preserve null/absent semantics, `snake_case`, open JSON dictionaries, and unknown enum values for future server compatibility. Do not synthesize extra request fields against older backends.
- `tui_gateway/rpc_dispatch.py:17–42`: unknown methods return `-32601`; invalid params `4000`; profile unavailable `4064`. Slow methods run in a worker pool, allowing interrupts and answers to be serviced (`:45–87`). A retiring backend returns `5035`.
- `hermes_cli/web_routers/chat_ws.py:573–586`: `/api/ws` mounts the JSON-RPC gateway and passes server-authenticated identity. The protocol is JSON-RPC 2.0, with `method: "event"` notifications; it is **bidirectional**, not only request/response plus streaming.
- `tui_gateway/ws.py:287–303`: first notification is `gateway.ready` with skin, change-event support, heartbeat support and replay epoch. `:350–354` handles transport heartbeat `gateway.ping`; this is distinct from the declared `ping` RPC.
- `apps/shared/src/json-rpc-gateway.ts:107–136`: socket generation, per-session watermarks, replay hold queue and epoch are explicit pieces of state. Port these behavioral invariants into a Swift actor, not the TypeScript implementation verbatim.
- `apps/shared/src/json-rpc-channel.ts:430–475`: server requests are recognized before RPC responses; `open_requests` from resume/replay responses are delivered before the original caller sees the result; capabilities are advertised on ready.
- `tui_gateway/contracts/liveness.py:21–43`: current capability negotiation is narrow: `gateway.capabilities` returns only `per_session_exclusive_submit`; `client.capabilities` accepts only `server_requests: bool` and returns possible server request methods. A richer platform capability protocol would be an extension.

Recommended Swift seams: `GatewayConnection` actor (socket, auth generation, requests, heartbeat, replay); generated `HermesProtocol` models; a REST client scoped by connection/profile; domain repositories whose state keys include connection and profile; reducers for transcript, run status, approvals and session lists; macOS-only local-runtime/SSH adapters.

## Existing session and turn lifecycle

1. Connect to `/api/ws`, await `gateway.ready`, advertise `client.capabilities {server_requests: true}`. Hydrate status/profile/model/history lists via the existing scoped REST/RPC calls.
2. `session.create` returns a runtime `session_id`, durable `stored_session_id`, messages and info. New sessions support source, profile, working directory, parent, title, model/provider/reasoning/fast settings and `close_on_disconnect` (default false). A stored row is written on first prompt unless seeded (`tui_gateway/contracts/sessions.py:118–144`).
3. Upload/attach media before submission. `image.attach` uses a gateway-visible host path; `image.attach_bytes` and `pdf.attach` accept bytes for remote clients (`tui_gateway/contracts/prompt_voice.py:107–155`). `file.attach`, image detach, paste collapse and input-drop detection are also declared; a device file path must not be mistaken for a backend path.
4. `prompt.submit` starts or queues/steers/redirects a turn. Its ACK is not completion. Parameters include hidden display, queued intent, barge-in context and explicit rewind consent using durable row IDs. Result status is `streaming|queued|steered|redirected` (`tui_gateway/contracts/prompt_voice.py:26–72`). No general client operation/idempotency key is declared.
5. Render `message.start`, `message.delta`, `message.interim`, `message.complete`, reasoning/thinking, tool progress, subagent, todo, session-control, voice and other events. The generated event map is at `apps/shared/src/gateway-contract.generated.ts:4888–5026`.
6. The server can issue `approval`, `clarify`, `sudo`, `secret`, vault prompts, `tour`, `terminal.read`, `preview.read`, `preview.act`, and `window.read` requests. Respond using the same JSON-RPC ID. Unknown requests need `-32601`, handler failures `-32603`; silently dropping them leaves the agent waiting. `request.cancel` withdraws a card (`tui_gateway/server_requests.py:1–28`, generated map `:4845–4869`). There is a `request.answer` RPC too, but current native design should implement genuine peer response frames.
7. `session.interrupt` is the existing stop operation. It cancels the running agent/compute host, clears queued prompts and pending requests and denies outstanding approval waits (`tui_gateway/session_lifecycle.py:590–633`). UI Task cancellation alone is not server cancellation.
8. `session.resume` takes a **stored** ID or exact title and returns a potentially different live/runtime ID. `session.activate` attaches to an existing live session without closing the previously focused session (`tui_gateway/contracts/sessions.py:150–180`). The snapshot contains messages, runtime/stored identity, running/rehydrating status, partial assistant and user turn, queued prompt, approvals/open requests, pending connector operation, todos and crash auto-continue metadata (`:29–98`).
9. `session.close` tears down a live runtime but leaves the durable row resumable; it is not a navigation command (`:328–340`). `session.branch`, undo, compress, save/export, hide, title, delete, cwd and workspace move are existing RPCs.

The desktop's submission timeout is deliberately 1,800 seconds because ACK latency is not equivalent to a completed turn (`apps/desktop/src/api/client.ts:18–26`). A native client should use method-specific deadlines and retain an explicit ambiguous-submission state when a network failure occurs after send.

## Replay, persistence and multiple devices: actual state

### Already implemented

- `tui_gateway/event_replay.py:1–36`: per-session monotonically sequenced event rings, process epoch, maximum 512 events and 4 MiB per session, 64 sessions and 64 MiB total. These are bounded, **in-memory** stores.
- `tui_gateway/methods_session.py:2211–2225`: `session.events.since {session_id,last_seen}` returns events, latest sequence, truncation flag, epoch and open requests.
- `apps/shared/src/json-rpc-gateway.ts:446–563`: reconnect replay holds incoming live frames until the missing interval has been dispatched, then sequence-deduplicates; a server restart invalidates old sequence watermarks. Swift must reproduce the ordering contract.
- `tui_gateway/server_requests.py:15–22, 42–75, 276–280`: unresolved request snapshots are replayed separately, including batch-clarify answers already locked. Requests themselves are held in a process-local dictionary, not durable storage.
- `tui_gateway/session_transports.py:62–94`: live session attachment is additive and uses `FanoutTransport`. A second client does not have to steal the first client's socket.
- `tui_gateway/session_lifecycle.py:821–878`: one client's disconnect does not detach/reap a session that still has another live client. Reattach cancels the pending orphan timer (`:700–704`).
- `hermes_cli/web_routers/sessions.py:165–222`: stored session lists have limit/offset and filtering, with compression-lineage-aware recency. Search uses session IDs and FTS5 message content (`:255` onward).
- `hermes_cli/web_routers/sessions.py:531–567`: messages are paged, defaulting to latest 500, with profile stamp and compacted-history option. `:585–625` provides a timeline with stable logical cursor and bounded `messages/around` to jump to a durable row. Do not invent history pagination as if absent.
- `tui_gateway/contracts/common.py:128–143`: projected RPC transcript rows use `text` rather than raw `content`, durable `row_id`, display metadata and reasoning/tool fields. REST messages and RPC projections must have deliberate adapters.

### Limits the native plan must address

- A long suspension cannot be reconstructed from the small event ring alone. Swift must use `truncated` and epoch changes to force authoritative snapshot/history reconciliation. The shared TS replay loop shown at `json-rpc-gateway.ts:478–505` reads events/epoch but does not itself act on `truncated`; higher-level hydration must be tested rather than assuming replay alone is lossless.
- After the **last** client disconnects, default grace is 20 seconds; active turns keep running while their activity clock is fresh (default stale threshold 600 seconds), while idle detached runtimes are reaped. Missing/unreadable activity is treated as not fresh. This is an intentional leak-prevention policy, not an unconditional detached-run guarantee (`tui_gateway/server.py:118–144`; `session_lifecycle.py:707–731,734–806`).
- A pending approval/question has an existing deadline and process-memory lifetime. `send()` supports bounded or unbounded wait; timeout sends `request.cancel` (`server_requests.py:143–179`). Mobile “approve hours later” requires an explicit new durable contract and product policy, not just a notification UI.
- Native offline draft persistence is client work. Automatically retrying prompt/approval/config mutations across ambiguous failures is unsafe without idempotency/settlement: `PromptSubmitParams` has no operation key; `rpc_dispatch.py` routes repeated IDs again, and Electron intentionally never replays arbitrary submitted REST mutations (`electron/oauth-rest-request.ts:28–43`). Exclusive session admission prevents racing active turns but is not exactly-once submission.
- Existing sessions can have multiple authenticated viewers, but this must not be advertised as tenant isolation: `_warn_foreign_login` explicitly logs rather than rejects a different authenticated user (`session_transports.py:50–59`). If a cloud deployment is meant to host unrelated users, audit and enforce owner authorization at all session, replay, file and request boundaries before making that product promise. Same-user Mac+iPhone on one trusted personal backend is a different case.
- No APNs provider/device-token registration surface was found in `apps`, `tui_gateway`, `hermes_cli`, or `gateway`. Existing `notification.show/clear` are in-app event types. Background completion/approval push requires new opt-in device registration, backend notification routing, revocation and deep-link rehydration; push should carry identifiers/minimal information, with authoritative state fetched on foreground.

## Background queue, relay and device-bound action ownership

The renderer owns important execution loops that a Swift port must account for:

- `apps/desktop/src/store/composer-queue.ts:29–73` stores pending composer entries in browser localStorage and keeps queue parking in memory. `app/session/hooks/use-background-queue-drain.ts:32–38,86–192` drains queues for offscreen sessions via renderer hooks. This is background relative to a selected chat, not an OS-background service. A phone suspended after queueing cannot keep this hook executing. If queued prompts must continue without a foreground client, add a scoped durable backend queue with enqueue/reorder/remove/pause/resume/status operations and attachment ownership, tied to submission idempotency; otherwise clearly persist drafts locally and resume on foreground. Existing `prompt.submit queued` and backend busy queues do not imply that the whole editable composer queue already lives on the server.
- `apps/desktop/src/plugins/hermes-bots/relay.ts:1–28` explicitly makes Desktop the cross-connection router. It pushes union rosters and drains outboxes, delivers turns on target sockets and posts replies to source gateways. Timers, in-flight state and retained sockets are renderer-owned (`:71–107`). A suspended iPhone cannot be the sole reliable router. For unattended cross-gateway bots, migrate that routing into a selected always-on host/service with delivery IDs, retries, settlement, revocation and one active relay owner. Existing `bot_relay.*` RPCs are useful endpoints, not proof that delivery is host-independent.
- **Hosted rooms are already more durable:** `tui_gateway/methods_groups.py:216–239,361–395,430–455,488–519` supplies capability probing, idempotent hosted creation, room state/replay cursor/fenced authority, user event IDs, durable stop, event log, replica ingestion and promote/demote. Reuse the existing hosted-room service and peer protocol for mobile rooms where appropriate; audit the renderer's chosen path before adding another room orchestrator.
- Generic server-to-client UI reads/actions route through the session transport, including fanout (`tui_gateway/server.py:611–628`, `transport.py:239–260`). A response settles the request by request ID, first response wins (`server_requests.py:201–236`). That can make sense for a shared approval, but a `window.read` or `preview.act` needs an explicitly selected device/window owner. Add target client/surface identity and claim/lease semantics for device-bound operations; observers receive status, not permission to execute the same action twice. Keep this separate from the existing `browser.controller.*` broker, which already tracks exact transport owners (`gateway/browser_control_broker.py:240–324,477–481`).

## HTTP and specialized channel families

These are part of full parity even though they are outside the OpenRPC file.

| Family | Current coverage / source |
|---|---|
| Status, health, setup | `/api/status`, `/api/health`, idle/retirement, system stats, curator/learning, diagnostics; `web_routers/status.py:103–732` |
| Profiles and global sidebar | Profile CRUD/config, souls, models, import/export; aggregate sessions/sidebar/projects across profile DBs; `web_routers/profiles.py:380–627,664–1000` |
| Session database | Lists, full text search, archive/rename/import/export/delete, paged transcript/timeline; `web_routers/sessions.py` |
| Models/provider authentication | Current/recommended/auxiliary/MoA models and switch; OAuth/device flows start/submit/poll/cancel; custom endpoints and key/env setup; `web_routers/models.py:53–272`, `oauth.py:572–728`, `config_env.py:529–743` |
| Skills, toolsets, MCP, plugins | Skill listing/content/toggle/edit, toolset config/provider/keys, terminal backend selection, computer-use status/permissions, MCP catalog/config/OAuth/install, plugin hubs/install/enable/update; `web_routers/skills.py:343–427`, `tools.py:218–680`, `mcp.py:94–443`, `dashboard_ui.py:126–310` |
| Cron and messaging | Job CRUD/runs/pause/resume/trigger/blueprints; Telegram/WhatsApp onboarding, platform config/test; gateway process lifecycle; `web_routers/cron.py:211–392`, `messaging.py:549–916`, `ops.py:251–264`, `actions.py:138–164` |
| Files/media | `/api/files` managed browsing, read/download/stream, upload and upload-stream, mkdir/delete; `/api/fs` list/read/write/data-url/download/git-root/default-cwd; media and image upload; `web_routers/files.py:243–746` |
| Git/review/worktrees | Status, branch/base/worktree lists, review list/diff/file diff/context/ref/ship info/PRs; stage/unstage/revert/commit/push/create PR/worktree add-remove/branch switch; `web_routers/git.py:48–208` |
| Voice | Upload transcription, provider-direct voice config, live-voice status/session, voices, TTS, direct TTS lease and `/api/audio/speak-stream`; `web_routers/audio.py:77–373` |
| Local model runtime | Hardware/catalog/status, runtime install, download/sideload, quickstart/server/eject/activate and job progress; `web_routers/local_models.py:461–924` |
| Ops/memory/credentials | Credential pools, memory configuration, doctor/security audit, backup download/import upload, hooks/checkpoints; `web_routers/ops.py:303–761`, `memory_providers.py:516–553` |
| Curated console and Ink PTY | `/api/console` JSON console engine; `/api/pty` spawns Hermes TUI and supports attach-token lifetime/replay; `/api/pub` and `/api/events` sidecar broadcast; `web_routers/chat_ws.py:271,432–564,607–619` |

**Terminal caveat:** `/api/pty` is a Hermes Ink terminal/TUI channel, not the general desktop shell terminal API. Electron's terminal IPC spawns local `node-pty` or `ssh -tt` (`apps/desktop/electron/terminal-ipc.ts:302–358`); `electron/ssh-connection.ts:298–303` explicitly calls this an interim path until `/api/terminal` lands. Native macOS can implement its local and SSH terminal adapters with a native terminal renderer. iOS needs an authenticated remote shell service or an explicitly scoped SSH implementation if full interactive shell access is included. Do not relabel `/api/pty` as that missing service.

Voice has two established routes: provider direct (credentials obtained from gateway, kept only in client memory) and relay fallback for host-only providers (`apps/desktop/src/lib/voice-client-direct.ts:4–19,53–105`). Swift audio capture/playback is new client work; provider selection and voice settings remain backend-owned. Mobile can initially prefer gateway relay to limit the number of device-side provider integrations, but that is an explicit latency/parity tradeoff.

## Connection, profile and authentication semantics

- REST and RPC state are scoped to `(connectionId, profile)`; sessions then have durable and live IDs under that scope. A bare profile name is not globally unique. `apps/desktop/src/api/client.ts:46–52,82–103,137–193` explains several existing routing failures that the Swift architecture must make unrepresentable.
- Backend profile resolution must bind config, secret and terminal scopes together. The launch backend home is itself the default profile, not automatically `~/.hermes` (`tui_gateway/AGENTS.md`, profile-scope section). Files/Git operations act on the selected backend's filesystem; native local dialogs produce device-side paths that need upload or host-local routing.
- `source: "desktop"` currently enables `desktop_ui` and `project` toolsets, regardless of where the server runs (`tui_gateway/server.py:1776–1780,1829–1863`). For macOS parity, implement those read/act bridges before advertising the surface. For iOS, define a supported client capability set and source mapping; blindly calling it desktop promises window/terminal/browser abilities the phone may not supply.
- Existing native auth is gateway-brokered OAuth/PKCE: `/auth/native/authorize`, exchange at `/auth/native/token`, rotate at `/auth/native/refresh`; session identity `/api/auth/me`; `hermes_cli/dashboard_auth/native_flow.py:1–12` and `routes.py:449–519`.
- **Actual iOS blocker:** the authorize route validates redirects as HTTP loopback IP only (`routes.py:218–229`). macOS can reuse the loopback flow; the planned mobile auth flow needs securely registered/allowlisted app callbacks (universal link/custom scheme as appropriate), retaining state, issuer and PKCE validation. This is a backend addition, not solved merely by choosing `ASWebAuthenticationSession`.
- `/api/auth/ws-ticket` issues one-use 30-second tickets bound to authenticated identity (`routes.py:458–466`, `ws_tickets.py:1–59`). Mint a new ticket for every socket dial. `apps/shared/src/websocket-url.ts:39–79` forbids OAuth fallback to a stale URL.
- Native bearer credentials, refresh and network failures are separate states; only confirmed rejection should trigger sign-in. Refresh failures can be 401 expired versus 503 unreachable (`routes.py:496–519`). On macOS store tokens in Keychain; retain origin/profile/connection routing and singleflight refresh. Gateway sign-in, model-provider sign-in and MCP-server sign-in are three different workflows and all need parity.

## Prioritized backend additions vs Swift implementation

| Work | Classification | Why / acceptance |
|---|---|---|
| Generate Swift models/client from current OpenRPC + captured REST schemas | Native foundation | Keep Python canonical; verify emitted Swift decodes actual fixture frames and detects generated drift. Add REST schema coverage where handlers' untyped dict results make FastAPI schema insufficient. |
| WebSocket requests/events/server requests, heartbeat, replay and snapshot recovery | Port existing behavior | Pass same replay race, restart, stale response, cancellation and profile isolation scenarios as desktop. |
| Native session/client capability matrix | Small backend extension + clients | Declare client-supported surfaces and per-method requests; never gate platform features by backend environment. Preserve existing desktop clients. |
| iOS callback registration/validation | Required for mobile browser auth design | Reuse PKCE broker, narrowly allow registered redirects, reject arbitrary redirect targets, test replay/state mismatch and cancellation. |
| Durable composer queue and cross-gateway routing | Backend/service extension when unattended execution is promised | Move the editable queue/drain and sole renderer relay into an always-on authority; reuse hosted rooms and bot-relay endpoints. |
| Targeted device read/act ownership | Backend extension + client registration | Pin device/window/surface, claim once, reject unsupported clients; do not broadcast executable UI requests to Mac and iPhone simultaneously. |
| Submission idempotency/settlement | Backend extension before automatic mobile retries | Client operation UUID, durable dedup/result state scoped to user/connection/profile/session, reconciliation for “sent but ACK lost.” Preserve old clients. |
| Foreground/background retention policy and pending actions | Backend extension if long background continuity is promised | Existing fresh-work retention is useful; explicitly specify leases, deadlines, durable pending actions and restart behavior, without disabling leak protection globally. |
| APNs notification delivery/device lifecycle | New service feature for mobile background notifications | Register/revoke devices, deduplicate terminal/action events, respect per-device preference, refresh authority on tap. |
| Remote general shell terminal | New or separately implemented host service | Existing Ink PTY does not satisfy this. Authenticate, bind scope, resize/stream/backpressure/reattach/timeout/close; mobile must be remote. |
| REST file upload/download, media, Git and paged history | Already available | Implement native UI/client adapters; validate remote filesystem mapping and backend capability differences. |
| Mac-to-phone state handoff | Primarily client work, some backend policy | Existing stored IDs, resume and fanout handle conversations; client-only drafts/layout/sidebar preferences need deliberate sync policy if required. Do not duplicate the transcript database into a competing authority. |
| Unrelated-user tenancy | Deployment security project, conditional | Current trusted-gateway fanout is not owner enforcement; scope claims must match deployment. |

## Validation scenarios to borrow or add

The repository already has targeted contracts rather than only UI mocks: `tests/tui_gateway/test_tui_gateway_event_replay.py`, `test_multi_client_fanout.py`, `test_ws_orphan_races.py`, `test_isolated_orphan_activity.py`, `test_session_resume_db_ownership.py`, `test_resume_live_profile_scope.py`, `tests/hermes_cli/test_dashboard_auth_native_flow.py`, `test_dashboard_auth_ws_tickets.py`, and `apps/shared/src/json-rpc-gateway-replay.test.ts`.

A shared Swift test harness should run against a temporary real `HERMES_HOME`, with two profiles and two connection endpoints. Test Mac+iPhone attachment to one run; disconnect one client; reconnect past the replay limit and after server restart; lose submit ACK; request an approval while phone is suspended; answer on Mac then foreground phone; switch account/profile while refresh/upload is pending; stream files large enough to trigger backpressure; resume a compressed lineage; and stop while a tool/subagent waits. Validate final visible transcript and backend side effects, not just that a socket reopened.

## RPC inventory by namespace

The following list is extracted directly from the pinned OpenRPC file. It is larger than the UI implementation list: some methods support CLI/TUI or compatibility pathways, so parity requires matching desktop usage, not exposing every method as a new screen.

- **agents**: `agents.list`.

- **approval**: `approval.pending`, `approval.received`, `approval.respond`.

- **billing**: `billing.auto_reload`, `billing.charge`, `billing.charge_status`, `billing.state`, `billing.step_up`.

- **bot_relay**: `bot_relay.deliver`, `bot_relay.outbox.drain`, `bot_relay.reply`, `bot_relay.roster.sync`.

- **browser**: `browser.controller.detach`, `browser.controller.heartbeat`, `browser.controller.register`, `browser.controller.result`, `browser.manage`.

- **clarify**: `clarify.lock`.

- **cli**: `cli.exec`.

- **client**: `client.capabilities`.

- **clipboard**: `clipboard.paste`.

- **command**: `command.dispatch`, `command.resolve`.

- **commands**: `commands.catalog`.

- **complete**: `complete.path`, `complete.slash`.

- **config**: `config.get`, `config.set`, `config.show`.

- **connection**: `connection.respond`.

- **connectors**: `connectors.connect`, `connectors.list`, `connectors.operation.status`.

- **cron**: `cron.manage`.

- **delegation**: `delegation.pause`, `delegation.status`.

- **diagnostics**: `diagnostics.share_nous`.

- **file**: `file.attach`.

- **free_tier**: `free_tier.ack_notice`, `free_tier.provision`, `free_tier.status`.

- **gateway**: `gateway.capabilities`.

- **groups**: `groups.approve`, `groups.capabilities`, `groups.create`, `groups.demote`, `groups.disband`, `groups.list`, `groups.log`, `groups.peer.invite`, `groups.peer.register`, `groups.peer.revoke`, `groups.promote`, `groups.rename`, `groups.replica_state`, `groups.replicate`, `groups.retry`, `groups.send`, `groups.state`, `groups.stop`.

- **handoff**: `handoff.fail`, `handoff.request`, `handoff.state`.

- **image**: `image.attach`, `image.attach_bytes`, `image.detach`, `image.generate`.

- **input**: `input.detect_drop`.

- **insights**: `insights.get`.

- **learning**: `learning.delete`, `learning.detail`, `learning.edit`, `learning.frames`.

- **llm**: `llm.oneshot`.

- **mcp**: `mcp.catalog`, `mcp.servers.add`, `mcp.servers.list`, `mcp.servers.oauth.callback`, `mcp.servers.oauth.cancel`, `mcp.servers.oauth.poll`, `mcp.servers.oauth.start`, `mcp.servers.remove`, `mcp.servers.set_api_key`, `mcp.servers.status`, `mcp.servers.test`.

- **message**: `message.react`.

- **model**: `model.disconnect`, `model.options`, `model.save_key`.

- **paste**: `paste.collapse`.

- **pdf**: `pdf.attach`.

- **pet**: `pet.cancel`, `pet.cells`, `pet.disable`, `pet.export`, `pet.gallery`, `pet.generate`, `pet.generate.status`, `pet.hatch`, `pet.info`, `pet.info.meta`, `pet.remove`, `pet.rename`, `pet.scale`, `pet.select`, `pet.thumb`.

- **ping**: `ping`.

- **plugins**: `plugins.list`, `plugins.manage`.

- **preview**: `preview.restart`.

- **process**: `process.kill`, `process.list`, `process.stop`.

- **profiles**: `profiles.configure`, `profiles.create`, `profiles.describe`, `profiles.get_asset`, `profiles.list`, `profiles.remember_onboarding`, `profiles.set_asset`.

- **project**: `project.facts`.

- **projects**: `projects.add_folder`, `projects.archive`, `projects.create`, `projects.delete`, `projects.discover_repos`, `projects.for_cwd`, `projects.get`, `projects.list`, `projects.project_sessions`, `projects.record_repos`, `projects.remove_folder`, `projects.set_active`, `projects.set_primary`, `projects.tree`, `projects.update`.

- **prompt**: `prompt.background`, `prompt.btw`, `prompt.submit`.

- **reload**: `reload.env`, `reload.mcp`.

- **request**: `request.answer`.

- **rollback**: `rollback.diff`, `rollback.list`, `rollback.restore`.

- **session**: `session.activate`, `session.active_list`, `session.branch`, `session.close`, `session.compress`, `session.context_breakdown`, `session.control`, `session.control.read`, `session.create`, `session.cwd.set`, `session.delete`, `session.events.since`, `session.events.stats`, `session.foreign.import`, `session.foreign.list`, `session.foreign.preview`, `session.history`, `session.interrupt`, `session.list`, `session.most_recent`, `session.redirect`, `session.resume`, `session.save`, `session.set_hidden`, `session.status`, `session.steer`, `session.title`, `session.undo`, `session.usage`, `session.workspace.move`.

- **setup**: `setup.runtime_check`, `setup.status`.

- **shell**: `shell.exec`.

- **skills**: `skills.manage`, `skills.reload`.

- **slash**: `slash.exec`.

- **spawn_tree**: `spawn_tree.list`, `spawn_tree.load`, `spawn_tree.save`.

- **subagent**: `subagent.interrupt`, `subagent.list`, `subagent.steer`, `subagent.tail`.

- **subscription**: `subscription.change`, `subscription.preview`, `subscription.resume`, `subscription.state`, `subscription.upgrade`.

- **system**: `system.battery`.

- **terminal**: `terminal.resize`.

- **tools**: `tools.configure`, `tools.list`, `tools.show`.

- **toolsets**: `toolsets.list`.

- **usage**: `usage.bars`.

- **vault**: `vault.add`, `vault.list`, `vault.lock`, `vault.remove`, `vault.source.set`, `vault.sources`, `vault.unlock`.

- **verification**: `verification.status`.

- **voice**: `voice.record`, `voice.toggle`, `voice.tts`.

- **wake**: `wake.feed`, `wake.pause`, `wake.resume`, `wake.start`, `wake.status`, `wake.stop`.
