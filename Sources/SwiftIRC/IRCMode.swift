import Foundation

/// One mode flag from a MODE message.
/// Channel modes are defined in RFC 2811 section 4. User modes are defined in RFC 2812 section 3.1.5.
public struct IRCModeChange: Equatable {
    public enum Action: Equatable {
        case enable
        case disable
        case query
    }

    public var action: Action
    public var mode: Character
    public var parameter: String?

    public init(action: Action, mode: Character, parameter: String? = nil) {
        self.action = action
        self.mode = mode
        self.parameter = parameter
    }

    public var takesParameter: Bool {
        parameter != nil
    }
}

public enum IRCChannelModeKind: Equatable {
    /// `a i m n q p s r t` — no parameter.
    case flag
    /// `O o v` — nickname parameter when set or unset.
    case membership
    /// `b e I` — mask parameter, omitted when listing.
    case list
    /// `k` — key parameter when set or unset.
    case key
    /// `l` — limit parameter only when set.
    case limit

    public static func kind(of mode: Character) -> IRCChannelModeKind? {
        switch mode {
        case "a", "i", "m", "n", "q", "p", "s", "r", "t":
            return .flag
        case "O", "o", "v":
            return .membership
        case "b", "e", "I":
            return .list
        case "k":
            return .key
        case "l":
            return .limit
        default:
            return nil
        }
    }
}

public enum IRCUserMode {
    /// `a i w r o O s`. Mode `a` is visible but cannot be changed with MODE.
    public static let letters: Set<Character> = ["a", "i", "w", "r", "o", "O", "s"]

    public static func isKnown(_ mode: Character) -> Bool {
        letters.contains(mode)
    }
}

public enum IRCModeParser {
    /// Parses the parameters of a channel MODE command that follow the channel name.
    public static func parseChannel(parameters: [String]) -> [IRCModeChange] {
        parse(parameters: parameters, channel: true)
    }

    /// Parses the parameters of a user MODE command that follow the nickname.
    public static func parseUser(parameters: [String]) -> [IRCModeChange] {
        parse(parameters: parameters, channel: false)
    }

    /// Formats changes into one mode string plus its parameters.
    /// Parameter-taking channel changes are limited to three by the caller.
    public static func format(_ changes: [IRCModeChange]) -> (modes: String, parameters: [String]) {
        var modes = ""
        var parameters: [String] = []
        var current: IRCModeChange.Action?
        for change in changes {
            if change.action != current {
                switch change.action {
                case .enable:
                    modes.append("+")
                case .disable:
                    modes.append("-")
                case .query:
                    break
                }
                current = change.action
            }
            modes.append(change.mode)
            if let parameter = change.parameter {
                parameters.append(parameter)
            }
        }
        return (modes, parameters)
    }

    private static func parse(parameters: [String], channel: Bool) -> [IRCModeChange] {
        var changes: [IRCModeChange] = []
        var index = 0
        while index < parameters.count {
            let word = parameters[index]
            index += 1
            if word.isEmpty {
                continue
            }
            var action: IRCModeChange.Action?
            var sawSign = false
            for character in word {
                if character == "+" {
                    action = .enable
                    sawSign = true
                    continue
                }
                if character == "-" {
                    action = .disable
                    sawSign = true
                    continue
                }
                let resolved = action ?? .query
                let parameter = takeParameter(
                    mode: character,
                    action: resolved,
                    sawSign: sawSign,
                    parameters: parameters,
                    index: &index,
                    channel: channel
                )
                changes.append(IRCModeChange(action: resolved, mode: character, parameter: parameter))
            }
        }
        return changes
    }

    private static func takeParameter(
        mode: Character,
        action: IRCModeChange.Action,
        sawSign: Bool,
        parameters: [String],
        index: inout Int,
        channel: Bool
    ) -> String? {
        guard channel, let kind = IRCChannelModeKind.kind(of: mode) else {
            return nil
        }
        switch kind {
        case .flag:
            return nil
        case .membership, .key:
            guard sawSign, index < parameters.count else {
                return nil
            }
            let value = parameters[index]
            index += 1
            return value
        case .limit:
            guard action == .enable, index < parameters.count else {
                return nil
            }
            let value = parameters[index]
            index += 1
            return value
        case .list:
            guard sawSign, index < parameters.count else {
                return nil
            }
            let next = parameters[index]
            if next.hasPrefix("+") || next.hasPrefix("-") {
                return nil
            }
            index += 1
            return next
        }
    }
}
