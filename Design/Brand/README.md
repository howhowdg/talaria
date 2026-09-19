# Talaria identity and native materials

## Approved identity

The [design handoff](../handoff/README.md), its [brand reference](../handoff/screens/mac-4b-brand-mark.png), and the [hierarchy specifications](../handoff/hierarchy/README.md) define the current identity: a winged sandal, blue accents, and a New York semibold wordmark.

Both the Mac and iOS launcher icons now use the supplied **full-detail white sandal** on the handoff's **#1F5FB8 blue**. The artwork is copied unchanged from `Design/handoff/assets/talaria-mark-white.png`. Its original 1024×1024 transparent canvas supplies the spacing; no extra inset or baked-in rounded rectangle is added.

The shared Icon Composer document leaves the fine white lines opaque, without a glass distortion or cast shadow on the foreground. The OS supplies the native enclosure, lighting, and appearance variants. The former green wing is retired from the launcher.

## Assets

- `../../Apps/Shared/Talaria.icon`: the single Icon Composer source used by both application targets.
- `../../Apps/Shared/Talaria.icon/Assets/talaria-mark-white.png`: unchanged full-detail handoff foreground for launcher icons.
- `talaria-app-icon.png`: preview exported from the compiled Mac fallback `.icns`, also displayed in the repository README.
- `talaria-app-icon-ios.png`: iOS 27 default appearance rendered by Apple's Icon Composer tool.
- `../../Sources/HermesUI/Resources/TalariaAssets.xcassets/TalariaMark.imageset`: supplied SVG used as an accent-tinted template inside the app.
- `talaria-wing.png`: retained only as an archive of the earlier identity.

| Use | Color |
| --- | --- |
| Launcher background, light links and in-app mark | `#1F5FB8` |
| Prominent buttons and running indicators | `#3B7DDD` |
| Dark appearance links and in-app mark | `#7FB0F0` |
| Needs you | `#B8640A` light / `#E8A24A` dark |

Use the full-detail PNG for the launcher and the vector mark for in-app labels and controls, as specified by the handoff. Do not substitute the archived green artwork or the old icon PNG bundled inside the original handoff's `Design/Brand` folder.

## Build and verify

Build with Xcode 27. Both targets set `ASSETCATALOG_COMPILER_APPICON_NAME = Talaria` and include the shared `.icon` document as a resource. No separate competing AppIcon catalog is needed. Xcode produces native appearance renditions and older-system fallback icons.

Mac verification extracts `Talaria.icns` from the compiled application with `iconutil`; iOS verification inspects the compiled `Talaria60x60@2x.png` and primary-icon metadata. The iOS simulator install updates the existing app in place.

Liquid Glass stays on native controls and floating chrome in the app. Older systems use native material/button fallbacks; accessibility settings retain the existing opaque surfaces and reduced motion.

## Historical generation record — retired green wing

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
