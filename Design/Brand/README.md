# Talaria identity and native materials

## Current in-app identity — handoff v2

The [v2 handoff](../handoff/README.md), refined by the [native Mac correction spec](../handoff/SWIFTUI_SPEC_MAC.md), is the source of truth for the redesign. `TalariaMark.imageset` contains the supplied `talaria-mark.svg` unchanged, preserves its vector representation, and renders it as an accent-tinted template. The native wordmark uses New York semibold with the handoff’s optical spacing. The blue palette replaces the original green in the application interface.

| Use | Color |
| --- | --- |
| Prominent buttons and running indicators | `#3B7DDD` |
| Light appearance links, mark and small labels | `#1F5FB8` |
| Dark appearance links, mark and small labels | `#7FB0F0` |

The Mac workspace uses the exact light palette and point sizes in `TalariaTheme.swift`, with custom glass modifiers behind the existing `TalariaStyle` interface. The iOS catalog retains adaptive colors, high-contrast variants and Dynamic Type under `TalariaMobileAccent`. Activity pulses respect Reduce Motion. The Mac workspace follows screen 4a; the iPhone floating-chrome redesign is a subsequent step.

The Icon Composer app icon still uses the earlier wing artwork described below; replacing the launcher icon is separate from this in-app mark/layout pass.

## Earlier identity and existing launcher icon

The following records the original artwork, not the current interface palette.

Talaria uses a swept wing, suggesting the winged sandals of Hermes. The highlighter-green panels borrow the color and curved surface rhythm of the Talaria running shoe. The mark is original artwork, with no Nike wordmark or Swoosh.

## Assets

- `talaria-wing.png`: original 1254 × 1254 transparent PNG, preserved without retouching. This is the reusable logo foreground.
- `talaria-app-icon.png`: Xcode-rendered Mac fallback icon preview, exported from the compiled `.icns`; the app itself uses the dynamic icon catalog on current systems.
- `../../Apps/Shared/Talaria.icon`: shared Icon Composer document for Mac, iPhone and iPad. A graphite background and independent wing layer let the OS render its glass, highlights, enclosure and appearance variants.
- `../../Sources/HermesUI/Resources/TalariaAssets.xcassets`: in-app template mark and adaptive accent colors.

The source PNG is raster artwork. It is not an editable vector master. The in-app mark uses the alpha silhouette as a template, while the app icon retains the green panel detail.

Actual build screenshots: [Mac welcome](../../research/screenshots/talaria-mac-glass-welcome.png), [Mac composer](../../research/screenshots/talaria-mac-glass-composer.png), [iPhone light](../../research/screenshots/talaria-ios-glass-light.png), [iPhone dark](../../research/screenshots/talaria-ios-glass-dark.png). The Mac composer screenshot uses an isolated local test gateway; its visible text is an unsent draft at capture time.

## Palette

| Use | Color |
| --- | --- |
| Wing and prominent control fill | Volt `#CEFA45` |
| Icon background / prominent control text | Graphite `#181E17` |
| Light appearance links and template mark | Deep green `#3F5B0A` |
| Dark appearance links and template mark | Volt `#CEFA45` |

High-contrast accent variants are supplied in the color catalog. Conversation text uses semantic system colors and fonts. Bright volt is a filled accent with dark text, rather than small text on white.

## Interface

Keep Liquid Glass in the control layer: native toolbars, buttons and the floating message composer. Preserve quiet, ordinary surfaces behind messages, reasoning, tools and forms. Native navigation and sheets inherit the current OS treatment automatically. A compact iPhone sidebar includes a direct connection action instead of an empty list.

The shared controls use the system glass APIs on iOS/macOS 26 and later, including OS 27 refinements. Older runtimes receive system material and bordered-button fallbacks. Custom glass becomes an opaque semantic surface when Reduce Transparency or Increase Contrast is enabled. The original version added no custom motion; the new activity indicators add a reduced-motion-aware pulse. Controls use semantic fonts; primary iPhone actions and attachment removal have generous touch targets.

Build with Xcode 27. Both targets use the same `.icon` document. The explicit `type: file` resource entry in `project.yml` preserves the document as a bundle with the installed XcodeGen 2.44.1. Regenerate the project with `xcodegen generate` after changing its build settings. Asset compilation produces the runtime variants and older-OS fallback icons.

## Generation record

Generated with the built-in `image_gen` tool in **generate** mode on 17 September 2026; no fallback CLI or API key was used. The selected output was copied into this project and into its native asset bundles. Source generation: `exec-595557be-55f3-4e30-8b38-22cc39d87247.png`.

Final prompt:

> Use case: logo-brand. Create one final, clean, abstract logo foreground for Talaria, an independent native Mac and iPhone AI assistant. It must work as the foreground layer in an Apple Liquid Glass app icon and as a small monochrome brand mark. Subject: an original compact aerodynamic wing, inspired by the winged sandals of the messenger Hermes. Use three broad, sculpted swept feathers/panels flowing upward to the right from a short elegant curved lower stem. Distinctive silhouette, balanced asymmetry, fluid negative spaces between the three feather shapes. Gentle curved panel geometry and very subtle tonal insets evoke the bright volt panels of the Nike Air Zoom Talaria running shoe, without depicting a shoe or using Nike logos, a Swoosh, any brand text, or any existing logo. Color: saturated highlighter yellow-green / volt #CEFA45, with only small restrained variations in the green panels if needed. Medium: precise flat vector-like graphic, smooth clean edges, solid fills, no photographic texture, no mesh detail, no bevels, no shadows, no lighting, no gloss; the operating system will supply glass effects. Composition: one large mark centered optically in a 1024-by-1024 square transparent canvas, mark fills about 72 percent of width and 66 percent of height, generous clear margins. IMPORTANT: genuine transparent background with alpha, no tile, no rounded-square enclosure, no backdrop, no checkerboard drawn into image. No letters, words, mockup, objects, device frames, or watermark. Quiet, confident, fresh, highly legible at 24 pixels.

The selected result has two broad panels and a curved stem; its actual output dimensions are recorded above.

## References

- [Apple: Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
- [Apple: Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views)
- [Apple: Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Apple: App icons](https://developer.apple.com/design/Human-Interface-Guidelines/app-icons)
- [Apple: Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
