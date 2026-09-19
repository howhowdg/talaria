# Talaria Mac — round 4: Conversation settings sheet

> Generalised in `SWIFTUI_SETTINGS_KIT.md` — build the primitives there first, then this sheet is ~40 lines of composition.

Reference: `Talaria Mac.dc.html` → 5a. Rebuild the sheet; don't patch the Form.

## What's wrong
- `Form(.grouped)` turns captions, the Browse button and the Apply button into rows.
- "Current model" and "Model ID" both show the same string.
- Labels stacked over values; ~15pt text; 17pt bold title; ~24pt sheet radius.
- Primary action ("Apply to conversation") is in the body; footer says "Done".

## Structure
No `Form`. Plain `VStack(spacing: 0)` in a sheet `.frame(width: 460)`, `.presentationCornerRadius(12)`. Background `Color.white.opacity(0.92)` over `.ultraThinMaterial`.

```swift
VStack(spacing: 0) {
  Text("Conversation settings").font(.system(size: 13.5, weight: .semibold))
    .frame(height: 44).frame(maxWidth: .infinity)
  hairline
  VStack(alignment: .leading, spacing: 22) {
    section("Model") {
      row("Provider") { Picker("", selection: $provider) { … }.labelsHidden().controlSize(.small) }
      hairline
      row("Model") { modelField }
      hairline
      row("Reasoning") { Picker("", selection: $reasoning) { … }.labelsHidden().controlSize(.small) }
    } footer: "Pick a listed model or type any model ID this provider accepts. Changes apply to this conversation only — finish or stop the current run first."
    section("Hermes profile") {
      row("Profile") { Picker(…) }
      hairline
      row("Working directory") { Text(path).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(T.ink2) }
      hairline
      row("Auto-approve read-only tools") { Toggle("", isOn: $autoApprove).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
    }
  }.padding(.init(top: 18, leading: 20, bottom: 6, trailing: 20))
  Spacer().frame(height: 12)
  hairline
  HStack {
    Button { refresh() } label: { Label("Refresh models", systemImage: "arrow.clockwise") }
      .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(T.ink2)
    Spacer()
    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
    Button("Apply") { apply() }.keyboardShortcut(.defaultAction).disabled(!isDirty)
  }.controlSize(.regular).frame(height: 52).padding(.horizontal, 20)
}
```

## Pieces
- `hairline` = `Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1)`.
- `section(title) { rows } footer:` — title 11 semibold `Color.black.opacity(0.45)`, `.padding(.leading, 2)`; rows in a card: `Color.white`, `RoundedRectangle(10, .continuous)`, 1pt stroke `black .08`, shadow `black .04, radius 1, y 1`; footer 11.5 regular `black .45`, `lineSpacing(3)`, 8pt below the card.
- `row(label) { control }` — `HStack { Text(label).font(.system(size: 13)); Spacer(); control }`, `.frame(height: 34)`, `.padding(.horizontal, 12)`. Label and control on ONE line, always.
- `modelField` — single `TextField` (prefilled with the current model, 12.5 monospaced) in a 24pt `RoundedRectangle(6)` fill `black .04`, stroke `black .08`; trailing inline `Button("Browse", systemImage: "list.bullet")` 11.5 medium `T.deep`, `.buttonStyle(.plain)`, separated by a 1pt `black .08` vertical line. Field takes remaining width (`.frame(maxWidth: .infinity)`).
- Popups: `.controlSize(.small)`, `.pickerStyle(.menu)`, `.labelsHidden()`. No `.bordered` prominent styles.

## Remove
- The "Current model" row (the field is prefilled — that *is* the current model).
- In-body "Apply to conversation" button; the "Done" button.
- All `.font(.title*)`, `.headline`, `.body`. `\.bold\(\)` → 0 hits (same as round 3).

## Behaviour
- Apply enabled only when something changed; disabled while a run is active, with the footer note doing the explaining (no alert).
- Esc = Cancel, Return = Apply.

## Verify at 2×
Sheet 920px wide; title bar 88px; rows 68px; section label 22px cap; footer 104px; Apply 56px tall, 14px corners; sheet corners 24px (12pt).
