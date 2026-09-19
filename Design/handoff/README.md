# Handoff: Talaria — Mac + iPhone redesign

## Current handoff — Home / Workspaces / Automations

Read [hierarchy/README.md](hierarchy/README.md) first. The current hierarchy uses **Home**, **Workspace**, **Delegated task**, **Automation**, **Run**, **Activity** and **Needs you** exactly as defined there. A Workspace is durable; a Delegated task is temporary work with an explicit lifecycle; an Automation owns Runs. The design's sample records do not establish real relationships.

### Precedence

1. [hierarchy/SPEC_MAC.md](hierarchy/SPEC_MAC.md) and [hierarchy/SPEC_IOS.md](hierarchy/SPEC_IOS.md) supersede earlier sidebar, tab-bar and typography instructions where stated. Mac navigation belongs to the sidebar; the Sidebar/Tabs preference is removed. iOS has Home / Workspaces / Automations / Activity tabs.
2. [SWIFTUI_FIXES_ROUND3.md](SWIFTUI_FIXES_ROUND3.md), [SWIFTUI_FIXES_ROUND4.md](SWIFTUI_FIXES_ROUND4.md) and [SWIFTUI_SETTINGS_KIT.md](SWIFTUI_SETTINGS_KIT.md) still govern unaffected details. Preserve the 70pt traffic-light reservation, compact lockup, 30pt compose control and Settings Kit surfaces.
3. [SWIFTUI_SPEC_MAC.md](SWIFTUI_SPEC_MAC.md) and the original material below are historical references wherever superseded. [SWIFTUI_SPEC_MAC-v1.md](SWIFTUI_SPEC_MAC-v1.md) is the earlier semantic-font version.

The current Mac scale is 12.5pt body, 12pt sidebar rows, 10pt section labels, 11pt tool rows, 15pt New York wordmark and 26pt mark. iOS keeps its platform scale and Dynamic Type. Attention alone uses amber `#B8640A` / dark `#E8A24A`; links, active work and completed results remain blue.

### Current implementation scope

The implementation follows [A → B → gated C](hierarchy/IMPLEMENTATION_NOTES.md): result-first Automations/Runs, explicit Home and unavailable state, retained session source and Activity; then explicit local Workspace classification, recorded origin links, unread tracking and selective Discuss drafts. **Organisation is currently local-only; iCloud KVS is not implemented.** Source/title/recency never assign Home, create a Workspace or prove a Telegram topic binding.

Backend-dependent topic bindings, delegated lifecycle/goal/progress, automation editing, reset/compression continuity and canonical provenance are not implemented; feature flags default off. An existing supported host request stays visible and retains its host permission options. Discuss prepares only chosen context in the destination's draft and requires a separate Send.

Current references: [hierarchy/screens](hierarchy/screens) contains the supplied 2× PNGs. Current native evidence and reproduction instructions live in [Design/verification/hierarchy](../verification/hierarchy/README.md). See [implementation status](../../IMPLEMENTATION_STATUS.md#current-hierarchy-implementation) for exact limits and test results. The hierarchy pass is source work and has not published a replacement Mac release.

## Historical visual foundation

The remainder preserves the original blue-brand handoff and its reference screen descriptions. Its Today/Yesterday/Folders sidebar, five phone tabs, Sources inspector tab, older point sizes and Sidebar/Tabs preference are **historical**, not the current navigation specification. The original assets and unaffected glass/composer treatments still apply through the precedence rules above.

## About the design files
Everything in this bundle is a **design reference built in HTML** — it shows intended look and behaviour, it is not code to ship. Recreate it in the existing SwiftUI codebase (`Sources/HermesUI`), using the existing patterns: `TalariaStyle` modifiers (`talariaGlass`, `talariaProminentButton`, `talariaSecondaryButton`), `NavigationSplitView`, semantic system fonts, and `.glassEffect` on macOS/iOS 26+ with the existing material fallbacks.

## Fidelity
**High-fidelity** for layout, colour, type, radii and hierarchy. Icons in the mocks are Unicode placeholders — use SF Symbols (suggested names below). Data is sample data.

## Current iOS implementation notes

The SwiftUI hierarchy shell uses four tabs and a navigation stack per tab. Skills and Settings are accessed from the profile menu; Files opens within its selected context. The shell also runs at regular width; the earlier iPad split interface is no longer the current claim, and a dedicated iPad redesign remains open.

Production views use actual host output and explicit local records. Home/Workspace assignment is never inferred. Run result text, unavailable output, request states and unread markers remain distinct. Existing once/session/always/deny controls retain the host's values and restrictions; no prototype-only folder grant, read-only execution claim or delegated progress is substituted. Live steering, new prompts during active turns, voice, automation creation/editing, skill management and push delivery remain future work.

[Current native captures](../verification/hierarchy/README.md) are synthetic fixture renders, not HTML mockups or live-service proof. The older screenshots indexed below remain historical design references.

## Historical screen index
| Screen | File / anchor |
| --- | --- |
| Mac · chat workspace (the chosen direction) | `Talaria Mac.dc.html#4a` |
| Mac · brand mark and size cuts | `Talaria Mac.dc.html#4b` |
| iPhone · Chat | `Talaria iOS.dc.html#1a` |
| iPhone · Sessions | `Talaria iOS.dc.html#1b` |
| iPhone · Updates (scheduled runs) | `Talaria iOS.dc.html#1c` |
| iPhone · Approval card + keyboard | `Talaria iOS.dc.html#1d` |
Earlier turns in the Mac file (1a–3c) are rejected explorations; ignore them.

## Design tokens
**Colour**
- Accent `#3B7DDD` — prominent buttons, running dots, cursor, active tab tint
- Accent deep `#1F5FB8` — mark tint, checkmarks, link colour, small labels ("NEEDS YOU", counts)
- Accent tint `rgba(59,125,221,0.16)` — selected row, active tab pill, icon tiles
- Ink `#1A1C1A`; secondary text `rgba(0,0,0,0.55)`; tertiary `rgba(0,0,0,0.45)`; placeholder `rgba(0,0,0,0.35–0.40)`
- Mac window background: light neutral `#E4E6EA` with soft radial washes (blue `#B9CDF0`, peach `#F1D3C0`, lilac `#D5C7EE`) — in SwiftUI just let the desktop wallpaper show through the window material.
- iPhone background `#F4F4F6` with the same soft washes.
- Volt/graphite from the old brand are **retired**. Replace `TalariaAccent` asset colours: light = `#1F5FB8`, dark = `#7FB0F0`.

**Glass surfaces (fallback values when `.glassEffect` is unavailable)**
- Side panels (Mac sidebar/inspector): `rgba(255,255,255,0.28)`, blur 60, saturate 1.9, 1px border `rgba(255,255,255,0.5)`
- Chat column: `rgba(255,255,255,0.60)`, blur 40
- Floating controls (composer, pills, tab bar, round buttons): `rgba(255,255,255,0.60–0.70)`, blur 20–30, saturate 1.6–1.8, 1px border `rgba(255,255,255,0.9)`, inner top highlight 1px white, shadow `0 4px 14px rgba(0,0,0,0.08)` (tab bar: `0 6px 20px rgba(0,0,0,0.10)`)
- Cards inside the transcript (tool card, approval card): `rgba(255,255,255,0.55–0.85)`, 1px border `rgba(255,255,255,0.9)`, shadow `0 1px 3px rgba(0,0,0,0.05)`
- Prominent button: fill `#3B7DDD`, white text, inner highlight `rgba(255,255,255,0.35)`, shadow `0 2px 6px rgba(59,125,221,0.35)`

**Radii** — Mac composer 26; Mac cards 12; Mac side-panel rows 8; capsule controls = half height. iPhone bubbles 20 (6 on the tail corner); tool card 18; approval card 22; composer 26; tab bar 30; round buttons 48 circle; icon tiles 14.

**Type** — system font (SF Pro) throughout. Wordmark: **New York semibold** (`.system(.title3, design: .serif).weight(.semibold)`), 16pt Mac header / 17pt iPhone pill; sits ~2–3pt below the mark's optical centre and 3–4pt tighter than natural against the sandal's toe.
- Mac: body 13.5/1.55, sidebar rows 13 (600 when selected) + 11.5 secondary, section labels 11/600 tertiary, toolbar title 13.5/600, tool rows 12, code 11.5 mono, status list 12.
- iPhone: bubbles 16/1.35, list rows 16 + 14 secondary, screen title 28/700 letter-spacing −0.4, update titles 17/600, body 15/1.4, pill 17 wordmark + 12.5 status, tab bar glyphs 20.

**Spacing** — Mac columns 240 / flexible / 290; toolbar row 52; chat content max-width 760, horizontal inset 36; side-panel inset 12; row padding 8×10. iPhone: 16 horizontal inset; floating controls 16 from edges; tab bar 60 tall, 44 from bottom; composer 52 tall, 118 from bottom (12 with keyboard up); top controls at y=62; identity pill top 58; content starts at 180.

## Mac screen — 4a
**Sidebar (240)** — traffic lights · mark (28, tinted `#1F5FB8`, bare, no tile) · "Talaria" wordmark · spacer · New-conversation glass square (30, `square.and.pencil`). Search field (28, radius 8). Sections: Today / Yesterday / Folders, section label 11/600. Session row: title (600 when active) + one-line preview; running dot 7px accent pulsing (1.4s, opacity .35↔1); "NEEDS YOU" 10/600 deep-accent label when an approval is pending. Selected row: white 55% fill, 1px white border, radius 8. Footer: profile switcher row (`person.crop.rectangle.stack`, name, chevrons) and connection row (7px status dot · name · "Connected", `slider.horizontal.3`).
**Chat (flex)** — toolbar 52: title 13.5/600, status "● Working · 48s" 11.5 secondary, trailing glass round button (30, `rectangle.on.rectangle` = split/pop-out). Transcript: "You" label 11/600 secondary over body text; "Hermes" label with 16px bare mark. "▸ Thought for 9s" disclosure 12 secondary. **Tool card**: stacked rows (✓ deep accent or 10px spinner ring · tool name 600 · argument secondary · trailing count/status tertiary), 1px separators `rgba(0,0,0,0.06)`. Streaming text ends with a 7×14 accent block cursor pulsing 1s. **Composer** (radius 26, glass): placeholder "Message Hermes…", bottom row: `paperclip` 34, `ellipsis` 34, model pill 26 tall ("claude-sonnet-4.5 · High ▾", white 50%), spacer, Stop/Send prominent capsule 36 tall.
**Inspector (290)** — segmented capsule tabs 28: Files (active, white 60%) / Sources (count badge deep accent) / Terminal. File tree 12/1.9, indent 18 per level, chevrons 9pt tertiary, active file row tinted with "NEW" 10/600 badge. Preview card (radius 10, white 60%): header 11 secondary "itinerary.md · Rendered · live", rendered markdown 12/1.55. **Status** list: 11/600 label; rows ☑ deep accent done / spinner current (600) / ☐ pending tertiary.

**Navigation setting** — a preference "Sessions in: Sidebar | Tabs". Sidebar (default) shows the session list as above and the toolbar shows the title. Tabs mode replaces the sidebar list with Folders + Hermes nav (Skills, Schedules, Kanban, Settings) and puts Safari-style session capsules (32 tall, active white 85%, running dot, ✕ on active, + at end, truncating with ellipsis) in the chat toolbar. Never both.

## iPhone screens
Common chrome: round glass buttons 48 at top-left (`line.3.horizontal` → sessions drawer) and top-right (`rectangle.on.rectangle` / `slider.horizontal.3`); **identity stack** top-centre — bare mark 56, then a glass pill (radius 16) overlapping it by 6, containing the wordmark 17 and a 12.5 status line ("● Working · 48s", "4 schedules · 2 new", "Needs your OK" in deep accent). Header band 175 tall: gradient from background to clear at 55% with 6px backdrop blur, so content scrolls under it blurred. Bottom: gradient fade 130–200 tall; **tab bar** capsule 60 with five glyphs — Chat `bubble.left`, Sessions `line.3.horizontal`, Updates `clock` (8px accent badge with 2px white ring when new), Skills `sparkles`, Files `folder`; active tab = 48 tall capsule tinted `rgba(59,125,221,0.16)`, glyph deep accent.
**1a Chat** — user bubble right, accent fill, white text, 82% max; Hermes bubbles left, white 85%, 88% max; tool card as on Mac (rows: Calendar / Flights / Stay / Writing) at 88% width; streaming cursor. Composer capsule 52: `plus` 22, placeholder "Steer Hermes…", `waveform` glyph, trailing 40 circle accent with 12px white square (Stop) — becomes `arrow.up` Send when idle.
**1b Sessions** — Talaria lockup in a left capsule (48 tall) and pencil round button right. Title "Sessions" 28/700; search capsule 44; sections Today / Yesterday / Folders; rows 16 + 14 secondary, radius 18, active row white 75% with border; "APPROVE" 22-tall accent capsule when pending; folder rows with a 18×14 swatch and chevron. Above the tab bar: connection card (radius 20): dot · "Personal · Hermes on your Mac" 14/600 · "Connected · studio.local" 12.5 · chevrons.
**1c Updates** — feed of scheduled-run results grouped by time ("This morning", "Yesterday" 28/700). Row: 44 icon tile (radius 14, tint fill, deep-accent SF Symbol: `envelope`, `folder`, `target`, `checkmark`) · title 17/600 · body 15/1.4 secondary · inline actions 14/500 deep accent ("Open chat", "Draft replies") or, for approvals, an Approve prominent capsule 34 + "Review files" glass capsule. 1px separators.
**1d Approval** — approval **card** in the transcript (radius 22, glass, shadow `0 8px 24px rgba(10,25,50,0.12)`): 34 icon tile · "Move 142 files" 15/600 · path 13 secondary; mono preview block 13/1.6 on `rgba(0,0,0,0.04)` radius 12; two 44-tall buttons "Allow once" (prominent) / "Always for Downloads" (glass); "Deny" 14 secondary centred. Composer sits 12 above the keyboard; user can type to steer ("Skip the dmg files") instead of answering.

## Interactions & state
- Running session: pulsing 7px dot in list, status in toolbar/pill, block cursor at stream end, Stop replaces Send.
- Pending input (approval/clarification): "NEEDS YOU" / "APPROVE" label in lists, "Needs your OK" in the iPhone pill, Updates tab badge; card actions map to the existing once / session / always / deny choices.
- Selecting a session: row highlight, title in toolbar, inspector switches to that session's workspace CWD.
- Inspector tabs: Files (tree + live rendered preview), Sources (search results count), Terminal.
- No custom motion beyond the pulse; respect Reduce Transparency (opaque surface fallback already in `TalariaGlass`).

## Assets (in /assets)
- **`talaria-mark.svg`** — the shippable vector mark: one path, `fill="currentColor"`, `fill-rule="evenodd"`, viewBox 770². Import into the asset catalog as a template image (or convert to a SwiftUI `Shape`); tint with the accent. `talaria-mark-ink.svg` / `-white.svg` are pre-tinted copies.
- `talaria-mark-white-mid.png`, `talaria-mark-ink-mid.png` — **the** mark (Mid cut) as 1024² transparent PNGs; ink = `#1F5FB8`. Use as a template image so it tints with the accent colour.
- `talaria-mark-{white,ink}.png` (full detail) — app icon foreground only, on a `#1F5FB8` squircle.
- `talaria-mark-{white,ink}-small.png` — optional 16pt cut.
- Source drawing: `uploads/pasted-1789687970138-0.png` (front sandal cut out). The SVG is auto-traced from the Mid cut and slightly bolder than the PNG — intentional, it holds up at 16pt.

## Historical implementation order
1. Swap `TalariaAssets.xcassets` colours and the wing mark for the new mark; set the wordmark font.
2. Mac `HermesRootView`: add the inspector column (Files / Sources / Terminal + status), move the model picker into the composer, restyle sidebar rows and footer, add the Sidebar/Tabs preference.
3. Tool card and status stack views (shared).
4. iPhone: floating chrome (identity pill, round buttons, tab bar, composer), then Chat, Sessions, Updates, Approval card.

## Historical screenshots (in /screens, 2×)
- `mac-4a-chat-workspace.png` — Mac chat workspace, 1180×760 window
- `mac-4b-brand-mark.png` — mark, wordmark lockup and size cuts
- `ios-1a-chat.png`, `ios-1b-sessions.png`, `ios-1c-updates.png`, `ios-1d-approval.png` — iPhone screens, 402×874 frame
