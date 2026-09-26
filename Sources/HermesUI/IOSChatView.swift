#if os(iOS)
import SwiftUI
import HermesCore
import UniformTypeIdentifiers

struct IOSChatView: View {
    @Bindable var model: HermesAppModel
    let state: ConversationState
    var topInset: CGFloat
    var keyboardVisible: Bool
    var composerPlaceholder = "Message Hermes…"
    var isComposerDisabled = false
    var transcriptOpacity: Double = 1
    var contextHeader: AnyView = AnyView(EmptyView())
    var contextFooter: AnyView = AnyView(EmptyView())
    var onBackToActivity: (() -> Void)?
    @State private var showImporter = false
    @State private var importScope: ComposerScope?
    @State private var composerHeight: CGFloat = 52
    @State private var followTail = true
    @State private var visibleMessageID: String?
    @State private var highlightsRequest = false
    @State private var showsActivityReturn = false
    @FocusState private var focused: Bool

    private var bottomInset: CGFloat { keyboardVisible ? 12 : 84 }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            contextHeader
                            ChannelHistoryControls(model: model)
                            if let banner = model.banner { notice(banner) }
                            if state.messages.isEmpty && !model.isPassiveChannel {
                                Text("What are we working on?").iosFont(24, .semibold, relativeTo: .title2)
                                Text("Ask a question, share a file, or start with an idea.")
                                    .iosFont(16).foregroundStyle(.secondary)
                            }
                            ForEach(groups) { group in
                                Group {
                                    if group.isToolGroup {
                                        ToolActivityCard(messages: group.messages)
                                            .frame(maxWidth: min(760, geometry.size.width - 32) * 0.93, alignment: .leading)
                                    } else if let message = group.messages.first {
                                        IOSMessageBubble(message: message, availableWidth: min(760, geometry.size.width - 32))
                                    }
                                }
                                .id(group.id).opacity(transcriptOpacity)
                            }
                            contextFooter
                            ForEach(state.pendingInputs) { input in
                                VStack(alignment: .leading, spacing: 8) {
                                    if showsActivityReturn, input.id == model.activityRequestFocusID,
                                       let onBackToActivity {
                                        Button(action: onBackToActivity) {
                                            Label("Back to Activity", systemImage: "arrow.backward")
                                                .iosFont(13, .semibold).frame(minHeight: 44)
                                        }.buttonStyle(.plain).foregroundStyle(TalariaStyle.accent)
                                    }
                                    InputRequestView(input: input) { answer in await model.answer(input, result: answer) }
                                }
                                .overlay(RoundedRectangle(cornerRadius: 22)
                                    .strokeBorder(highlightsRequest && input.id == model.activityRequestFocusID
                                        ? TalariaStyle.attention.opacity(0.6) : .clear, lineWidth: 2))
                                .id(input.id)
                            }
                            ForEach(model.requestReceipts(for: state.storedID)) { receipt in
                                RequestReceiptView(receipt: receipt)
                                    .id("request-receipt-\(receipt.id)")
                            }
                            // The stack contributes a 14pt gap before this spacer.
                            // Include the optional Latest control so it never covers a request choice.
                            Color.clear.frame(height: max(0, composerHeight + bottomInset + (followTail || !state.pendingInputs.isEmpty ? 0 : 46) - 4))
                                .id("tail").accessibilityHidden(true)
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, 16).padding(.top, topInset)
                        .frame(maxWidth: 792, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .scrollPosition(id: $visibleMessageID, anchor: .top)
                    .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in followTail = false })
                    .onAppear {
                        if model.isPassiveChannel { followTail = false }
                        if let saved = model.place(for: state.storedID).visibleMessageID {
                            followTail = false
                            proxy.scrollTo(saved, anchor: .top)
                        } else { proxy.scrollTo("tail", anchor: .bottom) }
                    }
                    .onChange(of: visibleMessageID) { _, id in
                        if !followTail { model.rememberPlace(id, for: state.storedID) }
                    }
                    .onDisappear {
                        model.rememberPlace(followTail ? nil : visibleMessageID, for: state.storedID)
                    }
                    .onChange(of: state.messages.last) { _, _ in
                        if followTail && !model.isPassiveChannel { proxy.scrollTo("tail", anchor: .bottom) }
                    }
                    .onChange(of: state.pendingInputs.count) { _, _ in if !model.isPassiveChannel { proxy.scrollTo("tail", anchor: .bottom) } }
                    .onChange(of: state.storedID) { _, _ in
                        focused = false
                        if let saved = model.place(for: state.storedID).visibleMessageID {
                            followTail = false
                            proxy.scrollTo(saved, anchor: .top)
                        } else {
                            followTail = !model.isPassiveChannel
                            proxy.scrollTo("tail", anchor: .bottom)
                        }
                    }
                    .task(id: model.activityRequestFocusID) {
                        guard let requestID = model.activityRequestFocusID,
                              state.pendingInputs.contains(where: { $0.id == requestID }) else { return }
                        followTail = false
                        showsActivityReturn = true
                        highlightsRequest = true
                        proxy.scrollTo(requestID, anchor: .top)
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { return }
                        highlightsRequest = false
                        try? await Task.sleep(for: .seconds(8))
                        guard !Task.isCancelled else { return }
                        showsActivityReturn = false
                    }
                    .onChange(of: keyboardVisible) { _, shown in
                        if shown, followTail { proxy.scrollTo("tail", anchor: .bottom) }
                    }
                    VStack(spacing: 10) {
                        if !followTail && state.pendingInputs.isEmpty {
                            Button {
                                followTail = true
                                model.rememberPlace(nil, for: state.storedID)
                                proxy.scrollTo("tail", anchor: .bottom)
                            } label: {
                                Label("Latest", systemImage: "arrow.down").iosFont(12, .medium)
                                    .padding(.horizontal, 14).frame(minHeight: 36)
                            }
                            .buttonStyle(.plain).talariaGlass(cornerRadius: 18, interactive: true)
                        }
                        if !model.isPassiveChannel { composer }
                    }
                    .frame(maxWidth: 792)
                    .padding(.horizontal, 16).padding(.bottom, bottomInset)
                    .background(alignment: .bottom) {
                        LinearGradient(colors: [.clear, IOSDesign.background.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                            .padding(.top, -20).allowsHitTesting(false)
                    }
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard let scope = importScope else { return }
            switch result {
            case .success(let urls): Task { await model.addAttachments(urls, to: scope) }
            case .failure(let error): model.banner = error.localizedDescription
            }
            importScope = nil
        }
        #if DEBUG
        .task(id: model.isLoadingSession) {
            if !model.isLoadingSession,
               ProcessInfo.processInfo.environment["TALARIA_DESIGN_PREVIEW"] == "1",
               ProcessInfo.processInfo.environment["TALARIA_DESIGN_KEYBOARD"] == "1" {
                await Task.yield()
                if model.draft.isEmpty { model.draft = "Skip the dmg files" }
                focused = true
            }
        }
        #endif
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if isSelectedConversation, !model.attachments.isEmpty {
                AttachmentStrip(items: model.attachments) { model.removeAttachment($0) }
                    .padding(.horizontal, 6).padding(.top, 8)
            }
            HStack(alignment: .bottom, spacing: 0) {
                Menu {
                    Button {
                        importScope = model.composerScope
                        showImporter = true
                    } label: { Label("Attach files", systemImage: "paperclip") }
                        .disabled(isComposerDisabled || !isSelectedConversation || !model.canAttach)
                    Button { model.showSessionSettings = true } label: {
                        Label("Model and profile", systemImage: "slider.horizontal.3")
                    }.disabled(!model.isConnected)
                    if !model.attachments.isEmpty {
                        Button("Remove attachments", role: .destructive) {
                            for item in model.attachments { model.removeAttachment(item.id) }
                        }.disabled(model.isSubmitting)
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.secondary).frame(width: 44, height: 44).contentShape(Circle())
                }
                .accessibilityLabel("Attachments and conversation options")
                TextField(canAnswerInComposer ? "Or answer in words…" : composerPlaceholder, text: composerDraft, axis: .vertical)
                    .iosFont(16).lineLimit(1...5).focused($focused)
                    .padding(.vertical, 11).padding(.leading, 2).padding(.trailing, 6)
                    .accessibilityLabel("Message Hermes")
                    .disabled(isComposerDisabled || !isSelectedConversation || !model.isConnected || model.isLoadingSession || model.isSubmitting)
                Button {
                    followTail = true
                    if canAnswerInComposer {
                        let text = model.draft
                        Task { await model.answerPendingText(text) }
                    } else if showsStopButton { Task { await model.stop() } }
                    else { Task { await model.send() } }
                } label: {
                    Group {
                        if showsStopButton { RoundedRectangle(cornerRadius: 3).frame(width: 12, height: 12) }
                        else { Image(systemName: "arrow.up").font(.system(size: 18, weight: .semibold)) }
                    }
                    .foregroundStyle(.white).frame(width: 40, height: 40)
                    .background(TalariaStyle.prominentAccent.opacity(sendEnabled ? 1 : 0.4), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                    .frame(width: 44, height: 44).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!sendEnabled)
                .accessibilityLabel(showsStopButton ? "Stop response" : canAnswerInComposer ? "Send answer" : "Send message")
            }
            .padding(4)
            .frame(minHeight: 52)
            .talariaGlass(cornerRadius: 26, interactive: true)
        }
        .background {
            GeometryReader { size in
                Color.clear.onAppear { composerHeight = size.size.height }
                    .onChange(of: size.size.height) { _, value in composerHeight = value }
            }
        }
    }

    private var isSelectedConversation: Bool { model.selectedID == state.storedID && model.currentHierarchyOwner == state.owner }
    private var composerDraft: Binding<String> {
        Binding(get: { isSelectedConversation ? model.draft : "" }, set: { if isSelectedConversation { model.draft = $0 } })
    }
    private var canAnswerInComposer: Bool { isSelectedConversation && model.canAnswerPendingText }
    private var showsStopButton: Bool { state.isRunning && !canAnswerInComposer }
    private var sendEnabled: Bool {
        guard !isComposerDisabled, isSelectedConversation else { return false }
        if canAnswerInComposer { return !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return showsStopButton ? model.isConnected && !model.isLoadingSession : model.canSend
    }

    private func notice(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(text).iosFont(14).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { model.banner = nil } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("Dismiss notice")
            }
            if !model.isConnected, model.endpoint != nil {
                Button("Reconnect") { Task { await model.reconnect() } }.talariaSecondaryButton()
            }
        }
        .padding(12).iosCard(radius: 18)
    }

    private struct GroupedMessage: Identifiable {
        var messages: [ChatMessage]
        var id: String { messages[0].id }
        var isToolGroup: Bool { messages[0].role == .tool }
    }
    private var groups: [GroupedMessage] {
        var rows: [[ChatMessage]] = []
        for message in state.messages {
            if message.role == .tool, rows.last?.last?.role == .tool { rows[rows.count - 1].append(message) }
            else { rows.append([message]) }
        }
        return rows.map { GroupedMessage(messages: $0) }
    }
}

/// A missing Home keeps its cached bubbles readable without creating a runtime
/// conversation or enabling submission to an unrelated selected session.
struct IOSUnavailableHomeView: View {
    @Bindable var model: HermesAppModel
    var topInset: CGFloat
    var bottomInset: CGFloat
    let onNavigate: @MainActor (HierarchyDestination) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        HierarchyHomeUnavailableNotice(model: model, onNavigate: onNavigate)
                        ForEach(model.cachedHomeMessages) { message in
                            IOSMessageBubble(message: message, availableWidth: min(760, geometry.size.width - 32))
                                .opacity(0.7)
                        }
                        Color.clear.frame(height: bottomInset + 62).accessibilityHidden(true)
                    }
                    .padding(.horizontal, 16).padding(.top, topInset)
                    .frame(maxWidth: 792).frame(maxWidth: .infinity)
                }
                HStack(spacing: 12) {
                    Image(systemName: "plus").font(.system(size: 22)).frame(width: 40, height: 44)
                    Text("Reconnect Home to continue").iosFont(16).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.up").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white).frame(width: 40, height: 40)
                        .background(TalariaStyle.prominentAccent.opacity(0.4), in: Circle())
                }
                .foregroundStyle(.secondary).padding(4).frame(minHeight: 52)
                .talariaGlass(cornerRadius: 26).accessibilityElement(children: .combine)
                .accessibilityLabel("Reconnect Home to continue. Composer unavailable.")
                .frame(maxWidth: 792).padding(.horizontal, 16).padding(.bottom, bottomInset)
            }
        }
    }
}

private struct IOSMessageBubble: View {
    let message: ChatMessage
    let availableWidth: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private var isUser: Bool { message.role == .user }
    private var hasContent: Bool { !message.text.isEmpty || message.isStreaming || !message.reasoning.isEmpty }

    var body: some View {
        if hasContent {
            HStack(spacing: 0) {
                if isUser { Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 10) {
                    if !message.reasoning.isEmpty {
                        DisclosureGroup("Reasoning") {
                            Text(message.reasoning).iosFont(14).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        .iosFont(13).tint(TalariaStyle.accent)
                    }
                    if !message.text.isEmpty || message.isStreaming {
                        MarkdownMessage(text: message.text, isStreaming: message.isStreaming)
                            .iosFont(16).lineSpacing(4)
                            .foregroundStyle(isUser ? .white : .primary)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: availableWidth * (isUser ? 0.9 : 0.97), alignment: .leading)
                .background(bubbleFill, in: bubbleShape)
                .overlay(bubbleShape.strokeBorder(isUser ? .clear : .white.opacity(scheme == .dark ? 0.12 : 0.9), lineWidth: 1))
                .shadow(color: .black.opacity(isUser ? 0 : 0.04), radius: 2, y: 1)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(isUser ? "You" : message.role == .system ? "System" : "Hermes")
                if !isUser { Spacer(minLength: 0) }
            }
        }
    }
    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: isUser ? 20 : 6,
                               bottomTrailingRadius: isUser ? 6 : 20, topTrailingRadius: 20)
    }
    private var bubbleFill: Color {
        if isUser { return TalariaStyle.prominentAccent }
        if reduceTransparency || contrast == .increased {
            return scheme == .dark ? Color(red: 34/255, green: 37/255, blue: 43/255) : .white
        }
        return .white.opacity(scheme == .dark ? 0.10 : 0.85)
    }
}
#endif
