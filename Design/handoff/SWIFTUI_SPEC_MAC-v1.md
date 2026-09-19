# Talaria Mac — SwiftUI-native spec (fix list against current build)

Target: `Talaria Mac.dc.html#4a` and `screens/mac-4a-chat-workspace.png`. Platform: macOS 26 (`.glassEffect`) with material fallbacks on 14/15. Everything below is a delta from the 2026-09-17 build screenshot.

## 0. Ground rules
- **Never set point sizes by hand for text.** Use text styles: Mac `.body` = 13pt, `.callout` = 12, `.caption` = 10, `.caption2` = 10, `.subheadline` = 11, `.headline` = 13 semibold, `.title3` = 15. The current build reads ~1.5× too large because it uses iOS-style sizes.
- `.controlSize(.regular)` on Mac (not `.large`). Toolbar buttons 28–30pt, composer capsule 36pt, composer field ≈ 76pt min height.
- Accent: replace `TalariaAccent` color set → light `#1F5FB8`, dark `#7FB0F0`. Add `TalariaFill` → `#3B7DDD`. Add `TalariaTint` → `Color.accentColor.opacity(0.16)`.
- Remove `TalariaStyle.volt` and `.ink` usages.

## 1. Window material — the #1 miss
```swift
// HermesMacApp.swift
WindowGroup { HermesRootView(model: model) }
  .windowStyle(.hiddenTitleBar)
  .windowToolbarStyle(.unified(showsTitle: false))

// HermesRootView body
NavigationSplitView { sidebar } content: { chat } detail: { inspector }
  .containerBackground(.thinMaterial, for: .window)   // wallpaper shows through everywhere
```
- Sidebar column: leave `.listStyle(.sidebar)` — it already uses the sidebar vibrancy material. Do **not** paint `windowBackgroundColor` behind it. Column widths: `.navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)`.
- Inspector column: `.background(.regularMaterial)` on the column root, width `min: 260, ideal: 290, max: 340`.
- Chat column: `.background(Color(nsColor: .textBackgroundColor).opacity(0.6))` so it's the most opaque of the three.
- Reduce Transparency: `TalariaGlass` already falls back to a solid surface; extend the same check to these three column backgrounds (`.background(Color(nsColor: .windowBackgroundColor))`).

## 2. Sidebar
Toolbar (leading → trailing): traffic lights · **bare mark** · **wordmark** · spacer · new-conversation button.
```swift
.toolbar {
  ToolbarItem(placement: .navigation) {
    HStack(spacing: -3) {                       // toe of the sandal nearly touches the T
      Image("TalariaMark").renderingMode(.template).resizable().scaledToFit()
        .frame(width: 28, height: 28).foregroundStyle(Color.accentColor)
      Text("Talaria").font(.system(.title3, design: .serif).weight(.semibold))  // New York
        .padding(.top, 2)
    }
  }
  ToolbarItem(placement: .primaryAction) {
    Button { … } label: { Label("New conversation", systemImage: "square.and.pencil") }
      .buttonStyle(.glass)   // fallback .bordered
  }
}
```
- **No capsule around the lockup.** It's a plain toolbar item.
- `TalariaMark` = `assets/talaria-mark.svg` imported into the asset catalog with *Preserve Vector Data*, *Render As: Template*.
- Search: `.searchable(text:, placement: .sidebar, prompt: "Find a conversation")`.
- Section headers: `Section("Today")` — default sidebar header style (11pt semibold secondary). Sections: Today, Yesterday, Folders.
- Row: `VStack(alignment: .leading, spacing: 3)` — title `.body.weight(selected ? .semibold : .medium)`, preview `.caption.foregroundStyle(.secondary)` 1 line. `.padding(.vertical, 6)`, `.frame(minHeight: 36)`.
- **Selection**: do not use the system blue row. `.listRowBackground(selected ? RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.55)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.7))) : nil)` and keep text `.primary`. Alternative that respects system: `.tint(Color("TalariaTint"))` on the List.
- Running indicator: `Circle().fill(Color("TalariaFill")).frame(width: 7)` with `.symbolEffect(.pulse)` or a 1.4s `opacity 0.35↔1` repeatForever animation.
- Pending approval: `Text("NEEDS YOU").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)`.
- Folder row: 14×11 `RoundedRectangle(cornerRadius: 3)` swatch (accent 45% for active folder, `.quaternary` otherwise) + name.
- Footer (`safeAreaInset(edge: .bottom)`): `Divider()` then two plain-button rows, 32pt each, `.padding(10)`: profile row (`person.crop.rectangle.stack`, name `.callout.weight(.medium)`, `chevron.up.chevron.down .caption`), connection row (7pt status dot · name `.callout.weight(.medium)` / "Connected" `.caption.secondary`, `slider.horizontal.3`). Current build is correct here except size — drop from ~17pt to `.callout`.

## 3. Chat column
Toolbar: title `.headline` · status `Label("Working · 48s", systemImage: "circle.fill")` `.caption .secondary` with the dot in `TalariaFill` · spacer · one `Button(systemImage: "rectangle.on.rectangle")` `.buttonStyle(.glass)`. **Remove the `…` button and the Talaria capsule from this toolbar** — the lockup lives in the sidebar only.
- Transcript container: `.frame(maxWidth: 760).padding(.horizontal, 36).padding(.top, 24)`, `LazyVStack(spacing: 26)`.
- Role label: `HStack(spacing: 8)` — for Hermes, the template mark at 16pt in accent; for You, nothing. Text `.caption.weight(.semibold).foregroundStyle(.secondary)`.
- Body text: `.body` with `.lineSpacing(5)`.
- Reasoning: `DisclosureGroup("Thought for 9s")` `.font(.callout).foregroundStyle(.secondary)`.
- **Tool card** (replaces the grey rounded text blob):
```swift
VStack(spacing: 0) {
  ForEach(rows) { row in
    HStack(spacing: 10) {
      row.done ? Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
               : ProgressView().controlSize(.mini)
      Text(row.tool).font(.callout.weight(.semibold))
      Text(row.argument).font(.callout).foregroundStyle(.secondary).lineLimit(1)
      Spacer()
      Text(row.trailing).font(.caption).foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 12).frame(height: 34)
    if row.id != rows.last?.id { Divider().opacity(0.6) }
  }
}
.background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
.overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.8)))
.shadow(color: .black.opacity(0.05), radius: 2, y: 1)
```
  Terminal output inside a tool card: `.font(.system(.caption, design: .monospaced))` on `Color(nsColor: .textBackgroundColor)` — **not** the large grey block currently shown.
- Streaming cursor: `RoundedRectangle(cornerRadius: 1).fill(Color("TalariaFill")).frame(width: 7, height: 14)` pulsing 1s, appended after the last text run.

### Composer
Keep `talariaGlass(cornerRadius: 26)`. Contents:
- `TextEditor` `.font(.body)`, min height 76, placeholder "Message Hermes…" `.foregroundStyle(.tertiary)`.
- Bottom row `HStack(spacing: 4)`: `paperclip` 34×34 plain · `ellipsis` 34×34 plain · **model pill** · `Spacer()` · Send/Stop.
- Model pill: `Menu { … } label: { Label("claude-sonnet-4.5 · High", systemImage: "chevron.down") }` `.font(.caption).menuStyle(.button).buttonStyle(.plain)` with `.padding(.horizontal, 10).frame(height: 26).background(.white.opacity(0.5), in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.7)))`. **Not** `.bordered` — the current outlined grey pill is wrong.
- Send/Stop: `.buttonStyle(.glassProminent).tint(Color("TalariaFill")).foregroundStyle(.white)`, `.frame(minWidth: 52, minHeight: 36)`. Label `Label("Stop", systemImage: "stop.fill")` / `Label("Send", systemImage: "arrow.up")` `.font(.callout.weight(.semibold))`. Currently renders empty — check `.labelStyle`.

## 4. Inspector
Header row 52pt, `.padding(.horizontal, 10)`:
- **Capsule tab pills, not a segmented control.** Three `Button`s "Files" / "Sources" / "Terminal", `.font(.callout.weight(selected ? .semibold : .regular))`, `.frame(height: 28).padding(.horizontal, 12)`; selected: `.background(.white.opacity(0.6), in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.8)))`; unselected: `.foregroundStyle(.secondary)`. Count badge: `Text("10").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)`.
- Drop the "Workspace view" label.
- File tree: `List` with `.listStyle(.plain)` and `.scrollContentBackground(.hidden)`, rows `.font(.callout)`, 18pt indent per level, chevrons `.caption2.tertiary`, file glyph `doc` 9pt. Selected file row: white 55% `RoundedRectangle(8)` + "NEW" `.caption2.weight(.semibold)` accent badge. Show the tree **relative to the session CWD**, not the absolute `/var/folders/…` path — put the CWD in a `.caption .secondary` line only if it fits on one line, else omit.
- Preview card: `.padding(.horizontal, 12)`, `RoundedRectangle(10)` white 60% + white 80% stroke. Header row `.caption .secondary` "itinerary.md · Rendered · live". Body `.callout` rendered Markdown (`MarkdownMessage`). Fills remaining height.
- **Status** section (`.padding(12)`): header `Text("Status").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)` — no "Ready" on the right. Rows `.callout`: done `checkmark.square` accent, current `ProgressView().controlSize(.mini)` + `.weight(.semibold)`, pending `square` `.tertiary`. One row per todo, no sub-caption.

## 5. Glass modifier update
```swift
func talariaGlass(cornerRadius: CGFloat = 20, interactive: Bool = false) -> some View
// fallback branch: .background(.white.opacity(0.55), in: shape)
//                  .overlay(shape.strokeBorder(.white.opacity(0.9)))
//                  .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
```
Keep the Reduce Transparency branch as is.

## 6. Acceptance checklist
- [ ] Desktop wallpaper visibly tints the sidebar and inspector; chat column is the most opaque
- [ ] Lockup is bare mark + serif "Talaria" in the sidebar toolbar, nothing in the chat toolbar
- [ ] Body text 13pt, sidebar rows 13/10, toolbar controls ≤30pt tall
- [ ] Selected session row is white-glass, text dark — no system blue
- [ ] Tool calls render as stacked rows in a card, terminal output monospaced caption
- [ ] Inspector uses three capsule pills; Status has no "Ready" label
- [ ] Send/Stop shows icon + label on a `#3B7DDD` capsule
- [ ] Reduce Transparency → all glass becomes opaque `windowBackgroundColor`
