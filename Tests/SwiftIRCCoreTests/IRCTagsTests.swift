import XCTest
@testable import SwiftIRCCore

final class IRCTagsTests: XCTestCase {
    func testTagsRoundTripWithEscapes() throws {
        let line = "@msgid=abc\\sdef;+draft/label PRIVMSG #chan :hello world"
        let message = try IRCMessage.parse(line: line)
        XCTAssertEqual(message?.tags.entries, [
            IRCTag(key: "msgid", value: "abc def"),
            IRCTag(key: "+draft/label")
        ])
        XCTAssertEqual(message?.command, "PRIVMSG")
        XCTAssertEqual(message?.parameters, ["#chan", "hello world"])
        XCTAssertEqual(try message?.serializedString(), line + "\r\n")
    }

    func testMissingAndEmptyTagValuesDiffer() throws {
        let tags = try IRCTags.parse("flag;empty=")
        XCTAssertEqual(tags.entries, [
            IRCTag(key: "flag", value: nil),
            IRCTag(key: "empty", value: "")
        ])
        XCTAssertEqual(tags.encoded(), "flag;empty=")
    }

    func testUntaggedMessagesStayUntagged() throws {
        let message = try IRCMessage.parse(line: "NICK Wiz")
        XCTAssertEqual(message?.tags.entries, [])
        XCTAssertEqual(try message?.serializedString(), "NICK Wiz\r\n")
    }
}
