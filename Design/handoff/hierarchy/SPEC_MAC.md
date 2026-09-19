# SPEC_MAC — Home / Workspaces / Automations

Window 1180×760 reference. Columns unchanged: sidebar **240** · content flex · inspector **290** (optional, `⌥⌘I`). Toolbar row **52** in every column. All values in points.

## Supersedes
- `../README.md` "Mac screen — 4a" sidebar section list (Today / Yesterday / Folders) → replaced by the hierarchy below. Session tabs mode (Sidebar | Tabs preference) is **removed**; the sidebar owns navigation.
- Body text 13.5 → **12.5**; sidebar rows 13 → **12**; section labels 11 → **10** uppercase; tool rows 12 → **11**; wordmark 16 → **15**, mark 28 → **26**. Everything else from `../SWIFTUI_FIXES_ROUND3.md` (glass, dividers, compose button 30/9, lockup after 70pt) still applies.
- `SWIFTUI_SETTINGS_KIT.md` remains the rule for every sheet/settings surface, including the Discuss sheet here.

## Attention colour
One new token: **`T.attention` `#B8640A`** (dark `#E8A24A`), tint **`T.attentionTint` `rgba(184,100,10,.16)`**. Used only for things that need a decision: NEEDS YOU tags, `!`/`?` glyphs, request-card icon tiles, "Waiting for you/for input" text, the Activity badge, the dashed border of a task card that is waiting. Actions that resolve them ("Answer ›", "Allow once") stay blue — the colour marks the *state*, the button is the *verb*.

## Type scale
| Role | Size / weight | Colour |
|---|---|---|
| Toolbar title / card title | 13 semibold | ink |
| Body (transcript, result) | 12.5 regular, lineSpacing 5 | ink |
| Sidebar row title | 12 medium (semibold when selected) | ink |
| Sidebar row secondary, meta lines | 11 regular | `black .50` |
| Tool rows, inspector rows, footnotes | 11 / 11.5 regular | `black .60` / `.45` |
| Section labels | 10 semibold, uppercase, tracking .3 | `black .45` |
| Role labels ("YOU · 9:02", "GILBERT") | 10 semibold uppercase | `black .50` |
| "NEEDS YOU" tag, `!`/`?` glyphs, "Waiting for you" | 9.5 bold, tracking .2 / 11 semibold | attention `#B8640A` |
| "NEW" tag | 9.5 bold | `#1F5FB8` |
| Badge count (needs-you) | 10 bold | white on `#B8640A` |
| Wordmark | New York 15 semibold, `.padding(.top, 3)` | ink |
| Mono (paths, commands) | 11 / 12.5 monospaced | `black .60` |

## Sidebar (240)
Order, top to bottom. Row = 8pt radius, `padding(.horizontal 10) (.vertical 5)`, selected = `white .55` fill + 1pt `white .7` stroke + shadow `black .05 r1 y1`; unselected has no fill. Two-line rows use `padding(.vertical 6)`, 2pt between lines.

1. Toolbar 52: traffic lights · lockup (mark 26 + "Talaria") · spacer · compose 30×30.
2. Search 28 tall, radius 8, `white .35`, 12pt placeholder "Search". Margins 12 / top 2 / bottom 8.
3. **Home** — `house` 12pt in `T.deep` · "Home" 12 semibold · trailing 7pt pulsing dot when Home's session is working.
4. **Activity** — `bell` or `circle.lefthalf.filled` 12pt `black .55` · "Activity" 12 medium · trailing count badge (16 tall, radius 8, min width 16, 10 bold white on `T.attention`). Hidden count when 0.
5. Section **WORKSPACES** (10 semibold, `padding(.top 12) (.bottom 4)`), trailing "All ›" 11 regular `black .40` → Workspaces list.
   - Workspace row, two lines: swatch 14×11 radius 3 (workspace colour at 45%) · title 12 medium · trailing status (see COMPONENTS › Status) ; line 2 at 11 `black .50`, indented 21: "{n} delegated · Telegram topic" / "Running tests · 1 delegated".
   - Show ≤5 active workspaces; overflow → "All ›".
6. Section **AUTOMATIONS**, trailing "All ›".
   - Automation row, one line: `clock` 12 · name 12 medium · trailing: 6pt dot (unread run) or "Paused" 10 `black .55`.
7. Section **OTHER CONVERSATIONS**, trailing count 11 regular. Plain one-line rows, 12 medium, truncate tail. Show ≤3, then "Show all".
8. Footer (`white .5` hairline above): profile row — 22pt square avatar (radius 6, `T.deep`, initial) · "Gilbert" 12 semibold · "Connected · this Mac" 11 with 6pt dot (`T.fill`; `#C8402F` + "Disconnected · retrying" when down) · `chevron.up.chevron.down` 10. Below it a utility row: "✦ Skills" "⚙ Settings" 11 `black .55`, 3×8 padding. Files are not here — they belong to the selected context (inspector).

Selection rules: selecting a delegated task or a run keeps its **parent** row selected in the sidebar (task → workspace row; run → automation row). Breadcrumb in the content toolbar shows the child.

## Content toolbar (52)
Left to right, 10pt gaps, 16pt inset:
- Optional back crumb `‹ {Parent}` 12 `T.deep` (task, automation, run). Then `›` 12 `black .30`.
- Type glyph: swatch 16×12 (workspace) · `⤷` (task) · `clock` (automation) · none (Home, run).
- Title 13 semibold, truncates. Child tag "delegated task" 10.5 `black .50` on `black .05` radius 5 when relevant.
- Meta 11 `black .50`: "Your conversation with Gilbert · since March" / "Telegram topic · started from Home ↗" (link) / "Working · 2m 10s" with dot / "✓ Completed · 41s" / "! Waiting for you · 3 min" (deep blue semibold).
- Spacer.
- Right side capsules 26 tall, radius 13, `white .55` + `white .8` stroke, 11 medium: context chip ("Lisbon · Oct 9–12 · €900", cwd in mono), actions ("Run now", "Edit instructions", "Rerun", "Organise ▾", "+ New workspace"). Primary capsule (Discuss this result) = `T.fill` white text 11 semibold. `•••` = 26 circle.
- Automation detail adds "Enabled" 11 + mini `Toggle(.switch)`.

## Content bodies
All transcripts: max width 760, inset 36, top 24, gap 22 between turns. Cards inside transcripts follow COMPONENTS.md. Composer: radius 22, min text height 30, placeholder names the place ("Message Gilbert…", "Message in Plan a trip…", "Answer the worker in words…", "Steer or answer in words…"). Send 32 tall capsule; disabled = `T.fill .4`; Stop = solid with 9pt white square.

**Home** — transcript. Role labels "YOU · time" / "GILBERT" with 15pt mark. The **Delegation reference card** appears in-line at the moment of delegation and updates live (see COMPONENTS). Trailing toolbar chip summarises: "{n} delegated · Working".
**Home · unavailable** — 10pt-radius banner above the transcript: `rgba(200,64,47,.08)` fill, `.2` stroke, `!` 700 `#C8402F`, body 12 with **bold lead**, actions "Choose another…" / "Start fresh" 11.5 semibold `T.deep`. Cached transcript below, composer disabled with placeholder "Reconnect Home to continue".
**Home · first use** — centred 460 column: mark 40, title 15 semibold, body 12 `black .55`, radio list card (rows 40, radio 14, selected row `T.tint .08` fill), footer buttons Not now / Use as Home (28 tall, radius 7), footnote 11 `black .45`.
**Workspaces list** — 760 column, sections ACTIVE / ARCHIVED (10 labels). Workspace card 12 radius, `white .65`, padding 12×14, gap 8: header (swatch 16×12, title 13 semibold, "Telegram topic" tag, spacer, status), purpose 12 `black .60` lineSpacing 4, meta row 11 `black .55` with bold counts. Archived = dashed `black .15` 1pt border, no fill, "Restore" action.
**Workspace detail** — transcript; delegated tasks render as **Delegated task cards** in-line where Gilbert created them. Results render as **Result rows** inside the completed task card.
**Delegated task** — Goal band first (10 radius, `T.tint .08`, 11.5, "Goal" semibold), then worker transcript with role label "WORKER · {TASK}" and a 15pt circle glyph, then the **Request card** (clarification/approval) as last item. Composer placeholder "Answer the worker in words…".
**Automations list** — automation cards: 2-column grid (title/purpose left; schedule + last/next right-aligned 11). Enabled tag `T.tint .12` / deep blue; Paused tag `black .06` / `black .55`. Paused card fill `white .45` and text `black .65`.
**Automation detail** — purpose paragraph 12 `black .60`, then TODAY / EARLIER groups of **Run rows**; "Show {n} earlier runs" 11 `black .45`.
**Run detail** — **Result card** first (12 radius, `white .8`, padding 16×18, title 14 semibold, bullets 12.5 lineSpacing 5 with `T.deep` bullet glyphs). Then meta line 11 `black .50` ("Read 4 sources · 6 tool calls · 41s · model"). Then **Execution transcript** disclosure row (10 radius, `black .08` stroke, `white .4`, `▸` 10 + "Execution transcript" 12 medium + "tools, sources and the scheduler's instructions" `black .45`). Expanded = the standard tool card + a mono instructions block. Runs with no output: result card replaced by a 12 `black .55` line "Nothing to report" and the disclosure still present. Failed: result card replaced by a `#C8402F` `.08` banner with the error and "Retry"; Waiting for input: the Request card.
**Activity** — 760 column, groups NEEDS YOU (label in `T.attention`) and UPDATES. **Activity rows**: 26pt icon tile (radius 8; `T.attentionTint` + `T.attention` glyph for needs-you; `black .05` + `black .60` for updates), title 12.5 semibold, time 11 right, origin line 11 `black .55` with swatch/glyph + "Parent › ⤷ child", trailing action (inline choices for approvals; "Answer ›", "Read ›", "Open ›", "Retry" 11 semibold `T.deep`). Unread dot 6pt after the title. Row fill `white .8` for needs-you, `.6` for unread, `.45` + `black .60` text for read/failed.
**Unmapped conversation** — plain transcript, plus a 10-radius notice band under the toolbar: `◌` glyph, "This conversation isn't part of Home, a workspace or an automation yet." and actions "Make it a workspace" / "Add to…" / "Use as Home" / "Archive". Toolbar has "Organise ▾" with the same four.
**Disconnected** — floating capsule at top-centre of the content column (y 64): `white .85`, blur 20, red 7pt dot, 11.5 text, "Retry now" `T.deep` semibold. Content stays visible, composer disabled, list rows keep last state.

## Inspector (290)
Segmented capsule 28: **Context · Files · Terminal** (Context replaces Sources; sources appear under the run's execution). Content is 10-label sections with 6pt gaps, 16 between sections, inset 12, `padding(.top 6)`:
- Home: DELEGATED FROM HOME (workspace rows) · RECENT RESULTS (runs) · HOME (session facts, "Change Home conversation…").
- Workspace / task: DELEGATED WORK (task rows, selected task highlighted) · FILES & RESULTS (tree rows 11.5 mono, NEW tag) · LINKS ("Started from Home · Thu 9:03" → Home, "Telegram topic · #trip").
- Automation / run: THIS AUTOMATION (key-value 11.5) · INSTRUCTIONS (mono 11 block on `white .45`).
- Build workspace: DELEGATED WORK · STATUS checklist (☑ deep / spinner current semibold / ☐ `black .45`).
- Lists (Workspaces, Activity, Other): empty message 11.5 `black .45` centred.

## Discuss sheet
Per `SWIFTUI_SETTINGS_KIT.md`: 440 wide, title 44 "Discuss this result", sections WHERE (radio rows: Home · the parent workspace · New conversation) and WHAT GILBERT WILL SEE (checkbox rows: The result ✓ · Link back to this run ✓ · Sources it read · Execution transcript), footer 11 explanatory, buttons Cancel / **Open in Home** (verb follows the chosen destination: "Open in Plan a trip", "Start conversation"). Never opens with everything ticked.

## Keyboard
`⌘1` Home · `⌘2` Workspaces · `⌘3` Automations · `⌘4` Activity · `⌘[` back within a stack · `⌥⌘I` inspector · `⌘N` new conversation (asks: Home reply / new workspace / plain) · `⌘⇧D` Discuss this result when a result is focused · Return/Esc in sheets.

## Dark, Reduce Transparency, Reduce Motion
- Dark: window background `#1B1D22` with the same three washes at 25% strength; panels `black .28`, content `black .20`; ink `#F2F3F5`; secondary `white .60/.45`; hairlines `white .08`; cards `white .08` + `white .12` stroke; accent `#7FB0F0`, deep `#5B93E0`; attention `#E8A24A` (tint `rgba(232,162,74,.18)`); failed `#E0705F`. Selected sidebar row `white .12`.
- Reduce Transparency: panels become opaque `#F1F2F5` (dark `#22252B`), blur 0, hairlines `black .08`. Nothing else changes.
- Reduce Motion: pulse → static dot at 100%, spinner → `progress.indicator` system style, no sheet slide (fade).
