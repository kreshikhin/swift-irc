import Foundation

/// One IRC message. RFC 2812 section 2.3.1.
public struct IRCMessage: Equatable {
    public var prefix: IRCPrefix?
    public var command: String
    public var parameters: [String]

    public init(prefix: IRCPrefix? = nil, command: String, parameters: [String] = []) throws {
        self.prefix = prefix
        self.command = try IRCCommand.canonicalName(command)
        guard parameters.count <= IRC.maximumParameterCount else {
            throw IRCError.tooManyParameters(parameters.count)
        }
        for parameter in parameters.dropLast() where parameter.contains(" ") || parameter.isEmpty || parameter.hasPrefix(":") {
            throw IRCError.parameterContainsSpace(parameter)
        }
        self.parameters = parameters
    }

    public init(prefix: IRCPrefix? = nil, command: IRCCommand) throws {
        try self.init(prefix: prefix, command: command.name, parameters: command.parameters)
    }

    public var numeric: IRCNumeric? {
        guard command.count == 3, command.allSatisfy({ $0.isNumber }) else {
            return nil
        }
        return IRCNumeric(code: Int(command) ?? 0)
    }

    /// Parses one line. `nil` means the line was empty and must be ignored.
    /// The line may include a trailing CR-LF.
    public static func parse(line: String) throws -> IRCMessage? {
        try parse(octets: IRCOctets.encode(line))
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
        return IRCMessage(prefix: prefix, command: command, parameters: parameters, validated: true)
    }

    public func serialized() throws -> [UInt8] {
        var text = ""
        if let prefix = prefix {
            text += ":" + prefix.raw + " "
        }
        text += command
        for (offset, parameter) in parameters.enumerated() {
            text += " "
            let isLast = offset == parameters.count - 1
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

    public func serializedString() throws -> String {
        IRCOctets.decode(try serialized())
    }

    private init(prefix: IRCPrefix?, command: String, parameters: [String], validated: Bool) {
        self.prefix = prefix
        self.command = command
        self.parameters = parameters
        _ = validated
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
            if let message = try IRCMessage.parse(octets: line) {
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
