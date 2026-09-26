import Foundation
import XCTest
@testable import HermesMacServices

final class SSHTunnelManagerTests: XCTestCase {
    func testArgumentsConstrainTheForwardAndHostVerification() throws {
        let key = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("test".utf8).write(to: key)
        defer { try? FileManager.default.removeItem(at: key) }
        let config = SSHConfiguration(host: "mini.tailnet.ts.net", user: "tom", sshPort: 2222,
                                      identityFile: key, gatewayPort: 8642, gatewayPath: "/api")
        try SSHLaunch.validate(config)
        XCTAssertEqual(SSHLaunch.arguments(for: config, localPort: 54321), [
            "-v", "-N", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "ExitOnForwardFailure=yes", "-o", "PermitLocalCommand=no",
            "-o", "ForwardAgent=no", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-p", "2222", "-i", key.path,
            "-L", "127.0.0.1:54321:127.0.0.1:8642", "tom@mini.tailnet.ts.net"
        ])
    }

    func testRejectsMalformedDestinationsAndPorts() {
        for host in ["", "-oProxyCommand=evil", "a b", "host@other", "host\nother"] {
            XCTAssertThrowsError(try SSHLaunch.validate(SSHConfiguration(host: host, gatewayPort: 8642)))
        }
        XCTAssertThrowsError(try SSHLaunch.validate(SSHConfiguration(host: "mini", user: "bad user", gatewayPort: 8642)))
        XCTAssertThrowsError(try SSHLaunch.validate(SSHConfiguration(host: "mini", gatewayPort: 0)))
        XCTAssertThrowsError(try SSHLaunch.validate(SSHConfiguration(host: "mini", gatewayPort: 8642, gatewayPath: "//evil")))
    }

    func testReadyParserWaitsForCompleteLoopbackPort() {
        XCTAssertEqual(SSHLaunch.readyPort(in: "debug1: Local forwarding listening on 127.0.0.1 port 54321.\r\n"), 54321)
        XCTAssertNil(SSHLaunch.readyPort(in: "debug1: Local forwarding listening on 127.0.0.1 port 543"))
        XCTAssertNil(SSHLaunch.readyPort(in: "debug1: Local forwarding listening on ::1 port 54321.\n"))
        XCTAssertNil(SSHLaunch.readyPort(in: "debug1: Local forwarding listening on 127.0.0.1 port 0.\n"))
    }

    func testResolvedSSHConfigRejectsInheritedForwards() {
        let config = SSHConfiguration(host: "mini", gatewayPort: 8642)
        let intended = "localforward [127.0.0.1]:54321 [127.0.0.1]:8642"
        XCTAssertTrue(SSHLaunch.resolvedForwardingsAreSafe("hostname mini\n\(intended)\n", config: config, localPort: 54321))
        XCTAssertFalse(SSHLaunch.resolvedForwardingsAreSafe("hostname mini\n\(intended)\nlocalforward [::1]:1234 [::1]:4321\n", config: config, localPort: 54321))
        XCTAssertFalse(SSHLaunch.resolvedForwardingsAreSafe("hostname mini\n\(intended)\nremoteforward 1234 localhost:4321\n", config: config, localPort: 54321))
        XCTAssertFalse(SSHLaunch.resolvedForwardingsAreSafe("hostname mini\n", config: config, localPort: 54321))
    }

    func testAllocatedPortIsLoopbackAndAvailable() throws {
        let port = try SSHLaunch.availablePort()
        XCTAssertTrue((1...65_535).contains(port))
    }
}
