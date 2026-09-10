import Foundation

/// A client or server command from RFC 1459, RFC 2812, and RFC 2813.
public struct IRCCommand: Equatable {
    public var name: String
    public var parameters: [String]

    public init(name: String, parameters: [String] = []) throws {
        self.name = try IRCCommand.canonicalName(name)
        guard parameters.count <= IRC.maximumParameterCount else {
            throw IRCError.tooManyParameters(parameters.count)
        }
        for parameter in parameters.dropLast() {
            if parameter.isEmpty || parameter.contains(" ") || parameter.hasPrefix(":") {
                throw IRCError.parameterContainsSpace(parameter)
            }
        }
        self.parameters = parameters
    }

    static func canonicalName(_ name: String) throws -> String {
        let scalars = Array(name.unicodeScalars)
        guard !scalars.isEmpty else {
            throw IRCError.invalidCommand(name)
        }
        let digits = scalars.allSatisfy { (0x30 ... 0x39).contains($0.value) }
        if digits {
            guard scalars.count == 3 else {
                throw IRCError.invalidCommand(name)
            }
            return name
        }
        var upper = ""
        for scalar in scalars {
            if (0x41 ... 0x5A).contains(scalar.value) {
                upper.unicodeScalars.append(scalar)
            } else if (0x61 ... 0x7A).contains(scalar.value) {
                upper.unicodeScalars.append(Unicode.Scalar(scalar.value - 32)!)
            } else {
                throw IRCError.invalidCommand(name)
            }
        }
        return upper
    }

    public static func pass(_ password: String) throws -> IRCCommand {
        try IRCCommand(name: "PASS", parameters: [password])
    }

    /// Server PASS. RFC 2813 section 4.1.1. Extra parameters are ignored when received from a client.
    public static func serverPass(password: String, version: String, flags: String, options: String? = nil) throws -> IRCCommand {
        var parameters = [password, version, flags]
        if let options = options {
            parameters.append(options)
        }
        return try IRCCommand(name: "PASS", parameters: parameters)
    }

    public static func nick(_ nickname: String) throws -> IRCCommand {
        try IRCNickname.validate(nickname)
        return try IRCCommand(name: "NICK", parameters: [nickname])
    }

    /// Server NICK. RFC 2813 section 4.1.3.
    public static func serverNick(
        nickname: String,
        hopcount: Int,
        username: String,
        host: String,
        serverToken: String,
        userMode: String,
        realName: String
    ) throws -> IRCCommand {
        try IRCNickname.validate(nickname)
        try IRCUsername.validate(username)
        return try IRCCommand(
            name: "NICK",
            parameters: [nickname, String(hopcount), username, host, serverToken, userMode, realName]
        )
    }

    public static func user(username: String, mode: IRCInitialUserMode = [], realName: String) throws -> IRCCommand {
        try IRCUsername.validate(username)
        return try IRCCommand(
            name: "USER",
            parameters: [username, String(mode.rawValue), "*", realName]
        )
    }

    public static func oper(name: String, password: String) throws -> IRCCommand {
        try IRCCommand(name: "OPER", parameters: [name, password])
    }

    public static func service(
        nickname: String,
        distribution: String,
        type: String,
        info: String
    ) throws -> IRCCommand {
        try IRCNickname.validate(nickname)
        return try IRCCommand(
            name: "SERVICE",
            parameters: [nickname, "*", distribution, type, "*", info]
        )
    }

    public static func quit(message: String? = nil) throws -> IRCCommand {
        try IRCCommand(name: "QUIT", parameters: message.map { [$0] } ?? [])
    }

    public static func squit(server: String, comment: String) throws -> IRCCommand {
        try IRCCommand(name: "SQUIT", parameters: [server, comment])
    }

    /// `JOIN 0` leaves every channel. RFC 2812 section 3.2.1.
    public static func joinAll() throws -> IRCCommand {
        try IRCCommand(name: "JOIN", parameters: ["0"])
    }

    public static func join(channels: [String], keys: [String] = []) throws -> IRCCommand {
        guard !channels.isEmpty else {
            throw IRCError.invalidChannel("")
        }
        for channel in channels {
            try IRCChannelName.validate(channel)
        }
        for key in keys {
            try IRCChannelKey.validate(key)
        }
        var parameters = [channels.joined(separator: ",")]
        if !keys.isEmpty {
            parameters.append(keys.joined(separator: ","))
        }
        return try IRCCommand(name: "JOIN", parameters: parameters)
    }

    public static func part(channels: [String], message: String? = nil) throws -> IRCCommand {
        for channel in channels {
            try IRCChannelName.validate(channel)
        }
        var parameters = [channels.joined(separator: ",")]
        if let message = message {
            parameters.append(message)
        }
        return try IRCCommand(name: "PART", parameters: parameters)
    }

    public static func userMode(nickname: String, changes: [IRCModeChange] = []) throws -> IRCCommand {
        try IRCNickname.validate(nickname)
        for change in changes where change.mode == "a" && change.action != .query {
            throw IRCError.awayModeIsNotSettable
        }
        let formatted = IRCModeParser.format(changes)
        var parameters = [nickname]
        if !formatted.modes.isEmpty {
            parameters.append(formatted.modes)
        }
        parameters.append(contentsOf: formatted.parameters)
        return try IRCCommand(name: "MODE", parameters: parameters)
    }

    public static func channelMode(channel: String, changes: [IRCModeChange] = []) throws -> IRCCommand {
        try IRCChannelName.validate(channel)
        let parameterCount = changes.filter { $0.parameter != nil }.count
        guard parameterCount <= IRC.maximumChannelModeParameters else {
            throw IRCError.tooManyModeParameters
        }
        let formatted = IRCModeParser.format(changes)
        var parameters = [channel]
        if !formatted.modes.isEmpty {
            parameters.append(formatted.modes)
        }
        parameters.append(contentsOf: formatted.parameters)
        return try IRCCommand(name: "MODE", parameters: parameters)
    }

    /// `MODE <channel> b`, `e`, `I`, or `O` without a sign lists that mode.
    public static func channelModeQuery(channel: String, mode: Character? = nil) throws -> IRCCommand {
        try IRCChannelName.validate(channel)
        var parameters = [channel]
        if let mode = mode {
            parameters.append(String(mode))
        }
        return try IRCCommand(name: "MODE", parameters: parameters)
    }

    public static func topic(channel: String, topic: String? = nil) throws -> IRCCommand {
        try IRCChannelName.validate(channel)
        var parameters = [channel]
        if let topic = topic {
            parameters.append(topic)
        }
        return try IRCCommand(name: "TOPIC", parameters: parameters)
    }

    public static func names(channels: [String] = [], target: String? = nil) throws -> IRCCommand {
        for channel in channels {
            try IRCChannelName.validate(channel)
        }
        var parameters: [String] = []
        if !channels.isEmpty {
            parameters.append(channels.joined(separator: ","))
        }
        if let target = target {
            parameters.append(target)
        }
        return try IRCCommand(name: "NAMES", parameters: parameters)
    }

    public static func list(channels: [String] = [], target: String? = nil) throws -> IRCCommand {
        for channel in channels {
            try IRCChannelName.validate(channel)
        }
        var parameters: [String] = []
        if !channels.isEmpty {
            parameters.append(channels.joined(separator: ","))
        }
        if let target = target {
            parameters.append(target)
        }
        return try IRCCommand(name: "LIST", parameters: parameters)
    }

    public static func invite(nickname: String, channel: String) throws -> IRCCommand {
        try IRCNickname.validate(nickname)
        try IRCChannelName.validate(channel)
        return try IRCCommand(name: "INVITE", parameters: [nickname, channel])
    }

    public static func kick(channels: [String], users: [String], comment: String? = nil) throws -> IRCCommand {
        for channel in channels {
            try IRCChannelName.validate(channel)
        }
        for user in users {
            try IRCNickname.validate(user)
        }
        var parameters = [channels.joined(separator: ","), users.joined(separator: ",")]
        if let comment = comment {
            parameters.append(comment)
        }
        return try IRCCommand(name: "KICK", parameters: parameters)
    }

    public static func privmsg(target: String, text: String) throws -> IRCCommand {
        try IRCCommand(name: "PRIVMSG", parameters: [target, text])
    }

    public static func notice(target: String, text: String) throws -> IRCCommand {
        try IRCCommand(name: "NOTICE", parameters: [target, text])
    }

    public static func motd(target: String? = nil) throws -> IRCCommand {
        try IRCCommand(name: "MOTD", parameters: target.map { [$0] } ?? [])
    }

    public static func lusers(mask: String? = nil, target: String? = nil) throws -> IRCCommand {
        var parameters: [String] = []
        if let mask = mask {
            parameters.append(mask)
        }
        if let target = target {
            parameters.append(target)
        }
        return try IRCCommand(name: "LUSERS", parameters: parameters)
    }

    public static func version(target: String? = nil) throws -> IRCCommand {
        try IRCCommand(name: "VERSION", parameters: target.map { [$0] } ?? [])
    }

    public static func stats(query: String? = nil, target: String? = nil) throws -> IRCCommand {
        var parameters: [String] = []
        if let query = query {
            parameters.append(query)
        }
        if let target = target {
            parameters.append(target)
        }
        return try IRCCommand(name: "STATS", parameters: parameters)
    }

    public static func links(serverMask: String? = nil, remoteServer: String? = nil) throws -> IRCCommand {
        var parameters: [String] = []
        if let remoteServer = remoteServer {
            parameters.append(remoteServer)
        }
        if let serverMask = serverMask {
            parameters.append(serverMask)
        }
        return try IRCCommand(name: "LINKS", parameters: parameters)
    }

    public static func time(target: String? = nil) throws -> IRCCommand {
        try IRCCommand(name: "TIME", parameters: target.map { [$0] } ?? [])
    }

    public static func connect(targetServer: String, port: Int, remoteServer: String? = nil) throws -> IRCCommand {
        var parameters = [targetServer, String(port)]
        if let remoteServer = remoteServer {
            parameters.append(remoteServer)
        }
        return try IRCCommand(name: "CONNECT", parameters: parameters)
    }

    public static func trace(target: String? = nil) throws -> IRCCommand {
        try IRCCommand(name: "TRACE", parameters: target.map { [$0] } ?? [])
    }

    public static func admin(target: String? = nil) throws -> IRCCommand {
        try IRCCommand(name: "ADMIN", parameters: target.map { [$0] } ?? [])
    }

    public static func info(target: String? = nil) throws -> IRCCommand {
        try IRCCommand(name: "INFO", parameters: target.map { [$0] } ?? [])
    }

    public static func servlist(mask: String? = nil, type: String? = nil) throws -> IRCCommand {
        var parameters: [String] = []
        if let mask = mask {
            parameters.append(mask)
        }
        if let type = type {
            parameters.append(type)
        }
        return try IRCCommand(name: "SERVLIST", parameters: parameters)
    }

    public static func squery(service: String, text: String) throws -> IRCCommand {
        try IRCCommand(name: "SQUERY", parameters: [service, text])
    }

    public static func who(mask: String? = nil, operatorsOnly: Bool = false) throws -> IRCCommand {
        var parameters: [String] = []
        if let mask = mask {
            parameters.append(mask)
        }
        if operatorsOnly {
            parameters.append("o")
        }
        return try IRCCommand(name: "WHO", parameters: parameters)
    }

    public static func whois(masks: [String], target: String? = nil) throws -> IRCCommand {
        var parameters: [String] = []
        if let target = target {
            parameters.append(target)
        }
        parameters.append(masks.joined(separator: ","))
        return try IRCCommand(name: "WHOIS", parameters: parameters)
    }

    public static func whowas(nicknames: [String], count: Int? = nil, target: String? = nil) throws -> IRCCommand {
        for nickname in nicknames {
            try IRCNickname.validate(nickname)
        }
        var parameters = [nicknames.joined(separator: ",")]
        if let count = count {
            parameters.append(String(count))
        }
        if let target = target {
            parameters.append(target)
        }
        return try IRCCommand(name: "WHOWAS", parameters: parameters)
    }

    public static func kill(nickname: String, comment: String) throws -> IRCCommand {
        try IRCNickname.validate(nickname)
        return try IRCCommand(name: "KILL", parameters: [nickname, comment])
    }

    public static func ping(server: String, server2: String? = nil) throws -> IRCCommand {
        var parameters = [server]
        if let server2 = server2 {
            parameters.append(server2)
        }
        return try IRCCommand(name: "PING", parameters: parameters)
    }

    public static func pong(server: String, server2: String? = nil) throws -> IRCCommand {
        var parameters = [server]
        if let server2 = server2 {
            parameters.append(server2)
        }
        return try IRCCommand(name: "PONG", parameters: parameters)
    }

    public static func error(_ message: String) throws -> IRCCommand {
        try IRCCommand(name: "ERROR", parameters: [message])
    }

    /// `AWAY` with no text removes the away message. RFC 2812 section 4.1.
    public static func away(text: String? = nil) throws -> IRCCommand {
        try IRCCommand(name: "AWAY", parameters: text.map { [$0] } ?? [])
    }

    public static func rehash() throws -> IRCCommand {
        try IRCCommand(name: "REHASH")
    }

    public static func die() throws -> IRCCommand {
        try IRCCommand(name: "DIE")
    }

    public static func restart() throws -> IRCCommand {
        try IRCCommand(name: "RESTART")
    }

    public static func summon(user: String, target: String? = nil, channel: String? = nil) throws -> IRCCommand {
        var parameters = [user]
        if let target = target {
            parameters.append(target)
        }
        if let channel = channel {
            try IRCChannelName.validate(channel)
            parameters.append(channel)
        }
        return try IRCCommand(name: "SUMMON", parameters: parameters)
    }

    public static func users(target: String? = nil) throws -> IRCCommand {
        try IRCCommand(name: "USERS", parameters: target.map { [$0] } ?? [])
    }

    public static func wallops(_ text: String) throws -> IRCCommand {
        try IRCCommand(name: "WALLOPS", parameters: [text])
    }

    public static func userhost(_ nicknames: [String]) throws -> IRCCommand {
        for nickname in nicknames {
            try IRCNickname.validate(nickname)
        }
        return try IRCCommand(name: "USERHOST", parameters: nicknames)
    }

    public static func ison(_ nicknames: [String]) throws -> IRCCommand {
        for nickname in nicknames {
            try IRCNickname.validate(nickname)
        }
        return try IRCCommand(name: "ISON", parameters: nicknames)
    }

    /// RFC 1459 SERVER. RFC 2813 adds `<token>` between hopcount and info.
    public static func server(name: String, hopcount: Int, token: String? = nil, info: String) throws -> IRCCommand {
        try IRCHostname.validate(name)
        var parameters = [name, String(hopcount)]
        if let token = token {
            parameters.append(token)
        }
        parameters.append(info)
        return try IRCCommand(name: "SERVER", parameters: parameters)
    }

    /// One member announced by NJOIN. RFC 2813 section 4.2.2.
    public struct ChannelMember: Equatable {
        public var nickname: String
        public var isCreator: Bool
        public var isOperator: Bool
        public var hasVoice: Bool

        public init(nickname: String, isCreator: Bool = false, isOperator: Bool = false, hasVoice: Bool = false) {
            self.nickname = nickname
            self.isCreator = isCreator
            self.isOperator = isOperator
            self.hasVoice = hasVoice
        }

        public var statusPrefix: String {
            var prefix = ""
            if isCreator {
                prefix += "@@"
            } else if isOperator {
                prefix += "@"
            }
            if hasVoice {
                prefix += "+"
            }
            return prefix
        }
    }

    public static func njoin(channel: String, members: [ChannelMember]) throws -> IRCCommand {
        try IRCChannelName.validate(channel)
        let list = members.map { $0.statusPrefix + $0.nickname }.joined(separator: ",")
        return try IRCCommand(name: "NJOIN", parameters: [channel, list])
    }
}

/// Messages a user sends to register. PASS, when present, comes before NICK and USER.
/// RFC 2812 section 3.1.
public enum IRCRegistration {
    public static func commands(
        password: String?,
        nickname: String,
        username: String,
        realName: String,
        mode: IRCInitialUserMode = []
    ) throws -> [IRCCommand] {
        var commands: [IRCCommand] = []
        if let password = password {
            commands.append(try .pass(password))
        }
        commands.append(try .nick(nickname))
        commands.append(try .user(username: username, mode: mode, realName: realName))
        return commands
    }
}
