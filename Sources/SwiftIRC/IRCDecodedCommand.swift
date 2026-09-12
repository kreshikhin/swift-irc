import Foundation

/// A message interpreted as one of the commands defined by RFC 1459, RFC 2812, or RFC 2813.
public enum IRCDecodedCommand: Equatable {
    case pass(password: String)
    case serverPass(password: String, version: String, flags: String, options: String?)
    case nick(String)
    case serverNick(
        nickname: String,
        hopcount: String,
        username: String,
        host: String,
        serverToken: String,
        userMode: String,
        realName: String
    )
    case user(username: String, mode: String, unused: String, realName: String)
    case oper(name: String, password: String)
    case service(nickname: String, distribution: String, type: String, info: String)
    case quit(String?)
    case squit(server: String, comment: String)
    case joinAll
    case join(channels: [String], keys: [String])
    case part(channels: [String], message: String?)
    case mode(target: String, changes: [IRCModeChange])
    case topic(channel: String, topic: String?)
    case names(channels: [String], target: String?)
    case list(channels: [String], target: String?)
    case invite(nickname: String, channel: String)
    case kick(channels: [String], users: [String], comment: String?)
    case privmsg(target: String, text: String)
    case notice(target: String, text: String)
    case motd(String?)
    case lusers(mask: String?, target: String?)
    case version(String?)
    case stats(query: String?, target: String?)
    case links(remoteServer: String?, serverMask: String?)
    case time(String?)
    case connect(targetServer: String, port: String, remoteServer: String?)
    case trace(String?)
    case admin(String?)
    case info(String?)
    case servlist(mask: String?, type: String?)
    case squery(service: String, text: String)
    case who(mask: String?, operatorsOnly: Bool)
    case whois(target: String?, masks: [String])
    case whowas(nicknames: [String], count: String?, target: String?)
    case kill(nickname: String, comment: String)
    case ping(server: String, server2: String?)
    case pong(server: String, server2: String?)
    case error(String)
    case away(String?)
    case rehash
    case die
    case restart
    case summon(user: String, target: String?, channel: String?)
    case users(String?)
    case wallops(String)
    case userhost([String])
    case ison([String])
    case server(name: String, hopcount: String, token: String?, info: String)
    case njoin(channel: String, members: [IRCCommand.ChannelMember])
    case numeric(IRCNumeric, target: String?, parameters: [String])
    case raw(name: String, parameters: [String])
}

extension IRCMessage {
    public func decode() -> IRCDecodedCommand {
        let parameters = self.parameters
        switch command {
        case "PASS":
            guard let password = parameters.first else {
                return .raw(name: command, parameters: parameters)
            }
            if parameters.count >= 3 {
                return .serverPass(
                    password: password,
                    version: parameters[1],
                    flags: parameters[2],
                    options: parameters.count > 3 ? parameters[3] : nil
                )
            }
            return .pass(password: password)
        case "NICK":
            if parameters.count >= 7 {
                return .serverNick(
                    nickname: parameters[0],
                    hopcount: parameters[1],
                    username: parameters[2],
                    host: parameters[3],
                    serverToken: parameters[4],
                    userMode: parameters[5],
                    realName: parameters[6]
                )
            }
            guard let nickname = parameters.first else {
                return .raw(name: command, parameters: parameters)
            }
            return .nick(nickname)
        case "USER":
            guard parameters.count >= 4 else {
                return .raw(name: command, parameters: parameters)
            }
            return .user(
                username: parameters[0],
                mode: parameters[1],
                unused: parameters[2],
                realName: parameters[3]
            )
        case "OPER":
            guard parameters.count >= 2 else { return .raw(name: command, parameters: parameters) }
            return .oper(name: parameters[0], password: parameters[1])
        case "SERVICE":
            guard parameters.count >= 6 else { return .raw(name: command, parameters: parameters) }
            return .service(
                nickname: parameters[0],
                distribution: parameters[2],
                type: parameters[3],
                info: parameters[5]
            )
        case "QUIT":
            return .quit(parameters.first)
        case "SQUIT":
            guard parameters.count >= 2 else { return .raw(name: command, parameters: parameters) }
            return .squit(server: parameters[0], comment: parameters[1])
        case "JOIN":
            guard let first = parameters.first else { return .raw(name: command, parameters: parameters) }
            if first == "0" {
                return .joinAll
            }
            let channels = first.split(separator: ",").map(String.init)
            let keys = parameters.count > 1
                ? parameters[1].split(separator: ",").map(String.init)
                : []
            return .join(channels: channels, keys: keys)
        case "PART":
            guard let first = parameters.first else { return .raw(name: command, parameters: parameters) }
            return .part(
                channels: first.split(separator: ",").map(String.init),
                message: parameters.count > 1 ? parameters[1] : nil
            )
        case "MODE":
            guard let target = parameters.first else { return .raw(name: command, parameters: parameters) }
            let rest = Array(parameters.dropFirst())
            let changes = IRCChannelName.isValid(target)
                ? IRCModeParser.parseChannel(parameters: rest)
                : IRCModeParser.parseUser(parameters: rest)
            return .mode(target: target, changes: changes)
        case "TOPIC":
            guard let channel = parameters.first else { return .raw(name: command, parameters: parameters) }
            return .topic(channel: channel, topic: parameters.count > 1 ? parameters[1] : nil)
        case "NAMES":
            return .names(
                channels: splitList(parameters.first),
                target: parameters.count > 1 ? parameters[1] : nil
            )
        case "LIST":
            return .list(
                channels: splitList(parameters.first),
                target: parameters.count > 1 ? parameters[1] : nil
            )
        case "INVITE":
            guard parameters.count >= 2 else { return .raw(name: command, parameters: parameters) }
            return .invite(nickname: parameters[0], channel: parameters[1])
        case "KICK":
            guard parameters.count >= 2 else { return .raw(name: command, parameters: parameters) }
            return .kick(
                channels: parameters[0].split(separator: ",").map(String.init),
                users: parameters[1].split(separator: ",").map(String.init),
                comment: parameters.count > 2 ? parameters[2] : nil
            )
        case "PRIVMSG":
            guard parameters.count >= 2 else { return .raw(name: command, parameters: parameters) }
            return .privmsg(target: parameters[0], text: parameters[1])
        case "NOTICE":
            guard parameters.count >= 2 else { return .raw(name: command, parameters: parameters) }
            return .notice(target: parameters[0], text: parameters[1])
        case "MOTD":
            return .motd(parameters.first)
        case "LUSERS":
            return .lusers(mask: parameters.first, target: parameters.count > 1 ? parameters[1] : nil)
        case "VERSION":
            return .version(parameters.first)
        case "STATS":
            return .stats(query: parameters.first, target: parameters.count > 1 ? parameters[1] : nil)
        case "LINKS":
            if parameters.count >= 2 {
                return .links(remoteServer: parameters[0], serverMask: parameters[1])
            }
            return .links(remoteServer: nil, serverMask: parameters.first)
        case "TIME":
            return .time(parameters.first)
        case "CONNECT":
            guard parameters.count >= 2 else { return .raw(name: command, parameters: parameters) }
            return .connect(
                targetServer: parameters[0],
                port: parameters[1],
                remoteServer: parameters.count > 2 ? parameters[2] : nil
            )
        case "TRACE":
            return .trace(parameters.first)
        case "ADMIN":
            return .admin(parameters.first)
        case "INFO":
            return .info(parameters.first)
        case "SERVLIST":
            return .servlist(mask: parameters.first, type: parameters.count > 1 ? parameters[1] : nil)
        case "SQUERY":
            guard parameters.count >= 2 else { return .raw(name: command, parameters: parameters) }
            return .squery(service: parameters[0], text: parameters[1])
        case "WHO":
            let operatorsOnly = parameters.count > 1 && parameters[1] == "o"
            return .who(mask: parameters.first, operatorsOnly: operatorsOnly)
        case "WHOIS":
            if parameters.count >= 2 {
                return .whois(target: parameters[0], masks: parameters[1].split(separator: ",").map(String.init))
            }
            guard let masks = parameters.first else { return .raw(name: command, parameters: parameters) }
            return .whois(target: nil, masks: masks.split(separator: ",").map(String.init))
        case "WHOWAS":
            guard let nicks = parameters.first else { return .raw(name: command, parameters: parameters) }
            return .whowas(
                nicknames: nicks.split(separator: ",").map(String.init),
                count: parameters.count > 1 ? parameters[1] : nil,
                target: parameters.count > 2 ? parameters[2] : nil
            )
        case "KILL":
            guard parameters.count >= 2 else { return .raw(name: command, parameters: parameters) }
            return .kill(nickname: parameters[0], comment: parameters[1])
        case "PING":
            guard let server = parameters.first else { return .raw(name: command, parameters: parameters) }
            return .ping(server: server, server2: parameters.count > 1 ? parameters[1] : nil)
        case "PONG":
            guard let server = parameters.first else { return .raw(name: command, parameters: parameters) }
            return .pong(server: server, server2: parameters.count > 1 ? parameters[1] : nil)
        case "ERROR":
            return .error(parameters.first ?? "")
        case "AWAY":
            return .away(parameters.first)
        case "REHASH":
            return .rehash
        case "DIE":
            return .die
        case "RESTART":
            return .restart
        case "SUMMON":
            guard let user = parameters.first else { return .raw(name: command, parameters: parameters) }
            return .summon(
                user: user,
                target: parameters.count > 1 ? parameters[1] : nil,
                channel: parameters.count > 2 ? parameters[2] : nil
            )
        case "USERS":
            return .users(parameters.first)
        case "WALLOPS":
            guard let text = parameters.first else { return .raw(name: command, parameters: parameters) }
            return .wallops(text)
        case "USERHOST":
            guard !parameters.isEmpty else { return .raw(name: command, parameters: parameters) }
            return .userhost(parameters)
        case "ISON":
            guard !parameters.isEmpty else { return .raw(name: command, parameters: parameters) }
            return .ison(parameters)
        case "SERVER":
            guard parameters.count >= 3 else { return .raw(name: command, parameters: parameters) }
            if parameters.count >= 4 {
                return .server(name: parameters[0], hopcount: parameters[1], token: parameters[2], info: parameters[3])
            }
            return .server(name: parameters[0], hopcount: parameters[1], token: nil, info: parameters[2])
        case "NJOIN":
            guard parameters.count >= 2 else { return .raw(name: command, parameters: parameters) }
            let members = parameters[1].split(separator: ",").map { token -> IRCCommand.ChannelMember in
                var rest = String(token)
                var creator = false
                var isOperator = false
                var voice = false
                if rest.hasPrefix("@@") {
                    creator = true
                    rest.removeFirst(2)
                } else if rest.hasPrefix("@") {
                    isOperator = true
                    rest.removeFirst()
                }
                if rest.hasPrefix("+") {
                    voice = true
                    rest.removeFirst()
                }
                return IRCCommand.ChannelMember(
                    nickname: rest,
                    isCreator: creator,
                    isOperator: isOperator,
                    hasVoice: voice
                )
            }
            return .njoin(channel: parameters[0], members: members)
        default:
            if let numeric = numeric {
                let target = parameters.first
                let rest = Array(parameters.dropFirst())
                return .numeric(numeric, target: target, parameters: rest)
            }
            return .raw(name: command, parameters: parameters)
        }
    }

    private func splitList(_ value: String?) -> [String] {
        guard let value = value, !value.isEmpty else {
            return []
        }
        return value.split(separator: ",").map(String.init)
    }
}
