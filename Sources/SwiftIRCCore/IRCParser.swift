import Foundation

/// Reads IRC messages from a line or a byte stream. RFC 2812 section 2.3.1.
///
/// A leading `@` introduces IRCv3 tags. The tags end at the first raw space.
public enum IRCParser {
    public static func parse(line: String) throws -> IRCMessage? {
        try parse(octets: try IRCOctets.encode(line))
    }

    public static func parse(octets: [UInt8]) throws -> IRCMessage? {
        if octets.contains(0) {
            throw IRCError.nulOctet
        }
        var bytes = octets
        if bytes.last == 0x0A {
            bytes.removeLast()
        }
        if bytes.last == 0x0D {
            bytes.removeLast()
        }
        if bytes.isEmpty {
            return nil
        }
        let hadTerminator = octets.last == 0x0A
        let framedLength = hadTerminator ? octets.count : bytes.count + 2
        guard framedLength <= IRC.maximumMessageLength else {
            throw IRCError.messageTooLong(framedLength)
        }

        var index = 0
        var tags = IRCTags()
        if bytes[index] == 0x40 {
            guard let space = bytes[index...].firstIndex(of: 0x20), space > index + 1 else {
                throw IRCError.invalidCommand("")
            }
            tags = try IRCTags.parse(IRCOctets.decode(Array(bytes[(index + 1) ..< space])))
            index = space + 1
            guard index < bytes.count else {
                throw IRCError.missingCommand
            }
        }

        var prefix: IRCPrefix?
        if bytes[index] == 0x3A {
            index += 1
            guard let space = bytes[index...].firstIndex(of: 0x20), space > index else {
                throw IRCError.invalidCommand("")
            }
            prefix = IRCPrefix(raw: IRCOctets.decode(Array(bytes[index ..< space])))
            index = space + 1
            guard index < bytes.count else {
                throw IRCError.missingCommand
            }
        }

        let commandEnd = bytes[index...].firstIndex(of: 0x20) ?? bytes.endIndex
        let commandBytes = Array(bytes[index ..< commandEnd])
        guard !commandBytes.isEmpty else {
            throw IRCError.missingCommand
        }
        let command = try IRCCommand.canonicalName(IRCOctets.decode(commandBytes))
        index = commandEnd == bytes.endIndex ? bytes.endIndex : commandEnd + 1

        var parameters: [String] = []
        while index < bytes.count {
            if bytes[index] == 0x3A {
                parameters.append(IRCOctets.decode(Array(bytes[(index + 1)...])))
                break
            }
            if parameters.count == IRC.maximumParameterCount - 1 {
                parameters.append(IRCOctets.decode(Array(bytes[index...])))
                break
            }
            if let space = bytes[index...].firstIndex(of: 0x20) {
                parameters.append(IRCOctets.decode(Array(bytes[index ..< space])))
                index = space + 1
                if index == bytes.count {
                    break
                }
            } else {
                parameters.append(IRCOctets.decode(Array(bytes[index...])))
                break
            }
        }
        guard parameters.count <= IRC.maximumParameterCount else {
            throw IRCError.tooManyParameters(parameters.count)
        }
        return IRCMessage(validatedPrefix: prefix, command: command, parameters: parameters, tags: tags)
    }
}

/// Splits a byte stream on LF, ignoring empty messages. RFC 2812 section 2.3.1.
public struct IRCFramer {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append(_ bytes: [UInt8]) throws -> [IRCMessage] {
        buffer.append(contentsOf: bytes)
        var messages: [IRCMessage] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Array(buffer[...newline])
            buffer.removeFirst(newline + 1)
            if line.count > IRC.maximumMessageLength {
                throw IRCError.messageTooLong(line.count)
            }
            if let message = try IRCParser.parse(octets: line) {
                messages.append(message)
            }
        }
        if buffer.count > IRC.maximumMessageLength {
            let length = buffer.count
            buffer.removeAll()
            throw IRCError.messageTooLong(length)
        }
        return messages
    }
}
