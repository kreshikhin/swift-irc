import Foundation
import SwiftIRCCore

extension IRCServer {
    func registerPassword(_ password: String, user: IRCUser, session: IRCServerSession) -> Outcome {
        if user.isRegistered || !user.nickname.isEmpty || !user.username.isEmpty {
            return reply(.alreadyRegistered, to: user, trailing: "You may not reregister", session: session)
        }
        user.password = password
        return Outcome()
    }

    func changeNick(_ nickname: String, user: IRCUser, session: IRCServerSession) -> Outcome {
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

    func registerUser(
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

    func finishRegistration(user: IRCUser, session: IRCServerSession) -> Outcome {
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

    func pong(_ token: String, session: IRCServerSession) -> Outcome {
        guard let message = try? IRCMessage(prefix: serverPrefix, command: "PONG", parameters: [name, token]) else {
            return Outcome()
        }
        return Outcome(deliveries: [Delivery(session: session, message: message)])
    }

    func negotiateCapabilities(_ message: IRCMessage, user: IRCUser, session: IRCServerSession) -> Outcome {
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

    func capabilityTokens(_ parameters: [String]) -> [String] {
        parameters.dropFirst().joined(separator: " ").split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    func capabilityReply(_ subcommand: String, payload: String, user: IRCUser, session: IRCServerSession) -> Outcome {
        let nick = user.nickname.isEmpty ? "*" : user.nickname
        guard let reply = try? IRCMessage(prefix: serverPrefix, command: "CAP", parameters: [nick, subcommand, payload]) else {
            return Outcome()
        }
        return Outcome(deliveries: [Delivery(session: session, message: reply)])
    }

    func invalidCapabilityCommand(_ subcommand: String, user: IRCUser, session: IRCServerSession) -> Outcome {
        let nick = user.nickname.isEmpty ? "*" : user.nickname
        guard let reply = try? IRCMessage(prefix: serverPrefix, command: "410", parameters: [nick, subcommand, "Invalid CAP command"]) else {
            return Outcome()
        }
        return Outcome(deliveries: [Delivery(session: session, message: reply)])
    }

}
