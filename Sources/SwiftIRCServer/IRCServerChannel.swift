import Foundation
import SwiftIRCCore

extension IRCServer {
    func join(_ channelNames: [String], keys: [String], user: IRCUser, session: IRCServerSession) -> Outcome {
        var outcome = Outcome()
        for (offset, channelName) in channelNames.enumerated() {
            let key = offset < keys.count ? keys[offset] : nil
            outcome.append(joinOne(channelName, key: key, user: user, session: session))
        }
        return outcome
    }


    func joinOne(_ channelName: String, key: String?, user: IRCUser, session: IRCServerSession) -> Outcome {
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


    func part(_ channelNames: [String], comment: String?, user: IRCUser, session: IRCServerSession) -> Outcome {
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


    func leaveAll(user: IRCUser, session: IRCServerSession, comment: String?) -> Outcome {
        let names = channels.values.compactMap { channel -> String? in
            channel.membership(for: user.nickname) == nil ? nil : channel.name
        }
        return part(names, comment: comment, user: user, session: session)
    }


    func setTopic(_ channelName: String, topic: String?, user: IRCUser, session: IRCServerSession) -> Outcome {
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


    func names(_ channelNames: [String], user: IRCUser, session: IRCServerSession) -> Outcome {
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


    func nameReplies(_ channel: IRCChannel, user: IRCUser, session: IRCServerSession) -> Outcome {
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

}
