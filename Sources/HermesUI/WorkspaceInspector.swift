import Foundation
import SwiftUI
import HermesCore
import HermesProtocol

/// A view of evidence already present in the conversation. Host paths are opaque
/// strings: this inspector never reads them through the device's filesystem.
public struct WorkspaceInspector: View {
    public let state: ConversationState?
    public let attachments: [AttachmentItem]
    private let pane: WorkspaceInspectorPane?
    private let recordedInput: InspectorInput?

    @State private var tab: InspectorTab = .files
    @State private var selectedFileID: String?
    @State private var snapshot = InspectorSnapshot()
    @State private var displayTree: [InspectorTreeNode] = []
    @State private var collapsedDirectories: Set<String> = []
    @State private var scope: InspectorScope?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    public init(state: ConversationState?, attachments: [AttachmentItem], pane: WorkspaceInspectorPane? = nil) {
        self.state = state
        self.attachments = attachments
        self.pane = pane
        recordedInput = nil
    }

    public init(run: AutomationRunDetail, owner: SessionOwner, pane: WorkspaceInspectorPane) {
        state = nil; attachments = []; self.pane = pane
        recordedInput = InspectorInput(messages: run.messages,
            scope: InspectorScope(owner: owner, storedID: StoredSessionID(rawValue: run.runID), cwd: ""))
    }

    public var body: some View {
        let input = recordedInput ?? InspectorInput(state: state, attachments: attachments)
        VStack(alignment: .leading, spacing: 0) {
            if pane == nil { HStack(spacing: 2) {
                inspectorTab(.files, title: "Files")
                inspectorTab(.sources, title: "Sources",
                             count: scope == input.scope ? snapshot.sources.count : 0)
                inspectorTab(.terminal, title: "Terminal")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 52)
            panelDivider
            }

            if state == nil && recordedInput == nil {
                emptyState("Select a conversation", symbol: "sidebar.right",
                           detail: "Files, sources and command output appear here as Hermes uses them.")
            } else if scope != input.scope {
                // Never render a previous conversation's cached evidence while
                // the change handler installs the new scoped snapshot.
                emptyState("Updating workspace", symbol: "arrow.triangle.2.circlepath",
                           detail: "Loading this conversation’s recorded activity.")
            } else {
                switch pane == .terminal ? InspectorTab.terminal : pane == .files ? .files : tab {
                case .files: filesPane
                case .sources: sourcesPane
                case .terminal: terminalPane
                }
            }

            #if os(macOS)
            if recordedInput == nil { WorkspaceStatusStack(state: state)
                .id(input.scope)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            #else
            Divider()
            ScrollView {
                WorkspaceStatusStack(state: state)
                    .id(input.scope)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 190)
            #endif
        }
        .font(inspectorFont(11, .callout)).foregroundStyle(primaryInk)
        #if os(macOS)
        .frame(width: T.inspectorW)
        #endif
        .frame(minWidth: 260, idealWidth: 290, maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if reduceTransparency || contrast == .increased {
                TalariaStyle.solidControlSurface
            } else {
                #if os(macOS)
                T.sideBG
                #else
                Rectangle().fill(.regularMaterial)
                #endif
            }
        }
        // This also applies to Markdown links in recorded file content. Rendering
        // never fetches a source; only an explicit HTTP(S) link click opens it.
        .environment(\.openURL, OpenURLAction { url in
            guard let safe = InspectorSnapshot.safeWebURL(url.absoluteString) else { return .discarded }
            return .systemAction(safe)
        })
        .onChange(of: input, initial: true) { _, updated in
            if scope != updated.scope {
                scope = updated.scope
                tab = .files
                selectedFileID = nil
                collapsedDirectories = []
            }
            snapshot = InspectorSnapshot(input: updated)
            displayTree = InspectorTreePresentation.nodes(files: snapshot.files, cwd: updated.scope?.cwd ?? "")
            if !snapshot.files.contains(where: { $0.id == selectedFileID }) {
                selectedFileID = snapshot.files.first?.id
            }
        }
    }

    private func inspectorTab(_ value: InspectorTab, title: String, count: Int = 0) -> some View {
        Button { tab = value } label: {
            HStack(spacing: 5) {
                Text(title).font(inspectorFont(11, .callout, tab == value ? .semibold : .regular))
                if count > 0 {
                    Text("\(count)").font(inspectorFont(10, .caption2, .semibold)).foregroundStyle(accentInk)
                }
            }
            .foregroundStyle(tab == value ? primaryInk : secondaryInk)
            .frame(height: 28).padding(.horizontal, 12)
            #if os(macOS)
            .background {
                if tab == value {
                    if reduceTransparency || contrast == .increased {
                        Capsule().fill(cardFill(opacity: 0.6)).overlay(Capsule().strokeBorder(cardStroke))
                    } else {
                        Color.clear.controlGlass(14, opacity: 0.6)
                    }
                }
            }
            #else
            .background(tab == value ? cardFill(opacity: 0.6) : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(tab == value ? cardStroke : .clear))
            #endif
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == value ? .isSelected : [])
        .accessibilityLabel(count > 0 ? "\(title), \(count)" : title)
    }

    private var selectedFile: InspectorFile? {
        snapshot.files.first { $0.id == selectedFileID }
    }

    private var filesPane: some View {
        VStack(alignment: .leading, spacing: filePaneSpacing) {
            #if !os(macOS)
            provenance("Files from conversation")
            #endif
            if snapshot.files.isEmpty {
                emptyState("No files recorded", symbol: "doc",
                           detail: "Files appear after an attachment or a file tool call. This is not a directory listing of the host.")
            } else {
                #if os(macOS)
                let rows = InspectorTreePresentation.rows(displayTree, collapsed: collapsedDirectories)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in fileTreeRow(row) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
                .id(scope)
                .frame(height: min(CGFloat(rows.count) * 23 + 20, 230))
                .help("Files recorded in this conversation. Host workspace: \(state?.cwd ?? "Unavailable")")
                #else
                List {
                    ForEach(InspectorTreePresentation.rows(displayTree, collapsed: collapsedDirectories)) { row in
                        fileTreeRow(row)
                            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .id(scope)
                .frame(minHeight: 80, maxHeight: 230)
                #endif
                if let selectedFile {
                    filePreview(selectedFile)
                }
            }
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func filePreview(_ file: InspectorFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(file.name).font(inspectorFont(10, .caption)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Text("Recorded").font(inspectorFont(10, .caption))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .help("From conversation · \(file.kind)")
            }
            .foregroundStyle(secondaryInk)
            .padding(.horizontal, 10).padding(.vertical, 7)
            panelDivider
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let content = file.content {
                        if file.isMarkdown {
                            MarkdownMessage(text: content).font(inspectorFont(11, .callout)).lineSpacing(4)
                        } else {
                            Text(content.isEmpty ? "Empty content" : content)
                                .font(monoFont)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if file.isTruncated {
                            Text("This preview contains an excerpt.")
                                .font(inspectorFont(10, .caption)).foregroundStyle(secondaryInk)
                        }
                    } else {
                        Text(file.note).font(inspectorFont(11, .callout)).foregroundStyle(secondaryInk)
                    }
                    Text("From conversation · \(file.kind)")
                        .font(inspectorFont(10, .caption)).foregroundStyle(secondaryInk)
                    if snapshot.isLimited {
                        Text("Showing recent recorded activity.")
                            .font(inspectorFont(10, .caption)).foregroundStyle(secondaryInk)
                    }
                    Text(InspectorTreePresentation.displayPath(file.path, cwd: state?.cwd ?? ""))
                        .font(previewPathFont)
                        .foregroundStyle(tertiaryInk).textSelection(.enabled)
                        .help(file.path)
                    Text("Recorded content may differ from the file on the host.")
                        .font(inspectorFont(10, .caption)).foregroundStyle(tertiaryInk)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
            .frame(maxHeight: .infinity)
        }
        .background(cardFill(opacity: 0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(cardStroke))
        .padding(.horizontal, 12)
        #if os(macOS)
        .padding(.top, 6)
        #endif
        .frame(minHeight: 160, maxHeight: .infinity)
    }

    private var sourcesPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            provenance("Sources from search results")
            if snapshot.sources.isEmpty {
                emptyState("No sources recorded", symbol: "link",
                           detail: "Structured web search and page-extraction results appear here. Links open in your browser when selected.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(snapshot.sources) { source in
                            Link(destination: source.url) {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(source.title).fontWeight(.medium).lineLimit(3)
                                        Spacer(minLength: 0)
                                        Image(systemName: "arrow.up.right").font(inspectorFont(10, .caption2))
                                    }
                                    .foregroundStyle(accentInk)
                                    Text(source.url.host ?? source.url.absoluteString)
                                        .font(inspectorFont(10, .caption)).foregroundStyle(secondaryInk).lineLimit(1)
                                    if !source.summary.isEmpty {
                                        Text(source.summary).foregroundStyle(secondaryInk).lineLimit(3)
                                    }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(source.url.absoluteString)
                            .accessibilityHint("Opens \(source.url.host ?? "source") in your browser")
                            panelDivider.padding(.horizontal, 10)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var terminalPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            provenance("Recorded command output")
            if snapshot.commands.isEmpty {
                emptyState("No commands recorded", symbol: "terminal",
                           detail: "Terminal tool calls appear here as a read-only record. Interactive terminal sessions are not available in this view.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(snapshot.commands) { command in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    Image(systemName: "terminal").foregroundStyle(accentInk)
                                    Text(command.status).font(inspectorFont(10, .caption, .medium))
                                    Spacer(minLength: 0)
                                }
                                Text(command.command).font(monoFont.weight(.medium))
                                    .textSelection(.enabled)
                                if !command.workdir.isEmpty {
                                    Text(command.workdir).font(monoFont)
                                        .foregroundStyle(secondaryInk).textSelection(.enabled)
                                }
                                panelDivider
                                Text(command.output.isEmpty ? "No output was included in the conversation." : command.output)
                                    .font(monoFont)
                                    .textSelection(.enabled)
                                if command.isTruncated {
                                    Text("Output preview truncated.").font(inspectorFont(10, .caption)).foregroundStyle(secondaryInk)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(cardFill(opacity: 0.6), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(cardStroke))
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func provenance(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(inspectorFont(10, .caption, .semibold)).foregroundStyle(tertiaryInk)
            if let state, !state.cwd.isEmpty {
                ViewThatFits(in: .horizontal) {
                    Text(state.cwd).font(inspectorFont(10, .caption)).foregroundStyle(secondaryInk)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .help("Current host workspace: \(state.cwd)")
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            if snapshot.isLimited {
                Text("Showing recent recorded activity.").font(inspectorFont(10, .caption)).foregroundStyle(secondaryInk)
            }
        }
        .padding(.horizontal, 12)
    }

    private func emptyState(_ title: String, symbol: String, detail: String) -> some View {
        VStack(spacing: 10) {
            #if os(macOS)
            if state == nil {
                Image("TalariaMark", bundle: .module).renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 40, height: 40).foregroundStyle(T.ink3).accessibilityHidden(true)
            } else {
                Image(systemName: symbol).font(T.f(24)).foregroundStyle(T.ink3)
            }
            #else
            Image(systemName: symbol).font(TalariaTypography.title).foregroundStyle(.tertiary)
            #endif
            Text(title).font(inspectorFont(12, .callout, .semibold))
            Text(detail).font(inspectorFont(11, .caption)).foregroundStyle(secondaryInk).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 220)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cardFill(opacity: Double) -> Color {
        if reduceTransparency || contrast == .increased { return TalariaStyle.solidControlSurface }
        #if os(macOS)
        return Color.white.opacity(opacity)
        #else
        return TalariaStyle.cardSurface.opacity(opacity)
        #endif
    }

    private var cardStroke: Color {
        if contrast == .increased { .primary.opacity(0.35) }
        else if reduceTransparency { .primary.opacity(0.15) }
        else {
            #if os(macOS)
            Color.white.opacity(0.8)
            #else
            TalariaStyle.cardBorder.opacity(0.8)
            #endif
        }
    }

    private func inspectorFont(_ size: CGFloat, _ fallback: Font, _ weight: Font.Weight = .regular) -> Font {
        #if os(macOS)
        T.f(size, weight)
        #else
        fallback.weight(weight)
        #endif
    }

    private var monoFont: Font {
        #if os(macOS)
        T.mono
        #else
        .system(.caption, design: .monospaced)
        #endif
    }

    private var previewPathFont: Font {
        #if os(macOS)
        .system(size: 10, design: .monospaced)
        #else
        monoFont
        #endif
    }

    private var primaryInk: Color {
        #if os(macOS)
        T.ink
        #else
        .primary
        #endif
    }

    private var secondaryInk: Color {
        #if os(macOS)
        T.ink2
        #else
        .secondary
        #endif
    }

    private var tertiaryInk: Color {
        #if os(macOS)
        T.ink3
        #else
        .secondary
        #endif
    }

    private var accentInk: Color {
        #if os(macOS)
        T.deep
        #else
        TalariaStyle.accent
        #endif
    }

    @ViewBuilder private var panelDivider: some View {
        #if os(macOS)
        Rectangle().fill(T.hair).frame(height: 1)
        #else
        Divider()
        #endif
    }

    private var filePaneSpacing: CGFloat {
        #if os(macOS)
        0
        #else
        10
        #endif
    }

    private func fileTreeRow(_ row: InspectorTreePresentation.Row) -> some View {
        let node = row.node
        let isDirectory = !node.children.isEmpty
        let isSelected = !isDirectory && node.fileID == selectedFileID
        return Button {
            if isDirectory {
                if !collapsedDirectories.insert(node.id).inserted { collapsedDirectories.remove(node.id) }
            } else if let fileID = node.fileID {
                selectedFileID = fileID
            }
        } label: {
            HStack(spacing: 6) {
                #if os(macOS)
                if isDirectory {
                    Image(systemName: collapsedDirectories.contains(node.id) ? "chevron.right" : "chevron.down")
                        .font(T.f(8, .semibold)).foregroundStyle(T.ink3).frame(width: 9)
                } else {
                    RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.35))
                        .frame(width: 9, height: 11)
                }
                #else
                if isDirectory {
                    Image(systemName: collapsedDirectories.contains(node.id) ? "chevron.right" : "chevron.down")
                        .font(TalariaTypography.caption2).foregroundStyle(.tertiary).frame(width: 10)
                } else {
                    Image(systemName: "doc").font(TalariaTypography.caption2).foregroundStyle(.secondary).frame(width: 10)
                }
                #endif
                Text(node.name)
                    #if os(macOS)
                    .font(isDirectory && row.depth == 0 ? T.f(11, .semibold) : T.tree).foregroundStyle(T.ink)
                    #else
                    .font(TalariaTypography.callout.weight(isSelected ? .semibold : .regular))
                    #endif
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(row.depth) * 18)
            #if os(macOS)
            .frame(height: 23).padding(.horizontal, isSelected ? 6 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6).fill(cardFill(opacity: 0.55))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
                            reduceTransparency || contrast == .increased ? cardStroke : Color.white.opacity(0.7)))
                        .padding(.horizontal, -6)
                }
            }
            #else
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? cardFill(opacity: 0.55) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? cardStroke : .clear))
            #endif
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(node.fileID ?? node.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isDirectory ? (collapsedDirectories.contains(node.id) ? "Collapsed" : "Expanded") : "")
    }
}

public enum WorkspaceInspectorPane: Sendable { case files, terminal }

private enum InspectorTab: Hashable { case files, sources, terminal }

struct InspectorScope: Hashable {
    let owner: SessionOwner
    let storedID: StoredSessionID
    let cwd: String
}

/// Assistant token deltas do not invalidate the inspector's parsed snapshot.
struct InspectorInput: Equatable {
    let scope: InspectorScope?
    let messages: [ChatMessage]
    let attachments: [AttachmentItem]
    let isLimited: Bool

    /// Results expose the same recorded-tool evidence without pretending a
    /// historical run is an attached conversation or reading the local disk.
    init(messages: [ChatMessage], scope: InspectorScope? = nil) {
        self.scope = scope
        let relevant = messages.filter { $0.role == .tool }
        self.messages = Array(relevant.suffix(500))
        attachments = []
        isLimited = relevant.count > 500
    }

    init(state: ConversationState?, attachments: [AttachmentItem]) {
        scope = state.map { InspectorScope(owner: $0.owner, storedID: $0.storedID, cwd: $0.cwd) }
        let relevant = state?.messages.filter { $0.role == .tool || $0.role == .user } ?? []
        messages = Array(relevant.suffix(500))
        self.attachments = state == nil ? [] : attachments
        isLimited = relevant.count > 500
    }
}

struct InspectorFile: Identifiable {
    var id: String { path }
    let path: String
    var name: String { path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? path }
    var kind: String
    var content: String?
    var note = "The conversation includes this path, but no file content to preview."
    var isTruncated = false
    var isMarkdown: Bool { ["md", "markdown", "mdown"].contains((name as NSString).pathExtension.lowercased()) }
}

struct InspectorSource: Identifiable {
    var id: String { url.absoluteString }
    let url: URL
    let title: String
    let summary: String
}

struct InspectorCommand: Identifiable {
    let id: String
    let command: String
    let workdir: String
    let status: String
    let output: String
    let isTruncated: Bool
}

struct InspectorTreeNode: Identifiable {
    let id: String
    let name: String
    var fileID: String?
    var children: [InspectorTreeNode] = []

    mutating func insert(_ parts: ArraySlice<String>, fileID: String, prefix: String) {
        guard let first = parts.first else { self.fileID = fileID; return }
        let key = prefix + "/" + first
        if let index = children.firstIndex(where: { $0.id == key }) {
            children[index].insert(parts.dropFirst(), fileID: fileID, prefix: key)
        } else {
            var child = InspectorTreeNode(id: key, name: first)
            child.insert(parts.dropFirst(), fileID: fileID, prefix: key)
            children.append(child)
        }
    }
}

/// Display-only shortening. Original file IDs remain opaque host paths, and a
/// historical relative path is never resolved against the current workspace.
enum InspectorTreePresentation {
    struct Row: Identifiable {
        let node: InspectorTreeNode
        let depth: Int
        var id: String { node.id }
    }

    static func displayPath(_ path: String, cwd: String) -> String {
        guard cwd.hasPrefix("/"), path.hasPrefix("/") else { return path }
        let prefix = cwd.hasSuffix("/") ? cwd : cwd + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return path }
        return String(path.dropFirst(prefix.count))
    }

    static func nodes(files: [InspectorFile], cwd: String) -> [InspectorTreeNode] {
        var workspace = InspectorTreeNode(id: "workspace", name: "")
        var relative = InspectorTreeNode(id: "relative", name: "")
        var external = InspectorTreeNode(id: "external", name: "")
        for file in files {
            let display = displayPath(file.path, cwd: cwd)
            var parts = display.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
            if display.hasPrefix("/") { parts.insert("/", at: 0) }
            if parts.count > 12 { parts = Array(parts.prefix(11)) + [parts.dropFirst(11).joined(separator: "/")] }
            if display != file.path {
                workspace.insert(parts[...], fileID: file.id, prefix: "workspace")
            } else if !file.path.hasPrefix("/") {
                relative.insert(parts[...], fileID: file.id, prefix: "relative")
            } else {
                external.insert(parts[...], fileID: file.id, prefix: "external")
            }
        }
        // Separate node identities keep an old relative reference distinct from
        // an absolute path that merely displays the same shortened filename.
        return workspace.children + relative.children + external.children
    }

    static func rows(_ nodes: [InspectorTreeNode], collapsed: Set<String>, depth: Int = 0) -> [Row] {
        nodes.flatMap { node in
            [Row(node: node, depth: depth)] + (collapsed.contains(node.id)
                ? [] : rows(node.children, collapsed: collapsed, depth: depth + 1))
        }
    }
}

/// Extraction is deliberately limited to known structured tool fields. It does
/// not infer filesystem contents from prose, fetch URLs, or run commands.
struct InspectorSnapshot {
    /// Retain the most recently observed URLs, including refreshed metadata for
    /// an existing source. Display sorting is separate from eviction order.
    private struct RecordedSources {
        private(set) var byID: [String: InspectorSource] = [:]
        private var order: [String] = []
        private(set) var isLimited = false

        mutating func record(_ source: InspectorSource) {
            let key = source.id
            order.removeAll { $0 == key }
            order.append(key)
            byID[key] = source
            if order.count > 100 {
                byID.removeValue(forKey: order.removeFirst())
                isLimited = true
            }
        }

        mutating func noteOmission() { isLimited = true }
    }

    var files: [InspectorFile] = []
    var sources: [InspectorSource] = []
    var commands: [InspectorCommand] = []
    var tree: [InspectorTreeNode] = []
    var isLimited = false

    init() {}

    init(input: InspectorInput) {
        isLimited = input.isLimited
        var recordedFiles: [String: InspectorFile] = [:]
        var recordedSources = RecordedSources()

        for message in input.messages {
            if message.role == .user {
                // Native document attachments persist as explicit @file references.
                for line in message.text.components(separatedBy: .newlines) where line.hasPrefix("@file:") {
                    if let path = Self.path(String(line.dropFirst(6))) {
                        recordedFiles[path] = recordedFiles[path] ?? InspectorFile(path: path, kind: "Referenced attachment")
                    }
                }
                continue
            }
            let name = message.toolName?.lowercased() ?? ""
            let args = Self.json(message.toolInput)
            let result = message.isStreaming ? nil : Self.json(message.text)
            let failed = message.isError || result?["success"]?.boolValue == false
                || (result?["error"]?.stringValue.map { !$0.isEmpty } ?? false)

            if ["read_file", "write_file", "patch"].contains(name),
               let path = Self.path(result?["resolved_path"]?.stringValue ?? args?["path"]?.stringValue) {
                var file = InspectorFile(path: path, kind: message.isStreaming ? "Tool in progress" : "Recorded file")
                if name == "read_file", !failed,
                   result?["is_image"]?.boolValue == true || result?["is_binary"]?.boolValue == true {
                    file.kind = result?["is_image"]?.boolValue == true ? "Recorded image" : "Recorded binary file"
                    file.note = "This tool result does not provide a text preview."
                } else if name == "read_file", !failed, let content = result?["content"]?.stringValue {
                    file.content = Self.bounded(Self.removeLineNumbers(content))
                    file.kind = "Read excerpt"
                    file.isTruncated = result?["truncated"]?.boolValue == true || content.count > 32_000
                } else if name == "write_file", let content = args?["content"]?.stringValue {
                    file.content = Self.bounded(content)
                    file.kind = failed ? "Failed write · submitted content" : message.isStreaming ? "Proposed write" : "Write arguments"
                    file.isTruncated = content.count > 32_000
                } else if name == "patch" {
                    file.kind = failed ? "Patch failed" : "Patch recorded"
                    file.note = "A patch was recorded. Its diff does not provide a complete file preview."
                } else if failed {
                    file.kind = "Tool reported an error"
                }
                recordedFiles[path] = file
            }

            for value in result?["files_modified"]?.arrayValue ?? [] {
                if let path = Self.path(value.stringValue) {
                    if name == "patch" {
                        // Multi-file patches may report paths only in the result.
                        // An older read snapshot no longer describes those files.
                        var file = InspectorFile(path: path, kind: failed ? "Patch reported an error" : "Patch recorded")
                        file.note = "A patch was recorded. Its diff does not provide a complete file preview."
                        recordedFiles[path] = file
                    } else if recordedFiles[path] == nil {
                        recordedFiles[path] = InspectorFile(path: path, kind: "Modified path reported")
                    }
                }
            }
            if ["search_files", "search"].contains(name), !failed {
                for match in result?["matches"]?.arrayValue ?? [] {
                    guard let path = Self.path(match["path"]?.stringValue) else { continue }
                    if recordedFiles[path] == nil {
                        recordedFiles[path] = InspectorFile(path: path, kind: "Search match")
                    }
                }
                for match in result?["files"]?.arrayValue ?? [] {
                    guard let path = Self.path(match.stringValue) else { continue }
                    recordedFiles[path] = recordedFiles[path] ?? InspectorFile(path: path, kind: "Search match")
                }
                for key in (result?["counts"]?.objectValue ?? [:]).keys {
                    guard let path = Self.path(key) else { continue }
                    recordedFiles[path] = recordedFiles[path] ?? InspectorFile(path: path, kind: "Search match")
                }
                // Hermes compacts five or more search matches into an explicit
                // path-grouped format. Parse only that declared format, never
                // arbitrary prose or a terminal command's text.
                if result?["matches_format"]?.stringValue?.hasPrefix("path-grouped:") == true,
                   let grouped = result?["matches_text"]?.stringValue {
                    let lines = grouped.components(separatedBy: .newlines)
                    for (index, line) in lines.enumerated() where index + 1 < lines.count {
                        guard !line.hasPrefix("  "), let path = Self.path(line),
                              lines[index + 1].hasPrefix("  "),
                              let colon = lines[index + 1].firstIndex(of: ":"),
                              Int(String(lines[index + 1][..<colon]).trimmingCharacters(in: .whitespaces)) != nil else { continue }
                        recordedFiles[path] = recordedFiles[path] ?? InspectorFile(path: path, kind: "Search match")
                    }
                }
            }
            if ["web_search", "web_extract"].contains(name), !failed, let result {
                Self.collectSources(result, depth: 0, into: &recordedSources)
            }
            if ["terminal", "process"].contains(name) {
                let output = result?["output"]?.stringValue
                    ?? result?["stdout"]?.stringValue
                    ?? (message.isStreaming ? "" : message.text)
                let code = result?["exit_code"]?.intValue
                let status = message.isStreaming ? "Working…" : failed ? "Reported error"
                    : code.map { "Exit \($0)" } ?? "Recorded output"
                commands.append(InspectorCommand(id: message.id,
                    command: Self.bounded(args?["command"]?.stringValue ?? args?["action"]?.stringValue ?? name, limit: 2_000),
                    workdir: Self.bounded(args?["workdir"]?.stringValue ?? "", limit: 1_024),
                    status: status, output: Self.bounded(output, limit: 24_000), isTruncated: output.count > 24_000))
            }
        }
        for attachment in input.attachments {
            let path = Self.path(attachment.destination) ?? attachment.filename
            let kind: String
            switch attachment.state {
            case .reading: kind = "Reading attachment"
            case .uploading: kind = "Uploading attachment"
            case .ready: kind = "Uploaded attachment"
            case .failed: kind = "Attachment failed"
            }
            if recordedFiles[path] == nil {
                var file = InspectorFile(path: path, kind: kind)
                file.note = "Attachment bytes are not included in this recorded preview."
                recordedFiles[path] = file
            }
        }
        isLimited = isLimited || recordedFiles.count > 200 || recordedSources.isLimited || commands.count > 30
        files = Array(recordedFiles.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.prefix(200))
        sources = recordedSources.byID.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        commands = Array(commands.suffix(30).reversed())
        var root = InspectorTreeNode(id: "root", name: "")
        for file in files {
            var parts = file.path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
            if file.path.hasPrefix("/") { parts.insert("/", at: 0) }
            // Keep pathological paths from producing deeply nested SwiftUI views.
            if parts.count > 12 { parts = Array(parts.prefix(11)) + [parts.dropFirst(11).joined(separator: "/")] }
            root.insert(parts[...], fileID: file.id, prefix: "")
        }
        tree = root.children
    }

    static func safeWebURL(_ value: String) -> URL? {
        guard value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }

    private static func collectSources(_ value: JSONValue, depth: Int, into sources: inout RecordedSources) {
        guard depth <= 5 else { return }
        if let rows = value.arrayValue {
            if rows.count > 100 { sources.noteOmission() }
            for row in rows.suffix(100) { collectSources(row, depth: depth + 1, into: &sources) }
        } else if let object = value.objectValue {
            guard object["success"]?.boolValue != false,
                  !(object["error"]?.stringValue.map { !$0.isEmpty } ?? false) else { return }
            if let rawURL = object["url"]?.stringValue ?? object["link"]?.stringValue,
               let url = safeWebURL(rawURL) {
                let title = object["title"]?.stringValue ?? url.host ?? "Source"
                let summary = object["description"]?.stringValue ?? object["snippet"]?.stringValue ?? ""
                sources.record(InspectorSource(url: url, title: bounded(title, limit: 240), summary: bounded(summary, limit: 500)))
            }
            for key in ["data", "web", "results", "organic", "organic_results", "sources"] {
                if let nested = object[key] { collectSources(nested, depth: depth + 1, into: &sources) }
            }
        }
    }

    private static func json(_ text: String?) -> JSONValue? {
        guard let text, text.utf8.count <= 1_048_576 else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private static func path(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    private static func bounded(_ value: String, limit: Int = 32_000) -> String { String(value.prefix(limit)) }

    private static func removeLineNumbers(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        // Hermes read_file emits LINE_NUM|CONTENT. Strip only a consistently
        // numbered result, leaving literal pipes in ordinary file content intact.
        guard lines.filter({ !$0.isEmpty }).allSatisfy({ line in
            guard let divider = line.firstIndex(of: "|") else { return false }
            return Int(String(line[..<divider]).trimmingCharacters(in: .whitespaces)) != nil
        }) else { return text }
        return lines.map { line in
            guard let divider = line.firstIndex(of: "|") else { return line }
            return String(line[line.index(after: divider)...])
        }.joined(separator: "\n")
    }
}
