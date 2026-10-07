import Foundation

/// One IRCv3 message tag. A missing value and an empty value are different:
/// `key` has no value, `key=` has an empty value.
public struct IRCTag: Equatable, Hashable {
    public var key: String
    public var value: String?

    public init(key: String, value: String? = nil) {
        self.key = key
        self.value = value
    }
}

/// The `@tags` prefix of an IRCv3 message.
///
/// Values escape space, `;`, `\`, CR, and LF as `\s`, `\:`, `\\`, `\r`, and `\n`.
public struct IRCTags: Equatable {
    public var entries: [IRCTag]

    public init(entries: [IRCTag] = []) {
        self.entries = entries
    }

    public var isEmpty: Bool {
        entries.isEmpty
    }

    public static func parse(_ raw: String) throws -> IRCTags {
        guard !raw.isEmpty else {
            throw IRCError.invalidCommand(raw)
        }
        var entries: [IRCTag] = []
        let parts = raw.split(separator: ";", omittingEmptySubsequences: false)
        for part in parts {
            if part.isEmpty {
                throw IRCError.invalidCommand(raw)
            }
            let text = String(part)
            let key: String
            let value: String?
            if let equal = text.firstIndex(of: "=") {
                key = String(text[..<equal])
                value = unescape(String(text[text.index(after: equal)...]))
            } else {
                key = text
                value = nil
            }
            guard isValidKey(key) else {
                throw IRCError.invalidCommand(key)
            }
            entries.append(IRCTag(key: key, value: value))
        }
        return IRCTags(entries: entries)
    }

    /// Encodes the tags without the leading `@`.
    public func encoded() -> String {
        entries.map { entry in
            guard let value = entry.value else {
                return entry.key
            }
            return entry.key + "=" + IRCTags.escape(value)
        }.joined(separator: ";")
    }

    private static func isValidKey(_ key: String) -> Bool {
        guard let first = key.first else {
            return false
        }
        guard first == "+" || isKeyCharacter(first) else {
            return false
        }
        for character in key {
            if character == "+" || character == "/" || isKeyCharacter(character) {
                continue
            }
            return false
        }
        return true
    }

    private static func isKeyCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        return (0x41 ... 0x5A).contains(scalar.value)
            || (0x61 ... 0x7A).contains(scalar.value)
            || (0x30 ... 0x39).contains(scalar.value)
            || scalar.value == 0x2D
            || scalar.value == 0x5F
            || scalar.value == 0x2E
    }

    static func escape(_ value: String) -> String {
        var encoded = ""
        for character in value {
            switch character {
            case " ":
                encoded += "\\s"
            case ";":
                encoded += "\\:"
            case "\\":
                encoded += "\\\\"
            case "\r":
                encoded += "\\r"
            case "\n":
                encoded += "\\n"
            default:
                encoded.append(character)
            }
        }
        return encoded
    }

    static func unescape(_ value: String) -> String {
        var decoded = ""
        var escaped = false
        for character in value {
            if escaped {
                switch character {
                case "s":
                    decoded += " "
                case ":":
                    decoded += ";"
                case "r":
                    decoded += "\r"
                case "n":
                    decoded += "\n"
                default:
                    decoded.append(character)
                }
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            decoded.append(character)
        }
        if escaped {
            decoded += "\\"
        }
        return decoded
    }
}
