import SwiftUI

/// Shared settings metrics from the handoff. Phone rows expand for Dynamic Type.
enum S {
    static let rowHeight: CGFloat = 34
    static let rowInset: CGFloat = 12
    static let cardRadius: CGFloat = 10
    static let sectionGap: CGFloat = 22
    static let labelToCard: CGFloat = 8
    static let cardToFooter: CGFloat = 8
    static let pageInset: CGFloat = 20
}

struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.06))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .accessibilityHidden(true)
    }
}

struct SettingsCard<Rows: View>: View {
    @ViewBuilder var rows: () -> Rows
    var body: some View {
        _VariadicView.Tree(SettingsCardLayout()) { rows() }
            .background(TalariaStyle.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: S.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: S.cardRadius).stroke(.primary.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
    }
}

private struct SettingsCardLayout: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != children.last?.id { Hairline() }
            }
        }
    }
}

struct SettingsSection<Rows: View>: View {
    let title: String
    var footer: String?
    let rows: () -> Rows
    init(_ title: String, footer: String? = nil, @ViewBuilder rows: @escaping () -> Rows) {
        self.title = title; self.footer = footer; self.rows = rows
    }
    var body: some View {
        VStack(alignment: .leading, spacing: S.labelToCard) {
            Text(title).font(settingsFont(11, .semibold)).foregroundStyle(.secondary)
                .padding(.leading, 2).accessibilityAddTraits(.isHeader)
            SettingsCard(rows: rows)
            if let footer {
                Text(footer).font(settingsFont(11.5)).foregroundStyle(.secondary)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
        }
    }
}

struct SettingsRow<Control: View>: View {
    let label: String
    let detail: String?
    let tall: Bool
    let control: () -> Control
    init(_ label: String, detail: String? = nil, tall: Bool = false, @ViewBuilder control: @escaping () -> Control) {
        self.label = label; self.detail = detail; self.tall = tall; self.control = control
    }
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(settingsFont(13))
                if let detail { Text(detail).font(settingsFont(11.5)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            control().font(settingsFont(12.5)).labelsHidden()
        }
        #if os(macOS)
        .frame(minHeight: S.rowHeight, maxHeight: tall ? nil : S.rowHeight)
        #else
        .frame(minHeight: 48)
        #endif
        .padding(.horizontal, S.rowInset).padding(.vertical, tall ? 8 : 0)
    }
}

struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: S.sectionGap, content: content)
                .padding(.init(top: 18, leading: S.pageInset, bottom: 18, trailing: S.pageInset))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsSheet<Content: View, Footer: View>: View {
    let title: String
    let width: CGFloat
    let content: () -> Content
    let footer: () -> Footer
    init(_ title: String, width: CGFloat = 460,
         @ViewBuilder content: @escaping () -> Content, @ViewBuilder footer: @escaping () -> Footer) {
        self.title = title; self.width = width; self.content = content; self.footer = footer
    }
    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(settingsFont(13.5, .semibold))
                .frame(maxWidth: .infinity).frame(height: 44).accessibilityAddTraits(.isHeader)
            Hairline()
            SettingsPage(content: content)
            Hairline()
            HStack(spacing: 10, content: footer)
                .font(settingsFont(12)).controlSize(.regular)
                .frame(height: 52).padding(.horizontal, S.pageInset)
        }
        #if os(macOS)
        .frame(width: width)
        .background(TalariaStyle.cardSurface.opacity(0.92)).background(.ultraThinMaterial)
        .modifier(SettingsSheetCorners())
        #else
        .background(TalariaStyle.solidControlSurface)
        .presentationDragIndicator(.visible)
        #endif
    }
}

#if os(macOS)
private struct SettingsSheetCorners: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.presentationCornerRadius(12) }
        else { content }
    }
}
#endif

struct ValueField: View {
    @Binding var text: String
    var mono = true
    var action: (title: String, symbol: String, run: () -> Void)?
    var body: some View {
        HStack(spacing: 0) {
            TextField("", text: $text).textFieldStyle(.plain)
                .font(settingsFont(12.5, design: mono ? .monospaced : .default))
                .padding(.horizontal, 8).frame(maxWidth: .infinity)
            if let action {
                Hairline(vertical: true)
                Button(action: action.run) { Label(action.title, systemImage: action.symbol)
                    .font(settingsFont(11.5, .medium)).foregroundStyle(TalariaStyle.accent) }
                    .buttonStyle(.plain).padding(.horizontal, 8)
            }
        }
        #if os(macOS)
        .frame(height: 24)
        #else
        .frame(minHeight: 44)
        #endif
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.primary.opacity(0.08)))
    }
}

private func settingsFont(_ size: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
    #if os(macOS)
    .system(size: size, weight: weight, design: design)
    #else
    .system(size >= 13 ? .body : .footnote, design: design).weight(weight)
    #endif
}
