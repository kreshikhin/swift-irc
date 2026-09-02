import Foundation

/// RFC 1459 casemapping: `[]\~` are the uppercase forms of `{}|^`.
public enum IRCCaseMapping {
    public static func fold(_ string: String) -> String {
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(string.unicodeScalars.count)
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x41 ... 0x5A:
                scalars.append(Unicode.Scalar(scalar.value + 32)!)
            case 0x5B: // [
                scalars.append(Unicode.Scalar(0x7B)!) // {
            case 0x5D: // ]
                scalars.append(Unicode.Scalar(0x7D)!) // }
            case 0x5C: // \
                scalars.append(Unicode.Scalar(0x7C)!) // |
            case 0x7E: // ~
                scalars.append(Unicode.Scalar(0x5E)!) // ^
            default:
                scalars.append(scalar)
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    public static func equals(_ lhs: String, _ rhs: String) -> Bool {
        fold(lhs) == fold(rhs)
    }
}

public enum IRCNickname {
    /// `nickname = ( letter / special ) *8( letter / digit / special / "-" )`
    public static func isValid(_ nickname: String) -> Bool {
        (try? validate(nickname)) != nil
    }

    public static func validate(_ nickname: String) throws {
        let bytes = try IRCOctets.encode(nickname)
        guard (1 ... IRC.nicknameMaximumLength).contains(bytes.count) else {
            throw IRCError.invalidNickname(nickname)
        }
        guard isLetter(bytes[0]) || isSpecial(bytes[0]) else {
            throw IRCError.invalidNickname(nickname)
        }
        for byte in bytes.dropFirst() {
            guard isLetter(byte) || isDigit(byte) || isSpecial(byte) || byte == 0x2D else {
                throw IRCError.invalidNickname(nickname)
            }
        }
    }

    static func isLetter(_ byte: UInt8) -> Bool {
        (0x41 ... 0x5A).contains(byte) || (0x61 ... 0x7A).contains(byte)
    }

    static func isDigit(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
    }

    /// `"["`, `"]"`, `"\"`, `` "`" ``, `"_"`, `"^"`, `"{"`, `"|"`, `"}"`.
    static func isSpecial(_ byte: UInt8) -> Bool {
        (0x5B ... 0x60).contains(byte) || (0x7B ... 0x7D).contains(byte)
    }
}

public enum IRCChannelName {
    public static func isValid(_ name: String) -> Bool {
        (try? validate(name)) != nil
    }

    public static func validate(_ name: String) throws {
        let bytes = try IRCOctets.encode(name)
        guard (2 ... IRC.channelNameMaximumLength).contains(bytes.count) else {
            throw IRCError.invalidChannel(name)
        }
        let prefix = bytes[0]
        guard prefix == 0x23 || prefix == 0x2B || prefix == 0x26 || prefix == 0x21 else {
            throw IRCError.invalidChannel(name)
        }
        var body = bytes.dropFirst()
        if prefix == 0x21 {
            guard body.count >= 5 else {
                throw IRCError.invalidChannel(name)
            }
            let identifier = body.prefix(5)
            guard identifier.allSatisfy({ isChannelID($0) }) else {
                throw IRCError.invalidChannel(name)
            }
            body = body.dropFirst(5)
            guard !body.isEmpty else {
                throw IRCError.invalidChannel(name)
            }
        }
        var sawColon = false
        var chunkLength = 0
        for byte in body {
            if byte == 0x3A { // :
                guard !sawColon, chunkLength > 0 else {
                    throw IRCError.invalidChannel(name)
                }
                sawColon = true
                chunkLength = 0
                continue
            }
            guard isChanStringOctet(byte) else {
                throw IRCError.invalidChannel(name)
            }
            chunkLength += 1
        }
        if sawColon && chunkLength == 0 {
            throw IRCError.invalidChannel(name)
        }
    }

    private static func isChannelID(_ byte: UInt8) -> Bool {
        (0x41 ... 0x5A).contains(byte) || (0x30 ... 0x39).contains(byte)
    }

    /// Any octet except NUL, BELL, CR, LF, space, comma, and colon.
    private static func isChanStringOctet(_ byte: UInt8) -> Bool {
        byte != 0x00 && byte != 0x07 && byte != 0x0A && byte != 0x0D
            && byte != 0x20 && byte != 0x2C && byte != 0x3A
    }
}

public enum IRCChannelKey {
    public static func validate(_ key: String) throws {
        let bytes = try IRCOctets.encode(key)
        guard (1 ... IRC.keyMaximumLength).contains(bytes.count) else {
            throw IRCError.invalidKey(key)
        }
        for byte in bytes {
            let allowed = (0x01 ... 0x05).contains(byte)
                || (0x07 ... 0x08).contains(byte)
                || byte == 0x0C
                || (0x0E ... 0x1F).contains(byte)
                || (0x21 ... 0x7F).contains(byte)
            guard allowed else {
                throw IRCError.invalidKey(key)
            }
        }
    }
}

public enum IRCUsername {
    /// Any octet except NUL, CR, LF, space, and `@`.
    public static func validate(_ username: String) throws {
        let bytes = try IRCOctets.encode(username)
        guard !bytes.isEmpty else {
            throw IRCError.invalidUsername(username)
        }
        for byte in bytes {
            let allowed = (0x01 ... 0x09).contains(byte)
                || (0x0B ... 0x0C).contains(byte)
                || (0x0E ... 0x1F).contains(byte)
                || (0x21 ... 0x3F).contains(byte)
                || (0x41 ... 0xFF).contains(byte)
            guard allowed else {
                throw IRCError.invalidUsername(username)
            }
        }
    }
}

public enum IRCHostname {
    public static func validate(_ hostname: String) throws {
        let bytes = try IRCOctets.encode(hostname)
        guard (1 ... IRC.hostnameMaximumLength).contains(bytes.count) else {
            throw IRCError.invalidHostname(hostname)
        }
    }
}

/// Bits 2 and 3 of the USER mode number. RFC 2812 section 3.1.3.
public struct IRCInitialUserMode: OptionSet, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Bit 2, value 4. Sets user mode `w`.
    public static let wallops = IRCInitialUserMode(rawValue: 1 << 2)

    /// Bit 3, value 8. Sets user mode `i`.
    public static let invisible = IRCInitialUserMode(rawValue: 1 << 3)
}
