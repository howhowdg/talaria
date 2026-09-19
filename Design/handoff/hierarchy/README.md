# Talaria — Home, Workspaces, Automations

Design handoff, 18 Sep 2026. Answers the brief in `uploads/CONVERSATION_HIERARCHY.md`. Builds on the approved visual system (`../README.md`, `../SWIFTUI_SETTINGS_KIT.md`); where this spec conflicts with the earlier one, this one wins (see "Supersedes" in each SPEC file).

## The hierarchy (as shipped)

```
Gilbert                          ← profile/connection; everything below is per profile
├── Home                         ← ONE conversation, explicitly chosen, pinned first
├── Activity                     ← utility view over everything below (Mac: sidebar row; iPhone: 4th tab)
├── Workspaces                   ← durable, named, has purpose + status
│   ├── Plan a trip              ← may be bound to a Telegram topic
│   │   ├── main conversation
│   │   ├── delegated tasks  ⤷   ← short-lived workers with a lifecycle
│   │   └── files & results
│   └── Build Talaria
├── Automations                  ← standing instructions with a schedule + enabled/paused
│   ├── Morning Brief
│   │   └── runs (today / earlier)  ← one execution each; result first
│   └── Weekly Review
└── Other conversations          ← unclassified history; never guessed, never hidden
```

## Terminology (use these words in UI and code)
| Word | Never say | Notes |
|---|---|---|
| Home | Main chat, Default | Proper noun. One per profile. |
| Workspace | Project, Topic, Folder | "Telegram topic" is a *binding* shown as a tag, not a type. |
| Delegated task | Subagent, Worker (in UI) | Glyph `⤷` (`arrow.turn.down.right`). Dashed border = temporary. In transcript role label: "Worker · {task}". |
| Automation | Schedule, Cron, Job | Has **Enabled / Paused**. |
| Run | Execution, Job | Has **Working / Completed / Failed / Waiting for input / No output**. |
| Activity | Inbox, Notifications | Two groups: **Needs you** (requires a decision) and **Updates** (unread results). |
| Needs you | Pending, Action required | Always **attention amber** `#B8640A` (tint `rgba(184,100,10,.16)`), always with a glyph (`!` or `?`) and text. Amber is reserved for this — nothing else in the app uses it. Blue stays for links, working, and completed. |

## Recommendation: where Activity lives
- **iPhone: fourth tab** (Home · Workspaces · Automations · Activity). Approvals are the phone's main job; a tab with a numeric badge is one thumb away and survives being deep in a workspace. Rejected: a bell in the top bar (competes with the identity pill, no badge count, invisible when scrolled).
- **Mac: sidebar utility row** directly under Home with a count badge, plus the same items surfacing in context (Home's delegation card, the inspector's Delegated Work list). Rejected: a fourth column or a popover — the window already has the room to show attention in place.

## Screen index
| # | Screen | Mac (`prototype/Talaria Hierarchy Mac.dc.html`) | iPhone (`prototype/Talaria Hierarchy iOS.dc.html`) |
|---|---|---|---|
| 1 | Home with delegation reference | jump: Home | i1 |
| 2 | Workspaces list (active / archived / other) | Workspaces | i2 |
| 3 | Workspace detail: conversation + 2 tasks + result | Plan a trip | i3 |
| 4 | Delegated task waiting for input, parent visible | Task needs you | i4 |
| 5 | Automations overview / Morning Brief with runs | Automations · Morning Brief | i5 · i6 |
| 6 | Completed run, result first, transcript disclosed | Run | i7 |
| 7 | Activity: approval + completed task + new run | Activity | i8 |
| 8 | Discuss-result flow (context sheet) | Discuss sheet | i9 |
| — | Home first use | Home · first use (or Tweak `homeState`) | i10 |
| — | Home unavailable | Home · unavailable | spec only (SPEC_IOS §States) |
| — | Unmapped legacy conversation | Unmapped conversation | i2 "Other conversations" → row |
| — | Disconnected | Disconnected | spec only |
| — | Approval inside a workspace | Build Talaria | i8 (Review →) |

## Flow map
**Journey A — delegation round trip**
Home → (Gilbert opens workspace; delegation card appears in Home) → Plan a trip → ⤷ Compare travel options (Needs you) → answer → task completes → result card in Plan a trip → "Discuss in Home" → sheet: pick Home, tick result + link → Home receives a quoted result block with a back-link.

**Journey B — automation result**
Automations → Morning Brief → today's run → result card → "Discuss this result" → same sheet → Home. "Rerun" and "Edit instructions" are separate buttons; neither opens a conversation.

**Attention**
Any Needs-you item → Activity (badge) → tap → the originating screen with the request card scrolled into view, choices intact (`once / session / always / deny` for approvals; the host's option list for clarifications).

**Place-keeping**
Each destination keeps its own scroll offset + draft (per session id). Back navigation is a real stack on iPhone (`‹ Plan a trip` shows the parent name); on Mac the sidebar selection + breadcrumb in the toolbar carry the place.

## Files
- `SPEC_MAC.md`, `SPEC_IOS.md` — measurements, type, behaviour.
- `COMPONENTS.md` — rows, cards, badges, their states and data.
- `IMPLEMENTATION_NOTES.md` — what ships now vs needs client vs needs backend.
- `prototype/` — the two linked HTML references (Mac is interactive; iPhone is a screen board).
- `screens/` — 2× PNGs.
- Colour tokens added by this handoff: `TalariaAttention` light `#B8640A` / dark `#E8A24A`; `TalariaAttentionTint` light `rgba(184,100,10,.16)` / dark `rgba(232,162,74,.18)`.
- `assets/` — none new. Everything is SF Symbols + the existing mark and pencil.

## Unresolved product decisions
1. **Telegram topic ↔ workspace binding UI.** Designed as a tag + "Bind to Telegram topic…" action in the workspace ••• menu; the picker itself is not designed until the metadata source is confirmed.
2. **Can a delegated task be started by the user directly?** Prototype only shows Gilbert delegating. If yes, it's a composer action "Delegate this…" — not designed.
3. **Result sharing default.** The Discuss sheet pre-ticks result + back-link only. Confirm that's the right privacy default.
4. **Home reset/compression.** Designed as "Home stays Home" with an inline notice when the underlying session changed. Needs the continuity rule from backend.
5. **Archive semantics for automations** (delete vs pause vs archive) — only Paused is designed.
