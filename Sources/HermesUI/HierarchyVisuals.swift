import SwiftUI
import HermesCore

/// Metrics shared by the hierarchy's result, organisation and activity surfaces.
enum H {
    #if os(macOS)
    static let mobile = false
    static let inset: CGFloat = 36
    static let radius: CGFloat = 12
    static let rowTitle: CGFloat = 12.5
    static let body: CGFloat = 12.5
    static let meta: CGFloat = 11
    #else
    static let mobile = true
    static let inset: CGFloat = 16
    static let radius: CGFloat = 18
    static let rowTitle: CGFloat = 16
    static let body: CGFloat = 14
    static let meta: CGFloat = 13
    #endif

    static func swatch(_ hex: String) -> Color {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard clean.count == 6, let value = UInt32(clean, radix: 16) else { return TalariaStyle.prominentAccent }
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255)
    }
}

extension View {
    @ViewBuilder func hierarchyFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        #if os(iOS)
        iosFont(size, weight)
        #else
        font(.system(size: size, weight: weight))
        #endif
    }
    func hierarchyCard(opacity: Double = 0.65, radius: CGFloat = H.radius, dashed: Bool = false) -> some View {
        modifier(HierarchySurface(opacity: opacity, radius: radius, dashed: dashed))
    }
}

private struct HierarchySurface: ViewModifier {
    let opacity: Double
    let radius: CGFloat
    let dashed: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduce
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                if !dashed {
                    shape.fill(reduce ? TalariaStyle.solidControlSurface
                               : scheme == .dark ? .white.opacity(0.08) : .white.opacity(opacity))
                }
            }
            .overlay(shape.strokeBorder(dashed ? Color.primary.opacity(0.15)
                : contrast == .increased ? Color.primary.opacity(0.25)
                : .white.opacity(scheme == .dark ? 0.12 : 0.8),
                style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : [])))
            .shadow(color: .black.opacity(dashed ? 0 : 0.025), radius: 2, y: 1)
    }
}

struct HierarchySectionLabel: View {
    let title: String
    var attention = false
    var body: some View {
        Text(title.uppercased()).hierarchyFont(H.mobile ? 13 : 10, .semibold)
            .tracking(0.3)
            .foregroundStyle(attention ? TalariaStyle.attention : Color.secondary)
            .padding(.leading, 2).accessibilityAddTraits(.isHeader)
    }
}

struct HierarchyNeedsYouTag: View {
    var body: some View {
        #if os(iOS)
        Label("NEEDS YOU", systemImage: "exclamationmark")
            .iosFont(11, .bold).foregroundStyle(.white)
            .padding(.horizontal, 8).frame(minHeight: 22)
            .background(TalariaStyle.attention, in: Capsule())
        #else
        Label("NEEDS YOU", systemImage: "exclamationmark")
            .font(.system(size: 9.5, weight: .bold)).tracking(0.2)
            .foregroundStyle(TalariaStyle.attention)
        #endif
    }
}

struct HierarchySwatch: View {
    let color: String
    var body: some View {
        RoundedRectangle(cornerRadius: H.mobile ? 4 : 3)
            .fill(H.swatch(color).opacity(0.45))
            .frame(width: H.mobile ? 18 : 16, height: H.mobile ? 14 : 12)
            .accessibilityHidden(true)
    }
}

struct HierarchyEmptyState: View {
    let title: String
    let detail: String
    var symbol: String? = nil
    var body: some View {
        VStack(spacing: 10) {
            if let symbol { Image(systemName: symbol).hierarchyFont(H.mobile ? 34 : 26).foregroundStyle(TalariaStyle.accent) }
            else { TalariaMark(size: H.mobile ? 56 : 40) }
            Text(title).hierarchyFont(H.mobile ? 17 : 15, .semibold)
            Text(detail).hierarchyFont(H.mobile ? 15 : 12).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity).padding(.vertical, H.mobile ? 34 : 44)
    }
}

struct HierarchyCapsuleStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.hierarchyFont(H.mobile ? 14 : 11, .semibold)
            .foregroundStyle(prominent ? .white : TalariaStyle.accent)
            .frame(maxWidth: H.mobile ? .infinity : nil)
            .padding(.horizontal, H.mobile ? 16 : 12)
            .frame(minHeight: H.mobile ? 44 : 28)
            .background(prominent ? TalariaStyle.prominentAccent : Color.primary.opacity(0.035), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(prominent ? 0.25 : 0.6), lineWidth: 1))
            .opacity(!enabled ? 0.45 : configuration.isPressed ? 0.7 : 1)
    }
}

struct HierarchyNotice: View {
    let text: String
    var isError = false
    var body: some View {
        Label(text, systemImage: isError ? "exclamationmark.circle" : "info.circle")
            .hierarchyFont(H.mobile ? 14 : 12).foregroundStyle(isError ? .red : .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).hierarchyCard(opacity: 0.55, radius: H.mobile ? 18 : 10)
    }
}
