import SwiftUI

/// Shared identity with precise Mac handoff metrics and adaptive iOS controls.
public enum TalariaStyle {
    /// Reserved for decisions that require the user's attention.
    public static var attention: Color { Color("TalariaAttention", bundle: .module) }
    public static var attentionTint: Color { Color("TalariaAttentionTint", bundle: .module) }
    /// Readable brand tint for links, template images and small labels.
    public static var accent: Color {
        #if os(macOS)
        T.deep
        #else
        Color("TalariaMobileAccent", bundle: .module)
        #endif
    }
    /// The handoff's brighter blue, with a deeper high-contrast fill for white labels.
    public static var prominentAccent: Color {
        #if os(macOS)
        T.fill
        #else
        Color("TalariaFill", bundle: .module)
        #endif
    }

    public static var accentTint: Color {
        #if os(macOS)
        T.tint
        #else
        Color("TalariaTint", bundle: .module)
        #endif
    }

    static var cardSurface: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0x22/255, green: 0x25/255, blue: 0x2B/255, alpha: 1)
                : UIColor(red: 0xF1/255, green: 0xF2/255, blue: 0xF5/255, alpha: 1)
        })
        #endif
    }

    static var cardBorder: Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.18) : .white
        })
        #else
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.18) : .white
        })
        #endif
    }

    static var solidControlSurface: Color {
        #if os(macOS)
        T.opaquePanel
        #else
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0x22/255, green: 0x25/255, blue: 0x2B/255, alpha: 1)
                : UIColor(red: 0xF1/255, green: 0xF2/255, blue: 0xF5/255, alpha: 1)
        })
        #endif
    }
}

public struct TalariaMark: View {
    public var size: CGFloat
    public var color: Color
    public init(size: CGFloat = 40, color: Color = TalariaStyle.accent) {
        self.size = size
        self.color = color
    }
    public var body: some View {
        Image("TalariaMark", bundle: .module)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// System serif resolves to New York on Apple platforms; no bundled font is needed.
public struct TalariaWordmark: View {
    public init() {}

    public var body: some View {
        Text("Talaria")
            #if os(macOS)
            .font(T.wordmark)
            .foregroundStyle(T.ink)
            #else
            .font(.system(.body, design: .serif).weight(.semibold))
            #endif
            .fixedSize()
    }
}

/// The bare 28-point mark and optical alignment from Mac reference 4a.
public struct TalariaBrandLockup: View {
    #if os(iOS)
    @ScaledMetric(relativeTo: .title3) private var markSize: CGFloat = 28
    @ScaledMetric(relativeTo: .title3) private var wordmarkOffset: CGFloat = 2.5
    #endif

    public init() {}

    public var body: some View {
        HStack(spacing: -3) {
            #if os(macOS)
            TalariaMark(size: 26)
            TalariaWordmark().padding(.top, 3)
            #else
            TalariaMark(size: markSize)
            TalariaWordmark().offset(y: wordmarkOffset)
            #endif
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Talaria")
    }
}

extension View {
    /// Reserve this material for floating controls, rather than transcript surfaces.
    func talariaGlass(cornerRadius: CGFloat = 20, interactive: Bool = false) -> some View {
        modifier(TalariaGlass(cornerRadius: cornerRadius, interactive: interactive))
    }

    func talariaProminentButton() -> some View { modifier(TalariaButton(prominent: true)) }
    func talariaSecondaryButton() -> some View { modifier(TalariaButton(prominent: false)) }
}

private struct TalariaGlass: ViewModifier {
    let cornerRadius: CGFloat
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        #if os(macOS)
        content.floatingGlass(cornerRadius)
        #else
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency || contrast == .increased {
            content
                .background(TalariaStyle.solidControlSurface, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.35 : 0.15)))
        } else if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            content
                .background(TalariaStyle.cardSurface.opacity(0.55), in: shape)
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(TalariaStyle.cardBorder.opacity(0.9)))
                .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
        }
        #endif
    }
}

private struct TalariaButton: ViewModifier {
    let prominent: Bool

    @ViewBuilder func body(content: Content) -> some View {
        #if os(macOS)
        if prominent {
            content.buttonStyle(ProminentCapsule()).controlSize(.regular)
        } else {
            content.buttonStyle(SecondaryCapsule()).controlSize(.regular)
        }
        #else
        if #available(iOS 26.0, macOS 26.0, *) {
            if prominent {
                sized(content)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .tint(TalariaStyle.prominentAccent)
            } else {
                sized(content)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    #if os(macOS)
                    .tint(nil as Color?)
                    .foregroundStyle(.primary)
                    #endif
            }
        } else {
            if prominent {
                sized(content)
                    .buttonStyle(.borderedProminent)
                    .tint(TalariaStyle.prominentAccent)
            } else {
                sized(content).buttonStyle(.bordered)
            }
        }
        #endif
    }

    @ViewBuilder private func sized(_ content: Content) -> some View {
        #if os(iOS)
        content.controlSize(.large)
        #else
        content.controlSize(.regular)
        #endif
    }
}

#if os(macOS)
private struct SecondaryCapsule: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(T.button).foregroundStyle(T.ink)
            .padding(.horizontal, 16).frame(height: 36)
            .controlGlass(18, opacity: 0.6)
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.85 : 1)
    }
}

extension View {
    func talariaWindowBackground() -> some View { modifier(TalariaWindowBackground()) }
}

private struct TalariaWindowBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            if reduceTransparency || contrast == .increased {
                content.containerBackground(TalariaStyle.solidControlSurface, for: .window)
            } else {
                content.containerBackground(.thinMaterial, for: .window)
            }
        } else if reduceTransparency || contrast == .increased {
            content.background(TalariaStyle.solidControlSurface)
        } else {
            content.background(.thinMaterial)
        }
    }
}
#endif
