#if os(macOS)
import SwiftUI
import HermesCore

/// One conversational turn. Cards share the assistant's content column, but
/// remain separate surfaces rather than inheriting the text bubble's padding.
struct MacTranscriptTurn<Cards: View>: View {
    var message: ChatMessage?
    var assistantName = "Hermes"
    var workerTask: String?
    var userLabel = "YOU"
    /// Allows an opaque preview without changing the Mac's accessibility setting.
    var forceOpaque = false
    @ViewBuilder var cards: Cards
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var isUser: Bool { message?.role == .user }
    private var label: String {
        if isUser {
            guard let date = message?.timestamp else { return userLabel }
            return "\(userLabel) · \(date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))"
        }
        if message?.role == .system { return "SYSTEM" }
        if let workerTask { return "WORKER · \(workerTask.uppercased())" }
        return assistantName.uppercased()
    }
    private var labelInk: Color { (scheme == .dark ? Color.white : .black).opacity(0.5) }
    private var assistantFill: Color {
        if reduceTransparency || forceOpaque { return T.opaquePanel }
        return .white.opacity(scheme == .dark ? 0.10 : 0.75)
    }

    var body: some View {
        MacTranscriptColumnLayout(fraction: isUser ? 0.78 : 0.88, trailing: isUser) {
            if isUser {
                VStack(alignment: .trailing, spacing: 5) {
                    Text(label).font(T.section).foregroundStyle(labelInk).padding(.trailing, 4)
                    if let message { bubble(message) }
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    avatar.padding(.top, 14)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(label).font(T.section).foregroundStyle(labelInk).padding(.leading, 4)
                        if let message {
                            if !message.displayText.isEmpty || message.isStreaming { bubble(message) }
                            if !message.reasoning.isEmpty {
                                DisclosureGroup("Reasoning") {
                                    Text(message.reasoning).font(T.body).lineSpacing(5)
                                        .textSelection(.enabled).padding(.top, 6)
                                }.font(T.f(11)).foregroundStyle(T.ink2)
                            }
                        }
                        cards
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var avatar: some View {
        ZStack {
            if workerTask != nil {
                Circle().fill((scheme == .dark ? Color.white : .black).opacity(0.10))
                Text("⤷").font(T.f(12)).foregroundStyle((scheme == .dark ? Color.white : .black).opacity(0.60))
            } else {
                Circle().fill(.white.opacity(scheme == .dark ? 0.12 : 1))
                    .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                TalariaMark(size: 22, color: scheme == .dark ? .white : T.ink)
            }
        }
        .frame(width: 28, height: 28).accessibilityHidden(true)
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: isUser ? 16 : 5,
            bottomLeadingRadius: 16, bottomTrailingRadius: isUser ? 5 : 16,
            topTrailingRadius: 16, style: .continuous)
        return MarkdownMessage(text: message.displayText, isStreaming: message.isStreaming,
                               fillsWidth: false, foregroundColor: isUser ? .white : nil)
            .font(T.body).lineSpacing(5)
            .foregroundStyle(isUser ? Color.white : message.isError ? T.failed : T.ink)
            .tint(isUser ? .white : T.deep)
            .padding(EdgeInsets(top: 9, leading: 13, bottom: 9, trailing: 13))
            .background(shape.fill(isUser ? T.outgoingBubble : assistantFill))
            .overlay(shape.strokeBorder(isUser ? .clear : .white.opacity(scheme == .dark ? 0.12 : 0.9), lineWidth: 1))
            .shadow(color: .black.opacity(isUser ? 0 : 0.04), radius: 1, y: 1)
    }
}

extension MacTranscriptTurn where Cards == EmptyView {
    init(message: ChatMessage, assistantName: String = "Hermes", workerTask: String? = nil, userLabel: String = "YOU", forceOpaque: Bool = false) {
        self.message = message; self.assistantName = assistantName
        self.workerTask = workerTask; self.userLabel = userLabel; self.forceOpaque = forceOpaque; self.cards = EmptyView()
    }
}

/// Session-owned items have no message ID in the gateway contract. Align them
/// with assistant cards without pretending they belong to a historical turn.
struct MacTranscriptAuxiliary<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        MacTranscriptColumnLayout(fraction: 0.88) {
            content.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 38)
        }
    }
}

/// Proposes a fraction of the actual transcript width, including bubble padding.
/// Unlike a GeometryReader row, this keeps intrinsic height while text streams.
private struct MacTranscriptColumnLayout: Layout {
    let fraction: CGFloat
    var trailing = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(0, proposal.width ?? T.contentMaxW)
        let size = subviews.first?.sizeThatFits(.init(width: width * fraction, height: nil)) ?? .zero
        return CGSize(width: width, height: size.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: trailing ? bounds.maxX : bounds.minX, y: bounds.minY),
            anchor: trailing ? .topTrailing : .topLeading,
            proposal: .init(width: bounds.width * fraction, height: nil))
    }
}

/// Consecutive tool messages remain in order beneath the assistant that issued
/// them. Leading tools get a card-only assistant turn; user/system boundaries
/// never absorb tools from a different turn.
struct MacTranscriptGroup: Identifiable {
    let id: String
    var message: ChatMessage?
    var tools: [ChatMessage]

    static func make(_ messages: [ChatMessage]) -> [Self] {
        var groups: [Self] = []
        for message in messages {
            if message.role == .tool {
                if let last = groups.last, last.message == nil || last.message?.role == .assistant {
                    groups[groups.count - 1].tools.append(message)
                } else {
                    groups.append(Self(id: message.id, message: nil, tools: [message]))
                }
            } else {
                groups.append(Self(id: message.id, message: message, tools: []))
            }
        }
        return groups
    }
}

struct MacTranscriptGroupView: View {
    let group: MacTranscriptGroup
    var assistantName = "Hermes"
    var workerTask: String?
    var userLabel = "YOU"
    var body: some View {
        MacTranscriptTurn(message: group.message, assistantName: assistantName, workerTask: workerTask, userLabel: userLabel) {
            if !group.tools.isEmpty {
                ToolActivityCard(messages: group.tools)
                    .id(group.tools[0].id)
            }
        }
    }
}

struct MacTranscriptMessages: View {
    let messages: [ChatMessage]
    var assistantName = "Hermes"
    var workerTask: String?
    var userLabel = "YOU"
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(MacTranscriptGroup.make(messages)) { group in
                MacTranscriptGroupView(group: group, assistantName: assistantName, workerTask: workerTask, userLabel: userLabel)
            }
        }
    }
}
#endif
