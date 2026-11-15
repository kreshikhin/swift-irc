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
    private var users: [String: IRCUser] = [:]
    private var sessions: [String: IRCServerSession] = [:]
    private var channels: [String: IRCChannel] = [:]
    private var allSessions: [IRCServerSession] = []
    private let created: String
    private let version: String

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

    private func registerPassword(_ password: String, user: IRCUser, session: IRCServerSession) -> Outcome {
        if user.isRegistered || !user.nickname.isEmpty || !user.username.isEmpty {
            return reply(.alreadyRegistered, to: user, trailing: "You may not reregister", session: session)
        }
        user.password = password
        return Outcome()
    }

    private func changeNick(_ nickname: String, user: IRCUser, session: IRCServerSession) -> Outcome {
        if (try? IRCNickname.validate(nickname)) == nil {
            return reply(.erroneusNickname, to: user, trailing: "Erroneous nickname", middle: [nickname], session: session)
        }
        if nickIsTaken(nickname, except: user) {
            return reply(.nicknameInUse, to: user, trailing: "Nickname is already in use", middle: [nickname], session: session)
        }
        let previous = user.nickname
        user.nickname = nickname
        guard user.isRegistered else {
            if !user.username.isEmpty {
                return finishRegistration(user: user, session: session)
            }
            return Outcome()
        }
        rekey(user, from: previous, session: session)
        for channel in channels.values {
            channel.rename(from: previous, to: nickname)
        }
        guard let announcement = try? IRCMessage(prefix: IRCPrefix(nick: previous, username: user.username, host: user.host), command: "NICK", parameters: [nickname]) else {
            return Outcome()
        }
        var outcome = broadcastToPeers(of: user, message: announcement)
        outcome.deliveries.append(Delivery(session: session, message: announcement))
        return outcome
    }

    private func registerUser(
        _ username: String,
        mode: String,
        realName: String,
        user: IRCUser,
        session: IRCServerSession
    ) -> Outcome {
        if user.isRegistered {
            return reply(.alreadyRegistered, to: user, trailing: "You may not reregister", session: session)
        }
        if (try? IRCUsername.validate(username)) == nil || realName.isEmpty {
            return reply(.needMoreParams, to: user, trailing: "Not enough parameters", middle: ["USER"], session: session)
        }
        user.username = username
        user.realName = realName
        if let rawMode = Int(mode) {
            user.apply(initialMode: rawMode)
        }
        guard !user.nickname.isEmpty else {
            return Outcome()
        }
        return finishRegistration(user: user, session: session)
    }

    private func finishRegistration(user: IRCUser, session: IRCServerSession) -> Outcome {
        if user.isNegotiatingCapabilities {
            return Outcome()
        }
        if let required = password, user.password != required {
            return reply(.passwordMismatch, to: user, trailing: "Password incorrect", session: session)
        }
        user.isRegistered = true
        let folded = IRCCaseMapping.fold(user.nickname)
        users[folded] = user
        sessions[folded] = session
        let welcome = "Welcome to the Internet Relay Network \(user.prefix.raw)"
        var outcome = reply(.welcome, to: user, trailing: welcome, session: session)
        outcome.append(reply(.yourHost, to: user, trailing: "Your host is \(name), running version \(version)", session: session))
        outcome.append(reply(.created, to: user, trailing: "This server was created \(created)", session: session))
        outcome.append(reply(.myInfo, to: user, trailing: "OovaimnqpsrtklbeI", middle: [name, version, "oiw"], session: session))
        outcome.append(lusers(user: user, session: session))
        outcome.append(motd(user: user, session: session))
        return outcome
    }

    private func pong(_ token: String, session: IRCServerSession) -> Outcome {
        guard let message = try? IRCMessage(prefix: serverPrefix, command: "PONG", parameters: [name, token]) else {
            return Outcome()
        }
        return Outcome(deliveries: [Delivery(session: session, message: message)])
    }

    private func join(_ channelNames: [String], keys: [String], user: IRCUser, session: IRCServerSession) -> Outcome {
        var outcome = Outcome()
        for (offset, channelName) in channelNames.enumerated() {
            let key = offset < keys.count ? keys[offset] : nil
            outcome.append(joinOne(channelName, key: key, user: user, session: session))
        }
        return outcome
    }

    private func joinOne(_ channelName: String, key: String?, user: IRCUser, session: IRCServerSession) -> Outcome {
        if (try? IRCChannelName.validate(channelName)) == nil {
            return reply(.badChanMask, to: user, trailing: "Bad channel mask", middle: [channelName], session: session)
        }
        let folded = IRCCaseMapping.fold(channelName)
        let channel: IRCChannel
        let createdChannel: Bool
        if let existing = channels[folded] {
            channel = existing
            createdChannel = false
        } else {
            channel = IRCChannel(name: channelName)
            channels[folded] = channel
            createdChannel = true
        }
        if channel.membership(for: user.nickname) != nil {
            return Outcome()
        }
        if let required = channel.key, required != key {
            return reply(.badChannelKey, to: user, trailing: "Cannot join channel (+k)", middle: [channel.name], session: session)
        }
        if let limit = channel.memberLimit, channel.members.count >= limit {
            return reply(.channelIsFull, to: user, trailing: "Cannot join channel (+l)", middle: [channel.name], session: session)
        }
        if channel.isInviteOnly && !channel.isInvited(user.nickname) {
            return reply(.inviteOnlyChan, to: user, trailing: "Cannot join channel (+i)", middle: [channel.name], session: session)
        }
        var membership = IRCMembership()
        if createdChannel {
            membership.isCreator = true
            membership.isOperator = true
        }
        channel.add(nickname: user.nickname, membership: membership)
        guard let joined = try? IRCMessage(prefix: user.prefix, command: "JOIN", parameters: [channel.name]) else {
            return Outcome()
        }
        var outcome = broadcast(joined, to: channel, except: nil)
        if let topic = channel.topic {
            outcome.append(reply(.topic, to: user, trailing: topic, middle: [channel.name], session: session))
        }
        outcome.append(nameReplies(channel, user: user, session: session))
        return outcome
    }

    private func part(_ channelNames: [String], comment: String?, user: IRCUser, session: IRCServerSession) -> Outcome {
        var outcome = Outcome()
        for channelName in channelNames {
            guard let channel = channels[IRCCaseMapping.fold(channelName)], channel.membership(for: user.nickname) != nil else {
                outcome.append(reply(.notOnChannel, to: user, trailing: "You're not on that channel", middle: [channelName], session: session))
                continue
            }
            var parameters = [channel.name]
            if let comment = comment {
                parameters.append(comment)
            }
            if let message = try? IRCMessage(prefix: user.prefix, command: "PART", parameters: parameters) {
                outcome.append(broadcast(message, to: channel, except: nil))
            }
            channel.remove(nickname: user.nickname)
            if channel.members.isEmpty {
                channels.removeValue(forKey: IRCCaseMapping.fold(channel.name))
            }
        }
        return outcome
    }

    private func leaveAll(user: IRCUser, session: IRCServerSession, comment: String?) -> Outcome {
        let names = channels.values.compactMap { channel -> String? in
            channel.membership(for: user.nickname) == nil ? nil : channel.name
        }
        return part(names, comment: comment, user: user, session: session)
    }

    private func chat(
        _ target: String,
        text: String,
        command: String,
        tags: IRCTags,
        user: IRCUser,
        session: IRCServerSession,
        reportErrors: Bool
    ) -> Outcome {
        if text.isEmpty {
            guard reportErrors else { return Outcome() }
            return reply(.noTextToSend, to: user, trailing: "No text to send", session: session)
        }
        guard var message = try? IRCMessage(prefix: user.prefix, command: command, parameters: [target, text], tags: tags) else {
            return Outcome()
        }
        if (try? IRCEncoder.encode(message)) == nil {
            message.tags = IRCTags()
            if (try? IRCEncoder.encode(message)) == nil {
                return Outcome()
            }
        }
        if (try? IRCChannelName.validate(target)) != nil {
            guard let channel = channels[IRCCaseMapping.fold(target)] else {
                guard reportErrors else { return Outcome() }
                return reply(.noSuchChannel, to: user, trailing: "No such channel", middle: [target], session: session)
            }
            let membership = channel.membership(for: user.nickname)
            if channel.noExternalMessages && membership == nil {
                guard reportErrors else { return Outcome() }
                return reply(.cannotSendToChan, to: user, trailing: "Cannot send to channel", middle: [channel.name], session: session)
            }
            if channel.isModerated && (membership == nil || membership?.canSpeakWhenModerated != true) {
                guard reportErrors else { return Outcome() }
                return reply(.cannotSendToChan, to: user, trailing: "Cannot send to channel", middle: [channel.name], session: session)
            }
            let outcome = broadcast(message, to: channel, except: user)
            if let away = user.awayMessage, command == "PRIVMSG" {
                _ = away
            }
            return outcome
        }
        guard let targetSession = sessions[IRCCaseMapping.fold(target)] else {
            guard reportErrors else { return Outcome() }
            return reply(.noSuchNick, to: user, trailing: "No such nick/channel", middle: [target], session: session)
        }
        var outcome = Outcome(deliveries: [Delivery(session: targetSession, message: messageForRecipient(message, session: targetSession))])
        if let away = targetSession.user.awayMessage, command == "PRIVMSG" {
            outcome.append(reply(.away, to: user, trailing: away, middle: [targetSession.user.nickname], session: session))
        }
        return outcome
    }

    private func setTopic(_ channelName: String, topic: String?, user: IRCUser, session: IRCServerSession) -> Outcome {
        guard let channel = channels[IRCCaseMapping.fold(channelName)] else {
            return reply(.noSuchChannel, to: user, trailing: "No such channel", middle: [channelName], session: session)
        }
        guard channel.membership(for: user.nickname) != nil else {
            return reply(.notOnChannel, to: user, trailing: "You're not on that channel", middle: [channel.name], session: session)
        }
        guard let topic = topic else {
            if let current = channel.topic {
                return reply(.topic, to: user, trailing: current, middle: [channel.name], session: session)
            }
            return reply(.noTopic, to: user, trailing: "No topic is set", middle: [channel.name], session: session)
        }
        if channel.topicLocked {
            let membership = channel.membership(for: user.nickname)
            if membership?.isOperator != true && membership?.isCreator != true {
                return reply(.chanOpPrivsNeeded, to: user, trailing: "You're not channel operator", middle: [channel.name], session: session)
            }
        }
        channel.topic = topic
        guard let message = try? IRCMessage(prefix: user.prefix, command: "TOPIC", parameters: [channel.name, topic]) else {
            return Outcome()
        }
        return broadcast(message, to: channel, except: nil)
    }

    private func names(_ channelNames: [String], user: IRCUser, session: IRCServerSession) -> Outcome {
        var outcome = Outcome()
        let selected: [IRCChannel]
        if channelNames.isEmpty {
            selected = channels.values.filter { channel in
                !channel.isSecret && !channel.isPrivate
            }
        } else {
            selected = channelNames.compactMap { channels[IRCCaseMapping.fold($0)] }
        }
        for channel in selected {
            outcome.append(nameReplies(channel, user: user, session: session))
        }
        outcome.append(reply(.endOfNames, to: user, trailing: "End of /NAMES list.", middle: ["*"], session: session))
        return outcome
    }

    private func nameReplies(_ channel: IRCChannel, user: IRCUser, session: IRCServerSession) -> Outcome {
        let nicks = channel.members.keys.sorted().map { folded -> String in
            let prefix = channel.members[folded]?.namesPrefix ?? ""
            let visible = users[folded]?.nickname ?? folded
            return prefix + visible
        }
        var outcome = reply(
            .nameReply,
            to: user,
            trailing: nicks.joined(separator: " "),
            middle: [channel.namesSymbol, channel.name],
            session: session
        )
        outcome.append(reply(.endOfNames, to: user, trailing: "End of /NAMES list.", middle: [channel.name], session: session))
        return outcome
    }

    private func modes(_ target: String, changes: [IRCModeChange], user: IRCUser, session: IRCServerSession) -> Outcome {
        if (try? IRCChannelName.validate(target)) != nil {
            return channelModes(target, changes: changes, user: user, session: session)
        }
        guard IRCCaseMapping.equals(target, user.nickname) else {
            return reply(.usersDontMatch, to: user, trailing: "Cannot change mode for other users", session: session)
        }
        if changes.isEmpty {
            return reply(.uModeIs, to: user, trailing: user.modeLetters.isEmpty ? "+" : user.modeLetters, session: session)
        }
        for change in changes {
            switch change.mode {
            case "i", "w", "s":
                if change.action == .enable {
                    user.modes.insert(change.mode)
                } else if change.action == .disable {
                    user.modes.remove(change.mode)
                }
            case "o", "O":
                if change.action == .enable {
                    return reply(.uModeUnknownFlag, to: user, trailing: "Unknown MODE flag", session: session)
                }
                user.modes.remove(change.mode)
                user.isOperator = false
            default:
                return reply(.uModeUnknownFlag, to: user, trailing: "Unknown MODE flag", session: session)
            }
        }
        let formatted = IRCModeParser.format(changes)
        guard let message = try? IRCMessage(prefix: user.prefix, command: "MODE", parameters: [user.nickname, formatted.modes]) else {
            return Outcome()
        }
        return Outcome(deliveries: [Delivery(session: session, message: message)])
    }

    private func channelModes(_ target: String, changes: [IRCModeChange], user: IRCUser, session: IRCServerSession) -> Outcome {
        guard let channel = channels[IRCCaseMapping.fold(target)] else {
            return reply(.noSuchChannel, to: user, trailing: "No such channel", middle: [target], session: session)
        }
        if changes.isEmpty {
            return reply(.channelModeIs, to: user, trailing: channel.modeString, middle: [channel.name], session: session)
        }
        let membership = channel.membership(for: user.nickname)
        let isOperator = membership?.isOperator == true || membership?.isCreator == true
        let changing = changes.contains { $0.action != .query }
        if changing && !isOperator {
            return reply(.chanOpPrivsNeeded, to: user, trailing: "You're not channel operator", middle: [channel.name], session: session)
        }
        for change in changes where change.action != .query {
            switch change.mode {
            case "i", "m", "n", "t", "s", "p", "a", "q", "r":
                channel.setMode(change.mode, enabled: change.action == .enable)
            case "k":
                if change.action == .enable, let key = change.parameter {
                    channel.key = key
                    channel.setMode("k", enabled: true)
                } else if change.action == .disable {
                    channel.key = nil
                    channel.setMode("k", enabled: false)
                }
            case "l":
                if change.action == .enable, let parameter = change.parameter, let limit = Int(parameter) {
                    channel.memberLimit = limit
                    channel.setMode("l", enabled: true)
                } else if change.action == .disable {
                    channel.memberLimit = nil
                    channel.setMode("l", enabled: false)
                }
            case "o", "O", "v":
                guard let parameter = change.parameter, var member = channel.membership(for: parameter) else {
                    continue
                }
                let enabled = change.action == .enable
                if change.mode == "v" {
                    member.hasVoice = enabled
                } else {
                    member.isOperator = enabled
                }
                channel.add(nickname: parameter, membership: member)
            default:
                return reply(.unknownMode, to: user, trailing: "is unknown mode char to me", middle: [String(change.mode)], session: session)
            }
        }
        let formatted = IRCModeParser.format(changes.filter { $0.action != .query })
        if formatted.modes.isEmpty {
            return reply(.channelModeIs, to: user, trailing: channel.modeString, middle: [channel.name], session: session)
        }
        var parameters = [channel.name, formatted.modes]
        parameters.append(contentsOf: formatted.parameters)
        guard let message = try? IRCMessage(prefix: user.prefix, command: "MODE", parameters: parameters) else {
            return Outcome()
        }
        return broadcast(message, to: channel, except: nil)
    }

    private func away(_ text: String?, user: IRCUser, session: IRCServerSession) -> Outcome {
        if let text = text, !text.isEmpty {
            user.awayMessage = text
            user.modes.insert("a")
            return reply(.nowAway, to: user, trailing: "You have been marked as being away", session: session)
        }
        user.awayMessage = nil
        user.modes.remove("a")
        return reply(.unAway, to: user, trailing: "You are no longer marked as being away", session: session)
    }

    private func motd(user: IRCUser, session: IRCServerSession) -> Outcome {
        reply(.noMotd, to: user, trailing: "MOTD File is missing", session: session)
    }

    private func lusers(user: IRCUser, session: IRCServerSession) -> Outcome {
        let count = users.count
        var outcome = reply(
            .luserClient,
            to: user,
            trailing: "There are \(count) users and 0 services on 1 servers",
            session: session
        )
        let operators = users.values.filter { $0.isOperator }.count
        outcome.append(reply(.luserOp, to: user, trailing: "operator(s) online", middle: [String(operators)], session: session))
        outcome.append(reply(.luserChannels, to: user, trailing: "channels formed", middle: [String(channels.count)], session: session))
        outcome.append(reply(.luserMe, to: user, trailing: "I have \(count) clients and 1 servers", session: session))
        return outcome
    }

    private func whois(_ masks: [String], user: IRCUser, session: IRCServerSession) -> Outcome {
        var outcome = Outcome()
        for mask in masks {
            guard let target = users[IRCCaseMapping.fold(mask)] else {
                outcome.append(reply(.noSuchNick, to: user, trailing: "No such nick/channel", middle: [mask], session: session))
                continue
            }
            outcome.append(reply(
                .whoisUser,
                to: user,
                trailing: target.realName,
                middle: [target.nickname, target.username, target.host],
                session: session
            ))
            outcome.append(reply(
                .whoisServer,
                to: user,
                trailing: name,
                middle: [target.nickname, name],
                session: session
            ))
            let shared = channels.values.compactMap { channel -> String? in
                guard let membership = channel.membership(for: target.nickname) else {
                    return nil
                }
                if (channel.isSecret || channel.isPrivate) && channel.membership(for: user.nickname) == nil {
                    return nil
                }
                return membership.namesPrefix + channel.name
            }
            if !shared.isEmpty {
                outcome.append(reply(
                    .whoisChannels,
                    to: user,
                    trailing: shared.joined(separator: " "),
                    middle: [target.nickname],
                    session: session
                ))
            }
        }
        let trailer = masks.last ?? "*"
        outcome.append(reply(.endOfWhois, to: user, trailing: "End of WHOIS list", middle: [trailer], session: session))
        return outcome
    }

    private func userhost(_ nicknames: [String], user: IRCUser, session: IRCServerSession) -> Outcome {
        let replies = nicknames.prefix(5).compactMap { nickname -> String? in
            guard let target = users[IRCCaseMapping.fold(nickname)] else {
                return nil
            }
            let oper = target.isOperator ? "*" : ""
            let away = target.awayMessage == nil ? "+" : "-"
            return "\(target.nickname)\(oper)=\(away)\(target.username)@\(target.host)"
        }
        return reply(.userHost, to: user, trailing: replies.joined(separator: " "), session: session)
    }

    private func ison(_ nicknames: [String], user: IRCUser, session: IRCServerSession) -> Outcome {
        let online = nicknames.compactMap { nickname -> String? in
            users[IRCCaseMapping.fold(nickname)]?.nickname
        }
        return reply(.isOn, to: user, trailing: online.joined(separator: " "), session: session)
    }

    private func drop(_ session: IRCServerSession, announce: Bool, comment: String) -> Outcome {
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

    private func nickIsTaken(_ nickname: String, except: IRCUser) -> Bool {
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

    private func rekey(_ user: IRCUser, from previous: String, session: IRCServerSession) {
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

    private func broadcast(_ message: IRCMessage, to channel: IRCChannel, except: IRCUser?) -> Outcome {
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

    private func broadcastToPeers(of user: IRCUser, message: IRCMessage) -> Outcome {
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

    private var serverPrefix: IRCPrefix {
        IRCPrefix(server: name)
    }

    private func reply(
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
}


    private func relayTags(_ message: IRCMessage, user: IRCUser) -> IRCTags {
        if user.enabledCapabilities.contains("message-tags") {
            return message.tags
        }
        return IRCTags()
    }

    private func messageForRecipient(_ message: IRCMessage, session: IRCServerSession) -> IRCMessage {
        if message.tags.isEmpty || session.user.enabledCapabilities.contains("message-tags") {
            return message
        }
        var stripped = message
        stripped.tags = IRCTags()
        return stripped
    }

    private func negotiateCapabilities(_ message: IRCMessage, user: IRCUser, session: IRCServerSession) -> Outcome {
        let subcommand = message.parameters.first?.uppercased() ?? ""
        switch subcommand {
        case "LS":
            let requested = message.parameters.count > 1 ? Int(message.parameters[1]) ?? 0 : 0
            if requested > user.capVersion {
                user.capVersion = requested
            }
            if !user.isRegistered {
                user.isNegotiatingCapabilities = true
            }
            return capabilityReply(
                "LS",
                payload: IRCServer.offeredCapabilities.sorted().joined(separator: " "),
                user: user,
                session: session
            )
        case "LIST":
            return capabilityReply(
                "LIST",
                payload: user.enabledCapabilities.sorted().joined(separator: " "),
                user: user,
                session: session
            )
        case "REQ":
            if !user.isRegistered {
                user.isNegotiatingCapabilities = true
            }
            let tokens = capabilityTokens(message.parameters)
            if tokens.isEmpty {
                return invalidCapabilityCommand(subcommand, user: user, session: session)
            }
            for token in tokens {
                let name = token.hasPrefix("-") ? String(token.dropFirst()) : token
                if name.isEmpty || !IRCServer.offeredCapabilities.contains(name) {
                    return capabilityReply("NAK", payload: tokens.joined(separator: " "), user: user, session: session)
                }
            }
            for token in tokens {
                if token.hasPrefix("-") {
                    user.enabledCapabilities.remove(String(token.dropFirst()))
                } else {
                    user.enabledCapabilities.insert(token)
                }
            }
            return capabilityReply("ACK", payload: tokens.joined(separator: " "), user: user, session: session)
        case "END":
            if user.isRegistered {
                return Outcome()
            }
            user.isNegotiatingCapabilities = false
            if !user.nickname.isEmpty && !user.username.isEmpty {
                return finishRegistration(user: user, session: session)
            }
            return Outcome()
        default:
            let name = subcommand.isEmpty ? "CAP" : subcommand
            return invalidCapabilityCommand(name, user: user, session: session)
        }
    }

    private func capabilityTokens(_ parameters: [String]) -> [String] {
        parameters.dropFirst().joined(separator: " ").split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    private func capabilityReply(_ subcommand: String, payload: String, user: IRCUser, session: IRCServerSession) -> Outcome {
        let nick = user.nickname.isEmpty ? "*" : user.nickname
        guard let reply = try? IRCMessage(prefix: serverPrefix, command: "CAP", parameters: [nick, subcommand, payload]) else {
            return Outcome()
        }
        return Outcome(deliveries: [Delivery(session: session, message: reply)])
    }

    private func invalidCapabilityCommand(_ subcommand: String, user: IRCUser, session: IRCServerSession) -> Outcome {
        let nick = user.nickname.isEmpty ? "*" : user.nickname
        guard let reply = try? IRCMessage(prefix: serverPrefix, command: "410", parameters: [nick, subcommand, "Invalid CAP command"]) else {
            return Outcome()
        }
        return Outcome(deliveries: [Delivery(session: session, message: reply)])
    }

private struct Delivery {
    var session: IRCServerSession
    var message: IRCMessage
}

private struct Outcome {
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
