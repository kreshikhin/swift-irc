import Foundation
import SwiftIRCCore

/// Membership of one nickname on a channel. RFC 2811.
public struct IRCMembership: Equatable {
    public var isCreator: Bool
    public var isOperator: Bool
    public var hasVoice: Bool

    public init(isCreator: Bool = false, isOperator: Bool = false, hasVoice: Bool = false) {
        self.isCreator = isCreator
        self.isOperator = isOperator
        self.hasVoice = hasVoice
    }

    /// The single prefix character sent in NAMES. `@` outranks `+`.
    public var namesPrefix: String {
        if isCreator || isOperator {
            return "@"
        }
        if hasVoice {
            return "+"
        }
        return ""
    }

    public var canSpeakWhenModerated: Bool {
        isCreator || isOperator || hasVoice
    }
}

/// A channel hosted by the local server. RFC 2811.
public final class IRCChannel {
    public let name: String
    public internal(set) var topic: String?
    public private(set) var members: [String: IRCMembership]
    public var key: String?
    public var memberLimit: Int?
    public var modes: Set<Character>
    public private(set) var invited: Set<String>

    public init(name: String) {
        self.name = name
        topic = nil
        members = [:]
        key = nil
        memberLimit = nil
        modes = Set("nt")
        invited = []
    }

    public var isInviteOnly: Bool { hasMode("i") }
    public var isModerated: Bool { hasMode("m") }
    public var isSecret: Bool { hasMode("s") }
    public var isPrivate: Bool { hasMode("p") }
    public var topicLocked: Bool { hasMode("t") }
    public var noExternalMessages: Bool { hasMode("n") }

    public func hasMode(_ letter: Character) -> Bool {
        modes.contains(letter)
    }

    public func setMode(_ letter: Character, enabled: Bool) {
        if enabled {
            modes.insert(letter)
        } else {
            modes.remove(letter)
        }
    }

    public func membership(for nickname: String) -> IRCMembership? {
        members[IRCCaseMapping.fold(nickname)]
    }

    public func add(nickname: String, membership: IRCMembership) {
        members[IRCCaseMapping.fold(nickname)] = membership
    }

    public func remove(nickname: String) {
        let folded = IRCCaseMapping.fold(nickname)
        members.removeValue(forKey: folded)
        invited.remove(folded)
    }

    public func rename(from oldNickname: String, to newNickname: String) {
        let oldKey = IRCCaseMapping.fold(oldNickname)
        guard let membership = members.removeValue(forKey: oldKey) else {
            return
        }
        members[IRCCaseMapping.fold(newNickname)] = membership
        if invited.remove(oldKey) != nil {
            invited.insert(IRCCaseMapping.fold(newNickname))
        }
    }

    public func invite(_ nickname: String) {
        invited.insert(IRCCaseMapping.fold(nickname))
    }

    public func isInvited(_ nickname: String) -> Bool {
        invited.contains(IRCCaseMapping.fold(nickname))
    }

    public var namesSymbol: String {
        if isSecret {
            return "@"
        }
        if isPrivate {
            return "*"
        }
        return "="
    }

    /// Mode string currently set, without list entries.
    public var modeString: String {
        let order: [Character] = ["a", "i", "m", "n", "q", "p", "s", "r", "t", "k", "l"]
        let enabled = order.filter { modes.contains($0) }
        if enabled.isEmpty && key == nil && memberLimit == nil {
            return "+"
        }
        return "+" + String(enabled)
    }
}
