import SwiftUI
import HermesCore

/// Links only work whose creation the client explicitly recorded. Neither a
/// backend parent ID, a familiar title nor a recent session establishes lineage.
struct HierarchyHomeReferences: View {
    @Bindable var model: HermesAppModel
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    private var records: [SessionLineage] {
        guard let home = model.homeSessionID else { return [] }
        return model.hierarchyClassification.lineage.filter {
            $0.parentSessionID == home && ($0.kind == .branch || $0.kind == .delegated)
        }
    }
    private var workspaces: [TalariaWorkspace] {
        let children = Set(records.map(\.childSessionID))
        return model.workspaces.filter { !$0.isArchived && $0.sessionIDs.contains(where: children.contains) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(workspaces) { workspace in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        HierarchySwatch(color: workspace.swatch)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workspace.name).hierarchyFont(H.mobile ? 14 : 12.5, .semibold)
                            Text("Workspace · started from here").hierarchyFont(H.meta).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button("Open ›") { onNavigate(.workspace(workspace.id)) }
                            .buttonStyle(.plain).hierarchyFont(H.meta, .semibold).foregroundStyle(TalariaStyle.accent)
                            .frame(minHeight: H.mobile ? 44 : 24)
                    }
                    ForEach(records.filter { workspace.sessionIDs.contains($0.childSessionID) }) { record in
                        childRow(record)
                    }
                }.padding(12).hierarchyCard(opacity: H.mobile ? 0.7 : 0.6, radius: H.mobile ? 18 : 10)
            }
        }
    }

    private func childRow(_ record: SessionLineage) -> some View {
        let state = model.conversations[record.childSessionID]
        let waiting = state?.pendingInputs.isEmpty == false
        let name = state?.title ?? model.sessions.first { $0.id == record.childSessionID }?.displayTitle
            ?? (record.kind == .delegated ? "Delegated task" : "Conversation")
        return Button { onNavigate(.conversation(record.childSessionID)) } label: {
            HStack(spacing: 8) {
                Image(systemName: waiting ? "exclamationmark.circle.fill"
                      : record.kind == .delegated ? "arrow.turn.down.right" : "bubble.left")
                    .foregroundStyle(waiting ? TalariaStyle.attention : TalariaStyle.accent)
                Text(name).hierarchyFont(H.mobile ? 14 : 12).lineLimit(1)
                Spacer()
                if waiting {
                    Text("Needs you").hierarchyFont(H.mobile ? 11 : 9.5, .bold).foregroundStyle(TalariaStyle.attention)
                } else if state?.isRunning == true {
                    Label("Working", systemImage: "circle.fill").hierarchyFont(H.meta).foregroundStyle(TalariaStyle.accent)
                } else {
                    Text(record.kind == .delegated ? "Delegated task" : "Conversation").hierarchyFont(H.meta).foregroundStyle(.secondary)
                }
            }.frame(minHeight: H.mobile ? 44 : 26).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct HierarchyHomeOriginLink: View {
    @Bindable var model: HermesAppModel
    let workspace: TalariaWorkspace
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    private var startedHere: Bool {
        guard let home = model.homeSessionID else { return false }
        return model.hierarchyClassification.lineage.contains {
            $0.parentSessionID == home && workspace.sessionIDs.contains($0.childSessionID)
                && ($0.kind == .branch || $0.kind == .delegated)
        }
    }
    var body: some View {
        if startedHere {
            Button { onNavigate(.home) } label: { Label("Started from Home", systemImage: "house") }
                .buttonStyle(.plain).hierarchyFont(H.meta).foregroundStyle(TalariaStyle.accent)
                .frame(minHeight: H.mobile ? 28 : 24)
        }
    }
}
