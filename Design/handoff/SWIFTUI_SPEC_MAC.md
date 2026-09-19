# Talaria Mac — complete implementation spec (no interpretation required)

Source of truth: `Talaria Mac.dc.html#4a` / `screens/mac-4a-chat-workspace.png` (that PNG is 2× — the window is **1180×760 pt**). Screenshots you send back are also 2× — compare at the same scale.

Every value below is a **point** size. Use `.font(.system(size:weight:))` exactly as written — **do not** use text styles (`.body`, `.title3`…), `.controlSize(.large)`, or `@ScaledMetric`. If a value isn't listed, it's 0.

---

## 1. `TalariaTheme.swift` — paste verbatim

```swift
import SwiftUI

enum T {
    // Colour
    static let fill    = Color(red: 0x3B/255, green: 0x7D/255, blue: 0xDD/255)   // #3B7DDD
    static let deep    = Color(red: 0x1F/255, green: 0x5F/255, blue: 0xB8/255)   // #1F5FB8
    static let tint    = fill.opacity(0.16)
    static let ink     = Color(red: 0x1A/255, green: 0x1C/255, blue: 0x1A/255)   // #1A1C1A
    static let ink2    = Color.black.opacity(0.55)
    static let ink3    = Color.black.opacity(0.45)
    static let ink4    = Color.black.opacity(0.35)
    static let hair    = Color.black.opacity(0.06)                               // separators
    static let glassHi = Color.white.opacity(0.90)                               // 1pt border on glass
    static let sideBG  = Color.white.opacity(0.28)
    static let chatBG  = Color.white.opacity(0.60)
    static let rowSel  = Color.white.opacity(0.55)
    static let card    = Color.white.opacity(0.55)
    static let field   = Color.black.opacity(0.05)

    // Type (points)
    static func f(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s, weight: w) }
    static let wordmark  = Font.system(size: 16, weight: .semibold, design: .serif)   // New York
    static let body      = f(13.5)          // transcript text, lineSpacing 5
    static let row       = f(13, .medium)   // sidebar row title (semibold when selected)
    static let rowSub    = f(11.5)
    static let section   = f(11, .semibold) // "Today", "Status"
    static let toolbar   = f(13.5, .semibold)
    static let status    = f(11.5)
    static let toolRow   = f(12)
    static let mono      = Font.system(size: 11.5, design: .monospaced)
    static let pill      = f(11.5)
    static let button    = f(13, .semibold)
    static let tab       = f(12)
    static let tree      = f(12)

    // Layout (points)
    static let sidebarW: CGFloat = 240, inspectorW: CGFloat = 290
    static let toolbarH: CGFloat = 52
    static let contentMaxW: CGFloat = 760, composerMaxW: CGFloat = 808
    static let chatInset: CGFloat = 36
}

/// Floating glass (composer, pills, round buttons). Exact CSS equivalent:
/// background rgba(255,255,255,.55); border 1px rgba(255,255,255,.9);
/// box-shadow inset 0 1px 0 #fff, 0 10px 30px rgba(10,25,50,.14)
struct FloatingGlass: ViewModifier {
    var radius: CGFloat
    var shadow: Bool = true
    @Environment(\.accessibilityReduceTransparency) private var reduce
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                if reduce { shape.fill(Color(nsColor: .windowBackgroundColor)) }
                else { shape.fill(.ultraThinMaterial).overlay(shape.fill(Color.white.opacity(0.55))) }
            }
            .overlay(shape.strokeBorder(T.glassHi, lineWidth: 1))
            .overlay(shape.inset(by: 1).strokeBorder(.white, lineWidth: 1).mask(
                LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)))   // inset top highlight
            .shadow(color: Color(red: 10/255, green: 25/255, blue: 50/255).opacity(shadow ? 0.14 : 0), radius: 15, y: 10)
    }
}
extension View { func floatingGlass(_ r: CGFloat, shadow: Bool = true) -> some View { modifier(FloatingGlass(radius: r, shadow: shadow)) } }

/// Small glass control (toolbar buttons, inspector tab pills, model pill):
/// rgba(255,255,255,.5–.7) fill, 1px white border, inset 1px white, 0 1px 2px rgba(0,0,0,.08)
struct ControlGlass: ViewModifier {
    var radius: CGFloat; var opacity: Double = 0.6
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.background(shape.fill(Color.white.opacity(opacity)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.8), lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
    }
}
extension View { func controlGlass(_ r: CGFloat, opacity: Double = 0.6) -> some View { modifier(ControlGlass(radius: r, opacity: opacity)) } }

/// Prominent capsule: fill #3B7DDD, white text, inset top highlight, 0 2px 6px rgba(59,125,221,.35)
struct ProminentCapsule: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(T.button).foregroundStyle(.white)
            .padding(.horizontal, 16).frame(height: 36)
            .background(Capsule().fill(T.fill))
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1).mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)))
            .shadow(color: T.fill.opacity(0.35), radius: 3, y: 2)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
```

## 2. Window

```swift
WindowGroup { HermesRootView(model: model) }
    .windowStyle(.hiddenTitleBar)
    .windowToolbarStyle(.unified(showsTitle: false))
    .defaultSize(width: 1180, height: 760)
```
Root:
```swift
HStack(spacing: 0) {
    Sidebar().frame(width: T.sidebarW)
    Divider().overlay(T.hair)
    ChatColumn().frame(maxWidth: .infinity)
    Divider().overlay(T.hair)
    Inspector().frame(width: T.inspectorW)
}
.ignoresSafeArea(.container, edges: .top)         // we draw our own 52pt toolbars
.containerBackground(.thinMaterial, for: .window)
```
Use a plain `HStack`, **not** `NavigationSplitView` — the split view injects its own toolbar heights and column materials, which is why the title bar and search field keep landing in the wrong place.

## 3. Sidebar (240 pt)

```swift
VStack(spacing: 0) {
    // ── toolbar 52pt ──
    HStack(spacing: 8) {
        Spacer().frame(width: 70)                         // room for traffic lights (they overlay here)
        HStack(spacing: -3) {
            Image("TalariaMark").renderingMode(.template).resizable().scaledToFit()
                .frame(width: 28, height: 28).foregroundStyle(T.deep)
            Text("Talaria").font(T.wordmark).foregroundStyle(T.ink).padding(.top, 3)
        }
        Spacer()
        Button { newConversation() } label: {
            Image(systemName: "square.and.pencil").font(.system(size: 15, weight: .medium)).foregroundStyle(T.deep)
                .frame(width: 30, height: 30)
        }.buttonStyle(.plain).controlGlass(9, opacity: 0.7)
    }
    .padding(.horizontal, 14).frame(height: T.toolbarH)

    // ── search 28pt, radius 8 (NOT a capsule) ──
    HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(T.ink3)
        TextField("Find a conversation", text: $search).textFieldStyle(.plain).font(T.f(12))
    }
    .padding(.horizontal, 9).frame(height: 28)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.field))
    .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 10)

    // ── list ──
    ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
            SectionLabel("Today")
            ForEach(today) { SessionRow($0) }
            SectionLabel("Yesterday").padding(.top, 8)
            ForEach(yesterday) { SessionRow($0) }
            SectionLabel("Folders").padding(.top, 8)
            ForEach(folders) { FolderRow($0) }
        }.padding(.horizontal, 8)
    }

    // ── footer ──
    Divider().overlay(T.hair)
    VStack(spacing: 6) {
        FooterRow(icon: "person.crop.rectangle.stack", title: profileName, trailing: "chevron.up.chevron.down")
        FooterRow(dot: connected ? T.fill : T.ink3, title: hostName, subtitle: connected ? "Connected" : "Disconnected", trailing: "slider.horizontal.3")
    }.padding(.horizontal, 12).padding(.vertical, 10)
}
.background(T.sideBG)
```
Pieces:
```swift
func SectionLabel(_ s: String) -> some View {
    Text(s).font(T.section).foregroundStyle(T.ink3).padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
}
struct SessionRow: View {           // 8×10 padding, radius 8
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title).font(selected ? T.f(13, .semibold) : T.row).foregroundStyle(T.ink).lineLimit(1)
                Spacer(minLength: 0)
                if running { Circle().fill(T.fill).frame(width: 7, height: 7).modifier(Pulse()) }
                if needsInput { Text("NEEDS YOU").font(T.f(10, .semibold)).foregroundStyle(T.deep) }
            }
            if !preview.isEmpty { Text(preview).font(T.rowSub).foregroundStyle(T.ink2).lineLimit(1) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.rowSel)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.7)))
                    .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
            }
        }
        .contentShape(Rectangle())
    }
}
struct FolderRow: View {            // 7×10 padding
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(active ? T.fill.opacity(0.45) : Color.black.opacity(0.18)).frame(width: 14, height: 11)
            Text(name).font(T.f(13)).foregroundStyle(T.ink)
            if let branch { Text(branch).font(T.f(11)).foregroundStyle(T.ink3) }
        }.padding(.horizontal, 10).padding(.vertical, 7)
    }
}
struct FooterRow: View {            // 4×6 padding, 32pt
    var body: some View {
        HStack(spacing: 9) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            if let icon { Image(systemName: icon).font(.system(size: 12)).foregroundStyle(T.ink3) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(T.f(12.5, .medium)).foregroundStyle(T.ink).lineLimit(1)
                if let subtitle { Text(subtitle).font(T.f(11)).foregroundStyle(T.ink2) }
            }
            Spacer()
            Image(systemName: trailing).font(.system(size: trailing.hasPrefix("chevron") ? 9 : 12)).foregroundStyle(T.ink3)
        }.padding(.horizontal, 6).padding(.vertical, 4).frame(minHeight: 32)
    }
}
struct Pulse: ViewModifier {        // opacity .35↔1, 1.4s
    @State private var on = false
    func body(content: Content) -> some View {
        content.opacity(on ? 1 : 0.35).onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { on = true } }
    }
}
```
Empty state (no sessions): keep `ContentUnavailableView` but wrap in `.font(T.f(13))` and set the title to `T.f(13, .semibold)`, description `T.f(12)` `T.ink2`; icon `.font(.system(size: 28))` `T.ink3`.

## 4. Chat column

```swift
VStack(spacing: 0) {
    // ── toolbar 52pt ──
    HStack(spacing: 10) {
        Text(title).font(T.toolbar).foregroundStyle(T.ink).lineLimit(1)
        HStack(spacing: 6) {
            Circle().fill(running ? T.fill : T.ink3).frame(width: 6, height: 6).modifier(running ? Pulse() : nil)
            Text(running ? "Working · \(elapsed)" : "Ready").font(T.status).foregroundStyle(T.ink2)
        }
        Spacer()
        Button { popOut() } label: { Image(systemName: "rectangle.on.rectangle").font(.system(size: 12)).foregroundStyle(T.ink2).frame(width: 30, height: 30) }
            .buttonStyle(.plain).controlGlass(15, opacity: 0.5)
    }
    .padding(.horizontal, 12).frame(height: T.toolbarH)
    Divider().overlay(T.hair)

    // ── transcript ──
    ScrollView {
        LazyVStack(alignment: .leading, spacing: 26) { ForEach(messages) { MessageView($0) } }
            .frame(maxWidth: T.contentMaxW)
            .padding(.horizontal, T.chatInset).padding(.top, 26)
            .frame(maxWidth: .infinity)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
        Composer()
            .frame(maxWidth: T.composerMaxW)
            .padding(.horizontal, T.chatInset).padding(.top, 14).padding(.bottom, 18)
            .frame(maxWidth: .infinity)
    }
}
.background(T.chatBG)
```
Message pieces:
```swift
// role label
HStack(spacing: 8) {
    if role == .assistant { Image("TalariaMark").renderingMode(.template).resizable().scaledToFit().frame(width: 16, height: 16).foregroundStyle(T.deep) }
    Text(role == .user ? "You" : "Hermes").font(T.f(11, .semibold)).foregroundStyle(T.ink2)
}
// body text
MarkdownMessage(text).font(T.body).lineSpacing(5).foregroundStyle(T.ink)
// inline code: font mono 12, background black .06, padding h5 v1, radius 4
// reasoning
DisclosureGroup { … } label: { Text("Thought for \(secs)s").font(T.f(12)).foregroundStyle(T.ink2) }
// streaming cursor appended after last run
RoundedRectangle(cornerRadius: 1).fill(T.fill).frame(width: 7, height: 14).modifier(Pulse())
```
Tool card (one per contiguous group of tool calls):
```swift
VStack(spacing: 0) {
    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
        HStack(spacing: 10) {
            if row.done { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(T.deep).frame(width: 12) }
            else { ProgressView().controlSize(.mini).frame(width: 12) }
            Text(row.tool).font(T.f(12, .semibold)).foregroundStyle(T.ink)
            Text(row.summary).font(row.isPath ? T.mono : T.toolRow).foregroundStyle(T.ink2).lineLimit(1)
            Spacer()
            Text(row.trailing).font(T.toolRow).foregroundStyle(T.ink3)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        if i < rows.count - 1 { Divider().overlay(T.hair) }
    }
    if let terminal = terminalOutput {      // dark block, only for terminal tools
        Text(terminal).font(T.mono).foregroundStyle(Color(red: 0xD8/255, green: 0xDD/255, blue: 0xE6/255)).lineSpacing(4)
            .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0x1A/255, green: 0x1C/255, blue: 0x22/255))
    }
}
.background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.card))
.overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.8)))
.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
```
`row.summary` rules: `read_file`/`write_file` → the path (mono); `terminal` → the command (mono); `web_search` → the query; any other tool → first string argument, max 60 chars; never raw JSON. `row.trailing`: line count, `+298`, `4 sources`, `running`, or empty.

### Composer — radius 26, floating glass with the big shadow
```swift
VStack(spacing: 10) {
    ZStack(alignment: .topLeading) {
        if draft.isEmpty { Text("Message Hermes…").font(T.body).foregroundStyle(T.ink4).padding(.horizontal, 4).padding(.top, 2) }
        TextEditor(text: $draft).font(T.body).scrollContentBackground(.hidden)
            .frame(minHeight: 36, maxHeight: 140).fixedSize(horizontal: false, vertical: true)
    }
    HStack(spacing: 4) {
        IconButton("paperclip")                                   // 34×34 plain, glyph 14pt T.ink2
        IconButton("ellipsis")
        Menu { … } label: {
            HStack(spacing: 6) { Text("\(model) · \(reasoning)").font(T.pill); Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
                .foregroundStyle(Color.black.opacity(0.65)).padding(.horizontal, 10).frame(height: 26)
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).controlGlass(13, opacity: 0.5)
        Spacer()
        Button(action: sendOrStop) {
            Label(running ? "Stop" : "Send", systemImage: running ? "stop.fill" : "arrow.up")
        }.buttonStyle(ProminentCapsule())
    }
}
.padding(.top, 14).padding(.horizontal, 14).padding(.bottom, 10)
.floatingGlass(26)
```
The `.floatingGlass(26)` shadow — `rgba(10,25,50,.14)`, radius 15, y 10 — is the "beautiful shadow". `controlSize` must stay `.regular`.

## 5. Inspector (290 pt)

```swift
VStack(spacing: 0) {
    // ── tabs 52pt: three capsule pills, NOT a segmented control ──
    HStack(spacing: 2) {
        ForEach(Tab.allCases) { tab in
            Button { selected = tab } label: {
                HStack(spacing: 5) {
                    Text(tab.label).font(selected == tab ? T.f(12, .semibold) : T.tab).foregroundStyle(selected == tab ? T.ink : T.ink2)
                    if let n = tab.badge { Text("\(n)").font(T.f(10, .semibold)).foregroundStyle(T.deep) }
                }.padding(.horizontal, 12).frame(height: 28)
            }.buttonStyle(.plain)
             .background { if selected == tab { Capsule().fill(Color.white.opacity(0.6)).overlay(Capsule().strokeBorder(Color.white.opacity(0.8))).shadow(color: .black.opacity(0.08), radius: 1, y: 1) } }
        }
        Spacer()
    }.padding(.horizontal, 10).frame(height: T.toolbarH)
    Divider().overlay(Color.white.opacity(0.5))

    // ── file tree ──
    VStack(alignment: .leading, spacing: 0) { ForEach(visibleNodes) { TreeRow($0) } }
        .padding(.horizontal, 12).padding(.vertical, 10)

    // ── preview card fills the rest ──
    VStack(spacing: 0) {
        HStack(spacing: 8) { Text(previewName).font(T.f(11)).foregroundStyle(T.ink2); Spacer(); Text(previewMode).font(T.f(11)).foregroundStyle(T.ink2) }
            .padding(.horizontal, 10).padding(.vertical, 7)
        Divider().overlay(T.hair)
        ScrollView { MarkdownMessage(previewText).font(T.f(12)).lineSpacing(4).padding(14) }
    }
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.6)))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.8)))
    .padding(.horizontal, 12).frame(maxHeight: .infinity)

    // ── status ──
    VStack(alignment: .leading, spacing: 8) {
        Text("Status").font(T.section).foregroundStyle(T.ink3)
        ForEach(todos) { t in
            HStack(spacing: 8) {
                switch t.state {
                case .done:    Image(systemName: "checkmark.square").font(.system(size: 12)).foregroundStyle(T.deep)
                case .current: ProgressView().controlSize(.mini)
                case .pending: Image(systemName: "square").font(.system(size: 12)).foregroundStyle(T.ink3)
                }
                Text(t.title).font(t.state == .current ? T.f(12, .semibold) : T.f(12)).foregroundStyle(t.state == .pending ? T.ink2 : T.ink)
            }
        }
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
}
.background(T.sideBG)
```
```swift
struct TreeRow: View {   // 12pt, line-height 1.9 → row height 23, indent 18/level
    var body: some View {
        HStack(spacing: 6) {
            if node.isDir { Image(systemName: node.expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(T.ink3).frame(width: 9) }
            else { RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.35)).frame(width: 9, height: 11) }
            Text(node.name).font(node.isRoot ? T.f(12, .semibold) : T.tree).foregroundStyle(T.ink).lineLimit(1)
            Spacer(minLength: 0)
            if let badge = node.badge { Text(badge).font(T.f(10, .semibold)).foregroundStyle(badge == "M" ? T.ink2 : T.deep) }
        }
        .padding(.leading, CGFloat(node.depth) * 18).frame(height: 23)
        .padding(.horizontal, node.selected ? 6 : 0)
        .background { if node.selected { RoundedRectangle(cornerRadius: 6).fill(T.rowSel).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.7))).padding(.horizontal, -6) } }
    }
}
```
Inspector empty state (no session): mark 40pt `T.ink3`, "Select a conversation" `T.f(13, .semibold)`, description `T.f(12)` `T.ink2`, max width 220, centred.

## 6. Welcome (no connection) — chat column
Mark 76pt in `T.deep` · "Hermes, made native." `T.f(26, .medium)` · subtitle `T.f(13.5)` `T.ink2` · buttons: "Start local Hermes" `ProminentCapsule` (36pt tall, **not** 60), "Connect to a gateway" `.buttonStyle(.plain)` with `T.button` `T.ink` + `.padding(.horizontal, 16).frame(height: 36).controlGlass(18, opacity: 0.6)` · caption `T.f(11.5)` `T.ink3`. Stack spacing 12, max width 320.

## 7. Assets
- `TalariaMark` — import `assets/talaria-mark.svg`, *Preserve Vector Data* on, *Render As* Template.
- Delete the old `TalariaWing`, `TalariaAccent` (volt), and any `Color("TalariaAccent")` usage → `T.deep`.

## 8. Verification (send back a 2× screenshot at 1180×760)
Measure in the screenshot at 2×: transcript body glyph x-height ≈ 14px (13.5pt), sidebar row title ≈ 13pt, toolbar 104px tall, composer bottom row 36pt button = 72px, search field 56px tall with 16px corner radius (radius 8pt — corners must be visibly squarer than the composer's).
- [ ] No text uses `.body/.title/.headline` etc. — grep the target for `\.font\(\.(body|title|headline|callout|caption|subheadline|footnote)` → 0 hits in HermesUI
- [ ] No `.controlSize(.large)` in Mac code paths
- [ ] Compose button is a 30pt rounded square (radius 9) with a `T.deep` pencil, top-right of the sidebar toolbar
- [ ] Search field is a rounded rectangle, radius 8, height 28, fill black 5%
- [ ] Composer has the 10pt-offset, 15pt-blur navy shadow and a 1pt white top highlight
- [ ] Sidebar footer "Connected/Disconnected" fully visible at 760pt window height
