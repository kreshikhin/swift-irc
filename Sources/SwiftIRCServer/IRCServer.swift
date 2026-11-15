import Darwin
import Foundation
import SwiftIRCCore

/// A single-server IRC daemon for the client commands in RFC 2812 and the channel rules in RFC 2811.
public final class IRCServer {
    public let name: String
    public let host: String
    public private(set) var port: UInt16
    public var password: String?

    static let offeredCapabilities: Set<String> = ["message-tags"]

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private let reactor = IRCServerReactor()
    var users: [String: IRCUser] = [:]
    var sessions: [String: IRCServerSession] = [:]
    var channels: [String: IRCChannel] = [:]
    var allSessions: [IRCServerSession] = []
    let created: String
    let version: String

    public init(
        name: String = "irc.example.net",
        host: String = "127.0.0.1",
        port: UInt16 = 0,
        password: String? = nil
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.password = password
        version = "SwiftIRC-" + IRC.serverProtocolVersion
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        created = formatter.string(from: Date())
    }

    deinit {
        stop()
    }

    public func start() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw IRCError.connectionFailed(String(cString: strerror(errno)))
        }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr(host)
        let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 16) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw IRCError.connectionFailed(message)
        }
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                getsockname(descriptor, rebound, &length)
            }
        }
        guard named == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw IRCError.connectionFailed(message)
        }
        port = UInt16(bigEndian: boundAddress.sin_port)
        listenFD = descriptor
        do {
            try reactor.start()
        } catch {
            listenFD = -1
            Darwin.close(descriptor)
            throw error
        }
        Thread.detachNewThread { [weak self] in
            self?.acceptLoop(descriptor)
        }
    }

    public func stop() {
        lock.lock()
        let descriptor = listenFD
        listenFD = -1
        allSessions = []
        users = [:]
        sessions = [:]
        channels = [:]
        lock.unlock()
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
        reactor.stop()
    }

    func receive(_ message: IRCMessage, from session: IRCServerSession) {
        lock.lock()
        let outcome = process(message, from: session)
        lock.unlock()
        deliver(outcome)
    }

    func remove(_ session: IRCServerSession) {
        lock.lock()
        let outcome = drop(session, announce: session.user.isRegistered && !session.user.didQuit, comment: "Connection closed")
        lock.unlock()
        deliver(outcome)
    }

    private func acceptLoop(_ descriptor: Int32) {
        while true {
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 {
                break
            }
            let user = IRCUser(
                nickname: "",
                username: "",
                realName: "",
                host: peerHost(client),
                serverName: name
            )
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            let flags = fcntl(client, F_GETFL, 0)
            _ = fcntl(client, F_SETFL, flags | O_NONBLOCK)
            let session = IRCServerSession(fileDescriptor: client, user: user, server: self, reactor: reactor)
            lock.lock()
            let stillListening = listenFD >= 0
            if stillListening {
                allSessions.append(session)
            }
            lock.unlock()
            if stillListening {
                reactor.add(session)
            } else {
                Darwin.close(client)
            }
        }
    }

    private func deliver(_ outcome: Outcome) {
        for delivery in outcome.deliveries {
            delivery.session.send(delivery.message)
        }
        for session in outcome.closing {
            session.close()
        }
    }

    private func process(_ message: IRCMessage, from session: IRCServerSession) -> Outcome {
        let user = session.user
        if user.didQuit {
            return Outcome()
        }
        if message.command == "CAP" {
            return negotiateCapabilities(message, user: user, session: session)
        }
        let decoded = message.decode()
        if !user.isRegistered {
            switch decoded {
            case .pass, .nick, .user, .ping, .pong, .quit:
                break
            default:
                return reply(.notRegistered, to: user, trailing: "You have not registered", session: session)
            }
        }
        switch decoded {
        case .pass(let password):
            return registerPassword(password, user: user, session: session)
        case .nick(let nickname):
            return changeNick(nickname, user: user, session: session)
        case .user(let username, let mode, _, let realName):
            return registerUser(username, mode: mode, realName: realName, user: user, session: session)
        case .ping(let token, _):
            return pong(token, session: session)
        case .pong:
            return Outcome()
        case .quit(let comment):
            return drop(session, announce: user.isRegistered, comment: comment ?? "Client Quit")
        case .joinAll:
            return leaveAll(user: user, session: session, comment: nil)
        case .join(let channelNames, let keys):
            return join(channelNames, keys: keys, user: user, session: session)
        case .part(let channelNames, let comment):
            return part(channelNames, comment: comment, user: user, session: session)
        case .privmsg(let target, let text):
            return chat(target, text: text, command: "PRIVMSG", tags: relayTags(message, user: user), user: user, session: session, reportErrors: true)
        case .notice(let target, let text):
            return chat(target, text: text, command: "NOTICE", tags: relayTags(message, user: user), user: user, session: session, reportErrors: false)
        case .topic(let channelName, let topic):
            return setTopic(channelName, topic: topic, user: user, session: session)
        case .names(let channelNames, _):
            return names(channelNames, user: user, session: session)
        case .mode(let target, let changes):
            return modes(target, changes: changes, user: user, session: session)
        case .away(let text):
            return away(text, user: user, session: session)
        case .motd:
            return motd(user: user, session: session)
        case .lusers:
            return lusers(user: user, session: session)
        case .version:
            return reply(.version, to: user, trailing: name, middle: [version, "0"], session: session)
        case .time:
            return reply(.time, to: user, trailing: created, middle: [name], session: session)
        case .whois(_, let masks):
            return whois(masks, user: user, session: session)
        case .userhost(let nicknames):
            return userhost(nicknames, user: user, session: session)
        case .ison(let nicknames):
            return ison(nicknames, user: user, session: session)
        case .error:
            return drop(session, announce: user.isRegistered, comment: "Client error")
        case .raw(let name, _):
            if name == "CAP" || name == "PASS" || name == "NICK" || name == "USER" {
                return reply(.needMoreParams, to: user, trailing: "Not enough parameters", middle: [name], session: session)
            }
            return reply(.unknownCommand, to: user, trailing: "Unknown command", middle: [name], session: session)
        default:
            return reply(.unknownCommand, to: user, trailing: "Unknown command", middle: [message.command], session: session)
        }
    }

    func drop(_ session: IRCServerSession, announce: Bool, comment: String) -> Outcome {
        guard let index = allSessions.firstIndex(where: { $0 === session }) else {
            return Outcome()
        }
        allSessions.remove(at: index)
        let user = session.user
        user.didQuit = true
        var outcome = Outcome(closing: [session])
        if announce && !user.nickname.isEmpty {
            if let message = try? IRCMessage(prefix: user.prefix, command: "QUIT", parameters: [comment]) {
                outcome.append(broadcastToPeers(of: user, message: message))
            }
        }
        if !user.nickname.isEmpty {
            let folded = IRCCaseMapping.fold(user.nickname)
            if users[folded] === user {
                users.removeValue(forKey: folded)
            }
            if sessions[folded] === session {
                sessions.removeValue(forKey: folded)
            }
            for channel in Array(channels.values) {
                channel.remove(nickname: user.nickname)
                if channel.members.isEmpty {
                    channels.removeValue(forKey: IRCCaseMapping.fold(channel.name))
                }
            }
        }
        return outcome
    }

    func nickIsTaken(_ nickname: String, except: IRCUser) -> Bool {
        let folded = IRCCaseMapping.fold(nickname)
        if let existing = users[folded], existing !== except {
            return true
        }
        for session in allSessions where session.user !== except {
            if session.user.nickname.isEmpty {
                continue
            }
            if IRCCaseMapping.fold(session.user.nickname) == folded {
                return true
            }
        }
        return false
    }

    func rekey(_ user: IRCUser, from previous: String, session: IRCServerSession) {
        let oldKey = IRCCaseMapping.fold(previous)
        let newKey = IRCCaseMapping.fold(user.nickname)
        if users[oldKey] === user {
            users.removeValue(forKey: oldKey)
        }
        users[newKey] = user
        if sessions[oldKey] === session {
            sessions.removeValue(forKey: oldKey)
        }
        sessions[newKey] = session
    }

    func broadcast(_ message: IRCMessage, to channel: IRCChannel, except: IRCUser?) -> Outcome {
        var deliveries: [Delivery] = []
        for folded in channel.members.keys {
            if let except = except, IRCCaseMapping.fold(except.nickname) == folded {
                continue
            }
            guard let session = sessions[folded] else {
                continue
            }
            deliveries.append(Delivery(session: session, message: messageForRecipient(message, session: session)))
        }
        return Outcome(deliveries: deliveries)
    }

    func broadcastToPeers(of user: IRCUser, message: IRCMessage) -> Outcome {
        var seen: [ObjectIdentifier: IRCServerSession] = [:]
        let folded = IRCCaseMapping.fold(user.nickname)
        for channel in channels.values {
            guard channel.members[folded] != nil else {
                continue
            }
            for member in channel.members.keys where member != folded {
                if let session = sessions[member] {
                    seen[ObjectIdentifier(session)] = session
                }
            }
        }
        return Outcome(deliveries: seen.values.map { Delivery(session: $0, message: self.messageForRecipient(message, session: $0)) })
    }

    var serverPrefix: IRCPrefix {
        IRCPrefix(server: name)
    }

    func reply(
        _ numeric: IRCNumeric,
        to user: IRCUser,
        trailing: String,
        middle: [String] = [],
        session: IRCServerSession
    ) -> Outcome {
        var parameters = [user.nickname.isEmpty ? "*" : user.nickname]
        parameters.append(contentsOf: middle)
        parameters.append(trailing)
        guard let message = try? IRCMessage(prefix: serverPrefix, command: numeric.wire, parameters: parameters) else {
            return Outcome()
        }
        return Outcome(deliveries: [Delivery(session: session, message: message)])
    }

    func relayTags(_ message: IRCMessage, user: IRCUser) -> IRCTags {
        if user.enabledCapabilities.contains("message-tags") {
            return message.tags
        }
        return IRCTags()
    }

    func messageForRecipient(_ message: IRCMessage, session: IRCServerSession) -> IRCMessage {
        if message.tags.isEmpty || session.user.enabledCapabilities.contains("message-tags") {
            return message
        }
        var stripped = message
        stripped.tags = IRCTags()
        return stripped
    }
}

struct Delivery {
    var session: IRCServerSession
    var message: IRCMessage
}

struct Outcome {
    var deliveries: [Delivery] = []
    var closing: [IRCServerSession] = []

    mutating func append(_ other: Outcome) {
        deliveries.append(contentsOf: other.deliveries)
        closing.append(contentsOf: other.closing)
    }
}

private func peerHost(_ descriptor: Int32) -> String {
    var address = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) { pointer -> Int32 in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
            getpeername(descriptor, rebound, &length)
        }
    }
    if result != 0 {
        return "127.0.0.1"
    }
    guard let hostPointer = inet_ntoa(address.sin_addr) else {
        return "127.0.0.1"
    }
    return String(cString: hostPointer)
}
