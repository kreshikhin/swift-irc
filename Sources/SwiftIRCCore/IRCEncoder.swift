import Foundation

/// Writes an `IRCMessage` as the octets sent on the wire, including CR-LF.
public enum IRCEncoder {
    public static func encode(_ message: IRCMessage) throws -> [UInt8] {
        var text = ""
        if !message.tags.isEmpty {
            text += "@" + message.tags.encoded() + " "
        }
        if let prefix = message.prefix {
            text += ":" + prefix.raw + " "
        }
        text += message.command
        for (offset, parameter) in message.parameters.enumerated() {
            text += " "
            let isLast = offset == message.parameters.count - 1
            if isLast && (parameter.isEmpty || parameter.contains(" ") || parameter.hasPrefix(":")) {
                text += ":" + parameter
            } else if !isLast && (parameter.isEmpty || parameter.contains(" ") || parameter.hasPrefix(":")) {
                throw IRCError.parameterContainsSpace(parameter)
            } else {
                text += parameter
            }
        }
        text += IRC.crlf
        let bytes = try IRCOctets.encode(text)
        guard bytes.count <= IRC.maximumMessageLength else {
            throw IRCError.messageTooLong(bytes.count)
        }
        return bytes
    }

    public static func encodeString(_ message: IRCMessage) throws -> String {
        IRCOctets.decode(try encode(message))
    }
}
