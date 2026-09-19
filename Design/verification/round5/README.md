# Round 5 — Mac transcript bubbles

Verified 18 September 2026 against the user's round-5 specification. The checked-in and supplied hierarchy HTML still contain the earlier stacked turns; the round-5 message is authoritative.

These PNGs are **2× SwiftUI ImageRenderer renders of the actual MacTranscriptTurn component**, with synthetic content. They are not screenshots of a running app or real Hermes conversations. The canvas has a 760pt transcript plus 36pt side insets; the narrow variant has a 500pt transcript. They cover short and wrapped user turns, assistant turns, worker styling, separate cards, and a streaming caret.

- `bubbles-light-2x.png`: 760pt column, light appearance.
- `bubbles-dark-2x.png`: same content in dark appearance.
- `bubbles-opaque-2x.png`: opaque assistant surfaces, using a component preview override without changing system accessibility settings.
- `bubbles-dark-opaque-2x.png`: dark opaque surface uses the existing #22252B token to retain readable light text.
- `bubbles-narrow-2x.png`: 500pt column, wrapping and right-edge alignment.
- `bubbles-rich-2x.png`: outgoing Markdown colors, including white links, list markers, quotes, inline code and code labels. ImageRenderer does not capture the nested native horizontal code scroll view; its live rendering remains to be checked.

The 760pt column proposes at most 592.8pt to the padded outgoing bubble and 668.8pt to the assistant row (28pt avatar + 10pt gap + 630.8pt content). Short outgoing bubbles keep their intrinsic width and share the same right edge. Continuous corner radii are 16/16/5/16pt for outgoing text and 5/16/16/16pt for assistant text. Turn spacing is 22pt; card spacing is 8pt.

Spec clarification: the explicit `avatar.padding(.top, 14)` is implemented. With the 10pt label and 8pt label/bubble gap, its centre is slightly higher than the separate “28px below the bubble's top” verification sentence implies. Both conditions cannot be satisfied by that HStack. The supplied SwiftUI layout takes precedence pending a design correction.

Tool cards attach only to the preceding assistant in chronological order. Requests, request receipts and Home references have session ownership but no message owner in the current data model; they align below the transcript without inventing historical message associations. Worker styling requires explicit delegated lineage and the delegated-tasks feature flag; this design pass does not enable backend delegation.

Timestamp labels use the gateway's optional numeric timestamp. Missing timestamps remain absent; no clock values are fabricated. Assistant names come from the connection, not personal constants.

Validation: 219 Swift tests pass, including five timestamp compatibility cases and two chronology/grouping cases. Mac Debug, Mac Release and iOS Simulator builds were checked. Live app interaction, nested Activity-request scrolling and window-compositor screenshots remain blocked while the Mac is locked.
