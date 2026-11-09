import Foundation
import XCTest
@testable import SwiftIRCClient
@testable import SwiftIRCCore
@testable import SwiftIRCServer

final class IRCServerTests: XCTestCase {
    func testChannelTracksMembershipAndTopicLock() {
        let channel = IRCChannel(name: "#Swift")
        XCTAssertTrue(channel.noExternalMessages)
        XCTAssertTrue(channel.topicLocked)
        channel.add(nickname: "Wiz", membership: IRCMembership(isOperator: true))
        channel.add(nickname: "Kilroy", membership: IRCMembership(hasVoice: true))
        XCTAssertEqual(channel.membership(for: "wiz")?.isOperator, true)
        XCTAssertEqual(channel.membership(for: "Kilroy")?.namesPrefix, "+")
        channel.rename(from: "Kilroy", to: "Kit")
        XCTAssertNil(channel.membership(for: "Kilroy"))
        XCTAssertEqual(channel.membership(for: "Kit")?.hasVoice, true)
        channel.remove(nickname: "Wiz")
        XCTAssertNil(channel.membership(for: "Wiz"))
    }

    func testClientRegistersAndReceivesAChannelMessage() throws {
        let server = IRCServer(name: "irc.example.net")
        try server.start()
        defer { server.stop() }

        let wiz = IRCClient(host: "127.0.0.1", port: server.port)
        try wiz.connect()
        defer { wiz.close() }
        let welcome = try wiz.register(nickname: "Wiz", username: "guest", realName: "Ronnie Reagan")
        XCTAssertEqual(welcome.first?.numeric, .welcome)
        XCTAssertTrue(wiz.isRegistered)

        let kilroy = IRCClient(host: "127.0.0.1", port: server.port)
        try kilroy.connect()
        defer { kilroy.close() }
        _ = try kilroy.register(nickname: "Kilroy", username: "guest", realName: "Kilroy")

        try wiz.send(.join(channels: ["#swift"]))
        _ = try waitFor(wiz, command: "366")
        try kilroy.send(.join(channels: ["#swift"]))
        _ = try waitFor(kilroy, command: "366")
        _ = try waitFor(wiz, command: "JOIN")

        try kilroy.send(.privmsg(target: "#swift", text: "hello wiz"))
        let message = try waitFor(wiz, command: "PRIVMSG")
        XCTAssertEqual(message.parameters, ["#swift", "hello wiz"])
        XCTAssertEqual(message.prefix?.origin, .user(nick: "Kilroy", username: "guest", host: "127.0.0.1"))
    }

    func testNicknameInUseIsRejected() throws {
        let server = IRCServer(name: "irc.example.net")
        try server.start()
        defer { server.stop() }

        let first = IRCClient(host: "127.0.0.1", port: server.port)
        try first.connect()
        defer { first.close() }
        _ = try first.register(nickname: "Wiz", username: "guest", realName: "Ronnie")

        let second = IRCClient(host: "127.0.0.1", port: server.port)
        try second.connect()
        defer { second.close() }
        XCTAssertThrowsError(
            try second.register(nickname: "Wiz", username: "guest", realName: "Other")
        ) { error in
            XCTAssertEqual(
                error as? IRCError,
                .registrationFailed(numeric: 433, message: "Nickname is already in use")
            )
        }
        XCTAssertFalse(second.isRegistered)
    }

    private func waitFor(_ client: IRCClient, command: String) throws -> IRCMessage {
        let deadline = Date().addingTimeInterval(5)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw IRCError.timedOut
            }
            guard let message = try client.receive(timeout: remaining) else {
                throw IRCError.unexpectedEnd
            }
            if message.command == command {
                return message
            }
        }
    }
}
