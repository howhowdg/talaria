#if os(macOS)
import SwiftUI

enum T {
    // Colour
    static let fill    = adaptive(0x3B7DDD, 0x7FB0F0)
    // Outgoing bubbles retain the brand blue in both appearances with white text.
    static let outgoingBubble = Color(red: 59.0 / 255, green: 125.0 / 255, blue: 221.0 / 255)
    static let deep    = adaptive(0x1F5FB8, 0x5B93E0)
    static let attention = TalariaStyle.attention
    static let attentionTint = TalariaStyle.attentionTint
    static let tint    = fill.opacity(0.16)
    static let ink     = adaptive(0x1A1C1A, 0xF2F3F5)
    static let ink2    = adaptive(0x000000, 0xFFFFFF, lightAlpha: 0.55, darkAlpha: 0.60)
    static let ink3    = adaptive(0x000000, 0xFFFFFF, lightAlpha: 0.45, darkAlpha: 0.45)
    static let ink4    = adaptive(0x000000, 0xFFFFFF, lightAlpha: 0.35, darkAlpha: 0.40)
    static let hair    = adaptive(0x000000, 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.08)
    static let glassHi = adaptive(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.90, darkAlpha: 0.12)
    static let sideBG  = adaptive(0xFFFFFF, 0x000000, lightAlpha: 0.28, darkAlpha: 0.28)
    static let chatBG  = adaptive(0xFFFFFF, 0x000000, lightAlpha: 0.60, darkAlpha: 0.20)
    static let rowSel  = adaptive(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.55, darkAlpha: 0.12)
    static let card    = adaptive(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.55, darkAlpha: 0.08)
    static let field   = adaptive(0x000000, 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.08)
    static let failed  = adaptive(0xC8402F, 0xE0705F)
    static let panelEdge = adaptive(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.5, darkAlpha: 0.08)
    static let opaquePanel = adaptive(0xF1F2F5, 0x22252B)

    static func adaptive(_ light: UInt32, _ dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    // Compact Mac type, revised after the round-three visual review.
    static func f(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s, weight: w) }
    static let wordmark  = Font.system(size: 15, weight: .semibold, design: .serif)
    static let bodySize: CGFloat = 12.5
    static let body      = f(bodySize)
    static let row       = f(12, .medium)
    static let rowSelected = f(12, .semibold)
    static let rowSub    = f(11)
    static let section   = f(10, .semibold)
    static let toolbar   = f(13, .semibold)
    static let status    = f(11)
    static let toolRow   = f(11)
    static let mono      = Font.system(size: 11, design: .monospaced)
    static let pill      = f(10.5)
    static let button    = f(12, .semibold)
    static let tab       = f(11)
    static let tree      = f(11)

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
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                if reduce || contrast == .increased { shape.fill(T.opaquePanel) }
                else { shape.fill(.ultraThinMaterial).overlay(shape.fill(T.card)) }
            }
            .overlay(shape.strokeBorder(contrast == .increased ? .black.opacity(0.35) : T.glassHi, lineWidth: 1))
            .overlay(shape.inset(by: 1).strokeBorder(T.glassHi, lineWidth: 1).mask(
                LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)))   // inset top highlight
            .shadow(color: Color(red: 10/255, green: 25/255, blue: 50/255).opacity(shadow ? 0.14 : 0), radius: 15, y: 10)
    }
}
extension View { func floatingGlass(_ r: CGFloat, shadow: Bool = true) -> some View { modifier(FloatingGlass(radius: r, shadow: shadow)) } }

/// Small glass control (toolbar buttons, inspector tab pills, model pill):
/// rgba(255,255,255,.5–.7) fill, 1px white border, inset 1px white, 0 1px 2px rgba(0,0,0,.08)
struct ControlGlass: ViewModifier {
    var radius: CGFloat; var opacity: Double = 0.6
    @Environment(\.accessibilityReduceTransparency) private var reduce
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.background(shape.fill(reduce || contrast == .increased ? T.opaquePanel : T.adaptive(0xFFFFFF, 0xFFFFFF, lightAlpha: opacity, darkAlpha: 0.08)))
            .overlay(shape.strokeBorder(contrast == .increased ? T.ink3 : T.glassHi, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
    }
}
extension View { func controlGlass(_ r: CGFloat, opacity: Double = 0.6) -> some View { modifier(ControlGlass(radius: r, opacity: opacity)) } }

/// Prominent capsule: fill #3B7DDD, white text, inset top highlight, 0 2px 6px rgba(59,125,221,.35)
struct ProminentCapsule: ButtonStyle {
    var height: CGFloat = 32
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(T.button).foregroundStyle(.white)
            .padding(.horizontal, 16).frame(height: height)
            .background(Capsule().fill(T.fill.opacity(isEnabled ? 1 : 0.4)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1).mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)))
            .shadow(color: T.fill.opacity(isEnabled ? 0.35 : 0.14), radius: 3, y: 2)
            .opacity(isEnabled && configuration.isPressed ? 0.85 : 1)
    }
}

#endif
