import Foundation
import HermesProtocol

public enum GatewayImageFormat: String, Sendable, Equatable {
    case png = "image/png", jpeg = "image/jpeg", gif = "image/gif", webp = "image/webp", bmp = "image/bmp"

    public static func detect(_ data: Data) -> Self? {
        let head = Array(data.prefix(16))
        if head.starts(with: [0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10]) { return .png }
        if head.starts(with: [0xff, 0xd8, 0xff]) { return .jpeg }
        if head.starts(with: Array("GIF87a".utf8)) || head.starts(with: Array("GIF89a".utf8)) { return .gif }
        if head.starts(with: Array("BM".utf8)) { return .bmp }
        if head.count >= 12 && head[0..<4].elementsEqual("RIFF".utf8) && head[8..<12].elementsEqual("WEBP".utf8) { return .webp }
        return nil
    }
}

public enum GatewayUploadError: Error, LocalizedError, Sendable, Equatable {
    case emptyFile, tooLarge, unsupportedImage, invalidFilename, invalidHostPath, transferFailed, invalidResponse
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyFile: "The selected file is empty."
        case .tooLarge: "Attachments in this preview must be 20 MB or smaller."
        case .unsupportedImage: "Choose a PNG, JPEG, GIF, WebP, or BMP image."
        case .invalidFilename: "The attachment filename is not valid."
        case .invalidHostPath: "Hermes did not provide a valid destination for the attachment."
        case .transferFailed: "The attachment could not be uploaded. Check the connection and try again."
        case .invalidResponse: "Hermes returned an invalid upload response."
        case .httpStatus(let status): "The attachment upload failed (HTTP \(status))."
        }
    }
}

/// An opaque gateway filesystem path. Never resolve this against the device filesystem.
public struct GatewayUploadResult: Sendable, Equatable {
    public let hostPath: String
    public let byteCount: Int
    public init(hostPath: String, byteCount: Int) {
        self.hostPath = hostPath
        self.byteCount = byteCount
    }
}

/// Profile-scoped HTTP uploads do not queue images or submit any prompt.
/// The bounded body is in memory; multipart avoids base64 growth for documents.
public struct GatewayUploadClient: Sendable {
    public static let maximumBytes = 20 * 1_024 * 1_024
    private let http: any GatewayHTTPTransport

    public init() { http = URLSessionGatewayNetwork() }
    init(http: any GatewayHTTPTransport) { self.http = http }

    public func uploadImage(data: Data, filename: String, endpoint: GatewayEndpoint, token: String) async throws -> GatewayUploadResult {
        try validate(data: data, filename: filename)
        guard let format = GatewayImageFormat.detect(data) else { throw GatewayUploadError.unsupportedImage }
        var request = try uploadRequest(endpoint: endpoint, token: token, route: "chat/image-upload")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object([
            "filename": .string(filename),
            "data_url": .string("data:\(format.rawValue);base64,\(data.base64EncodedString())")
        ]))
        let result = try await send(request)
        guard result["bytes"]?.intValue == data.count else { throw GatewayUploadError.invalidResponse }
        return try validatedResult(result, byteCount: data.count)
    }

    public func uploadFile(data: Data, filename: String, mimeType: String, hostPath: String,
                           endpoint: GatewayEndpoint, token: String) async throws -> GatewayUploadResult {
        try validate(data: data, filename: filename)
        guard Self.validHostPath(hostPath), !mimeType.isEmpty,
              !mimeType.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw GatewayUploadError.invalidHostPath
        }
        var request = try uploadRequest(endpoint: endpoint, token: token, route: "files/upload-stream")
        let boundary = "HermesNative-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func append(_ string: String) { body.append(contentsOf: string.utf8) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"path\"\r\n\r\n\(hostPath)\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\nfalse\r\n")
        let safeName = filename.replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: "\"", with: "_")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        request.httpBody = body
        let result = try await send(request)
        return try validatedResult(result, byteCount: data.count)
    }

    private func uploadRequest(endpoint: GatewayEndpoint, token: String, route: String) throws -> URLRequest {
        guard !token.isEmpty else { throw GatewayTransportError.missingToken }
        guard !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw GatewayTransportError.authenticationRejected
        }
        // Reuse the existing endpoint validation, profile query, secret header,
        // and reverse-proxy base-path handling without putting secrets in a URL.
        var request = try GatewayRoutes(endpoint: endpoint).statusRequest(token: token)
        guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path.hasSuffix("/api/status") else { throw GatewayTransportError.invalidEndpoint }
        components.path = String(components.path.dropLast("status".count)) + route
        guard let uploadURL = components.url else { throw GatewayTransportError.invalidEndpoint }
        request.url = uploadURL
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        return request
    }

    private func send(_ request: URLRequest) async throws -> JSONValue {
        do {
            try Task.checkCancellation()
            let response = try await http.data(for: request)
            // A canceled transfer can still finish on the host, but never becomes
            // a sendable attachment in this client after cancellation.
            try Task.checkCancellation()
            if response.status == 401 || response.status == 403 { throw GatewayTransportError.authenticationRejected }
            guard (200..<300).contains(response.status) else { throw GatewayUploadError.httpStatus(response.status) }
            guard let result = try? JSONDecoder().decode(JSONValue.self, from: response.data), result["ok"]?.boolValue == true else {
                throw GatewayUploadError.invalidResponse
            }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch let error as GatewayUploadError { throw error }
        catch let error as GatewayTransportError { throw error }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw GatewayUploadError.transferFailed
        }
    }

    private func validatedResult(_ value: JSONValue, byteCount: Int) throws -> GatewayUploadResult {
        guard let path = value["path"]?.stringValue, Self.validHostPath(path) else { throw GatewayUploadError.invalidResponse }
        return GatewayUploadResult(hostPath: path, byteCount: byteCount)
    }

    private func validate(data: Data, filename: String) throws {
        guard !data.isEmpty else { throw GatewayUploadError.emptyFile }
        guard data.count <= Self.maximumBytes else { throw GatewayUploadError.tooLarge }
        guard !filename.isEmpty, filename.count <= 255, !filename.contains("/"), !filename.contains("\\"),
              !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw GatewayUploadError.invalidFilename
        }
    }

    static func validHostPath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        let chars = Array(value)
        return value.hasPrefix("/") || value.hasPrefix("\\\\") ||
            (chars.count >= 3 && chars[0].isLetter && chars[1] == ":" && (chars[2] == "\\" || chars[2] == "/"))
    }
}
