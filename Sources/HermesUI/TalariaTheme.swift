#if os(macOS)
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

    // Compact Mac type, revised after the round-three visual review.
    static func f(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s, weight: w) }
    static let wordmark  = Font.system(size: 15, weight: .semibold, design: .serif)
    static let bodySize: CGFloat = 12.5
    static let body      = f(bodySize)
    static let row       = f(12, .medium)
    static let rowSelected = f(12, .semibold)
    static let rowSub    = f(10.5)
    static let section   = f(10, .semibold)
    static let toolbar   = f(12.5, .semibold)
    static let status    = f(10.5)
    static let toolRow   = f(11)
    static let mono      = Font.system(size: 10.5, design: .monospaced)
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
                if reduce || contrast == .increased { shape.fill(Color(nsColor: .windowBackgroundColor)) }
                else { shape.fill(.ultraThinMaterial).overlay(shape.fill(Color.white.opacity(0.55))) }
            }
            .overlay(shape.strokeBorder(contrast == .increased ? .black.opacity(0.35) : T.glassHi, lineWidth: 1))
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
    @Environment(\.accessibilityReduceTransparency) private var reduce
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.background(shape.fill(reduce || contrast == .increased ? Color(nsColor: .windowBackgroundColor) : Color.white.opacity(opacity)))
            .overlay(shape.strokeBorder(contrast == .increased ? .black.opacity(0.35) : .white.opacity(0.8), lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
    }
}
extension View { func controlGlass(_ r: CGFloat, opacity: Double = 0.6) -> some View { modifier(ControlGlass(radius: r, opacity: opacity)) } }

/// Prominent capsule: fill #3B7DDD, white text, inset top highlight, 0 2px 6px rgba(59,125,221,.35)
struct ProminentCapsule: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(T.button).foregroundStyle(.white)
            .padding(.horizontal, 16).frame(height: 36)
            .background(Capsule().fill(T.fill.opacity(isEnabled ? 1 : 0.4)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1).mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)))
            .shadow(color: T.fill.opacity(isEnabled ? 0.35 : 0.14), radius: 3, y: 2)
            .opacity(isEnabled && configuration.isPressed ? 0.85 : 1)
    }
}

#endif
