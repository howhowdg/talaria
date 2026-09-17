import SwiftUI

/// A small shared palette; the system owns the navigation materials and typography.
public enum TalariaStyle {
    public static var accent: Color { Color("TalariaAccent", bundle: .module) }
    public static let volt = Color(red: 206 / 255, green: 250 / 255, blue: 69 / 255)
    public static let ink = Color(red: 24 / 255, green: 30 / 255, blue: 23 / 255)

    static var solidControlSurface: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}

public struct TalariaMark: View {
    public var size: CGFloat
    public init(size: CGFloat = 40) { self.size = size }
    public var body: some View {
        Image("TalariaWing", bundle: .module)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(TalariaStyle.accent)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
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
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency || contrast == .increased {
            content
                .background(TalariaStyle.solidControlSurface, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.35 : 0.15)))
        } else if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

private struct TalariaButton: ViewModifier {
    let prominent: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if prominent {
                sized(content)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .tint(TalariaStyle.volt)
                    .foregroundStyle(TalariaStyle.ink)
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
                    .tint(TalariaStyle.volt)
                    .foregroundStyle(TalariaStyle.ink)
            } else {
                sized(content).buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder private func sized(_ content: Content) -> some View {
        #if os(iOS)
        content.controlSize(.large)
        #else
        content.controlSize(.regular)
        #endif
    }
}
