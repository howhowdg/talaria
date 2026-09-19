import Foundation
import SwiftUI

/// Lightweight native Markdown for conversation text, including unfinished
/// fenced code while a reply is streaming. No HTML or web content is executed.
public struct MarkdownMessage: View {
    public let text: String
    public let isStreaming: Bool
    public var fillsWidth: Bool
    public var foregroundColor: Color?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cursorBright = false

    public init(text: String, isStreaming: Bool = false, fillsWidth: Bool = true, foregroundColor: Color? = nil) {
        self.text = text
        self.isStreaming = isStreaming
        self.fillsWidth = fillsWidth
        self.foregroundColor = foregroundColor
    }

    public var body: some View {
        let blocks = MarkdownBlock.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, streaming: isStreaming && index == blocks.count - 1)
            }
            if blocks.isEmpty && isStreaming { TalariaStreamingCursor() }
        }
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        .textSelection(.enabled)
        #if os(macOS)
        .modifier(MacMarkdownRendering())
        #endif
        .animation(isStreaming && !reduceMotion
                   ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : nil, value: cursorBright)
        .onChange(of: isStreaming, initial: true) { _, running in cursorBright = running && !reduceMotion }
        .onChange(of: reduceMotion) { _, reduced in cursorBright = isStreaming && !reduced }
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlock, streaming: Bool) -> some View {
        switch block {
        case .paragraph(let value):
            inline(value, streaming: streaming)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let value):
            inline(value, streaming: streaming)
                #if os(macOS)
                .font(T.f(level == 1 ? 19 : level == 2 ? 15 : T.bodySize, .semibold))
                #else
                .font(level == 1 ? .title2 : level == 2 ? .title3 : .headline)
                #endif
                .fontWeight(.semibold)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .listItem(let marker, let value, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(foregroundColor ?? .secondary).monospacedDigit()
                    .frame(minWidth: 14, alignment: .trailing)
                inline(value, streaming: streaming).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(min(indent, 6)) * 8)
        case .quote(let value):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(.tertiary).frame(width: 3)
                inline(value, streaming: streaming).foregroundStyle(foregroundColor ?? .secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let value):
            VStack(alignment: .leading, spacing: 8) {
                if !language.isEmpty {
                    Text(language)
                        #if os(macOS)
                        .font(T.f(10, .medium)).foregroundStyle(foregroundColor ?? T.ink2)
                        #else
                        .font(TalariaTypography.caption.weight(.medium)).foregroundStyle(.secondary)
                        #endif
                }
                ScrollView(.horizontal) {
                    appendingCursor(to: Text(value.isEmpty ? " " : value), streaming: streaming)
                        #if os(macOS)
                        .font(T.mono)
                        #else
                        .font(.system(.callout, design: .monospaced))
                        #endif
                        .fixedSize(horizontal: true, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 2)
                }
                .accessibilityLabel(language.isEmpty ? "Code" : "\(language) code")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
        case .rule:
            Divider().padding(.vertical, 3)
            if streaming { TalariaStreamingCursor() }
        }
    }

    private func inline(_ value: String, streaming: Bool) -> Text {
        // Full Markdown parsing flattens block spacing in AttributedString;
        // preserve whitespace here and let the surrounding native blocks lay out.
        var parsed = (try? AttributedString(markdown: value, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(value)
        if let foregroundColor { parsed.foregroundColor = foregroundColor }
        #if os(macOS)
        if #available(macOS 15.0, *) {
            var content = Text("")
            for run in parsed.runs {
                var fragment = AttributedString(parsed[run.range])
                if run.inlinePresentationIntent?.contains(.code) == true {
                    fragment.font = .system(size: 11, design: .monospaced)
                    let code = Text(fragment).customAttribute(InlineCodeAttribute())
                    // An em-space at 5pt reserves exactly 5pt at each side,
                    // while keeping the code selectable in the native Text.
                    let padding = Text("\u{2003}").font(.system(size: 5))
                    content = Text("\(content)\(padding)\(code)\(padding)")
                } else {
                    content = Text("\(content)\(Text(fragment))")
                }
            }
            return appendingCursor(to: content, streaming: streaming)
        }
        for run in parsed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            parsed[run.range].font = .system(size: 11, design: .monospaced)
            parsed[run.range].backgroundColor = T.hair
        }
        #endif
        return appendingCursor(to: Text(parsed), streaming: streaming)
    }

    private func appendingCursor(to content: Text, streaming: Bool) -> Text {
        guard streaming else { return content }
        // The inline cursor follows the last rendered run and wraps with it.
        #if os(macOS)
        let cursor = Text(Image(nsImage: Self.cursorImage)).baselineOffset(-2)
            .foregroundColor((foregroundColor ?? T.fill).opacity(reduceMotion || cursorBright ? 1 : 0.35))
        #else
        let cursor = Text("█").font(.system(.body, design: .monospaced))
            .foregroundColor(TalariaStyle.prominentAccent.opacity(reduceMotion || cursorBright ? 1 : 0.35))
        #endif
        return Text("\(content)\(cursor)")
    }

    #if os(macOS)
    /// A vector attachment keeps the 7×14pt cursor in the final text line.
    private static var cursorImage: NSImage {
        let image = NSImage(size: NSSize(width: 7, height: 14), flipped: false) { bounds in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 1, yRadius: 1).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
    #endif
}

#if os(macOS)
@available(macOS 15.0, *)
private struct InlineCodeAttribute: TextAttribute {}

@available(macOS 15.0, *)
private struct InlineCodeRenderer: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                if run[InlineCodeAttribute.self] != nil {
                    let bounds = run.typographicBounds.rect.insetBy(dx: -5, dy: -1)
                    context.fill(Path(roundedRect: bounds, cornerRadius: 4), with: .color(.black.opacity(0.06)))
                }
                context.draw(run)
            }
        }
    }
}

private struct MacMarkdownRendering: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.textRenderer(InlineCodeRenderer())
        } else {
            content
        }
    }
}
#endif

/// Intentionally a small block parser: unknown Markdown remains readable text.
/// Fences are recognized only with at most three leading spaces, as in CommonMark.
private enum MarkdownBlock {
    case paragraph(String)
    case heading(Int, String)
    case listItem(String, String, Int)
    case quote(String)
    case code(String, String)
    case rule

    private struct Fence {
        let character: Character
        let count: Int
        let language: String
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        guard !text.isEmpty else { return [] }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var activeFence: Fence?

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll(keepingCapacity: true)
            }
        }

        for line in lines {
            if let active = activeFence {
                if closesFence(line, active) {
                    blocks.append(.code(active.language, code.joined(separator: "\n")))
                    code.removeAll(keepingCapacity: true)
                    activeFence = nil
                } else { code.append(line) }
                continue
            }
            if let fence = opensFence(line) {
                flushParagraph()
                activeFence = fence
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
            } else if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(.heading(heading.0, heading.1))
            } else if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
            } else if let item = listItem(line) {
                flushParagraph()
                blocks.append(.listItem(item.0, item.1, item.2))
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                let value = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if case .quote(let previous) = blocks.last {
                    blocks[blocks.count - 1] = .quote(previous + "\n" + value)
                } else { blocks.append(.quote(value)) }
            } else { paragraph.append(line) }
        }
        if let active = activeFence {
            // An open fence is expected during streaming; render everything
            // received so far as code without waiting for the closing marker.
            blocks.append(.code(active.language, code.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    private static func opensFence(_ line: String) -> Fence? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let content = line.dropFirst(indent)
        guard let character = content.first, character == "`" || character == "~" else { return nil }
        let count = content.prefix { $0 == character }.count
        guard count >= 3 else { return nil }
        let info = content.dropFirst(count).trimmingCharacters(in: .whitespaces)
        guard character != "`" || !info.contains("`") else { return nil }
        return Fence(character: character, count: count, language: String(info.split(whereSeparator: \.isWhitespace).first ?? ""))
    }

    private static func closesFence(_ line: String, _ fence: Fence) -> Bool {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return false }
        let content = line.dropFirst(indent)
        let count = content.prefix { $0 == fence.character }.count
        return count >= fence.count && content.dropFirst(count).allSatisfy(\.isWhitespace)
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
        return (level, String(rest).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, ["-", "*", "_"].contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> (String, String, Int)? {
        let indent = line.prefix { $0 == " " }.count
        let content = line.dropFirst(indent)
        guard let first = content.first else { return nil }
        if ["-", "+", "*"].contains(first), content.dropFirst().first?.isWhitespace == true {
            return ("•", String(content.dropFirst()).trimmingCharacters(in: .whitespaces), indent)
        }
        let digits = content.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let suffix = content.dropFirst(digits.count)
        guard let separator = suffix.first, separator == "." || separator == ")",
              suffix.dropFirst().first?.isWhitespace == true else { return nil }
        return (String(digits) + ".", String(suffix.dropFirst()).trimmingCharacters(in: .whitespaces), indent)
    }
}
