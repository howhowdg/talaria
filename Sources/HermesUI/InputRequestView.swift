import Foundation
import SwiftUI
import HermesCore
import HermesProtocol

/// A session-scoped answer card. The owning model sends the response over the
/// connection that delivered the request and removes the card after settlement.
@MainActor
public struct InputRequestView: View {
    public let input: PendingInput
    private let onAnswer: @MainActor (JSONValue) async -> Bool

    @State private var secret = ""
    @State private var identifier = ""
    @State private var writtenAnswers: [String: String] = [:]
    @State private var selections: [String: Set<String>] = [:]
    @State private var submitting = false
    @State private var submissionID: UUID?

    public init(input: PendingInput, onAnswer: @escaping @MainActor (JSONValue) async -> Bool) {
        self.input = input
        self.onAnswer = onAnswer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(title).foregroundStyle(.primary)
            } icon: {
                Image(systemName: input.method == "clarify" ? "questionmark.bubble" : "lock.shield")
                    .foregroundStyle(TalariaStyle.accent)
            }
            .font(TalariaTypography.headline)
            switch input.method {
            case "approval": approvalBody
            case "clarify": clarificationBody
            case "sudo", "secret", "vault.code", "vault.unlock_prompt", "vault.save_login": secretBody
            default:
                Text("This request needs a feature that is not available in this build.")
                    .foregroundStyle(.secondary)
                Button("Decline") { answer(.object(["value": .string("")])) }
                    .talariaSecondaryButton()
            }
            if submitting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Sending response…").font(TalariaTypography.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary, lineWidth: 1))
        .disabled(submitting)
        .onChange(of: input.id) { _, _ in reset() }
        .onDisappear { clearValues() }
    }

    private var title: String {
        switch input.method {
        case "approval": "Permission requested"
        case "clarify": questions.count > 1 ? "A few questions for you" : "A question for you"
        case "sudo": "Administrator password"
        case "secret": input.params["env_var"]?.stringValue ?? "Secret requested"
        case "vault.unlock_prompt": "Unlock \(input.params["display_name"]?.stringValue ?? "password manager")"
        case "vault.save_login": "Save login for \(input.params["site"]?.stringValue ?? "this site")"
        case "vault.code": "Verification code"
        default: "Input requested"
        }
    }

    private var approvalChoices: [String] {
        let supplied = input.params["choices"]?.arrayValue?.compactMap(\.stringValue)
        let allowed: [String]
        if let supplied, !supplied.isEmpty { allowed = supplied }
        else { allowed = ["once", "session", "always", "deny"] }
        let smartDenied = input.params["smart_denied"]?.boolValue == true
        return ["once", "session", "always"].filter { choice in
            guard allowed.contains(choice) else { return false }
            if choice == "session" || choice == "always" {
                guard !smartDenied, input.params["allow_session"]?.boolValue != false else { return false }
            }
            return choice != "always" || input.params["allow_permanent"]?.boolValue != false
        }
    }

    private var approvalBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let description = nonempty("description") { Text(description) }
            command
            if input.params["smart_denied"]?.boolValue == true {
                Text("Hermes flagged this command for review. Permission is limited to this attempt.")
                    .font(TalariaTypography.callout).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { approvalButtons }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 10) { approvalButtons }
            }
        }
    }

    @ViewBuilder private var approvalButtons: some View {
        Button("Deny", role: .cancel) { answer(.object(["choice": .string("deny")])) }
            .talariaSecondaryButton()
        ForEach(approvalChoices, id: \.self) { choice in
            Button(approvalLabel(choice)) { answer(.object(["choice": .string(choice)])) }
                .talariaSecondaryButton()
        }
    }

    private func approvalLabel(_ choice: String) -> String {
        switch choice {
        case "once": "Allow once"
        case "session": "Allow for this session"
        case "always": "Always allow"
        default: choice
        }
    }

    @ViewBuilder private var command: some View {
        if let command = nonempty("command") {
            ScrollView(.horizontal) {
                Text(command).font(TalariaTypography.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Requested command: \(command)")
        }
    }

    private struct Question: Identifiable {
        let id: String
        let text: String
        let choices: [String]
        let multiple: Bool
    }

    private var isBatch: Bool { !(input.params["questions"]?.arrayValue ?? []).isEmpty }

    private var questions: [Question] {
        if isBatch {
            return (input.params["questions"]?.arrayValue ?? []).compactMap { item in
                guard let id = item["qid"]?.stringValue, let question = item["question"]?.stringValue else { return nil }
                return Question(id: id, text: question,
                                choices: item["choices"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                                multiple: item["multi_select"]?.boolValue ?? false)
            }
        }
        return [Question(id: "single", text: input.params["question"]?.stringValue ?? "How should Hermes proceed?",
                         choices: input.params["choices"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                         multiple: input.params["multi_select"]?.boolValue ?? false)]
    }

    private var lockedAnswers: [String: String] {
        (input.params["answers"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
    }

    private var clarificationBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 9) {
                    Text(question.text).font(TalariaTypography.body.weight(.medium)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let locked = lockedAnswers[question.id] {
                        Label(locked.isEmpty ? "Skipped" : locked, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                        Text("Already received by Hermes").font(TalariaTypography.caption).foregroundStyle(.secondary)
                    } else {
                        if question.multiple && !question.choices.isEmpty {
                            Text("Choose any that apply, or write your own answer.")
                                .font(TalariaTypography.caption).foregroundStyle(.secondary)
                        }
                        ForEach(Array(question.choices.enumerated()), id: \.offset) { _, choice in
                            Button { select(choice, for: question) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Image(systemName: selectedSymbol(choice, for: question))
                                        .foregroundStyle(selections[question.id, default: []].contains(choice) ? TalariaStyle.accent : Color.secondary)
                                    Text(choice).multilineTextAlignment(.leading)
                                        .foregroundStyle(.primary)
                                    Spacer(minLength: 0)
                                }
                                .frame(minHeight: choiceMinimumHeight, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityAddTraits(selections[question.id, default: []].contains(choice) ? [.isSelected] : [])
                        }
                        TextField(question.choices.isEmpty ? "Your answer" : "Or write your own answer",
                                  text: writtenBinding(for: question.id), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...5)
                            .frame(minHeight: choiceMinimumHeight)
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { clarificationActions }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 10) { clarificationActions }
            }
        }
    }

    @ViewBuilder private var clarificationActions: some View {
        Button(isBatch ? "Cancel questions" : "Skip", role: .cancel) {
            answer(isBatch ? .object([:]) : .object(["answer": .string("")]))
        }
        .talariaSecondaryButton()
        Button(isBatch ? "Send answers" : "Send answer") { sendClarification() }
            .talariaProminentButton()
            .disabled(questions.isEmpty || questions.contains { answerText(for: $0).isEmpty && lockedAnswers[$0.id] == nil })
    }

    private var choiceMinimumHeight: CGFloat {
        #if os(iOS)
        44
        #else
        28
        #endif
    }

    private func selectedSymbol(_ choice: String, for question: Question) -> String {
        let selected = selections[question.id, default: []].contains(choice)
        if question.multiple { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "largecircle.fill.circle" : "circle"
    }

    private func select(_ choice: String, for question: Question) {
        writtenAnswers[question.id] = ""
        if question.multiple {
            if selections[question.id, default: []].contains(choice) { selections[question.id]?.remove(choice) }
            else { selections[question.id, default: []].insert(choice) }
        } else { selections[question.id] = [choice] }
    }

    private func writtenBinding(for id: String) -> Binding<String> {
        Binding(get: { writtenAnswers[id, default: ""] }, set: { value in
            writtenAnswers[id] = value
            if !value.isEmpty { selections[id] = [] }
        })
    }

    private func answerText(for question: Question) -> String {
        if let locked = lockedAnswers[question.id] { return locked }
        let written = writtenAnswers[question.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        if !written.isEmpty { return written }
        let selected = question.choices.filter { selections[question.id, default: []].contains($0) }
        guard !selected.isEmpty else { return "" }
        // The gateway expects a JSON-encoded array inside the string answer.
        if question.multiple { return jsonString(.array(selected.map(JSONValue.string))) }
        return selected.first ?? ""
    }

    private func sendClarification() {
        if isBatch {
            var answers: [String: JSONValue] = [:]
            for question in questions { answers[question.id] = .string(answerText(for: question)) }
            answer(.object(["answers": .object(answers)]))
        } else if let question = questions.first {
            answer(.object(["answer": .string(answerText(for: question))]))
        }
    }

    private var secretBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let description = secretDescription { Text(description).foregroundStyle(.secondary) }
            if input.method == "sudo" { command }
            if input.method == "vault.save_login" {
                TextField("Username or email", text: $identifier).textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .frame(minHeight: choiceMinimumHeight)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }
            SecureField(input.method == "vault.code" ? "Verification code" : "Password or secret", text: $secret)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .frame(minHeight: choiceMinimumHeight)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { secretActions }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 10) { secretActions }
            }
        }
    }

    @ViewBuilder private var secretActions: some View {
        Button(input.method == "vault.save_login" ? "Don't save" : "Cancel", role: .cancel) {
            answer(.object(["value": .string("")]))
        }
        .talariaSecondaryButton()
        Button(input.method == "vault.save_login" ? "Save login" : "Send") { sendSecret() }
            .talariaProminentButton()
            .disabled(!canSendSecret)
    }

    private var secretDescription: String? {
        switch input.method {
        case "secret": nonempty("prompt")
        case "vault.save_login": nonempty("origin")
        case "vault.code": [nonempty("site"), nonempty("hint")].compactMap { $0 }.joined(separator: " · ")
        case "vault.unlock_prompt": "Unlock this password manager for the current session."
        case "sudo": "The requested command needs an administrator password on the Hermes host."
        default: nil
        }
    }

    private var normalizedCode: String {
        secret.filter { !$0.isWhitespace && $0 != "-" }
    }

    private var canSendSecret: Bool {
        if input.method == "vault.code" { return !normalizedCode.isEmpty }
        if input.method == "vault.save_login" {
            return !secret.isEmpty && !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !secret.isEmpty
    }

    private func sendSecret() {
        guard canSendSecret else { return }
        var value = secret
        if input.method == "vault.code" { value = normalizedCode }
        if input.method == "vault.save_login" {
            value = jsonString(.object([
                "identifier": .string(identifier.trimmingCharacters(in: .whitespacesAndNewlines)),
                "password": .string(secret)
            ]))
        }
        answer(.object(["value": .string(value)]))
    }

    private func jsonString(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func nonempty(_ key: String) -> String? {
        guard let value = input.params[key]?.stringValue, !value.isEmpty else { return nil }
        return value
    }

    private func answer(_ value: JSONValue) {
        guard !submitting else { return }
        submitting = true
        let attempt = UUID()
        submissionID = attempt
        // Passwords are cleared as soon as they leave the field. Keep ordinary
        // clarification drafts available if the response cannot be sent.
        secret = ""
        identifier = ""
        Task { @MainActor in
            let sent = await onAnswer(value)
            guard submissionID == attempt else { return }
            if sent { clearValues() }
            else { submitting = false }
        }
    }

    private func clearValues() {
        secret = ""
        identifier = ""
        writtenAnswers.removeAll()
        selections.removeAll()
    }

    private func reset() {
        clearValues()
        submissionID = nil
        submitting = false
    }
}
