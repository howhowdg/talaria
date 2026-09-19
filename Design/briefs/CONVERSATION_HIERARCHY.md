# Talaria: Home, Workspaces, and Automations

Proposed design brief, 18 September 2026. This is a product direction for exploration, not an approved implementation specification. Existing approved visual references remain in `Design/handoff/README.md`.

## Prompt for Claude Design

Design the next version of Talaria, a native macOS and iPhone companion for a personal Hermes agent. Talaria already connects, displays conversations, streams responses, and presents approval requests. Its current flat list treats personal conversations, Telegram topics, and scheduled executions too similarly. We need a clear hierarchy that reflects how a person relates to their agent and its work.

Use this product model:

| Concept | Meaning | Default experience |
| --- | --- | --- |
| Home | My ongoing primary conversation with my agent, Gilbert. A stable place to talk, ask for help, and return to. | Conversation first, with compact references to work delegated elsewhere. |
| Workspace | A distinct, durable problem or area of work, such as planning a trip or building an app. A Telegram topic may correspond to one workspace. | A focused conversation with its own title, relevant files/results, and delegated work. |
| Delegated task / subagent | A worker pursuing a specific goal within a conversation or workspace. It has a lifecycle and reports a result. | Goal, status, progress when available, requests for input, and result; detailed execution is expandable. |
| Automation | Instructions that run repeatedly or on a schedule, such as a daily briefing. | Purpose, schedule, last/next execution, and a history of runs. |
| Run | One execution of an automation. | Result first, with execution details available on demand. |

The primary destinations are **Home**, **Workspaces**, and **Automations**. Make **Activity / Needs you** a shared view of updates and requests across these destinations, with a clear path back to the originating work. Explore its placement as a utility or a fourth phone tab, and recommend one treatment. Skills and connection settings are supporting utilities; files belong to the selected work's context.

### The hierarchy to communicate

```text
Gilbert — selected agent connection/profile
├── Home — my primary conversation
├── Workspaces
│   ├── Plan a trip
│   │   ├── Main conversation
│   │   ├── Delegated work
│   │   │   ├── Compare travel options
│   │   │   └── Research places to stay
│   │   └── Files and results
│   └── Build Talaria
└── Automations
    ├── Morning Brief
    │   ├── Today's run
    │   └── Earlier runs
    └── Weekly Review

Activity / Needs you links into any of the above.
```

This is the conceptual hierarchy, not a requirement to render every item in a permanently expanded tree. Home may also contain delegated work. Keep the default view calm and let people reveal execution detail when useful.

### Product behavior to design

1. **Home feels permanent and personal.** It is always easy to reach. It is the selected primary conversation, not a dashboard of every event. Show a small number of relevant work references inside or alongside it. Include a first-use state for choosing an existing conversation as Home, and a state where its underlying conversation is unavailable.

2. **Workspaces feel independent but related.** Give each a clear name, purpose, and status. Within a workspace, distinguish the user's conversation from delegated workers. Show a parent/child relationship only when known. Represent “started from Home” or another workspace as an explicit link. A long-lived Telegram topic and a short-lived subagent should have different visual treatments.

3. **Delegation has a beginning and an end.** Show a task being assigned, work in progress, a request for permission or clarification, and a completed result. Make it possible to inspect a worker without losing the main conversation. Design an explicit “Bring result to Home” or “Discuss result” flow showing what context will be included. Do not imply that every conversation automatically shares its complete history.

4. **Automations are ongoing instructions.** Group executions under the automation that produced them. A daily run should add a run to Morning Brief, rather than another peer workspace. Distinguish the schedule's enabled/paused state from an individual run's working/completed/failed state.

5. **Run details lead with the useful output.** Show the briefing, findings, or generated artifact first. Put the execution transcript, tools, and scheduler instructions behind a clearly labeled disclosure or secondary view. Include runs with no output, failed runs, and runs waiting for input. “Discuss this result” should open a conversation with the selected result as explicit context; distinguish that action from rerunning the automation or editing its instructions.

6. **Attention is visible everywhere.** Use consistent treatments for Working, Needs you, Completed, and Failed; use text and symbols as well as color. Show where a request originated and what decision it needs. Keep unread results distinct from requests requiring action. Answering an approval must retain the actual choices the host allows.

7. **Navigation preserves place.** Moving between Home, a workspace, and a run should preserve drafts and reading position. Use clear back navigation and concise context labels on iPhone. Search should identify the kind of result—conversation, workspace, automation, or run—and its parent when known.

8. **Unclassified history stays available.** Include a neutral place for older conversations whose role is unknown, and a lightweight way to organize them or choose one as Home. Classification must never be guessed from a conversation title. Archived work remains findable without crowding active work.

### Visual direction

Evolve the existing Talaria visual system. Use the supplied winged-sandal mark, New York wordmark, blue accent, native SF Symbols, and the existing Liquid Glass treatment for navigation and controls. Preserve the approved compact Mac typography, lockup alignment, and standalone pencil compose control. Use readable content surfaces and subtle distinctions in layout, labels, and iconography for the different constructs.

The approved Mac scale is 12.5pt conversation body, 12pt sidebar rows, 11pt tool/inspector text, 10pt section labels, and 15pt wordmark. These are Mac reference dimensions, not iPhone typography. iPhone retains Dynamic Type, accessible touch targets, and keyboard-safe layouts. Include light/dark states and Reduce Transparency/Reduce Motion behavior.

Mac reference window: 1180 × 760 points, with a 240pt sidebar and optional 290pt inspector. iPhone reference frame: 402 × 874 points. If a structural change requires different dimensions, annotate the reason and new measurements.

### Screens and flows to deliver

Use the same synthetic example data across Mac and iPhone so relationships can be followed end to end.

1. Home, showing the primary conversation and a link to work delegated into a workspace.
2. Workspace overview/list, clearly separated from Home and Automations.
3. Workspace detail with a main conversation, two delegated tasks, and a result/artifact.
4. One delegated task waiting for input, with its parent workspace still apparent.
5. Automations overview and Morning Brief detail, with several runs underneath.
6. A completed run showing its useful result first and an optional execution transcript.
7. Activity / Needs you, mixing a workspace approval, a completed task, and a new automation result while preserving their origins.
8. The complete journey from Home → workspace → delegated result → discussion back in Home, plus Automation → run → discussion of that result.

Include meaningful empty, disconnected, loading, error, long-title, and archived states. Provide a first-use Home selection and an unmapped legacy-conversation example. Start with the information architecture and key wireframes, then carry one recommended direction into detailed screens and a linked prototype.

### Handoff format

Return a folder that can be handed directly to the SwiftUI implementer:

- `README.md`: the chosen hierarchy, terminology, screen index, flow map, and any unresolved product decisions.
- `SPEC_MAC.md` and `SPEC_IOS.md`: dimensions in points, typography, spacing, components, scrolling behavior, keyboard behavior, and responsive rules. Say which previous layout rules the new spec supersedes.
- `COMPONENTS.md`: reusable rows/cards/navigation components, their data fields, all visual states, and action behavior.
- `screens/`: named 2× PNG exports of every selected screen and key state.
- `prototype/`: a linked interactive reference, with synthetic data and clear navigation between screens.
- `assets/`: only new required assets, preferably SVG with tintable fills where appropriate.
- `IMPLEMENTATION_NOTES.md`: separate actions available now, actions requiring client work, and actions depending on backend support. Every visible action must have an annotated outcome. Mark future concepts explicitly in this handoff.

Treat HTML/React prototypes as visual and interaction references. The shipping application remains native SwiftUI, using its existing TalariaStyle modifiers.

## Material to attach alongside this brief

- `Design/handoff/README.md` for the existing design system and its latest overrides.
- `research/screenshots/talaria-mac-compact-workspace-2x.png` for the approved compact Mac appearance.
- `research/screenshots/talaria-ios-handoff-chat.png` and the existing iPhone handoff screens for the phone appearance.
- `Design/handoff/assets/talaria-mark.svg` for the existing mark.

## Implementation grounding for the eventual build

These notes describe the checked-in source and pinned Hermes contract, not a guarantee of every feature on the connected older Hermes version.

- Talaria already has separate schedule and run models and reads job-specific run history. The proposed Automations → Runs organization has a direct foundation.
- The current session list discards the host's `source` field. Retaining source is a useful first step; it does not by itself identify Home, Telegram topics, or every parent/child relationship.
- Hermes persists Telegram topic/session bindings separately. A reliable topic-to-workspace mapping needs accessible metadata or explicit user assignment. Topic identity, origin links, and cross-device persistence need verification before implementation.
- Actual subagents have separate live execution APIs and a lifecycle. Their full history is not guaranteed to remain available after cleanup. Designs must handle unavailable execution details.
- Home needs an explicit stable identity per connection/profile. The API's most-recent conversation is not a reliable substitute. Conversation reset/compression continuity needs deliberate handling.
- A stored parent session ID can mean delegation, branching, reset, or compression. It must not automatically become a visual subagent relationship.
- Creating/mapping workspaces, returning results to Home, automation editing/rerunning, live subagent control, and cross-device organization are proposed work. They are not all implemented in Talaria today.
- The first implementation can organize confirmed conversation/run types, add an explicit Home selection, and provide result-first automation views. Rich delegation and shared workspace metadata can follow as their backend requirements are verified.
