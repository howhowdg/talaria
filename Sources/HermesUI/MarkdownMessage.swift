import Foundation
import SwiftUI

/// Lightweight native Markdown for conversation text, including unfinished
/// fenced code while a reply is streaming. No HTML or web content is executed.
public struct MarkdownMessage: View {
    public let text: String

    public init(text: String) { self.text = text }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let value):
            inline(value)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let value):
            inline(value)
                .font(level == 1 ? .title2 : level == 2 ? .title3 : .headline)
                .fontWeight(.semibold)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .listItem(let marker, let value, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(.secondary).monospacedDigit()
                    .frame(minWidth: 14, alignment: .trailing)
                inline(value).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(min(indent, 6)) * 8)
        case .quote(let value):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(.tertiary).frame(width: 3)
                inline(value).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let value):
            VStack(alignment: .leading, spacing: 8) {
                if !language.isEmpty {
                    Text(language).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(value.isEmpty ? " " : value)
                        .font(.system(.callout, design: .monospaced))
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
        }
    }

    private func inline(_ value: String) -> Text {
        // Full Markdown parsing flattens block spacing in AttributedString;
        // preserve whitespace here and let the surrounding native blocks lay out.
        let parsed = try? AttributedString(markdown: value, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible))
        return Text(parsed ?? AttributedString(value))
    }
}

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
