import Foundation
import SwiftIRCCore

extension IRCServer {
    func chat(
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


    func away(_ text: String?, user: IRCUser, session: IRCServerSession) -> Outcome {
        if let text = text, !text.isEmpty {
            user.awayMessage = text
            user.modes.insert("a")
            return reply(.nowAway, to: user, trailing: "You have been marked as being away", session: session)
        }
        user.awayMessage = nil
        user.modes.remove("a")
        return reply(.unAway, to: user, trailing: "You are no longer marked as being away", session: session)
    }


    func motd(user: IRCUser, session: IRCServerSession) -> Outcome {
        reply(.noMotd, to: user, trailing: "MOTD File is missing", session: session)
    }


    func lusers(user: IRCUser, session: IRCServerSession) -> Outcome {
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


    func whois(_ masks: [String], user: IRCUser, session: IRCServerSession) -> Outcome {
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


    func userhost(_ nicknames: [String], user: IRCUser, session: IRCServerSession) -> Outcome {
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


    func ison(_ nicknames: [String], user: IRCUser, session: IRCServerSession) -> Outcome {
        let online = nicknames.compactMap { nickname -> String? in
            users[IRCCaseMapping.fold(nickname)]?.nickname
        }
        return reply(.isOn, to: user, trailing: online.joined(separator: " "), session: session)
    }

}
