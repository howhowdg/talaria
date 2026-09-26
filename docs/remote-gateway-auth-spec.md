# Remote gateway authentication: review and implementation spec

Status: Basic sign-in and macOS SSH implemented on `codex/basic-sign-in`. Reviewed 2026-09-25; managed SSH connected to the Mac Mini and loaded conversations on 2026-09-26.
Talaria revision: `874d5bfdf77762939873bf5f3a2c3343c97c8324`.
Upstream source checked: `NousResearch/hermes-agent@9fc7f17906eab1dd81ddfdf8a1edeecac1e79940`.

## Basic implementation verification

- `swift test` passes, including cookie rotation/isolation, persistence, cancellation and legacy migration checks.
- Real backend smoke: `python3 scripts/smoke-real-gateway.py --auth basic --repo /path/to/clean/hermes-agent --extended --timeout 45` passes against the reviewed auth revision. It covers login rejection, session restore, authenticated HTTP, fresh WebSocket connections, chat/tools, reconnect, uploads, named profiles and logout.
- The original pinned token backend also passes the extended smoke. Timed Basic expiry/refresh is covered by unit tests, not a wall-clock integration run.
- Mac Debug app builds with `CODE_SIGNING_ALLOWED=NO ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS=NO`; the latter avoids this machine's broken Xcode asset-symbol plugin. Both connection modes were inspected in the running Mac UI.
- iOS Swift sources compile, but full simulator app packaging/runtime verification is blocked by this machine's CoreSimulator version mismatch. No Xcode installation or system configuration was changed.
- Independent review found and fixed successful-sheet-dismissal cancellation of history loading and the smoke test's logout error expectation. Full iOS runtime acceptance remains outstanding.

## Recommendation

Add Hermes username/password sign-in on macOS and iOS, and managed SSH forwarding on macOS. Keep session-token support for local runtimes and compatible older hosts. Separate **how we reach the gateway** from **how we authenticate to it**.

Hermes's `basic` provider is a username/password login that issues a session. It is not HTTP `Authorization: Basic`. SSH encrypts and authenticates a connection to a machine; the forwarded Hermes service still has its own authentication.

The current docs promote provider sign-in, but the reviewed source still uses session tokens for loopback/SSH runtimes. No blanket session-token removal deadline was found. Do not delete that path based on an assumed deprecation.

Deliver in separate changes: shared connection/session plumbing with legacy compatibility; Basic sign-in; macOS SSH. This spans authentication, persistence, process ownership and UI, so one large PR would be harder to verify.

## Current architecture

```text
ConnectionView (URL, profile, token)
  -> HermesAppModel.connect
       -> supplied / in-memory / Keychain token
       -> GatewayClient
            GET /api/status + X-Hermes-Session-Token
            reject auth_required=true
            WS /api/ws?profile=...&token=...
            gateway.ready -> capabilities -> session hydration
       -> GatewayReader (separate network + token)
       -> AttachmentTransferService -> GatewayUploadClient (separate network + token)

MacCoordinator -> LocalRuntimeManager -> loopback Hermes child + generated token
iOS           -> remote connection only
```

| Area | Existing behavior and extension point |
| --- | --- |
| `HermesTransport/GatewayEndpoint.swift` | `GatewayEndpoint` is Codable metadata: UUID, name, URL, profile. Routes preserve proxy prefixes and reject URL credentials, query/fragment, and non-loopback HTTP. |
| `HermesTransport/GatewayClient.swift` | Actor owns one socket generation, pending RPCs, readiness, heartbeat and capability negotiation. A stale generation cannot take over a newer connection. Mutations are never automatically replayed. |
| `HermesTransport/GatewayNetwork.swift` | Ephemeral URLSessions, denied redirects, no cookie storage. HTTP result exposes only data/status. Separate HTTP/socket deadlines are intentional. |
| `HermesTransport/GatewayReader.swift`, `GatewayUpload.swift` | Independently created token-only clients cover activity, session history, automation actions, Telegram metadata and both upload formats. |
| `HermesCore/HermesAppModel.swift` | Main-actor coordinator handles reconnect, profile switching, hydration, drafts and cancellation. Several feature guards require a token. |
| `HermesCore/CredentialStore.swift` | One raw token per connection UUID in device-only Keychain; metadata is stored under `gateway.endpoint` in UserDefaults. |
| `HermesUI/HermesRootView.swift` | Both connection forms expose URL/profile/token; saved identity changes when URL changes. |
| `HermesMacServices/LocalRuntimeManager.swift` | Owns only its launched local child. Supplies a generated token through the environment, parses readiness, bounds logs and termination. Reuse its lifecycle patterns for SSH, without turning it into a generic process framework. |
| `Apps/iOS/HermesIOSApp.swift` | Foreground recovery reconnects whenever an endpoint exists. It currently lacks explicit disconnected intent. |

The pinned OpenRPC contract is older (`a566d20...`, `Contracts/pin.json`) and does not establish the HTTP authentication contract. Record auth compatibility fixtures separately; no RPC schema regeneration is needed merely to add login.

## Complete finding ledger

Priorities describe obstacles to this feature, except R5, which is an existing lifecycle bug. All are VALID based on code; none justify an unrequested application change in this planning task.

| ID | Priority | Location | Concrete failure and evidence | Required verification |
| --- | --- | --- | --- | --- |
| R1 | P1 | `Sources/HermesTransport/GatewayClient.swift:112–117`; `GatewayEndpoint.swift:100–111` | A gateway advertising `auth_required=true` is rejected before a socket is created. The only socket credential is `token`. Valid Basic credentials cannot connect. | Basic login/ticket flow connects; wrong credentials and unsupported providers fail clearly; token mode still connects. |
| R2 | P1 | `Sources/HermesTransport/GatewayNetwork.swift:3–6,44–56`; `GatewayReader.swift:19–24`; `GatewayUpload.swift:52–55,92–99` | Cookie responses cannot establish a session, and readers/uploads own independent token-only networks. A socket-only fix leaves uploads, activity and automations broken. | All HTTP and socket paths use one connection-scoped session; refresh, cookie rotation, origin isolation and denied redirects work. |
| R3 | P2 | `Sources/HermesTransport/GatewayEndpoint.swift:4–14`; `Sources/HermesCore/HermesAppModel.swift:199–204,248–250` | No SSH configuration/owner exists. Saving a tunnel's temporary loopback URL would make restart use a dead port and could confuse connection identity. | Persist SSH destination, never assigned local port; port changes preserve drafts, selected conversation and classifications. |
| R4 | P2 | `Sources/HermesCore/HermesAppModel.swift:111–119,507–531,829–837,1132–1192,1254–1262` | Feature guards and helper APIs require a raw token even after successful provider login. | Replace every token-specific guard/caller, including injected test loaders; exercise each feature with Basic and SSH. |
| R5 | P2 | `Apps/iOS/HermesIOSApp.swift:25–27`; `Sources/HermesCore/HermesAppModel.swift:278–288` | Connect → Disconnect → background → foreground reconnects because disconnect retains the endpoint and foreground checks only endpoint presence. | Explicit disconnect/sign-out stays disconnected; suspension of an intended connection still rehydrates without resending work. |

## Scope and platform decisions

| Capability | macOS | iOS |
| --- | --- | --- |
| Existing local/token connection | Preserve | Preserve remote token connection |
| Direct Basic sign-in | Add | Add |
| SSH key/agent authentication and forwarding | Add using `/usr/bin/ssh` | Deferred: needs an embedded SSH implementation |
| Basic sign-in over SSH | Add | Deferred with SSH |

First SSH release attaches to an **already running** Hermes service. It does not install Hermes, start/upgrade a remote daemon, change its configuration, or kill remote services. The official desktop's isolated remote runtime management is a larger feature and is not required to forward an existing service.

SSH initially uses keys and the SSH agent, including existing SSH configuration aliases. SSH passwords, interactive keyboard authentication, a key manager, cloud login, OAuth UI and an arbitrary reverse-proxy HTTP Basic header are outside this release. These are explicit scope choices, not claims that they are already supported. If native iOS SSH is required for the initial release, choose and audit an SSH library before committing to that milestone; a macOS `Process` implementation cannot be reused there.

Talaria now accepts HTTP for direct Tailscale 100.64.0.0/10 IP addresses, with a matching ATS exception. Other remote URLs still require HTTPS.

## Proposed ownership and data

```text
SavedConnection (stable UUID, profile, transport, auth method; no secrets)
  -> macOS SSH manager, when selected
  -> ActiveConnection (resolved endpoint, generation, authenticated session)
       -> GatewayClient: RPC and socket lifetime
       -> GatewayReader: HTTP reads/actions
       -> GatewayUploadClient: HTTP uploads
```

Add a small Codable connection configuration around the existing endpoint identity:

- Common: schema version, UUID, display name, selected Hermes profile.
- Direct transport: validated base URL.
- SSH transport: host/SSH-config alias, optional username, port (default 22), optional identity-file reference, remote loopback target and service port (default 9119), optional gateway path prefix.
- Gateway authentication: `sessionToken` or `basic`. SSH's token mode can acquire the loopback token through the established tunnel when supported; a manually supplied token remains a compatibility fallback.

Use one concrete connection-session actor in `HermesTransport` to own authenticated HTTP requests, cookie updates and ticket acquisition. Inject it into the existing clients. Keep `GatewayClient` responsible for RPC framing/readiness; do not introduce a transport plugin framework. The actor's calls can overlap after suspension: cookie updates need generation/revision checks, and refresh probes must be coalesced explicitly.

Keep configured identity separate from the resolved tunnel endpoint. Use the stable UUID/profile for `SessionOwner`, `ComposerScope`, draft selection and attachment ownership. Remove transient URL/port from `mobileSeenKey` identity. Profile changes create a fresh socket/ticket but can reuse a still-valid SSH tunnel and origin-scoped auth session.

Migration: decode legacy `gateway.endpoint` as direct/session-token, preserve its UUID, and read its existing Keychain UUID account. Write the new version only after a successful save; keep the legacy record during initial rollout. Never treat undecodable data as a fresh connection and overwrite it. New Keychain records use distinct typed accounts, include the configured origin/base path or SSH destination binding, and never reuse a secret after that binding changes.

## Basic sign-in contract

Use the cookie route for the first implementation. It supports a native username/password form on both platforms without introducing a browser callback server. The upstream native PKCE/bearer flow is valid, but is extra machinery for this scope; do not pretend `/auth/password-login` returns bearer-token JSON.

All paths below are relative to the configured gateway prefix; preserve profile routing where applicable.

1. `GET /api/status` without credentials discovers `auth_required` and `auth_providers`. If the selected mode is Basic, require the `basic` provider. Do not silently downgrade a gated endpoint to token mode or guess an OAuth flow.
2. `POST /auth/password-login`, `Content-Type: application/json`, body `{ "provider": "basic", "username": "…", "password": "…" }`. Success returns `{ "ok": true, "next": "…" }` and session cookies. Ignore `next`; this native client does not navigate it. Clear the password from form/session state after the request completes.
3. `GET /api/auth/me` with the session confirms the provider/identity and returns `expires_at`. Public status alone does not prove successful sign-in; a configured gate can still report `auth_required=true` after login.
4. `POST /api/auth/ws-ticket` with the session returns `{ "ticket": "…", "ttl_seconds": 30 }` at the reviewed revision.
5. Open `/api/ws?profile=…&ticket=…`. Consume one fresh ticket per socket attempt; never save or reuse it. Keep tickets out of displayed/logged URLs. Preserve the existing ready/capability/hydration sequence.
6. All activity reads, automation actions, image uploads and document uploads use this same session. No `X-Hermes-Session-Token` or legacy `token` query is sent in Basic mode.

### Cookie handling and persistence

Keep automatic shared cookie storage disabled. Extend the HTTP response wrapper to retain the headers needed for Foundation's cookie parsing. Preserve multiple `Set-Cookie` values; do not split them naively on commas. Use an in-memory, connection-scoped cookie collection and Foundation's cookie APIs for parsing/request formatting, with explicit exact-origin and gateway-path enforcement.

Allow only the upstream session cookie families: `hermes_session_at`, `hermes_session_rt`, `hermes_session_provider`, including `__Host-` and `__Secure-` variants. Honor expiry, deletion, Secure and Path semantics; reject domain widening. Cookie scope must include the configured port even though browser cookies normally do not. A sibling path/port/connection must never receive these credentials. Do not log response headers/bodies containing credentials.

The middleware refreshes expired cookie sessions while handling a request and returns rotated cookies on that response. Apply session-cookie updates on every response, including failures/deletions, before dispatching the next dependent operation. Coalesce a `/api/auth/me` refresh probe when expiry is known; keep the refresh cookie after the access cookie expires. Never hardcode provider token TTLs. A terminal session-expired 401 clears unusable session material and requests sign-in; a 503 retains it and reports temporary provider failure. Prevent late responses from restoring signed-out cookies or replacing a newer session.

“Remember sign-in” stores only the allowlisted session material, expiry and scope metadata in device-only Keychain, never the password. Persist successful rotations when remembering is enabled. With remembering off, use memory only; opting out of a previously remembered sign-in removes its saved credential. If saving fails, keep the working connection and report that it was not saved. On restart, verify restored material using `/api/auth/me` before claiming authenticated status.

“Disconnect” stops traffic/tunnels and clears active session state but may retain an explicitly remembered credential. “Sign out” additionally calls `/auth/logout` best-effort and deletes the saved session. The logout route returns 302; accept its clearing cookies without following the redirect. Do not promise global revocation of every stateless Basic token.

Do not automatically replay POSTs or RPC mutations after an auth/network failure, including uploads and automation triggers. Reauthentication may recover the connection; it cannot establish whether an earlier operation ran. Read-only GETs may be retried once after an explicit successful refresh. Do not retry wrong passwords automatically. Distinguish login 401, unsupported provider/404, rate limiting/429 and provider outage/503 with fixed, sanitized messages.

## SSH connection lifecycle

The implemented default starts a separate, loopback-only remote Hermes gateway with a temporary token, as Hermes Desktop does. The existing-gateway forwarding flow below remains available under **Advanced → Use running gateway**.

Add `SSHTunnelManager` in `HermesMacServices`, owned through the Mac coordinator/platform boundary. Shared Core code receives the resolved endpoint and cancellation/cleanup capability; it does not import a macOS-only process API.

1. Validate host/alias, username, port, identity reference and remote target. Reject controls, leading option syntax and embedded credentials. Remote forwarding target is a loopback literal for this release. Pass arguments directly to `Process`; never assemble a shell command.
2. Launch a dedicated `/usr/bin/ssh -N -T` child with an explicit loopback `-L` forward. Set `BatchMode=yes`, `ExitOnForwardFailure=yes`, connection timeout and keepalive limits; disable agent forwarding, inherited extra forwards, remote commands and connection sharing for the app-owned child. Respect the user's alias/key/ProxyJump configuration where compatible with these ownership limits. No `sshpass` or password command-line arguments.
3. Use `StrictHostKeyChecking=yes` and the user's known-hosts configuration. Unknown or changed host keys fail closed with a specific error. Initial release asks the user to verify/enroll a host through their SSH client, then retry; no silent `accept-new`, automatic `ssh-keyscan` trust, or host-check bypass.
4. Choose an available loopback port. The reserve/release race is real: retry a small bounded number of times only on local bind collision, not on authentication/host-key failure. Use bounded OpenSSH verbose output to confirm the owned child's local-forward listener (as upstream does), with a startup deadline and exit checks, before making credential-bearing requests; merely finding an open local port is insufficient. Then complete authenticated Hermes HTTP + WS readiness before showing Connected.
5. Probe `/api/status` through the tunnel first. For `auth_required=false`, fetch the gateway root (`<base-prefix>/`) over this verified, owned tunnel; current headless `hermes serve` returns `window.__HERMES_SESSION_TOKEN__` as a JSON string assignment. Parse that exact assignment as a JSON string, require a nonempty valid token, and bound the response size; never execute JavaScript. Keep it in memory and reacquire after remote restart. Do not scrape arbitrary direct HTTPS pages for credentials. If the host does not expose the supported bootstrap contract, offer a token field or Basic sign-in; report the limitation instead of guessing a token file path.
6. For a gated service, run the Basic flow through the tunnel. A configured public `dashboard.public_url` can enable the gate even when the service binds to loopback; unsupported providers need a clear error. The tunnel does not disable the auth gate. Maintain gateway Host/Origin checks; do not spoof Host to evade rejection. Cookies are bound to the verified SSH destination and resolved generation; on a new local port, explicitly rebind only after the same trusted tunnel is established, never through a global localhost cookie jar.
7. Tunnel exit marks the connection unavailable, cancels its HTTP/socket work and preserves uncertain-send state. Reconnect establishes a new tunnel, resolves credentials/tickets again and hydrates history. Never resume by replaying a prompt.
8. Cancellation, connection replacement, explicit disconnect and application exit stop only the owned SSH child and wait for termination with a bounded escalation. Close sockets/HTTP work before releasing the tunnel. Do not kill unrelated SSH masters, local Hermes processes or remote services. Late startup/exit callbacks must check the connection generation.

Loopback bootstrap is a compatibility dependency, not a stable advertised public auth API. Pin a fixture and test it against the target `hermes serve` version before shipping. The reviewed headless serve implements it; older hosts may not. Keep manual token fallback for those hosts rather than reading remote secret files or starting services implicitly.

## UI and connection intent

Keep the existing SwiftUI visual language. Use concise labels, no default explanatory paragraphs.

- Connection: Name, Transport (`Direct` / `SSH` on Mac), Profile.
- Direct: Gateway URL; Authentication (`Username & password` / `Session token`).
- Basic: Username, Password, Remember sign-in, Sign in/Connect; Sign out when authenticated.
- SSH: Host, User, Port, Identity file (optional), Gateway port; gateway auth selection. Show a token input only for manual fallback. Hide SSH on iOS until implemented.
- Keep Start local Hermes available with its existing behavior.
- Expose progress as Connecting SSH → Signing in → Connecting gateway; show errors at the failing step. Disable duplicate submissions and make Cancel actually cancel startup/login, not just dismiss the sheet.

Track user intent separately from current socket state. Explicit Disconnect/Sign out clears the desired-connection flag. Foreground recovery only reconnects when that flag remains set. Preserve remembered metadata without using its existence as permission to reconnect.

## Implementation sequence and acceptance

1. **Shared session and migration:** add configuration/active-session types; route client, readers, uploads, attachment service and test-loader closures through them; remove token-only guards. Preserve token behavior, request bounds, TLS/redirect policy and stable IDs. Cover legacy migration and R5.
2. **Basic end to end:** status discovery, password login, scoped cookies, identity probe, tickets, refresh/persistence, sign-out, and both forms. Add recorded synthetic HTTP fixtures from the reviewed upstream revision, with no real secrets.
3. **macOS SSH:** process supervision, configuration form, strict host verification, forward readiness, bootstrap compatibility check, stable identity, cancellation and cleanup. Keep remote process management separate.
4. **Docs and integration:** update README/security/status claims only when the feature passes the following acceptance matrix. Keep iOS SSH explicitly unsupported until separately delivered.

| Check | Acceptance |
| --- | --- |
| Legacy/local | Saved token entries and Start local Hermes connect; protocol negotiation, heartbeat and hydration remain unchanged. |
| Basic on macOS and iOS | On each platform, verify login, refresh/restart, sign-out, all HTTP reads/actions/uploads and WebSocket behavior. Correct login reaches `gateway.ready`; bad password, unavailable provider and rate limit produce distinct safe errors. No HTTP Basic header is invented. |
| All feature paths | Basic and SSH connections list/resume sessions, stream a prompt, handle an approval, read activity/topics, control an automation and upload an image/document using the same identity. Optional topic endpoint 404 remains optional. |
| Refresh/restart | Expired access cookie with valid refresh cookie recovers; invalid refresh prompts sign-in; rotated cookies survive app restart only when remembered; 503 does not erase a usable refresh credential. |
| Tickets | Expired/consumed tickets cannot be reused; each reconnect gets a fresh ticket; failure never falls back to a legacy token on a gated host. |
| Isolation | Redirects denied; path-prefixed HTTPS cookies work; sibling port/path and another connection receive no cookies; edited destination never receives old credentials. |
| SSH | Known-key host connects; unknown/changed key, missing key, unreachable host and stopped backend fail distinctly; only loopback listens; port collisions do not send secrets to another listener. |
| SSH bootstrap | Parse valid JSON-escaped token assignments; reject missing, malformed and oversized responses; exercise manual-token fallback and fresh token acquisition after backend restart. A gated service must never enter the bootstrap branch. |
| Ownership | Cancel during SSH/login/ticket startup, switch profile/connection, quit, and remote/tunnel death leave no owned tunnel or stale callback affecting the replacement. |
| Stable state | New SSH port preserves drafts, Home/Workspace classification, read state and selected stored session; attachment ownership remains profile/connection scoped. |
| Intent | Explicit disconnect stays disconnected across iOS background/foreground; intended connections rehydrate after suspension. |
| Mutation uncertainty | Drop the connection after send/upload/trigger dispatch: no automatic replay; reconcile authoritative history before retry. |
| Secrets | Sentinel password/token/cookie/ticket strings never appear in UserDefaults, logs, diagnostics, process arguments, documents or screenshots. |

Reuse the existing injected HTTP/socket fakes and XCTest setup. Add focused auth-session and SSH lifecycle checks; a dependency-free rewrite of the test framework is unnecessary. Run `swift test`, then Mac/iOS builds and a disposable real Hermes integration environment. The current smoke runner covers token mode; extend it for Basic and a controlled SSH fixture. Do not use a user's active remote gateway as the test fixture.

Baseline: `swift test --scratch-path /tmp/talaria-auth-spec-tests-20260925` passed on the reviewed Talaria revision. This validates existing behavior only. No new auth flow, actual SSH server, iOS build or live gateway behavior was verified in this planning task.

## Sources and confidence

- [Hermes remote-backend guide](https://hermes-agent.nousresearch.com/docs/user-guide/desktop#connecting-to-a-remote-backend): provider setup, trusted-network use and remote connection concepts. The guide is live and may change.
- [Dashboard auth guide](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard#usernamepassword-provider-no-oauth-idp): Basic provider context. For exact wire behavior, prefer the pinned source below over older examples on the page.
- [Auth routes at reviewed SHA](https://github.com/NousResearch/hermes-agent/blob/9fc7f17906eab1dd81ddfdf8a1edeecac1e79940/hermes_cli/dashboard_auth/routes.py): password login, identity probe, WS tickets, native token exchange/refresh and logout.
- [Cookie definitions](https://github.com/NousResearch/hermes-agent/blob/9fc7f17906eab1dd81ddfdf8a1edeecac1e79940/hermes_cli/dashboard_auth/cookies.py) and [middleware](https://github.com/NousResearch/hermes-agent/blob/9fc7f17906eab1dd81ddfdf8a1edeecac1e79940/hermes_cli/dashboard_auth/middleware.py): cookie prefixes, scope, rotation and rejection semantics.
- [Headless token bootstrap server](https://github.com/NousResearch/hermes-agent/blob/9fc7f17906eab1dd81ddfdf8a1edeecac1e79940/hermes_cli/web_server_dashboard.py#L110) and [gate selection](https://github.com/NousResearch/hermes-agent/blob/9fc7f17906eab1dd81ddfdf8a1edeecac1e79940/hermes_cli/web_server.py#L1104): exact root token response only when ungated; loopback alone does not guarantee that.
- [Upstream SSH connection](https://github.com/NousResearch/hermes-agent/blob/9fc7f17906eab1dd81ddfdf8a1edeecac1e79940/apps/desktop/electron/ssh-connection.ts), [remote lifecycle](https://github.com/NousResearch/hermes-agent/blob/9fc7f17906eab1dd81ddfdf8a1edeecac1e79940/apps/desktop/electron/remote-lifecycle.ts), and [token bootstrap](https://github.com/NousResearch/hermes-agent/blob/9fc7f17906eab1dd81ddfdf8a1edeecac1e79940/apps/desktop/electron/dashboard-token.ts): reference implementations, not a mandate to duplicate their full lifecycle.

The requested `~/.codex/docs/codex-review-protocol.md` was absent. Review followed the complete-ledger and evidence rules supplied in the task. Remaining release gates are the SSH bootstrap compatibility fixture, final iOS SSH scope decision if parity is required, and integration testing against an actual supported Hermes version.
