import Foundation

/// Constants from RFC 1459, RFC 2812, and RFC 7194.
public enum IRC {
    /// Maximum length of one message, including the trailing CR-LF.
    /// RFC 2812 section 2.3.
    public static let maximumMessageLength = 512

    /// Maximum number of parameters in one message. RFC 2812 section 2.3.
    public static let maximumParameterCount = 15

    /// Nickname length: `( letter / special ) *8( ... )`. RFC 2812 section 2.3.1.
    public static let nicknameMaximumLength = 9

    /// Channel names are at most 50 characters. RFC 2812 section 1.3.
    public static let channelNameMaximumLength = 50

    /// Channel keys are 1 to 23 octets. RFC 2812 section 2.3.1.
    public static let keyMaximumLength = 23

    /// Hostnames carried by the protocol are limited to 63 characters.
    /// RFC 2812 section 2.3.1, note 2.
    public static let hostnameMaximumLength = 63

    /// At most three parameter-taking channel mode changes per MODE command.
    /// RFC 2812 section 3.2.3.
    public static let maximumChannelModeParameters = 3

    /// Plaintext client port used by the protocol. RFC 1459.
    public static let cleartextPort: UInt16 = 6667

    /// Default port for IRC via TLS. RFC 7194.
    public static let tlsPort: UInt16 = 6697

    /// Server-to-server protocol version encoded as in RFC 2813 (`2.10` -> `0210`).
    public static let serverProtocolVersion = "0210"

    public static let crlf = "\r\n"
}

public enum IRCError: Error, Equatable {
    case emptyMessage
    case messageTooLong(Int)
    case missingCommand
    case invalidCommand(String)
    case tooManyParameters(Int)
    case parameterContainsSpace(String)
    case nulOctet
    case invalidOctet
    case invalidNickname(String)
    case invalidChannel(String)
    case invalidKey(String)
    case invalidUsername(String)
    case invalidHostname(String)
    case awayModeIsNotSettable
    case tooManyModeParameters
    case missingModeParameter(Character)
    case notConnected
    case alreadyRegistered
    case passwordSentTooLate
    case connectionFailed(String)
    case registrationFailed(numeric: Int, message: String)
    case timedOut
    case unexpectedEnd
}

enum IRCOctets {
    static func encode(_ string: String) throws -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(string.unicodeScalars.count)
        for scalar in string.unicodeScalars {
            guard scalar.value <= 255 else {
                throw IRCError.invalidOctet
            }
            bytes.append(UInt8(scalar.value))
        }
        return bytes
    }

    static func decode(_ bytes: [UInt8]) -> String {
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(bytes.count)
        for byte in bytes {
            scalars.append(Unicode.Scalar(byte))
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
