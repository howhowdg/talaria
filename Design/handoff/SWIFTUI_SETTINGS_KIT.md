# Talaria Mac — Settings surface kit

One layout system for every form-like surface: Conversation settings, global Settings (all tabs), Skill detail, Schedule editor, Onboarding steps, approval sheets, the inspector Status block. Never `Form`, never `GroupBox`, never `List` for settings. Build from these five pieces only.

## 1. Primitives (`Sources/UI/Settings/`)

```swift
enum S {                                  // settings metrics — nothing else may define these
  static let rowHeight: CGFloat = 34
  static let rowInset: CGFloat = 12
  static let cardRadius: CGFloat = 10
  static let sectionGap: CGFloat = 22
  static let labelToCard: CGFloat = 8
  static let cardToFooter: CGFloat = 8
  static let pageInset: CGFloat = 20
}

/// 1pt divider. Inside cards / between bars only. Never darker than 6% black.
struct Hairline: View {
  var vertical = false
  var body: some View {
    Rectangle().fill(Color.black.opacity(0.06))
      .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
  }
}

/// Section = label + card of rows + optional footer.
struct SettingsSection<Rows: View>: View {
  let title: String
  var footer: String? = nil
  @ViewBuilder var rows: () -> Rows
  var body: some View {
    VStack(alignment: .leading, spacing: S.labelToCard) {
      Text(title).font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color.black.opacity(0.45)).padding(.leading, 2)
      SettingsCard(rows: rows)
      if let footer {
        Text(footer).font(.system(size: 11.5)).lineSpacing(3)
          .foregroundStyle(Color.black.opacity(0.45)).padding(.horizontal, 2)
      }
    }
  }
}

/// Card = white, radius 10, 8% stroke, soft shadow. Rows are separated by Hairline automatically.
struct SettingsCard<Rows: View>: View {
  @ViewBuilder var rows: () -> Rows
  var body: some View {
    _VariadicView.Tree(_CardLayout()) { rows() }
      .background(Color.white)
      .clipShape(RoundedRectangle(cornerRadius: S.cardRadius, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: S.cardRadius, style: .continuous)
        .stroke(Color.black.opacity(0.08), lineWidth: 1))
      .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
  }
}
private struct _CardLayout: _VariadicView_MultiViewRoot {
  func body(children: _VariadicView.Children) -> some View {
    VStack(spacing: 0) {
      ForEach(children) { c in
        c
        if c.id != children.last?.id { Hairline() }
      }
    }
  }
}

/// Row = label left, control right, ONE line, 34pt. Use `.tall` only for multi-line values (paths, descriptions).
struct SettingsRow<Control: View>: View {
  let label: String
  var detail: String? = nil                  // grey secondary text under label (11.5, ink3) — rare
  var tall = false
  @ViewBuilder var control: () -> Control
  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(label).font(.system(size: 13))
        if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(T.ink3) }
      }
      Spacer(minLength: 12)
      control()
    }
    .frame(minHeight: S.rowHeight, maxHeight: tall ? nil : S.rowHeight)
    .padding(.horizontal, S.rowInset)
    .padding(.vertical, tall ? 8 : 0)
  }
}

/// Page = scrolling stack of sections with 20pt inset. Used inside sheets and Settings tabs alike.
struct SettingsPage<Content: View>: View {
  @ViewBuilder var content: () -> Content
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: S.sectionGap, content: content)
        .padding(.init(top: 18, leading: S.pageInset, bottom: 18, trailing: S.pageInset))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
```

## 2. Controls that go in the right slot
Always `.labelsHidden()`. One control per row.

| Kind | SwiftUI | Metrics |
|---|---|---|
| Choice (≤8) | `Picker(.menu)` | `.controlSize(.small)`, 12.5pt label |
| Choice (long / searchable) | `ValueField` + inline **Browse** | see §3 |
| On/off | `Toggle(.switch)` | `.controlSize(.mini)` |
| Short text / number | `TextField` | 24pt tall, radius 6, fill `black .04`, stroke `black .08`, 12.5pt |
| Path / ID / code | `Text` monospaced 12.5 `T.ink2` | read-only; tap → copy |
| Numeric range | `Slider` + `Text` value 12 mono | slider max width 160 |
| Action inside a card | `Button(.plain)` 12.5 medium `T.deep` | text only, no fill, right-aligned |
| Navigation | `Text` value `T.ink3` + `chevron.right` 9 semibold `T.ink3` | whole row is the button |
| Status | 8pt dot + 12.5 text | dot `T.fill` / `black .25` / `#C8402F` |

Never inside a card: filled buttons, captions, headers, spacers, primary actions, disclosure groups.

```swift
/// Field with a trailing inline action (Browse / Reveal / Test…).
struct ValueField: View {
  @Binding var text: String
  var mono = true
  var action: (title: String, symbol: String, run: () -> Void)? = nil
  var body: some View {
    HStack(spacing: 0) {
      TextField("", text: $text).textFieldStyle(.plain)
        .font(.system(size: 12.5, design: mono ? .monospaced : .default))
        .padding(.horizontal, 8).frame(maxWidth: .infinity)
      if let a = action {
        Hairline(vertical: true)
        Button { a.run() } label: {
          Label(a.title, systemImage: a.symbol).labelStyle(.titleAndIcon)
            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(T.deep)
        }.buttonStyle(.plain).padding(.horizontal, 8)
      }
    }
    .frame(height: 24)
    .background(Color.black.opacity(0.04))
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.black.opacity(0.08)))
  }
}
```

## 3. Containers

**Sheet** (`SettingsSheet`) — width 460 (or 560 for editors with a code/prompt area), `.presentationCornerRadius(12)`, bg `Color.white.opacity(0.92)` over `.ultraThinMaterial`.
- Title bar 44pt, title 13.5 semibold centred, `Hairline` below.
- Body: `SettingsPage`.
- Footer 52pt, `Hairline` above: left = optional plain-text utility (`Refresh models`, `Reset to defaults`) 12pt `T.ink2`; right = `Cancel` + primary. Primary is `.borderedProminent`, tint `T.fill`, `.keyboardShortcut(.defaultAction)`, disabled until dirty. Cancel = `.cancelAction`.
- Verb on the primary names the effect: **Apply** (live change), **Save** (persists), **Create**, **Allow** (approval). Never "Done" on a sheet that changes state; "Done" only when the sheet has no primary action, and then it's the sole right button.

**Settings window** — `TabView`-free: 180pt sidebar list (General · Providers · Profiles · Skills · Schedules · Advanced) in the same glass as the main sidebar; right side is a `SettingsPage` per tab, no footer — every control saves on change. Window 760×520, title 13.5 semibold in the toolbar.

**Inspector blocks** (Status, Sources) — a `SettingsSection` with no footer; card fill `Color.white.opacity(0.55)` instead of solid white because it sits on glass. Row height 28, label 12, control 12.

**Onboarding step** — a single `SettingsSection` centred in a 520pt column, headline 20 medium above it (the only place a >13.5pt text appears), footer text as the section footer, primary **Continue** in a 52pt footer.

## 4. Copy rules
- Section titles: sentence case nouns (`Model`, `Hermes profile`, `Working directory`). No colons.
- Row labels ≤ 3 words. Explanations go in the footer, never in the label or a detail line, unless the row is unintelligible without it.
- One footer per section, ≤ 2 sentences, states scope + consequence ("Applies to this conversation only — stop the current run first").
- Show the current value *in the control*; never a separate "Current X" row.

## 5. Migration checklist (per surface)
1. Replace `Form`/`GroupBox`/`List` with `SettingsPage` + `SettingsSection`.
2. Every row becomes `SettingsRow(label) { control }` — if it doesn't fit the one-line rule, it's a footer, a sheet, or doesn't belong.
3. Move any filled button out of cards into the footer; pick the verb from §3.
4. Delete duplicate value displays.
5. Grep: `Form\(`, `GroupBox`, `\.font\(\.(title|headline|body|caption` → 0 hits in `Settings/`, `Sheets/`, `Onboarding/`, `Inspector/`.
6. Screenshot at 2× and check: rows 68px, section label 22px cap height, card corners 20px, hairlines lighter than any text.

## 6. Apply now
- `ConversationSettingsSheet` — per `SWIFTUI_FIXES_ROUND4.md`.
- `SettingsWindow` all tabs.
- `ToolApprovalSheet` — one section "Request" (Tool · Command mono · Scope), footer = risk note, primary **Allow**, secondary **Allow always** as left utility, **Deny** as Cancel slot.
- `ScheduleEditorSheet` (560) — sections Trigger · Task · Delivery.
- Inspector `Status` block.
