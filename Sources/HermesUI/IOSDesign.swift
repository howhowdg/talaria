#if os(iOS)
import SwiftUI

/// iPhone handoff metrics scale with the reader's preferred text size.
private struct IOSFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight
    init(size: CGFloat, weight: Font.Weight, relativeTo: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: relativeTo)
        self.weight = weight
    }
    func body(content: Content) -> some View { content.font(.system(size: size, weight: weight)) }
}

extension View {
    func iosFont(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo: Font.TextStyle = .body) -> some View {
        modifier(IOSFont(size: size, weight: weight, relativeTo: relativeTo))
    }
    func iosCard(radius: CGFloat = 20, opacity: Double = 0.85) -> some View {
        modifier(IOSCard(radius: radius, opacity: opacity))
    }
}

enum IOSDesign {
    static var background: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(red: 0.065, green: 0.075, blue: 0.095, alpha: 1)
                : UIColor(red: 244/255, green: 244/255, blue: 246/255, alpha: 1)
        })
    }
}

private struct IOSCard: ViewModifier {
    var radius: CGFloat
    var opacity: Double
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background((scheme == .dark ? Color(uiColor: .secondarySystemGroupedBackground) : .white)
                .opacity(reduceTransparency || contrast == .increased ? 1 : opacity), in: shape)
            .overlay(shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.3)
                                        : .white.opacity(scheme == .dark ? 0.12 : 0.9), lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }
}

struct IOSBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                IOSDesign.background
                if !reduceTransparency {
                    RadialGradient(colors: [Color(red: 0.66, green: 0.77, blue: 0.95).opacity(scheme == .dark ? 0.08 : 0.2), .clear],
                                   center: UnitPoint(x: 0, y: 110 / max(1, geometry.size.height)),
                                   startRadius: 0, endRadius: geometry.size.width * 0.95)
                    RadialGradient(colors: [Color(red: 0.95, green: 0.8, blue: 0.69).opacity(scheme == .dark ? 0.045 : 0.22), .clear],
                                   center: UnitPoint(x: 1, y: 160 / max(1, geometry.size.height)),
                                   startRadius: 0, endRadius: geometry.size.width * 0.8)
                    RadialGradient(colors: [Color(red: 0.8, green: 0.74, blue: 0.94).opacity(scheme == .dark ? 0.06 : 0.12), .clear],
                                   center: .bottomTrailing, startRadius: 0, endRadius: geometry.size.width)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct IOSActivityDot: View {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false
    var body: some View {
        Circle().fill(TalariaStyle.prominentAccent).frame(width: 7, height: 7)
            .opacity(!active || reduceMotion || bright ? 1 : 0.35)
            .animation(active && !reduceMotion ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : nil, value: bright)
            .onAppear { bright = active }
            .onChange(of: active) { _, value in bright = value }
            .accessibilityHidden(true)
    }
}

/// Navigation errors stay visible on the originating tab when an open fails.
struct IOSWorkspaceNotice: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text).iosFont(14).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark").frame(width: 44, height: 44)
            }
            .buttonStyle(.plain).accessibilityLabel("Dismiss notice")
        }
        .padding(12).iosCard(radius: 18)
        .accessibilityElement(children: .contain)
    }
}
#endif
