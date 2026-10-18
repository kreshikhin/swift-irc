import Foundation
import SwiftIRCCore

/// A client speaking the IRC client protocol. RFC 2812.
///
/// The connection carries bytes. The session tracks registration.
public final class IRCClient {
    public let connection: IRCConnection
    public let session: IRCClientSession

    public var host: String { connection.host }
    public var port: UInt16 { connection.port }
    public var useTLS: Bool { connection.useTLS }
    public var nickname: String { session.nickname }
    public var isRegistered: Bool { session.isRegistered }

    public init(host: String, port: UInt16? = nil, useTLS: Bool = false) {
        let connection = IRCConnection(host: host, port: port, useTLS: useTLS)
        self.connection = connection
        session = IRCClientSession(connection: connection)
    }

    public init(connection: IRCConnection) {
        self.connection = connection
        session = IRCClientSession(connection: connection)
    }

    deinit {
        connection.close()
    }

    public func connect(timeout: TimeInterval = 30) throws {
        try connection.connect(timeout: timeout)
    }

    public func register(
        password: String? = nil,
        nickname: String,
        username: String,
        realName: String,
        mode: IRCInitialUserMode = [],
        timeout: TimeInterval = 30
    ) throws -> [IRCMessage] {
        try session.register(
            password: password,
            nickname: nickname,
            username: username,
            realName: realName,
            mode: mode,
            timeout: timeout
        )
    }

    public func send(_ command: IRCCommand) throws {
        try session.send(command)
    }

    public func send(_ message: IRCMessage) throws {
        try session.send(message)
    }

    public func receive(timeout: TimeInterval = 30) throws -> IRCMessage? {
        try session.receive(timeout: timeout)
    }

    public func quit(message: String? = nil) throws {
        if connection.isConnected {
            try send(.quit(message: message))
        }
        close()
    }

    public func close() {
        connection.close()
    }
}
