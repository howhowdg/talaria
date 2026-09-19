# SPEC_IOS — Home / Workspaces / Automations

Frame 402×874. Dynamic Type on; values below are `.large` defaults using semantic styles where noted. Touch targets ≥44. Content scrolls edge-to-edge under floating glass chrome exactly as in `../README.md` (fades, blur band, pill, tab bar) — those metrics are unchanged.

## Supersedes
- Five-tab bar (Chat · Sessions · Updates · Skills · Files) → **four tabs: Home `house` · Workspaces `square.stack` · Automations `clock` · Activity `bell.badge` (or `circle.lefthalf.filled`)**. Skills and Settings move to the profile button (top-left, avatar). Files live inside the workspace (chip row → Files screen).
- "Sessions" screen → **Workspaces** (this file). "Updates" screen → **Activity** + **Automations**.
- Identity pill's wordmark line shows the **destination name** on content screens ("Home"), the wordmark only on list screens' left capsule.

## Chrome per screen type
| Screen | Top-left | Top-centre | Top-right | Bottom |
|---|---|---|---|---|
| Home | avatar circle 48 (profile menu) | mark 56 + pill: "Home" 17 NY / status 12.5 | `rectangle.on.rectangle` 48 | composer 52 + tab bar |
| Lists (Workspaces, Automations, Activity) | lockup capsule 48 | — | `plus` 48 / "Mark read" capsule | tab bar |
| Detail (workspace, automation, run, task) | back capsule 48: `‹ {Parent}` 16 `T.deep` | — | `ellipsis` 48 / status capsule | composer (conversations) + tab bar |
Large title on lists: 28/700 tracking −0.4 at y 128. Detail title: 22/700 tracking −0.3 at y 118–120 with a 13 `black .50` sub-line (type + meta), content starts at 168–176.

## Attention colour
Same token as Mac: `T.attention` `#B8640A` (dark `#E8A24A`), `T.attentionTint` `rgba(184,100,10,.16)`. NEEDS YOU / ANSWER capsules, `!`/`?` glyphs and tiles, "Waiting" capsule, the Activity tab badge and the NEEDS YOU section label use it; nothing else does.

## Type
Bubbles 16/1.35 · card body 14/1.4 · card title 15 semibold · row title 16 (medium; semibold when it carries a badge) · row secondary 14 · meta 13 `black .50–.55` · section labels 13 semibold `black .45` uppercase · tags 11 bold in 22-tall capsules (NEEDS YOU / ANSWER on `T.attention`) · tab badge 10 bold on `T.attention` with 2pt white ring · result title 17 semibold · result body 15/1.45.

## Tab bar
60 tall capsule, 4 columns, active = 48-tall `T.tint .16` capsule with `T.deep` glyph. Activity badge = count (16 tall, min 16 wide, radius 8, `T.attention`, white 10 bold, 2pt white ring), offset top 8 / right 26. Badge counts **Needs you** only; unread updates show a plain 8pt dot instead.

## Screens
**i1 Home** — transcript with bubbles. **Delegation reference card** (88% width, radius 18, `white .7`, blur 20): header row swatch + "Plan a trip" 14 semibold + "workspace" 13 `black .50` + "Open ›" `T.deep`; then one row per task: glyph (`!` deep bold / `✓` deep) · title 14 · trailing "ANSWER" 22-capsule (`T.fill`, white 11 bold) or "Completed" 13 `black .50`. Composer "Message Gilbert…"; Stop = 40 circle with 12 square while working.
**i2 Workspaces** — sections ACTIVE / ARCHIVED / OTHER CONVERSATIONS · n. Workspace card radius 18, `white .75`, padding 14×16, gap 6: title row (swatch 18×14, 16 semibold, trailing NEEDS YOU capsule or "● Working" 13), purpose 14 `black .60`, meta 13 `black .50` joined by "·". Archived: dashed `black .15` border, `black .55` text, month + chevron. Other conversations: plain 16 medium rows with chevron; tapping opens the conversation with the **Organise** notice (see States).
**i3 Workspace detail** — chip row under the title (28-tall capsules `white .7`, 13): "Telegram topic", "⌂ Started from Home" (`T.deep`, tappable), "3 files" (→ Files). Then the conversation. **Delegated task cards**: 92% width, radius 18, **1.5pt dashed** border (`T.attention .55` when needs you, `black .20` otherwise), `white .6`, padding 12×14, gap 8: header `⤷` + title 15 semibold + status; goal 14 `black .60`; request line (`!` + question + "Answer ›") or **Result row** (white 12-radius row: file glyph, mono filename 14 medium, one-line summary 13, "Discuss" 13 semibold `T.deep`) + "▸ Execution · 14 tool calls" 13 `black .45`. Composer "Message in Plan a trip…".
**i4 Delegated task** — back capsule `‹ ▪ Plan a trip` (swatch included), right capsule "! Waiting · 3m" 13 semibold `T.deep`. Title `⤷ Compare travel options` 22/700, sub "Delegated task · started 14 min ago by Gilbert". Goal band (radius 14, `T.tint .08`, 14). Tool card 88%. Worker bubble. **Request card** full width, radius 22, `white .8`, shadow `0 8 24 rgba(10,25,50,.12)`: 34 icon tile + title 15 semibold + origin 13; stacked 44-tall choice buttons (first prominent). Composer "Or answer in words…" — typing is always allowed as an alternative to the buttons.
**i5 Automations** — automation cards radius 18: title row (`clock` 15 `black .55`, 16 semibold, trailing **Enabled** / **Paused** tag 12 semibold in 6-radius pill), schedule + purpose 14 `black .60`, status row 13: run glyph + "Today 7:02" + unread dot/"Unread" or "Waiting for input" `T.deep` semibold, spacer, "Next tomorrow 7:00". Paused card `white .5` and `black .65` text. Closing footnote 13 `black .45`.
**i6 Automation detail** — title `◷ Morning Brief`, sub "Daily · 7:00 · next tomorrow · runs as Gilbert, read-only". Enabled row (radius 18, `white .6`, system `Toggle`). Two 40-tall glass capsules "Run now" / "Edit instructions". TODAY / EARLIER **Run rows** (radius 18): glyph (`✓` deep · `✕` `#C8402F` · `○` `black .35` · `!` deep bold) + day/time 15 + one-line summary 13 + trailing chevron / "Retry" / "No output" / "Fix ›". Today's run card is taller with a 2-line preview and Unread dot. "Show 23 earlier runs" 14 `T.deep`.
**i7 Run** — back `‹ ◷ Morning Brief`, share 48 circle. Title "Today · 7:02", sub "✓ Completed · 41s · run of Morning Brief". **Result card** radius 22, `white .85`, padding 18: 17 semibold date, bullets 15/1.45 with `T.deep` bullet glyphs. Then **Discuss this result** 48-tall prominent capsule, then Rerun / Edit instructions 44-tall glass capsules in a row. Meta 13. **Execution transcript** disclosure row radius 18 `white .5` + `black .06` stroke; expands in place to the tool card + mono instructions.
**i8 Activity** — NEEDS YOU · 2 (label `T.attention`) then UPDATES. Approval row radius 18 `white .85`: 34 tile + "Allow a command?" 15 semibold + origin 13 (swatch + workspace + time); mono command block 13 on `black .04` radius 10; two 40-tall buttons Allow once (prominent) / Review (glass). Clarification row: tile `?` + question + origin "Plan a trip › ⤷ Compare travel options" + "Answer ›". Update rows `white .65`: tile `black .05`, title 15 semibold + 7pt unread dot, one-line preview 13, time 13 right. Failed row `white .45`, `✕` `#C8402F`, "Retry". Top-right capsule "Mark read".
**i9 Discuss sheet** — `.presentationDetents([.large])`-style bottom sheet, radius 30, `rgba(250,250,252,.96)`, grabber 36×5. Header: Cancel 16 `T.deep` · title 17 semibold. Sections WHERE (radio rows 48, selected row `T.tint .06`) and WHAT GILBERT WILL SEE (check rows 48, ticked = 22pt `T.fill` square with white ✓). Footnote 13 `black .45`. Primary 50-tall capsule "Open in Home" (verb follows destination).
**i10 Home first use** — pill reads "Home / Not set for Gilbert". Title 22/700 "Choose your Home", body 15 `black .55`, radio card (rows ≥56, radius 18, selected row `T.tint .08`), footnote, primary 50-tall "Use as Home" above the tab bar. Only the Home tab is active; other tabs work normally.

## States (not drawn — implement from these)
- **Home unavailable**: pill status "Session unavailable" in `#C8402F`; a radius-18 banner at the top of the transcript (`rgba(200,64,47,.08)`, `!`, body 14 with bold lead, actions "Choose another…" / "Start fresh" 14 semibold `T.deep`); composer disabled, placeholder "Reconnect Home to continue"; cached bubbles at 70% opacity.
- **Unmapped conversation**: opened from OTHER CONVERSATIONS; back `‹ Workspaces`; a radius-18 `white .6` notice under the title: `◌` "Not part of Home, a workspace or an automation yet." with a horizontally scrolling chip row: Make it a workspace · Add to… · Use as Home · Archive.
- **Disconnected**: pill status "Disconnected · retrying" red; a 44-tall glass banner under the header band "Can't reach Hermes — showing what was loaded · Retry now". Lists keep last data; composers disabled.
- **Loading**: skeleton rows (radius 18, `black .05`) for lists; conversations show the pill status "Loading…" and an empty transcript — never a spinner over content.
- **Empty**: Workspaces — mark 56 centred, "No workspaces yet" 17 semibold, "Ask Gilbert to take something on as a proper thing, or create one." 15 `black .55`, primary "New workspace". Automations — same pattern, "New automation". Activity — "All caught up" 17 semibold + "Nothing needs you." 15.
- **Long titles**: single line, tail-truncated in rows and the back capsule (max 140pt for the parent name → "‹ Rewrite the landl…"); two lines allowed in detail titles.
- **Archived**: dashed border, `black .55` text, actions Restore / Delete in swipe.
- **Keyboard**: composer 12 above keyboard; tab bar hides; back capsule stays.

## Navigation & place
`NavigationStack` per tab. Each stack element keeps scroll offset + draft keyed by session id. Deep link from Activity pushes onto the **owning tab's** stack and switches tab (so Back returns to the parent, not to Activity); a "Back to Activity" chip appears in the request card's origin line for 10s.
Search (pull down on any list): results grouped by kind — Conversations · Workspaces · Automations · Runs — each row shows its parent in 13 `black .50` when known.

## Dark / Reduce Transparency / Reduce Motion
Same tokens as SPEC_MAC §Dark: background `#15171B`, bubbles `white .10` (Gilbert) / `T.fill` (you), cards `white .08` + `white .12` stroke, glass chrome `black .35` blur 24 with `white .12` stroke. Reduce Transparency: chrome `#F1F2F5` / dark `#22252B`, no blur, `black .08` strokes; header fade band becomes a solid band with a hairline. Reduce Motion: no pulse, no sheet spring; use cross-fades.
