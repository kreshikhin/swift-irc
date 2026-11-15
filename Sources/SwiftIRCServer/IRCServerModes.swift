import Foundation
import SwiftIRCCore

extension IRCServer {
    func modes(_ target: String, changes: [IRCModeChange], user: IRCUser, session: IRCServerSession) -> Outcome {
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


    func channelModes(_ target: String, changes: [IRCModeChange], user: IRCUser, session: IRCServerSession) -> Outcome {
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

}
