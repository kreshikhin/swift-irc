import Foundation
import SwiftIRCCore

/// Registration state for one client connection. RFC 2812 section 3.1.
///
/// PASS, when used, has to be sent before NICK, USER, or SERVICE.
/// Registration finishes at `RPL_WELCOME`. `PING` during registration is answered with `PONG`.
public final class IRCClientSession {
    public let connection: IRCConnection
    public private(set) var nickname: String
    public private(set) var isRegistered: Bool

    private var sentRegistrationIdentity = false

    public init(connection: IRCConnection) {
        self.connection = connection
        nickname = ""
        isRegistered = false
    }

    public func register(
        password: String? = nil,
        nickname: String,
        username: String,
        realName: String,
        mode: IRCInitialUserMode = [],
        timeout: TimeInterval = 30
    ) throws -> [IRCMessage] {
        guard !isRegistered else {
            throw IRCError.alreadyRegistered
        }
        let commands = try IRCRegistration.commands(
            password: password,
            nickname: nickname,
            username: username,
            realName: realName,
            mode: mode
        )
        for command in commands {
            try send(command)
        }
        self.nickname = nickname
        var received: [IRCMessage] = []
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw IRCError.timedOut
            }
            guard let message = try receive(timeout: remaining) else {
                throw IRCError.unexpectedEnd
            }
            if message.command == "PING" {
                let token = message.parameters.first ?? ""
                let second = message.parameters.count > 1 ? message.parameters[1] : nil
                try send(.pong(server: token, server2: second))
                continue
            }
            received.append(message)
            if message.command == "ERROR" {
                throw IRCError.registrationFailed(numeric: 0, message: message.parameters.last ?? "ERROR")
            }
            if let numeric = message.numeric {
                if numeric == IRCNumeric.welcome {
                    if let assigned = message.parameters.first, !assigned.isEmpty {
                        self.nickname = assigned
                    }
                    isRegistered = true
                    return received
                }
                if numeric.isError {
                    throw IRCError.registrationFailed(
                        numeric: numeric.code,
                        message: message.parameters.last ?? numeric.name
                    )
                }
            }
        }
    }

    public func send(_ command: IRCCommand) throws {
        try send(try IRCMessage(command: command))
    }

    public func send(_ message: IRCMessage) throws {
        if message.command == "PASS" && (sentRegistrationIdentity || isRegistered) {
            throw IRCError.passwordSentTooLate
        }
        if message.command == "NICK" || message.command == "USER" || message.command == "SERVICE" {
            sentRegistrationIdentity = true
        }
        try connection.send(message)
    }

    public func receive(timeout: TimeInterval = 30) throws -> IRCMessage? {
        try connection.receive(timeout: timeout)
    }
}
