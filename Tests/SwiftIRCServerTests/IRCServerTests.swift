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

    func testCapabilityNegotiationDelaysWelcomeUntilEnd() throws {
        let server = IRCServer(name: "irc.example.net")
        try server.start()
        defer { server.stop() }

        let client = IRCClient(host: "127.0.0.1", port: server.port)
        try client.connect()
        defer { client.close() }

        try client.send(IRCCommand(name: "CAP", parameters: ["LS", "302"]))
        let listed = try waitFor(client, command: "CAP")
        XCTAssertEqual(listed.parameters, ["*", "LS", "message-tags"])

        try client.send(.nick("Wiz"))
        try client.send(.user(username: "guest", realName: "Ronnie Reagan"))
        try client.send(IRCCommand(name: "CAP", parameters: ["REQ", "not-a-cap"]))
        let rejected = try waitFor(client, command: "CAP", forbid: "001")
        XCTAssertEqual(rejected.parameters, ["Wiz", "NAK", "not-a-cap"])

        try client.send(IRCCommand(name: "CAP", parameters: ["REQ", "message-tags"]))
        let accepted = try waitFor(client, command: "CAP", forbid: "001")
        XCTAssertEqual(accepted.parameters, ["Wiz", "ACK", "message-tags"])

        try client.send(IRCCommand(name: "CAP", parameters: ["LIST"]))
        let enabled = try waitFor(client, command: "CAP", forbid: "001")
        XCTAssertEqual(enabled.parameters, ["Wiz", "LIST", "message-tags"])

        try client.send(IRCCommand(name: "CAP", parameters: ["NOPE"]))
        let invalid = try waitFor(client, command: "410", forbid: "001")
        XCTAssertEqual(invalid.parameters, ["Wiz", "NOPE", "Invalid CAP command"])

        try client.send(IRCCommand(name: "CAP", parameters: ["END"]))
        let welcome = try waitFor(client, command: "001")
        XCTAssertEqual(welcome.numeric, .welcome)
    }

    func testMessageTagsAreRelayedOnlyToCapableClients() throws {
        let server = IRCServer(name: "irc.example.net")
        try server.start()
        defer { server.stop() }

        let plain = IRCClient(host: "127.0.0.1", port: server.port)
        try plain.connect()
        defer { plain.close() }
        _ = try plain.register(nickname: "Plain", username: "guest", realName: "Plain")

        let sender = try connectWithMessageTags(server, nickname: "Wiz")
        defer { sender.close() }
        let watcher = try connectWithMessageTags(server, nickname: "Kit")
        defer { watcher.close() }

        let tags = IRCTags(entries: [IRCTag(key: "msgid", value: "abc def")])
        let toPlain = try IRCMessage(command: "PRIVMSG", parameters: ["Plain", "hello"], tags: tags)
        try sender.send(toPlain)
        let stripped = try waitFor(plain, command: "PRIVMSG")
        XCTAssertTrue(stripped.tags.isEmpty)
        XCTAssertEqual(stripped.parameters, ["Plain", "hello"])

        let toWatcher = try IRCMessage(command: "PRIVMSG", parameters: ["Kit", "hello"], tags: tags)
        try sender.send(toWatcher)
        let kept = try waitFor(watcher, command: "PRIVMSG")
        XCTAssertEqual(kept.tags.entries, [IRCTag(key: "msgid", value: "abc def")])
        XCTAssertEqual(kept.parameters, ["Kit", "hello"])
    }

    private func connectWithMessageTags(_ server: IRCServer, nickname: String) throws -> IRCClient {
        let client = IRCClient(host: "127.0.0.1", port: server.port)
        try client.connect()
        try client.send(IRCCommand(name: "CAP", parameters: ["LS", "302"]))
        _ = try waitFor(client, command: "CAP")
        try client.send(.nick(nickname))
        try client.send(.user(username: "guest", realName: nickname))
        try client.send(IRCCommand(name: "CAP", parameters: ["REQ", "message-tags"]))
        let accepted = try waitFor(client, command: "CAP", forbid: "001")
        XCTAssertEqual(accepted.parameters[1], "ACK")
        try client.send(IRCCommand(name: "CAP", parameters: ["END"]))
        _ = try waitFor(client, command: "001")
        return client
    }

    private func waitFor(_ client: IRCClient, command: String, forbid: String? = nil) throws -> IRCMessage {
        let deadline = Date().addingTimeInterval(5)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw IRCError.timedOut
            }
            guard let message = try client.receive(timeout: remaining) else {
                throw IRCError.unexpectedEnd
            }
            if let forbid = forbid, message.command == forbid {
                XCTFail("saw \(forbid) while waiting for \(command)")
                throw IRCError.registrationFailed(numeric: 1, message: "registration completed early")
            }
            if message.command == command {
                return message
            }
        }
    }
}
