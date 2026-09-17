import Foundation
import Darwin
import UniformTypeIdentifiers
import HermesTransport

public typealias AttachmentScope = ComposerScope

public enum AttachmentKind: String, Sendable, Equatable { case image, file }

public enum AttachmentError: Error, LocalizedError, Sendable, Equatable {
    case unreadable, regularFileRequired, tooLarge, empty, unsupportedImage, invalidPDF, invalidName
    case wrongOwner, workspaceUnavailable, invalidReference, tooManyFiles

    public var errorDescription: String? {
        switch self {
        case .unreadable: "The selected file could not be read. Choose it again and check its permissions."
        case .regularFileRequired: "Choose a regular file. Folders, packages, and symbolic links cannot be attached."
        case .tooLarge: "Attachments in this preview must be 20 MB or smaller."
        case .empty: "The selected file is empty."
        case .unsupportedImage: "Choose a PNG, JPEG, GIF, WebP, or BMP image. Image conversion is not available yet."
        case .invalidPDF: "The selected PDF does not have a valid PDF header."
        case .invalidName: "The attachment filename is not valid."
        case .wrongOwner: "This attachment belongs to a different connection, profile, or conversation."
        case .workspaceUnavailable: "Hermes has not provided a working directory for this conversation."
        case .invalidReference: "The uploaded attachment has an invalid gateway reference."
        case .tooManyFiles: "Attach up to 8 files, totaling no more than 64 MB per message."
        }
    }
}

/// Device bytes staged in memory for exactly one composer. This deliberately is
/// not Codable: attachments are never written into ordinary persisted drafts.
public struct StagedAttachment: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let scope: AttachmentScope
    public let filename: String
    public let kind: AttachmentKind
    public let mimeType: String
    public var byteCount: Int { data.count }
    fileprivate let data: Data
}

public struct UploadedAttachment: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let scope: AttachmentScope
    public let filename: String
    public let kind: AttachmentKind
    public let mimeType: String
    public let byteCount: Int
    /// Opaque host path; never pass this to Foundation device file APIs.
    public let hostPath: String
    public let relativePath: String?
    public var promptReference: String? {
        guard kind == .file, let relativePath else { return nil }
        return "@file:\(relativePath)"
    }

    public init(id: UUID, scope: AttachmentScope, filename: String, kind: AttachmentKind,
                mimeType: String, byteCount: Int, hostPath: String, relativePath: String? = nil) {
        self.id = id; self.scope = scope; self.filename = filename; self.kind = kind
        self.mimeType = mimeType; self.byteCount = byteCount; self.hostPath = hostPath
        self.relativePath = relativePath
    }
}

public enum AttachmentLoader {
    public static let maximumBytes = GatewayUploadClient.maximumBytes
    public static let maximumCount = 8
    public static let maximumBatchBytes = 64 * 1_024 * 1_024

    public static func read(url: URL, scope: AttachmentScope) async throws -> StagedAttachment {
        // Keep security-scoped access alive for the entire coordinated read,
        // including iCloud/file-provider materialization. File I/O stays off UI.
        let task = Task.detached(priority: .userInitiated) {
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            guard url.isFileURL else { throw AttachmentError.regularFileRequired }
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isPackageKey])
            guard values.isSymbolicLink != true, values.isDirectory != true, values.isPackage != true else { throw AttachmentError.regularFileRequired }
            var result: Result<StagedAttachment, Error>?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinated in
                result = Result {
                    let bytes = try readRegularFile(coordinated)
                    return try stage(data: bytes, filename: url.lastPathComponent, scope: scope)
                }
            }
            try Task.checkCancellation()
            if let result { return try result.get() }
            throw AttachmentError.unreadable
        }
        return try await withTaskCancellationHandler {
            do { return try await task.value }
            catch is CancellationError { throw CancellationError() }
            catch let error as AttachmentError { throw error }
            catch { throw AttachmentError.unreadable }
        } onCancel: { task.cancel() }
    }

    /// Validated in-memory staging is also useful for native paste/drop and fixtures.
    public static func stage(data: Data, filename: String, scope: AttachmentScope) throws -> StagedAttachment {
        guard !data.isEmpty else { throw AttachmentError.empty }
        guard data.count <= maximumBytes else { throw AttachmentError.tooLarge }
        guard !filename.isEmpty, filename.count <= 255, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\"),
              !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw AttachmentError.invalidName }
        let ext = (filename as NSString).pathExtension.lowercased()
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "tif", "tiff", "svg", "ico", "avif"]
        let format = GatewayImageFormat.detect(data)
        let kind: AttachmentKind
        let mimeType: String
        if let format {
            kind = .image
            mimeType = format.rawValue
        } else if imageExtensions.contains(ext) {
            throw AttachmentError.unsupportedImage
        } else {
            if ext == "pdf" && !data.starts(with: Data("%PDF-".utf8)) { throw AttachmentError.invalidPDF }
            kind = .file
            mimeType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
        return StagedAttachment(id: UUID(), scope: scope, filename: filename, kind: kind, mimeType: mimeType, data: data)
    }

    private static func readRegularFile(_ url: URL) throws -> Data {
        // O_NOFOLLOW rejects a symlink swapped in after selection. O_NONBLOCK
        // prevents a FIFO/device from hanging before fstat can reject its type.
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw AttachmentError.unreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw AttachmentError.unreadable }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw AttachmentError.regularFileRequired }
        guard metadata.st_size <= maximumBytes else { throw AttachmentError.tooLarge }
        var data = Data()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, maximumBytes - data.count + 1)), !chunk.isEmpty else { break }
            data.append(chunk)
            guard data.count <= maximumBytes else { throw AttachmentError.tooLarge }
        }
        return data
    }
}

/// A transfer writes bytes to the captured host/profile; it never queues an
/// image or sends a prompt. Caller must discard results whose composer changed.
public struct AttachmentTransferService: Sendable {
    private let uploader: GatewayUploadClient
    public init(upload: GatewayUploadClient = GatewayUploadClient()) { self.uploader = upload }

    public func upload(_ attachment: StagedAttachment, workspace: String,
                       endpoint: GatewayEndpoint, token: String) async throws -> UploadedAttachment {
        guard endpoint.id == attachment.scope.connectionID, endpoint.profile == attachment.scope.profile else { throw AttachmentError.wrongOwner }
        try Task.checkCancellation()
        let result: GatewayUploadResult
        let relativePath: String?
        if attachment.kind == .image {
            relativePath = nil
            result = try await uploader.uploadImage(data: attachment.data, filename: attachment.filename, endpoint: endpoint, token: token)
        } else {
            let base = try Self.workspacePath(workspace)
            let relative = ".hermes/native-attachments/\(attachment.id.uuidString.lowercased())/\(Self.safeFilename(attachment.filename))"
            relativePath = relative
            result = try await uploader.uploadFile(data: attachment.data, filename: attachment.filename, mimeType: attachment.mimeType,
                                                 hostPath: base + "/" + relative, endpoint: endpoint, token: token)
        }
        try Task.checkCancellation()
        return UploadedAttachment(id: attachment.id, scope: attachment.scope, filename: attachment.filename, kind: attachment.kind,
                                  mimeType: attachment.mimeType, byteCount: result.byteCount, hostPath: result.hostPath, relativePath: relativePath)
    }

    private static func workspacePath(_ value: String) throws -> String {
        let characters = Array(value)
        let absolute = value.hasPrefix("/") || value.hasPrefix("\\\\") ||
            (characters.count >= 3 && characters[0].isLetter && characters[1] == ":" && (characters[2] == "\\" || characters[2] == "/"))
        guard absolute, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !value.replacingOccurrences(of: "\\", with: "/").split(separator: "/").contains("..") else { throw AttachmentError.workspaceUnavailable }
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    private static func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let clean = String(value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" })
        let ext = (clean as NSString).pathExtension
        let suffix = !ext.isEmpty && ext.count <= 20 ? "." + ext : ""
        let stem = suffix.isEmpty ? clean : (clean as NSString).deletingPathExtension
        let result = (String(stem.prefix(160 - suffix.count)) + suffix).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return result.isEmpty ? "attachment" : result
    }
}

public enum AttachmentPrompt {
    public static func compose(text: String, attachments: [UploadedAttachment], scope: AttachmentScope) throws -> String {
        guard attachments.count <= AttachmentLoader.maximumCount,
              attachments.allSatisfy({ $0.byteCount > 0 && $0.byteCount <= AttachmentLoader.maximumBytes }),
              attachments.reduce(0, { $0 + $1.byteCount }) <= AttachmentLoader.maximumBatchBytes else { throw AttachmentError.tooManyFiles }
        guard attachments.allSatisfy({ $0.scope == scope }) else { throw AttachmentError.wrongOwner }
        var refs: [String] = []
        for attachment in attachments where attachment.kind == .file {
            guard let relative = attachment.relativePath,
                  relative.hasPrefix(".hermes/native-attachments/"),
                  !relative.split(separator: "/").contains(".."),
                  relative.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/").contains($0) }),
                  let reference = attachment.promptReference else { throw AttachmentError.invalidReference }
            refs.append(reference)
        }
        let caption = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = caption.isEmpty && !attachments.isEmpty ? "Please review the attached files." : text
        return ([message] + refs).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

public enum AttachmentTransferState: Sendable, Equatable { case reading, uploading, ready, failed(String) }

public struct AttachmentItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let filename: String
    public let kind: AttachmentKind?
    public let byteCount: Int?
    public let state: AttachmentTransferState
    public let destination: String?
    public init(id: UUID, filename: String, kind: AttachmentKind? = nil, byteCount: Int? = nil,
                state: AttachmentTransferState, destination: String? = nil) {
        self.id = id; self.filename = filename; self.kind = kind; self.byteCount = byteCount
        self.state = state; self.destination = destination
    }
}
