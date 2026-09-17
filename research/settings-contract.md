# Native settings contract

Audited against pinned Hermes commit `a566d20d226a8e2ef0747639dc8a3fc1c43f9dba`. This increment selects models on an existing live conversation and discovers existing profiles. It does not provision credentials, change profile defaults, create/delete profiles, or call a process-global profile activation operation.

## Actual RPCs

There is no `models.list` or `providers.list` RPC in this pinned gateway. The combined picker API is `model.options`.

| Operation | Request | Response / semantics |
| --- | --- | --- |
| Model/provider catalog | `model.options {profile, session_id?, explicit_only:true, include_unconfigured:false, refresh:false}` | `{model, provider, providers}`. Provider rows contain `slug`, `name`, `models`, `aliases`, `authenticated`, `warning`, per-model `capabilities`, and `unavailable_models`. |
| Explicit catalog refresh | Same, with `refresh:true` | Probes saved custom endpoints and refreshes caches; normal opens probe only the current custom endpoint and use cached pricing. |
| Current reasoning | `config.get {profile, session_id?, key:"reasoning"}` | `{value, display}`; live/pinned session reasoning preferred, otherwise profile default. `display` is rendering preference, not model effort. |
| Current fast mode | `config.get {profile, session_id?, key:"fast"}` | `{value:"fast"|"normal"}`; live/prebuild session service tier preferred, otherwise profile default. This getter collapses non-priority tiers to `normal`. |
| Model / provider / reasoning change | `config.set {profile, session_id, key:"model", value:"MODEL --provider SLUG --session [--reasoning LEVEL]", confirm_expensive_model:false}` | Session-scoped selection. Explicit provider identity is preserved; a missing/stale runtime produces error `4001`. |
| Existing profiles | `profiles.list {profile, include_sessions:false}` | `profiles` with `name`, `display_name`, `description`, `is_default`, `model`, `provider`, plus other metadata. Host-side paths are not needed in native DTOs. |

Evidence: [catalog handler](../upstream/hermes-agent/tui_gateway/methods_complete.py#L323), [catalog contract](../upstream/hermes-agent/tui_gateway/contracts/config_free_tier_control.py#L211), [builder and refresh policy](../upstream/hermes-agent/hermes_cli/inventory.py#L182), [config getters](../upstream/hermes-agent/tui_gateway/methods_config.py#L151), [model setter](../upstream/hermes-agent/tui_gateway/methods_config_set.py#L107), [profile roster](../upstream/hermes-agent/tui_gateway/methods_profiles.py#L248).

`explicit_only` is not proof every returned provider is usable: the catalog retains the current provider after its credentials disappear, with `authenticated:false` and a warning. Native UI shows that row but refuses to apply it. It also disables models named in `unavailable_models`. Local-runtime and virtual provider rows are legitimate catalog entries. Slug, name, and aliases identify the same current provider; the service preserves the supplied explicit provider instead of guessing from a model-ID prefix. [Inventory behavior](../upstream/hermes-agent/hermes_cli/inventory.py#L119), [missing credential rows](../upstream/hermes-agent/hermes_cli/inventory.py#L402), [Electron identity matching](../upstream/hermes-agent/apps/desktop/src/lib/model-options.ts#L7).

The catalog is advisory about model membership: an available configured provider can accept a custom or newer model ID that its list does not include. The native service sends that exact model/provider pair to the gateway for validation. The parser splits text on whitespace rather than interpreting shell quoting, and normalizes four Unicode dash characters in flags. Native inputs therefore require a single ID without whitespace/control characters or a leading flag dash; this prevents a custom ID from changing `--session` into `--global`. Model IDs containing `/`, `:`, and other normal identifier punctuation remain valid. [Picker rationale](../upstream/hermes-agent/apps/desktop/src/lib/model-options.ts#L34), [parser](../upstream/hermes-agent/hermes_cli/model_switch.py#L463).

## Mutation results and concurrency

`GatewaySettingChange` preserves `value`, `warning`, `confirmationMessage`, `deferred`, and `scope`. A successful JSON-RPC envelope containing `confirm_required:true` is **not an applied change**. The sheet shows the host's confirmation message and only repeats the same selection with `confirm_expensive_model:true` after the user confirms. Confirmation state is cleared when its profile/session changes. The service never automatically confirms or retries mutations. [Guarded switch](../upstream/hermes-agent/tui_gateway/model_switch.py#L282).

If the session is running, the backend stores `pending_model_switch` and returns `deferred:true`; the next turn applies it. Talaria currently blocks changes during known running/queued/pending-input work. A competing client can still start a turn during validation, so the deferred response remains meaningful: do not replace it immediately with an old `model.options` snapshot. Later `session.info` provides the applied identity. [Pending switch](../upstream/hermes-agent/tui_gateway/methods_config_set.py#L73), [Electron handling](../upstream/hermes-agent/apps/desktop/src/app/session/hooks/use-model-controls.ts#L270).

The caller owns connection/profile/session fencing. `HermesAppModel` captures the gateway client and generation before each request, uses a new `GatewayClient` for each connection generation, and accepts settings results only for their selected owner/revision. Profile switching changes the endpoint's routing profile and reconnects; it never activates a global host profile. Text drafts and restored selection use `(connection UUID, profile, stored session ID)`, while mutations use the current runtime ID. A model update does not change the owner of a conversation or its drafts.

`load` requires the model catalog. Failure to read profile discovery or reasoning/fast state leaves the catalog usable and adds an explicit notice. RPC/model errors propagate to the owner for sanitized presentation; cancellation is not reported as a successful partial load. No endpoint token is passed into these DTOs.

## Reasoning and fast mode

`capabilities[model]` advertises `reasoning`, `fast`, and optional `can_disable_reasoning`. Missing capabilities are treated as unknown, so no reasoning controls are offered. The native picker offers the Hermes effort vocabulary (`minimal`, `low`, `medium`, `high`, `xhigh`, `max`, `ultra`), plus `none` only when `can_disable_reasoning:true`. The schema advertises boolean reasoning support, not a provider-specific allowed-effort list; final provider normalization remains backend-owned. [Capabilities schema](../upstream/hermes-agent/tui_gateway/contracts/config_free_tier_control.py#L238), [effort parser](../upstream/hermes-agent/hermes_constants.py#L960).

**Do not call `config.set key=reasoning` or `key=fast` for a session-only native control in this pinned version.** The setter reads `_sessions.get(session_id)`. If that runtime has expired, reasoning writes `agent.reasoning_effort` globally and fast writes `agent.service_tier` globally, even when the caller intended a session change. The profile wrapper binds configuration scope but does not validate the runtime's existence. A read-before-write preflight would still leave a race. [Dispatch lookup](../upstream/hermes-agent/tui_gateway/methods_config_set.py#L470), [reasoning fallback](../upstream/hermes-agent/tui_gateway/methods_config_set.py#L297), [fast fallback](../upstream/hermes-agent/tui_gateway/methods_config_set.py#L190), [profile wrapper](../upstream/hermes-agent/tui_gateway/server.py#L545).

Reasoning changes instead travel in the validated model command, after switching that model, with `--session --reasoning LEVEL`; the setter rejects a stale session before this path. No sessionless retry occurs. [Session rejection](../upstream/hermes-agent/tui_gateway/methods_config_set.py#L142), [reasoning applied with model](../upstream/hermes-agent/tui_gateway/model_switch.py#L306).

Fast mode is displayed read-only for an advertised capable current model. A future safe writer needs the backend to reject an explicitly supplied invalid runtime, or a new atomic session-scoped setter. `session.create` already supports `fast` with presence semantics (omitted inherits, true pins priority, false pins normal), which can support a future new-conversation picker without changing current-chat globals. [Creation contract](../upstream/hermes-agent/tui_gateway/contracts/sessions.py#L119).

## Profile discovery is deliberately lightweight

`include_sessions:false` avoids session preview/canonical-chat processing. That processing can resurrect recoverable archived canonical sessions; a settings roster does not need that side effect. The native DTO retains names and descriptive/model metadata without displaying host filesystem paths. Selecting a profile changes only this native connection's routing. [Canonical recovery](../upstream/hermes-agent/tui_gateway/methods_profiles.py#L121), [conditional session metadata](../upstream/hermes-agent/tui_gateway/methods_profiles.py#L259).

## Verification

- Ten focused settings tests cover real method/parameter shapes, profile scope, aliases/capabilities, partial read failures, custom models, explicit session pinning, confirmation without auto-retry, unsupported/unavailable selections, Unicode flag injection, and stale-runtime rejection without sessionless fallback.
- Three `HermesAppModel` integration tests use a controllable real `GatewayClient` transport: profile A → B → A restores drafts/selection, late old-connection settings cannot repaint the new profile, and equal profile/session names on different connection identities stay isolated.
- The isolated settings Core/UI sources and focused settings tests typecheck under Swift 6 with macOS 14 deployment. The parent runs combined package tests and the real pinned-backend smoke, including checking temporary profile YAML defaults after live selection and a rejected stale selection.

Public implementation: [GatewaySettings.swift](../Sources/HermesCore/GatewaySettings.swift), [SessionSettingsView.swift](../Sources/HermesUI/SessionSettingsView.swift), [settings tests](../Tests/HermesCoreTests/GatewaySettingsTests.swift), [owner-transition tests](../Tests/HermesCoreTests/HermesAppModelTests.swift).
