import SwiftUI
import HermesCore

/// Composer attachment chips. Selection/import is owned by the containing view.
public struct AttachmentStrip: View {
    public let items: [AttachmentItem]
    private let onRemove: @MainActor (UUID) -> Void
    @ScaledMetric(relativeTo: .callout) private var textWidth: CGFloat = 170

    public init(items: [AttachmentItem], onRemove: @escaping @MainActor (UUID) -> Void) {
        self.items = items
        self.onRemove = onRemove
    }

    public var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: item.kind == .image ? "photo" : "doc")
                            .font(.body).foregroundStyle(TalariaStyle.accent).padding(.top, 2)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.filename).font(.callout.weight(.medium)).lineLimit(2)
                                .truncationMode(.middle)
                            status(item)
                            if let destination = item.destination, !destination.isEmpty {
                                Text("On Hermes host: \(destination)").font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(2).truncationMode(.middle)
                            }
                        }
                        .frame(width: textWidth, alignment: .leading)
                        Button { onRemove(item.id) } label: {
                            Image(systemName: "xmark").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                                .frame(width: removalTargetSize, height: removalTargetSize)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel("Remove \(item.filename)")
                        .help("Remove attachment")
                    }
                    .padding(10)
                    .background(.background, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 1))
                }
            }
            .padding(.vertical, 3)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attachments")
    }

    private var removalTargetSize: CGFloat {
        #if os(iOS)
        44
        #else
        28
        #endif
    }

    @ViewBuilder private func status(_ item: AttachmentItem) -> some View {
        switch item.state {
        case .reading, .uploading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(item.state == .reading ? "Reading…" : "Uploading…").font(.caption).foregroundStyle(.secondary)
            }
        case .ready:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                Text(item.byteCount.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "Ready")
                    .foregroundStyle(.secondary)
            }.font(.caption)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.red).lineLimit(3)
        }
    }
}
