# Talaria Mac — round 3 fixes (against 17:57 screenshot)

Structure is right. These are finish issues. Apply exactly.

## 1. Fonts — weights and sizes are still heavier/larger than spec
Root cause: some views still use text styles or `.bold()`/`.semibold` where spec says `.medium`/`.regular`, and the `2×` screenshot shows ~15pt body text (spec 13.5).
- Grep and fix: `\.font\(\.(body|title|title2|title3|headline|callout|caption|caption2|subheadline|footnote)` → 0 hits. `\.bold\(\)` → 0 hits. `\.fontWeight\(\.bold\)` → 0 hits.
- Sidebar row title: `.medium` (600 only when **selected**). Currently both rows are semibold — the unselected "Native integration smoke" must be `.medium`.
- Transcript body: `T.body` = 13.5 **regular**, `lineSpacing(5)`, colour `T.ink`. Not `.medium`.
- Role labels "You"/"Hermes": 11 **semibold**, `T.ink2` — correct, keep.
- Section labels "Today"/"Folders"/"Status": 11 semibold `T.ink3` — currently too dark; use `Color.black.opacity(0.45)` exactly.
- Inspector tab labels: 12 regular for unselected, 12 semibold for selected. "Sources"/"Terminal" currently render medium.
- Toolbar title: 13.5 semibold — correct.
- Check the window isn't being rendered with `.dynamicTypeSize` or `NSApp` text scaling > 100%. In `HermesMacApp` add `.dynamicTypeSize(.medium)` on the root view to pin it.

## 2. Compose button — wrong shape and fill
Current: 40pt-ish capsule/rounded square with a blue tinted fill and a bordered look.
Spec: **30×30**, `RoundedRectangle(cornerRadius: 9, style: .continuous)`, fill `Color.white.opacity(0.7)`, 1pt border `Color.white.opacity(0.8)`, shadow `black .08, radius 1, y 1`. Glyph `square.and.pencil` at `.system(size: 15, weight: .medium)` in `T.deep`. **No** blue background, **no** `.bordered`/`.glass` button style — `.buttonStyle(.plain)` + `.controlGlass(9, opacity: 0.7)`.

## 3. Lockup — vertical centring and position
- The lockup must be vertically centred in the 52pt toolbar: wrap the whole toolbar `HStack` in `.frame(height: 52)` and make sure nothing has extra `.padding(.top)`. Currently it sits ~4pt high.
- Wordmark baseline: `Text("Talaria")` gets `.padding(.top, 3)` (spec) — verify it's 3, not 0. The optical centre of the sandal should line up with the x-height centre of "Talaria".
- Horizontal: with the sidebar at 240 the lockup starts right after the traffic-light reservation (70pt) — `Spacer().frame(width: 70)` then the lockup, then `Spacer()`, then the compose button. In the current build the lockup is centred in the sidebar; it should be **left-aligned after the traffic lights**, not centred. (In full-screen mode traffic lights hide — keep the 70pt reservation anyway so the layout doesn't jump.)
- Mark size 28, `HStack(spacing: -3)`.

## 4. Panel dividers — too dark
Replace every `Divider()` between columns with a 1pt line of `Color.white.opacity(0.5)` (on glass, white hairlines read as edges; black ones read as borders):
```swift
Rectangle().fill(Color.white.opacity(0.5)).frame(width: 1)
```
Inside panels (toolbar bottom, footer top, tool-card rows) use `Color.black.opacity(0.06)`. Nothing darker than 6% black anywhere.

## 5. Sidebar rows — selected vs unselected
Only the selected row gets the white-glass background. Currently **both** Today rows have it. Unselected rows: no background, title `.medium`.

## 6. Search field
Height 28, radius 8, fill `Color.black.opacity(0.05)`, placeholder 12pt `T.ink3`, glyph 11pt. Current is ~36 tall with a 13–14pt placeholder. Horizontal margin 12, top 2, bottom 10.

## 7. Composer
- Field placeholder 13.5 regular `T.ink4`.
- Model pill: 26 tall, radius 13, fill `white .5`, text 11.5 `black .65` — current is ~32 tall with 13pt text.
- Send disabled state: fill `T.fill.opacity(0.4)` with white text; keep the arrow. Current uses a paler blue with a darker label — fine, but the pill must stay 36 tall (currently ~40).
- Icon buttons: 34×34, glyph 14pt `T.ink2` — current glyphs ~17pt.

## 8. Inspector
- Preview card should start directly under the tree with `.padding(.top, 6)` and fill to the Status block (`.frame(maxHeight: .infinity)`) — correct now, but the header row is 2 lines ("native-smoke.txt / Recorded"): make it one `HStack`, 11pt, with `Spacer()` between name and mode.
- Empty-preview copy: body 12 `T.ink2`; the mono path 11 `T.ink3`; "Recorded content may differ…" 11 `T.ink3`.
- Tree row 23 tall, 12pt; folder chevrons 8pt semibold `T.ink3`. Currently ~15pt text.

## 9. Verify at 2× (screenshot the 1180×760 window)
- Toolbar 104px; compose button 60×60 px with 18px corners; search 56px tall, 16px corners
- Body text cap height ≈ 19px (13.5pt); sidebar row 26px; section label 15px
- Column dividers are lighter than the panel behind them, never darker
- Only one sidebar row has a background
