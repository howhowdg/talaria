# COMPONENTS — hierarchy handoff

Shared between Mac and iPhone; sizes are Mac / iPhone. Colours: ink `#1A1C1A`, accent `T.fill #3B7DDD`, deep `T.deep #1F5FB8`, tint `T.tint rgba(59,125,221,.16)`, **attention `T.attention #B8640A`**, attention tint `rgba(184,100,10,.16)`, failed `#C8402F`. All surfaces follow the glass values in `../README.md`.

## Status (one vocabulary everywhere)
| State | Glyph | Colour | Text | Where |
|---|---|---|---|---|
| Working | 7pt dot, pulse 1.4s (static under Reduce Motion) | `T.fill` | "Working · 48s" | rows, toolbar, pills |
| Needs you | `!` bold (approval / blocked) or `?` bold (clarification) | `T.attention` | "NEEDS YOU" tag · "Waiting for you · 3 min" | rows, cards, Activity, badges |
| Completed | `✓` (`checkmark`) | `T.deep` | "Completed · 41s" | rows, cards |
| Failed | `✕` (`xmark`) | `#C8402F` | "Failed · {reason}" | run rows, Activity |
| No output | `○` (`circle`) | `black .35` | "Nothing to report" / "No output" | run rows |
| Unread | 6pt dot after title | `T.fill` | "Unread" (optional) | run rows, Activity updates |
| Enabled / Paused (automation only) | tag | deep on `T.tint .12` / `black .55` on `black .06` | "Enabled" · "Paused" | automation cards, detail |
Never colour alone: every state carries a glyph and/or a word. Unread (blue dot, information) and Needs you (amber, decision) never share a row treatment.

## Rows

### SidebarRow (Mac) / ListRow (iPhone)
Data: `kind` (home · activity · workspace · automation · conversation), `title`, `secondary?`, `status`, `badgeCount?`, `swatch?`, `selected`.
- Mac: 8 radius, 10×5 padding (6 for two-line), leading glyph 16 wide; iPhone: 18 radius, 16×14 padding.
- Variants: Home (house glyph deep, title semibold), Activity (count badge on `T.attention`), Workspace (swatch 14×11 / 18×14, two lines), Automation (clock, one line, trailing dot or "Paused"), Conversation (plain, truncating).
- States: default · hover (Mac: `white .30`) · selected (`white .55` + `white .7` stroke) · working (dot) · needs-you (tag) · disabled/disconnected (`black .45` text).

### WorkspaceCard
Data: `name`, `swatch`, `purpose`, `binding?` ("Telegram topic"), `originLink?` ("Started from Home"), `counts {delegated, needsYou, files}`, `lastActivity`, `status`, `archived`.
12 / 18 radius; header · purpose · meta. Archived: dashed `black .15` border, no fill, "Restore". Tap → workspace detail.

### AutomationCard
Data: `name`, `purpose`, `schedule` ("Daily · 7:00"), `enabled`, `lastRun {time, state, unread}`, `nextRun?`.
Two-column (Mac) / stacked (iPhone). Paused: fill `.45/.5`, text `black .65`, next = "Won't run while paused".

### RunRow
Data: `time`, `state` (working · completed · failed · noOutput · waitingInput), `summary` (first line of result), `unread`, `duration`.
Mac 12 radius `white .5` (today's run `.7`, two-line preview); iPhone 18 radius. Trailing: chevron · "Retry" (failed) · "No output" · "Fix ›" (waiting). Tap → Run detail.

### ActivityRow
Data: `kind` (approval · clarification · taskCompleted · runCompleted · runFailed), `title`, `origin {parentName, parentKind, childName?}`, `time`, `unread`, `actions[]` (host-provided for approvals).
Grid: tile 26 / 34 (radius 8 / 10) · title · time · origin line · actions. Needs-you rows: tile attention tint + attention glyph, fill `white .8/.85`. Update rows: tile `black .05`, fill `.6/.65`; read: `.45` + `black .60` text. Tap anywhere except a button → origin screen with the item revealed.

### ContextRow (inspector)
Data: `glyph/swatch`, `title`, `secondary`, `status`, `selected`. 8 radius, 8×7 padding, 11.5 / 11. Used for DELEGATED WORK, DELEGATED FROM HOME, RECENT RESULTS.

## Cards inside transcripts

### DelegationReferenceCard (Home)
The single link between Home and delegated work. Data: `workspace {name, swatch}`, `origin` ("started from here"), `tasks[] {name, state, summary}`.
Header row (swatch, name semibold, "workspace · started from here", "Open ›") + one row per task (status glyph, name, summary, trailing tag/label). 10 / 18 radius, `white .6/.7`. Updates live; never expands into the worker transcript — tap to go there.

### DelegatedTaskCard (workspace transcript)
Data: `name`, `goal`, `state`, `startedAt`, `request? {question, options[]}`, `result? {file, summary}`, `toolCallCount`.
10 / 18 radius, **dashed** 1 / 1.5pt border — `T.attention .55` when waiting, `black .20` otherwise — fill `white .55/.6`. Rows: header (`⤷`, name semibold, "delegated task", status) · goal · then exactly one of: request line ("!" + question + "Answer ›"), ResultRow, progress line ("Working · 12 of 18 passed"). Footer "▸ Execution · {n} tool calls" 11 / 13 `black .45` expands the worker's tool card in place. Distinct from a WorkspaceCard by the dashed edge, the `⤷` glyph and the absence of a swatch: workspaces are solid and durable, tasks are dashed and temporary.

### ResultRow
Data: `file`, `summary`, `producedBy`, `actions` (Discuss · Open · Reveal).
White 8 / 12 radius, `black .08` stroke; file glyph 14×16 tinted; mono filename medium; summary `black .5`; "Discuss in Home" / "Discuss" `T.deep` semibold.

### RequestCard (approval / clarification)
Data: `kind`, `title`, `origin {parent, child?}`, `detail?` (mono command / path), `options[]` (from the host: e.g. once · session · always · deny; or the clarification choices), `allowFreeText: true`.
12 / 22 radius, `white .8`, shadow `0 6 20 rgba(10,25,50,.10)` / `0 8 24 .12`. Icon tile attention tint + `⌘` / `?` / `!`. Title 12.5 / 15 semibold, origin 11 / 13. Options: Mac inline 28-tall capsules (first prominent, "Deny" plain right-aligned); iPhone stacked 44-tall (first prominent). The composer under it always accepts a typed answer. Options are rendered exactly as the host lists them — never collapse or rename them.

### ResultCard (run)
Data: `title`, `body` (markdown), `producedAt`, `meta {sources, toolCalls, duration, model}`.
12 / 22 radius, `white .8/.85`, padding 16×18 / 18. Title 14 / 17 semibold; body 12.5 / 15 with `T.deep` bullets. Followed by meta line and ExecutionDisclosure.

### ExecutionDisclosure
Data: `toolCalls[]`, `sources[]`, `instructions`. Collapsed row (`▸`, "Execution transcript", hint). Expanded: standard tool card + SOURCES list + mono instructions block. Collapsed by default, remembered per run.

### GoalBand (task detail)
10 / 14 radius, `T.tint .08`, "Goal" semibold + text. Always the first element of a task transcript.

### NoticeBand
Data: `tone` (info · warning), `text` (bold lead + body), `actions[]`.
Info: `white .55` + `white .9` stroke, `◌` glyph. Warning: `rgba(200,64,47,.08)` + `.2` stroke, `!` red. Used for Home unavailable, unmapped conversation, disconnected (as a floating capsule).

## Small parts
- **Tag** "NEEDS YOU" / "ANSWER" / "NEW": Mac 9.5 bold text only (attention / deep); iPhone 22-tall capsule, 11 bold white on `T.attention` (NEW stays text).
- **CountBadge**: 16 tall, min 16, radius 8, 10 bold white on `T.attention`; hidden at 0.
- **Swatch**: workspace colour at 45% (`T.fill` default, `black .18` neutral), 14×11 / 16×12 / 18×14, radius 3–4. User-pickable from 6 palette colours; the swatch is the only place a workspace colour appears.
- **Type glyphs**: Home `house` · workspace swatch · task `arrow.turn.down.right` (`⤷`) · automation `clock` · run none · activity `bell.badge`.
- **BackCrumb**: Mac `‹ Parent` 12 `T.deep` in toolbar; iPhone 48-tall glass capsule `‹ Parent` 16, includes the parent's swatch/glyph, parent name truncates at 140.

## Behaviour summary
| Action | Result |
|---|---|
| Tap workspace row/card | Workspace detail; sidebar selects it; inspector → its context |
| Tap task card / ContextRow | Task detail (breadcrumb to parent); parent stays selected |
| Answer / Allow (RequestCard) | Sends the host option; card collapses to a one-line receipt "You chose: Direct only · 9:44" |
| Discuss (ResultRow / ResultCard / toolbar) | Discuss sheet → destination receives a quoted result block with back-link |
| Rerun | New run row appears as Working under the automation; no navigation |
| Edit instructions | Automation editor sheet (SETTINGS_KIT) |
| Enabled toggle | Pauses/resumes the schedule; runs unaffected |
| Use as Home | Sets Home for this profile; first-use screen dismisses |
| Make it a workspace / Add to… / Archive | Reclassifies the conversation; row moves sections |
| Retry (failed run) | Same as Rerun, from the failed row |
| Tap Activity row | Owning screen with the item revealed and highlighted for 2s |
