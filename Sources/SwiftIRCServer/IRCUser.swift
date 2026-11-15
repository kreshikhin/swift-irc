import Foundation
import SwiftIRCCore

/// One user known to a local server. RFC 2812 section 3.1.
public final class IRCUser {
    public var nickname: String
    public var username: String
    public var realName: String
    public var host: String
    public var serverName: String
    public var modes: Set<Character>
    public var awayMessage: String?
    public var isRegistered: Bool
    public var isOperator: Bool
    public var password: String?
    public internal(set) var didQuit: Bool
    var isNegotiatingCapabilities: Bool
    var capVersion: Int
    var enabledCapabilities: Set<String>

    public init(
        nickname: String,
        username: String,
        realName: String,
        host: String,
        serverName: String
    ) {
        self.nickname = nickname
        self.username = username
        self.realName = realName
        self.host = host
        self.serverName = serverName
        modes = []
        awayMessage = nil
        isRegistered = false
        isOperator = false
        password = nil
        didQuit = false
        isNegotiatingCapabilities = false
        capVersion = 0
        enabledCapabilities = []
    }

    public var isInvisible: Bool {
        modes.contains("i")
    }

    public var receivesWallops: Bool {
        modes.contains("w")
    }

    public var prefix: IRCPrefix {
        let user = username.isEmpty ? nil : username
        let userHost = host.isEmpty ? nil : host
        return IRCPrefix(nick: nickname, username: user, host: userHost)
    }

    /// Applies the bitmask from the USER command. Bits 2 and 3 are `w` and `i`.
    public func apply(initialMode rawValue: Int) {
        let mode = IRCInitialUserMode(rawValue: rawValue)
        if mode.contains(.invisible) {
            modes.insert("i")
        }
        if mode.contains(.wallops) {
            modes.insert("w")
        }
    }

    public var modeLetters: String {
        let known: [Character] = ["i", "w", "o", "O", "r", "s"]
        let enabled = known.filter { modes.contains($0) }
        if enabled.isEmpty {
            return ""
        }
        return "+" + String(enabled)
    }
}
