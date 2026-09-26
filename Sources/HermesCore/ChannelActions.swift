import Foundation
import HermesProtocol
import HermesTransport

public typealias ChannelReader = @Sendable (GatewaySession, GatewayReadEndpoint) async throws -> JSONValue

public struct ChannelHandoffDestination: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let isAvailable: Bool
    public init(id: String, label: String, isAvailable: Bool) {
        self.id = id; self.label = label; self.isAvailable = isAvailable
    }
}
