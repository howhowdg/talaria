import Foundation
import SwiftUI
import HermesCore
import HermesProtocol

/// A compact group of adjacent tool messages. Expanded details retain the exact
/// arguments and output; collapsed rows show only parsed, bounded summaries.
public struct ToolActivityCard: View {
    public let messages: [ChatMessage]
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(messages: [ChatMessage]) { self.messages = messages }

    public var body: some View {
        let tools = messages.filter { $0.role == .tool }
        let shape = RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
        if !tools.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(tools.enumerated()), id: \.element.id) { index, message in
                    if index > 0 { Rectangle().fill(ActivityAppearance.hairline).frame(height: 1) }
                    ToolActivityRow(message: message)
                }
            }
            .background(reduceTransparency || contrast == .increased
                        ? TalariaStyle.solidControlSurface : ActivityAppearance.card, in: shape)
            .overlay {
                shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.25)
                                   : ActivityAppearance.cardBorder, lineWidth: 1)
            }
            .clipShape(shape)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tool activity")
        }
    }

    private var cardRadius: CGFloat {
        #if os(macOS)
        12
        #else
        18
        #endif
    }
}

private struct ToolActivityRow: View {
    let message: ChatMessage
    @State private var expanded = false
    #if os(iOS)
    @ScaledMetric private var rowSize: CGFloat = 14
    #endif
    private var name: String { message.toolName?.nonempty ?? "Tool" }
    private var rowFont: Font {
        #if os(iOS)
        .system(size: rowSize)
        #else
        ActivityAppearance.row
        #endif
    }

    var body: some View {
        let phase = ToolPhase(message)
        let argument = ActivityPresentation.argumentSummary(message.toolInput, toolName: message.toolName)
        let trailing = ActivityPresentation.trailingMetadata(message)
        VStack(spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 10) {
                    ToolPhaseSymbol(phase: phase).frame(width: 12)
                    Text(name).font(rowFont.weight(.semibold)).foregroundStyle(ActivityAppearance.ink).lineLimit(1)
                    if let argument {
                        Text(argument.text).font(argument.isCode ? ActivityAppearance.mono : rowFont)
                            .foregroundStyle(ActivityAppearance.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if !trailing.isEmpty {
                        Text(trailing).font(rowFont).foregroundStyle(ActivityAppearance.tertiary).lineLimit(1)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                #if os(iOS)
                .frame(minHeight: 44)
                #endif
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name), \(phase.accessibilityLabel)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows or hides full arguments and output")

            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    if let input = message.toolInput?.nonempty { rawSection("Arguments", text: input) }
                    if let result = message.text.nonempty {
                        rawSection(message.isStreaming ? "Reported output" : "Result", text: result)
                    }
                    if let summary = message.toolSummary?.nonempty, summary != message.text {
                        rawSection("Summary", text: summary)
                    }
                    if message.toolInput?.nonempty == nil && message.text.nonempty == nil && message.toolSummary?.nonempty == nil {
                        Text("No arguments or output were included.").foregroundStyle(ActivityAppearance.secondary)
                    }
                }
                .font(ActivityAppearance.mono)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
            if let output = ActivityPresentation.terminalOutput(message) {
                Text(output).font(ActivityAppearance.mono)
                    .foregroundStyle(Color(red: 216 / 255, green: 221 / 255, blue: 230 / 255)).lineSpacing(4)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 26 / 255, green: 28 / 255, blue: 34 / 255))
            }
        }
    }

    private func rawSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(ActivityAppearance.detailLabel).foregroundStyle(ActivityAppearance.secondary)
            Text(text).foregroundStyle(ActivityAppearance.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private enum ActivityAppearance {
    static var row: Font {
        #if os(macOS)
        T.toolRow
        #else
        .callout
        #endif
    }
    static var rowSemibold: Font {
        #if os(macOS)
        T.f(11, .semibold)
        #else
        .callout.weight(.semibold)
        #endif
    }
    static var section: Font {
        #if os(macOS)
        T.section
        #else
        .caption.weight(.semibold)
        #endif
    }
    static var detailLabel: Font {
        #if os(macOS)
        T.f(10)
        #else
        .caption
        #endif
    }
    static var mono: Font {
        #if os(macOS)
        T.mono
        #else
        .system(.caption, design: .monospaced)
        #endif
    }
    static var ink: Color {
        #if os(macOS)
        T.ink
        #else
        .primary
        #endif
    }
    static var secondary: Color {
        #if os(macOS)
        T.ink2
        #else
        .secondary
        #endif
    }
    static var tertiary: Color {
        #if os(macOS)
        T.ink3
        #else
        .secondary.opacity(0.8)
        #endif
    }
    static var accent: Color {
        #if os(macOS)
        T.deep
        #else
        TalariaStyle.accent
        #endif
    }
    static var fill: Color {
        #if os(macOS)
        T.fill
        #else
        TalariaStyle.prominentAccent
        #endif
    }
    static var hairline: Color {
        #if os(macOS)
        T.hair
        #else
        .primary.opacity(0.06)
        #endif
    }
    static var card: Color {
        #if os(macOS)
        T.card
        #else
        Color(uiColor: .secondarySystemGroupedBackground).opacity(0.85)
        #endif
    }
    static var cardBorder: Color {
        #if os(macOS)
        .white.opacity(0.8)
        #else
        TalariaStyle.cardBorder.opacity(0.8)
        #endif
    }
}

/// The inspector's actual task list or recent tool activity. Nothing here infers
/// tasks from prose or treats a tool's requested arguments as confirmed state.
public struct WorkspaceStatusStack: View {
    public let state: ConversationState?
    @State private var showAllTasks = false
    @State private var todoCache = WorkspaceTodoCache()

    public init(state: ConversationState?) { self.state = state }

    public var body: some View {
        let todoInput = WorkspaceTodoInput(state: state)
        VStack(alignment: .leading, spacing: 8) {
            Text("Status").font(ActivityAppearance.section).foregroundStyle(ActivityAppearance.tertiary)
            if let state {
                if !state.pendingInputs.isEmpty {
                    Label(state.pendingInputs.count == 1 ? "Waiting for your answer" : "\(state.pendingInputs.count) answers needed",
                          systemImage: "hand.raised")
                        .foregroundStyle(ActivityAppearance.accent)
                }
                reportedActivity(state, todos: todoCache.todos(matching: todoInput))
            } else {
                Text("Select a conversation to see its activity.").foregroundStyle(ActivityAppearance.secondary)
            }
        }
        .font(ActivityAppearance.row)
        .foregroundStyle(ActivityAppearance.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .onChange(of: todoInput, initial: true) { old, new in
            if old.scope != new.scope { showAllTasks = false }
            todoCache.update(new)
        }
    }

    @ViewBuilder private func reportedActivity(_ state: ConversationState, todos: [ReportedTodo]?) -> some View {
        if let todos {
            if todos.isEmpty {
                Text("No tasks in the last reported list.").foregroundStyle(ActivityAppearance.secondary)
            } else {
                if !state.isRunning {
                    Text("Last reported tasks").font(ActivityAppearance.detailLabel).foregroundStyle(ActivityAppearance.tertiary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(todos.prefix(5))) { todo in
                        taskRow(todo, todos: todos, isRunning: state.isRunning)
                    }
                }
                if todos.count > 5 {
                    DisclosureGroup(isExpanded: $showAllTasks) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(todos.dropFirst(5))) { todo in
                                    taskRow(todo, todos: todos, isRunning: state.isRunning)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                        }.frame(maxHeight: 160)
                    } label: {
                        Text("\(todos.count - 5) more tasks").foregroundStyle(ActivityAppearance.secondary)
                            .frame(minHeight: disclosureHeight, alignment: .leading)
                    }
                }
            }
        } else {
            let recentTools = Array(state.messages.filter { $0.role == .tool }.suffix(3))
            if recentTools.isEmpty {
                Text(state.isRunning ? "Tool activity will appear here when reported." : "No tool activity reported yet.")
                    .foregroundStyle(ActivityAppearance.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(recentTools) { message in
                        HStack(alignment: .top, spacing: 8) {
                            ToolPhaseSymbol(phase: ToolPhase(message)).frame(width: 14).padding(.top, 1)
                            Text(message.toolName?.nonempty ?? "Tool")
                                .font(message.isStreaming ? ActivityAppearance.rowSemibold : ActivityAppearance.row).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(ToolPhase(message).accessibilityLabel)
                    }
                }
            }
        }
    }

    private var disclosureHeight: CGFloat {
        #if os(macOS)
        24
        #else
        44
        #endif
    }

    private func taskRow(_ todo: ReportedTodo, todos: [ReportedTodo], isRunning: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                switch todo.status {
                case .completed: Image(systemName: "checkmark.square").foregroundStyle(ActivityAppearance.accent)
                case .inProgress:
                    if isRunning { ToolPhaseSymbol(phase: .running) }
                    else { Image(systemName: "circle.lefthalf.filled").foregroundStyle(ActivityAppearance.accent) }
                case .pending: Image(systemName: "square").foregroundStyle(ActivityAppearance.tertiary)
                case .cancelled: Image(systemName: "minus.square").foregroundStyle(ActivityAppearance.secondary)
                }
            }.frame(width: 14).padding(.top, 1)
            Text(todo.content)
                .font(todo.status == .inProgress ? ActivityAppearance.rowSemibold : ActivityAppearance.row)
                .foregroundStyle(todo.status == .cancelled || todo.status == .pending ? ActivityAppearance.secondary : ActivityAppearance.ink)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(ActivityPresentation.depth(of: todo, in: todos)) * 12)
        .help(todo.content)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(todo.content), \(todo.status.label)\(todo.status == .inProgress && !isRunning ? ", last reported" : "")")
    }
}

/// The only custom motion in the workspace: a small activity pulse. In Reduce
/// Motion it remains steady, and idle indicators never schedule an animation.
public struct TalariaActivityIndicator: View {
    public let isRunning: Bool
    public let size: CGFloat
    public init(isRunning: Bool, size: CGFloat = 7) { self.isRunning = isRunning; self.size = size }

    public var body: some View {
        Circle().fill(isRunning ? ActivityAppearance.fill : ActivityAppearance.tertiary)
            .frame(width: size, height: size)
            .modifier(ActivityPulse(active: isRunning, period: 1.4))
            .accessibilityLabel(isRunning ? "Working" : "Idle")
    }
}

public struct TalariaStreamingCursor: View {
    public init() {}
    public var body: some View {
        RoundedRectangle(cornerRadius: 1).fill(ActivityAppearance.fill).frame(width: 7, height: 14)
            .modifier(ActivityPulse(active: true, period: 1.4))
            .accessibilityHidden(true)
    }
}

private struct ActivityPulse: ViewModifier {
    let active: Bool
    let period: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    func body(content: Content) -> some View {
        content
            .opacity(active && !reduceMotion ? (bright ? 1 : 0.35) : 1)
            .animation(active && !reduceMotion ? .easeInOut(duration: period / 2).repeatForever(autoreverses: true) : nil, value: bright)
            .onAppear { bright = active && !reduceMotion }
            .onChange(of: active) { _, _ in bright = active && !reduceMotion }
            .onChange(of: reduceMotion) { _, _ in bright = active && !reduceMotion }
    }
}

enum ToolPhase: Equatable {
    case running, result, failed, idle

    init(_ message: ChatMessage) {
        if message.isError || ActivityPresentation.reportsFailure(message.text) { self = .failed }
        else if message.isStreaming { self = .running }
        else if message.toolSummary?.nonempty != nil || message.text.nonempty != nil { self = .result }
        else { self = .idle }
    }
    var label: String {
        switch self { case .running: "Running"; case .result: "Result"; case .failed: "Error"; case .idle: "Idle" }
    }
    var accessibilityLabel: String {
        switch self { case .running: "Running"; case .result: "Reported output available"; case .failed: "Reported an error"; case .idle: "Not running" }
    }
}

private struct ToolPhaseSymbol: View {
    let phase: ToolPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            switch phase {
            case .running:
                if reduceMotion { Image(systemName: "circle.dotted").foregroundStyle(ActivityAppearance.accent) }
                else { ProgressView().controlSize(.mini).tint(ActivityAppearance.accent).scaleEffect(0.75) }
            case .result: Image(systemName: "checkmark").font(ActivityAppearance.section).foregroundStyle(ActivityAppearance.accent)
            case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
            case .idle: Image(systemName: "circle").foregroundStyle(.tertiary)
            }
        }.accessibilityHidden(true)
    }
}

struct ReportedTodo: Identifiable, Equatable {
    enum Status: String {
        case pending, inProgress = "in_progress", completed, cancelled
        var label: String {
            switch self { case .pending: "Pending"; case .inProgress: "In progress"; case .completed: "Completed"; case .cancelled: "Cancelled" }
        }
    }
    let id: String
    let content: String
    let status: Status
    let parent: String?
}

/// Only completed todo result text participates in invalidation. Assistant deltas,
/// tool arguments, and unrelated tools do not cause another JSON decoding pass.
struct WorkspaceTodoInput: Equatable {
    let scope: ComposerScope?
    let results: [String]

    init(state: ConversationState?) {
        scope = state.map { ComposerScope(owner: $0.owner, sessionID: $0.storedID) }
        results = state.map { ActivityPresentation.completedTodoResults($0.messages) } ?? []
    }
}

struct WorkspaceTodoCache {
    private var input: WorkspaceTodoInput?
    private var reported: [ReportedTodo]?

    mutating func update(_ input: WorkspaceTodoInput,
                         parse: ([String]) -> [ReportedTodo]? = { ActivityPresentation.reportedTodos(in: $0) }) {
        guard self.input != input else { return }
        reported = parse(input.results)
        self.input = input
    }

    func todos(matching input: WorkspaceTodoInput) -> [ReportedTodo]? {
        // SwiftUI draws before onChange runs. Never expose a previous scope's
        // tasks during that first frame, even if both sessions have the same ID.
        self.input == input ? reported : nil
    }
}

enum ActivityPresentation {
    struct ArgumentSummary: Equatable {
        let text: String
        let isCode: Bool
    }

    static func argumentPreview(_ raw: String?) -> String? {
        argumentSummary(raw, toolName: nil)?.text
    }

    static func argumentSummary(_ raw: String?, toolName: String?) -> ArgumentSummary? {
        guard let raw = raw?.nonempty, let value = decode(raw), let fields = value.objectValue else { return nil }
        let preferred: [String]
        let isCode: Bool
        switch toolName ?? "" {
        case "read_file", "write_file": preferred = ["path", "file_path"]; isCode = true
        case "terminal": preferred = ["command"]; isCode = true
        case "web_search": preferred = ["query"]; isCode = false
        default: preferred = []; isCode = false
        }
        for key in preferred {
            if let text = fields[key]?.stringValue?.nonempty {
                return ArgumentSummary(text: compact(text), isCode: isCode)
            }
        }
        // Core serializes arguments with sorted keys; use that same stable order.
        // Never fall back to the raw JSON object, an array, or nested JSON text.
        for key in fields.keys.sorted() {
            guard let text = fields[key]?.stringValue?.nonempty else { continue }
            if let nested = decode(text), nested.objectValue != nil || nested.arrayValue != nil { continue }
            return ArgumentSummary(text: compact(text), isCode: false)
        }
        return nil
    }

    static func trailingMetadata(_ message: ChatMessage) -> String {
        if message.isError || reportsFailure(message.text) { return "error" }
        if message.isStreaming { return "running" }
        guard let value = decode(message.text) else { return "" }
        switch message.toolName ?? "" {
        case "read_file":
            if let lines = value["total_lines"]?.intValue, lines >= 0 { return "\(lines) lines" }
        case "write_file":
            if let added = value["lines_added"]?.intValue, added >= 0 { return "+\(added)" }
            if let bytes = value["bytes_written"]?.intValue, bytes >= 0 { return "\(bytes) bytes" }
        case "web_search":
            if let sources = value["data"]?["web"]?.arrayValue ?? value["results"]?.arrayValue {
                return "\(sources.count) \(sources.count == 1 ? "source" : "sources")"
            }
        case "terminal":
            if value["status"]?.stringValue == "yielded_to_background" { return "background" }
            if let exit = value["exit_code"]?.intValue { return "exit \(exit)" }
        default: break
        }
        return ""
    }

    static func terminalOutput(_ message: ChatMessage) -> String? {
        guard message.toolName == "terminal", let value = decode(message.text) else { return nil }
        guard let output = value["output"]?.stringValue, output.nonempty != nil else { return nil }
        return output
    }

    static func reportsFailure(_ text: String) -> Bool {
        guard let value = decode(text) else { return false }
        if value["is_error"]?.boolValue == true || value["success"]?.boolValue == false { return true }
        if let exitCode = value["exit_code"]?.intValue, exitCode != 0 { return true }
        if let status = value["status"]?.stringValue, ["error", "failed"].contains(status) { return true }
        return value["error"]?.boolValue == true || value["error"]?.stringValue?.nonempty != nil
    }

    static func completedTodoResults(_ messages: [ChatMessage]) -> [String] {
        messages.compactMap { message in
            guard message.role == .tool, !message.isStreaming, !message.isError,
                  message.toolName == "todo_list" || message.toolName == "todo" else { return nil }
            return message.text
        }
    }

    static func latestTodos(_ messages: [ChatMessage]) -> [ReportedTodo]? {
        reportedTodos(in: completedTodoResults(messages))
    }

    static func reportedTodos(in results: [String]) -> [ReportedTodo]? {
        var latest: [ReportedTodo]?
        var highestRevision: Int?
        for text in results {
            guard let value = decode(text), !reportsFailure(text),
                  let items = todoArray(value), items.count <= 256 else { continue }
            let revision: Int?
            if let raw = todoRevision(value), raw != .null {
                // Malformed revisions must not bypass the stale-result guard.
                guard let parsed = raw.intValue, parsed >= 0, parsed <= 9_007_199_254_740_991 else { continue }
                revision = parsed
            } else { revision = nil }
            if let revision, let highestRevision, revision < highestRevision { continue }

            // The backend normalizes duplicate IDs by keeping the last occurrence.
            var byID: [String: (offset: Int, todo: ReportedTodo)] = [:]
            for (offset, value) in items.enumerated() {
                guard let id = value["id"]?.stringValue?.nonempty,
                      let content = value["content"]?.stringValue?.nonempty,
                      content.count <= 4_000,
                      let rawStatus = value["status"]?.stringValue,
                      let status = ReportedTodo.Status(rawValue: rawStatus) else { continue }
                byID[id] = (offset, ReportedTodo(id: id, content: content, status: status,
                    parent: value["parent"]?.stringValue?.nonempty))
            }
            let todos = byID.values.sorted { $0.offset < $1.offset }.map(\.todo)
            guard items.isEmpty || !todos.isEmpty else { continue }
            latest = todos // Explicit clears must not revive an older task list.
            if let revision { highestRevision = revision }
        }
        return latest
    }

    static func depth(of todo: ReportedTodo, in todos: [ReportedTodo]) -> Int {
        var depth = 0, node = todo
        var visited: Set<String> = [todo.id]
        while let parent = node.parent, let next = todos.first(where: { $0.id == parent }) {
            guard visited.insert(parent).inserted else { return 0 }
            depth += 1; node = next
        }
        return min(depth, 3)
    }

    private static func todoArray(_ value: JSONValue, depth: Int = 0) -> [JSONValue]? {
        guard depth <= 2 else { return nil }
        if let items = value.arrayValue { return items }
        if let nested = value["todos"] { return todoArray(nested, depth: depth + 1) }
        if let text = value.stringValue, let nested = decode(text) { return todoArray(nested, depth: depth + 1) }
        return nil
    }
    private static func todoRevision(_ value: JSONValue, depth: Int = 0) -> JSONValue? {
        guard depth <= 2 else { return nil }
        if let revision = value["revision"] { return revision }
        if let text = value.stringValue, let nested = decode(text) {
            return todoRevision(nested, depth: depth + 1)
        }
        return nil
    }
    private static func decode(_ text: String) -> JSONValue? {
        guard text.utf8.count <= 512_000, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
    private static func compact(_ text: String) -> String {
        let condensed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return condensed.count <= 60 ? condensed : String(condensed.prefix(59)) + "…"
    }
}

private extension String {
    var nonempty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
