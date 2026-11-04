import Darwin
import Foundation
import XCTest
@testable import SwiftIRCClient
@testable import SwiftIRCCore

final class IRCClientTests: XCTestCase {
    func testTLSUsesTheStandardPort() {
        XCTAssertEqual(IRCClient(host: "irc.example", useTLS: true).port, IRC.tlsPort)
        XCTAssertEqual(IRCClient(host: "irc.example").port, IRC.cleartextPort)
    }

    func testRegistrationSpeaksRFC2812OrderAndAnswersPing() throws {
        let server = try ScriptedServer()
        defer { server.stop() }
        let client = IRCClient(host: "127.0.0.1", port: server.port)
        try client.connect()
        defer { client.close() }

        let finished = expectation(description: "registered")
        var received: [IRCMessage] = []
        var failure: Error?
        DispatchQueue.global().async {
            do {
                received = try client.register(
                    password: "secret",
                    nickname: "Wiz",
                    username: "guest",
                    realName: "Ronnie Reagan",
                    mode: .invisible
                )
                finished.fulfill()
            } catch {
                failure = error
                finished.fulfill()
            }
        }

        XCTAssertTrue(server.waitUntil { $0.contains("USER guest 8 * :Ronnie Reagan") })
        server.send("PING :register")
        XCTAssertTrue(server.waitUntil { $0.contains("PONG register") })
        server.send(":irc.example.net 001 Wiz :Welcome to the Internet Relay Network Wiz!guest@127.0.0.1")
        wait(for: [finished], timeout: 10)
        XCTAssertNil(failure)
        XCTAssertTrue(client.isRegistered)
        XCTAssertEqual(client.nickname, "Wiz")
        XCTAssertEqual(received.first?.numeric, .welcome)

        let transcript = server.received()
        let pass = transcript.range(of: "PASS secret")
        let nick = transcript.range(of: "NICK Wiz")
        let user = transcript.range(of: "USER guest")
        let pong = transcript.range(of: "PONG register")
        XCTAssertNotNil(pass)
        XCTAssertNotNil(nick)
        XCTAssertNotNil(user)
        XCTAssertNotNil(pong)
        if let pass = pass, let nick = nick, let user = user, let pong = pong {
            XCTAssertLessThan(pass.lowerBound, nick.lowerBound)
            XCTAssertLessThan(nick.lowerBound, user.lowerBound)
            XCTAssertLessThan(user.lowerBound, pong.lowerBound)
        }
    }

    func testPasswordAfterNickIsRejected() throws {
        let server = try ScriptedServer()
        defer { server.stop() }
        let client = IRCClient(host: "127.0.0.1", port: server.port)
        try client.connect()
        defer { client.close() }
        try client.send(.nick("Wiz"))
        XCTAssertThrowsError(try client.send(.pass("late"))) { error in
            XCTAssertEqual(error as? IRCError, .passwordSentTooLate)
        }
    }

    func testNicknameInUseFailsRegistration() throws {
        let server = try ScriptedServer()
        defer { server.stop() }
        let client = IRCClient(host: "127.0.0.1", port: server.port)
        try client.connect()
        defer { client.close() }

        DispatchQueue.global().async {
            _ = server.waitUntil { $0.contains("NICK Wiz") }
            server.send(":irc.example.net 433 * Wiz :Nickname is already in use")
        }
        XCTAssertThrowsError(
            try client.register(nickname: "Wiz", username: "guest", realName: "Ronnie Reagan")
        ) { error in
            XCTAssertEqual(
                error as? IRCError,
                .registrationFailed(numeric: 433, message: "Nickname is already in use")
            )
        }
        XCTAssertFalse(client.isRegistered)
    }
}

private final class ScriptedServer {
    let port: UInt16
    private let condition = NSCondition()
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var text = ""

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IRCError.connectionFailed(String(cString: strerror(errno)))
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(fd, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw IRCError.connectionFailed(String(cString: strerror(errno)))
        }
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                getsockname(fd, pointer, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(fd)
            throw IRCError.connectionFailed(String(cString: strerror(errno)))
        }
        port = UInt16(bigEndian: boundAddress.sin_port)
        listenFD = fd
        Thread.detachNewThread { [weak self] in
            self?.acceptClient()
        }
    }

    func stop() {
        if clientFD >= 0 {
            Darwin.close(clientFD)
            clientFD = -1
        }
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
    }

    func received() -> String {
        condition.lock()
        defer { condition.unlock() }
        return text
    }

    func waitUntil(_ predicate: (String) -> Bool) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while !predicate(text) {
            if !condition.wait(until: deadline) {
                return false
            }
        }
        return true
    }

    func send(_ line: String) {
        let bytes = Array((line + "\r\n").utf8)
        condition.lock()
        let fd = clientFD
        condition.unlock()
        guard fd >= 0 else {
            return
        }
        _ = bytes.withUnsafeBytes { raw in
            Darwin.send(fd, raw.baseAddress, bytes.count, 0)
        }
    }

    private func acceptClient() {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else {
            return
        }
        condition.lock()
        clientFD = fd
        condition.unlock()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else {
                    return -1
                }
                return recv(fd, base, raw.count, 0)
            }
            if count <= 0 {
                break
            }
            condition.lock()
            text += String(bytes: buffer.prefix(count), encoding: .utf8) ?? ""
            condition.signal()
            condition.unlock()
        }
    }
}
