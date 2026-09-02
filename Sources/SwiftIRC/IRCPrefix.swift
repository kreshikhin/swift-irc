import Foundation

/// `prefix = servername / ( nickname [ [ "!" user ] "@" host ] )`.
///
/// A prefix with no `!` or `@` is a server name when it contains `.`,
/// and a nickname otherwise. That matches the examples in RFC 2812 and RFC 2813.
public struct IRCPrefix: Equatable, Hashable {
    public enum Origin: Equatable, Hashable {
        case server(String)
        case user(nick: String, username: String?, host: String?)
    }

    public let raw: String
    public let origin: Origin

    public init(raw: String) {
        self.raw = raw
        self.origin = IRCPrefix.parse(raw)
    }

    public init(server: String) {
        raw = server
        origin = .server(server)
    }

    public init(nick: String, username: String? = nil, host: String? = nil) {
        var value = nick
        if let username = username {
            value += "!" + username
        }
        if let host = host {
            value += "@" + host
        }
        raw = value
        origin = .user(nick: nick, username: username, host: host)
    }

    private static func parse(_ raw: String) -> Origin {
        if let at = raw.firstIndex(of: "@") {
            let left = String(raw[..<at])
            let host = String(raw[raw.index(after: at)...])
            if let bang = left.firstIndex(of: "!") {
                let nick = String(left[..<bang])
                let username = String(left[left.index(after: bang)...])
                return .user(nick: nick, username: username, host: host)
            }
            return .user(nick: left, username: nil, host: host)
        }
        if let bang = raw.firstIndex(of: "!") {
            let nick = String(raw[..<bang])
            let username = String(raw[raw.index(after: bang)...])
            return .user(nick: nick, username: username, host: nil)
        }
        if raw.contains(".") {
            return .server(raw)
        }
        return .user(nick: raw, username: nil, host: nil)
    }
}
