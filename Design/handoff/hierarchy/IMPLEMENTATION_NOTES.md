# IMPLEMENTATION_NOTES — what can ship when

Grounded in the notes at the end of the brief. Three buckets; every visible action in the prototypes is listed once.

## A. Available now (client work only, current Hermes contract)
| Action / view | Outcome | Notes |
|---|---|---|
| Automations list, Automation detail, Run rows, Run detail (result first) | Reads existing schedule + run models and job-specific history | Direct foundation exists. Result card = the run's final assistant message; ExecutionDisclosure = its tool calls. |
| Enabled / Paused toggle | Existing schedule state | Distinguish from run state in UI as specced. |
| Rerun / Retry | Triggers the job now | Appears as a Working run row. |
| Choose Home (first use), "Use as Home", "Change Home conversation…" | Stores `{profileId → sessionId}` locally (and in iCloud KVS for cross-device) | **Client-side identity**. Not derived from the API's most-recent session. |
| Home unavailable state | Shown when the stored session id 404s | Offer Choose another / Start fresh. Keep cached transcript. |
| Retain `source` on sessions | Enables the "Telegram topic" tag and the OTHER CONVERSATIONS bucket | First step; does not identify workspaces by itself. |
| Approvals with host options (once / session / always / deny) | Existing approval flow, re-skinned as RequestCard | Options rendered verbatim from the host. |
| Free-text answer under a RequestCard | Existing send | Composer stays enabled during a pending request. |
| Activity — approvals + unread run results | Aggregates existing pending approvals and runs newer than last-seen | Needs-you count = approvals only until clarifications exist. |
| Search grouped by kind | Local grouping of existing session + run lists | Parent shown only when known. |
| Place-keeping (scroll + drafts per session) | Local | |
| Dark / Reduce Transparency / Reduce Motion | Tokens in SPEC files | `TalariaAttention` colour asset (light `#B8640A`, dark `#E8A24A`). |

## B. Requires client work beyond today's UI (no new backend)
| Action | What's needed |
|---|---|
| Workspaces as a first-class list; Make it a workspace / Add to… / Archive / Restore | A local classification store `{sessionId → workspaceId | home | archived}` with names, swatches and purpose text. Sync via iCloud KVS. Never auto-classify from titles. |
| Workspace detail: FILES & RESULTS | Files under the session's working directory, filtered to ones touched by that session's tool calls. |
| "Started from Home ↗" link | Record `{childSessionId, parentSessionId, kind: delegated | branch | reset | compression}` **at creation time in the client**. A stored parent id alone must not render as delegation. |
| Delegation reference card in Home | Rendered from the client's own delegation records + live status of the child sessions. |
| Discuss this result → destination | Client composes a message: quoted result block + deep link, sends to the chosen session. Only ticked items are included. |
| Unread tracking (runs, task completions) | Local last-seen timestamps per automation / task. |
| Task cards' "▸ Execution · n tool calls" | Cached transcript of the worker session; show "Execution details no longer available" when the host cleaned it up. |
| Activity "Mark all read" | Local. |

## C. Depends on backend / Hermes support (design is ready, ship behind feature flags)
| Action | Dependency |
|---|---|
| Telegram topic ↔ workspace binding, "#trip" label | Access to Hermes' persisted topic/session bindings or an explicit assignment API. Until then: manual "Bind to Telegram topic…" is not shown. |
| Delegated task cards with live status, goal, progress ("12 of 18 passed") | Subagent live execution API + lifecycle events. Full history may be unavailable after cleanup → always design for the "unavailable" fallback. |
| Clarification requests (`?` cards with host-provided choices) | A request type beyond approvals. Until then the Needs-you count covers approvals only. |
| Cross-device workspace organisation | Server-side metadata or a synced store beyond iCloud KVS. |
| Automation "Edit instructions" | Schedule edit endpoint (exists? verify). |
| Home continuity across reset/compression | A rule from Hermes for what the "same conversation" means after reset. Designed as "Home stays Home" + notice. |
| Result → Home with guaranteed provenance | Optional: host-side "context reference" so the quoted block links canonically. Client-side quoting works meanwhile. |

## Future concepts shown in the prototype (marked, not promised)
- Worker role label and worker-authored bubbles (needs C · subagent API).
- "Runs as Gilbert · read-only" in the automation header (needs tool-permission metadata per schedule).
- "1 approval waiting" counts on workspace cards (needs B classification + A approvals).
- Skills / Settings in the sidebar footer are placeholders for the existing screens.

## Suggested order
1. A: Automations/Runs result-first views, Home selection + unavailable state, retain `source`, Activity (approvals + unread runs), attention colour asset.
2. B: classification store + Workspaces list/detail, delegation records + Home reference card, Discuss sheet.
3. C behind flags as Hermes exposes topic bindings, subagent lifecycle and clarification requests.
