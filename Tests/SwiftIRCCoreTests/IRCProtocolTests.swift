import XCTest
@testable import SwiftIRCCore

final class IRCProtocolTests: XCTestCase {
    func testParsesRFC2812Examples() throws {
        let nick = try IRCMessage.parse(line: "NICK Wiz")
        XCTAssertEqual(nick?.command, "NICK")
        XCTAssertEqual(nick?.parameters, ["Wiz"])
        XCTAssertNil(nick?.prefix)
        XCTAssertEqual(nick?.decode(), .nick("Wiz"))

        let changed = try IRCMessage.parse(line: ":WiZ!jto@tolsun.oulu.fi NICK Kilroy")
        XCTAssertEqual(
            changed?.prefix?.origin,
            .user(nick: "WiZ", username: "jto", host: "tolsun.oulu.fi")
        )
        XCTAssertEqual(changed?.decode(), .nick("Kilroy"))

        let user = try IRCMessage.parse(line: "USER guest 8 * :Ronnie Reagan")
        XCTAssertEqual(
            user?.decode(),
            .user(username: "guest", mode: "8", unused: "*", realName: "Ronnie Reagan")
        )

        let join = try IRCMessage.parse(line: "JOIN #foo,#bar fubar,foobar")
        XCTAssertEqual(
            join?.decode(),
            .join(channels: ["#foo", "#bar"], keys: ["fubar", "foobar"])
        )
        XCTAssertEqual(try IRCMessage.parse(line: "JOIN 0")?.decode(), .joinAll)

        let part = try IRCMessage.parse(line: ":WiZ!jto@tolsun.oulu.fi PART #playzone :I lost")
        XCTAssertEqual(part?.decode(), .part(channels: ["#playzone"], message: "I lost"))

        let privmsg = try IRCMessage.parse(line: ":Angel!wings@irc.org PRIVMSG Wiz :Are you receiving this message ?")
        XCTAssertEqual(
            privmsg?.decode(),
            .privmsg(target: "Wiz", text: "Are you receiving this message ?")
        )

        let welcome = try IRCMessage.parse(line: ":irc.example.net 001 Wiz :Welcome to the Internet Relay Network Wiz!guest@host")
        XCTAssertEqual(welcome?.prefix?.origin, .server("irc.example.net"))
        XCTAssertEqual(welcome?.numeric, .welcome)
        XCTAssertEqual(welcome?.numeric?.name, "RPL_WELCOME")
        XCTAssertEqual(welcome?.numeric?.wire, "001")
    }

    func testCommandFactoriesMatchTheWireFormat() throws {
        try assertWire(.pass("secretpasswordhere"), "PASS secretpasswordhere")
        try assertWire(.nick("Wiz"), "NICK Wiz")
        try assertWire(.user(username: "guest", realName: "Ronnie Reagan"), "USER guest 0 * :Ronnie Reagan")
        try assertWire(.user(username: "guest", mode: .invisible, realName: "Ronnie Reagan"), "USER guest 8 * :Ronnie Reagan")
        try assertWire(.user(username: "guest", mode: [.invisible, .wallops], realName: "Ronnie Reagan"), "USER guest 12 * :Ronnie Reagan")
        try assertWire(.oper(name: "foo", password: "bar"), "OPER foo bar")
        try assertWire(.quit(message: "Gone to have lunch"), "QUIT :Gone to have lunch")
        try assertWire(.join(channels: ["#foobar"]), "JOIN #foobar")
        try assertWire(.join(channels: ["&foo"], keys: ["fubar"]), "JOIN &foo fubar")
        try assertWire(.join(channels: ["#foo", "&bar"], keys: ["fubar"]), "JOIN #foo,&bar fubar")
        try assertWire(.join(channels: ["#foo", "#bar"], keys: ["fubar", "foobar"]), "JOIN #foo,#bar fubar,foobar")
        try assertWire(.joinAll(), "JOIN 0")
        try assertWire(.part(channels: ["#oz-ops", "&group5"]), "PART #oz-ops,&group5")
        try assertWire(.topic(channel: "#chan", topic: "hello world"), "TOPIC #chan :hello world")
        try assertWire(.topic(channel: "#chan", topic: ""), "TOPIC #chan :")
        try assertWire(.invite(nickname: "Wiz", channel: "#foo"), "INVITE Wiz #foo")
        try assertWire(.kick(channels: ["#Finnish"], users: ["John"], comment: "No reason"), "KICK #Finnish John :No reason")
        try assertWire(.privmsg(target: "#chan", text: "hello"), "PRIVMSG #chan hello")
        try assertWire(.notice(target: "Wiz", text: "hello"), "NOTICE Wiz hello")
        try assertWire(.motd(target: "irc.example.net"), "MOTD irc.example.net")
        try assertWire(.lusers(mask: "*.fi", target: "irc.example.net"), "LUSERS *.fi irc.example.net")
        try assertWire(.version(target: "irc.example.net"), "VERSION irc.example.net")
        try assertWire(.stats(query: "m", target: "irc.example.net"), "STATS m irc.example.net")
        try assertWire(.links(serverMask: "*.fi", remoteServer: "irc.example.net"), "LINKS irc.example.net *.fi")
        try assertWire(.time(), "TIME")
        try assertWire(.connect(targetServer: "tolsun.oulu.fi", port: 6667, remoteServer: "csd.bu.edu"), "CONNECT tolsun.oulu.fi 6667 csd.bu.edu")
        try assertWire(.trace(), "TRACE")
        try assertWire(.admin(), "ADMIN")
        try assertWire(.info(), "INFO")
        try assertWire(.servlist(mask: "*!irc", type: "0"), "SERVLIST *!irc 0")
        try assertWire(.squery(service: "dict@bu.edu", text: "hello"), "SQUERY dict@bu.edu hello")
        try assertWire(.who(mask: "*.fi", operatorsOnly: true), "WHO *.fi o")
        try assertWire(.whois(masks: ["Wiz", "Kilroy"], target: "irc.example.net"), "WHOIS irc.example.net Wiz,Kilroy")
        try assertWire(.whowas(nicknames: ["Wiz"], count: 10, target: "irc.example.net"), "WHOWAS Wiz 10 irc.example.net")
        try assertWire(.kill(nickname: "Wiz", comment: "Spamming"), "KILL Wiz Spamming")
        try assertWire(.ping(server: "irc.example.net", server2: "other.example.net"), "PING irc.example.net other.example.net")
        try assertWire(.pong(server: "irc.example.net"), "PONG irc.example.net")
        try assertWire(.error("Closing Link"), "ERROR :Closing Link")
        try assertWire(.away(text: "Gone"), "AWAY Gone")
        try assertWire(.away(), "AWAY")
        try assertWire(.rehash(), "REHASH")
        try assertWire(.die(), "DIE")
        try assertWire(.restart(), "RESTART")
        try assertWire(.summon(user: "jto", target: "tolsun.oulu.fi", channel: "#finnish"), "SUMMON jto tolsun.oulu.fi #finnish")
        try assertWire(.users(target: "eff.org"), "USERS eff.org")
        try assertWire(.wallops("Test"), "WALLOPS Test")
        try assertWire(.userhost(["Wiz", "Michael", "syrk"]), "USERHOST Wiz Michael syrk")
        try assertWire(.ison(["phone", "trillian", "WiZ", "jarlek"]), "ISON phone trillian WiZ jarlek")
        try assertWire(.squit(server: "tolsun.oulu.fi", comment: "Bad link"), "SQUIT tolsun.oulu.fi :Bad link")
        try assertWire(
            .service(nickname: "dict", distribution: "*.fi", type: "0", info: "Dictionary"),
            "SERVICE dict * *.fi 0 * Dictionary"
        )
        try assertWire(
            .serverPass(password: "moresecretpassword", version: "0210010000", flags: "IRC|aBgH$", options: "Z"),
            "PASS moresecretpassword 0210010000 IRC|aBgH$ Z"
        )
        try assertWire(
            .server(name: "test.oulu.fi", hopcount: 1, token: "1", info: "Experimental server"),
            "SERVER test.oulu.fi 1 1 :Experimental server"
        )
        try assertWire(
            .server(name: "tolsun.oulu.fi", hopcount: 1, info: "Experimental"),
            "SERVER tolsun.oulu.fi 1 Experimental"
        )
        try assertWire(
            .serverNick(
                nickname: "Wiz",
                hopcount: 1,
                username: "guest",
                host: "tolsun.oulu.fi",
                serverToken: "1",
                userMode: "+i",
                realName: "Ronnie Reagan"
            ),
            "NICK Wiz 1 guest tolsun.oulu.fi 1 +i :Ronnie Reagan"
        )
        let members = [
            IRCCommand.ChannelMember(nickname: "WiZ", isOperator: true),
            IRCCommand.ChannelMember(nickname: "syrk", hasVoice: true),
            IRCCommand.ChannelMember(nickname: "avalon")
        ]
        try assertWire(.njoin(channel: "#Twilight_zone", members: members), "NJOIN #Twilight_zone @WiZ,+syrk,avalon")
    }

    func testChannelModesFromRFC2812() throws {
        let moderated = try IRCCommand.channelMode(channel: "#Finnish", changes: [
            IRCModeChange(action: .enable, mode: "i"),
            IRCModeChange(action: .enable, mode: "m"),
            IRCModeChange(action: .enable, mode: "I", parameter: "*!*@*.fi")
        ])
        try assertWire(moderated, "MODE #Finnish +imI *!*@*.fi")

        try assertWire(
            .channelMode(channel: "#Finnish", changes: [IRCModeChange(action: .enable, mode: "o", parameter: "Kilroy")]),
            "MODE #Finnish +o Kilroy"
        )
        try assertWire(
            .channelMode(channel: "#42", changes: [IRCModeChange(action: .enable, mode: "k", parameter: "oulu")]),
            "MODE #42 +k oulu"
        )
        try assertWire(
            .channelMode(channel: "#42", changes: [IRCModeChange(action: .disable, mode: "k", parameter: "oulu")]),
            "MODE #42 -k oulu"
        )
        try assertWire(
            .channelMode(channel: "#eu-opers", changes: [IRCModeChange(action: .enable, mode: "l", parameter: "10")]),
            "MODE #eu-opers +l 10"
        )
        try assertWire(
            .channelMode(channel: "#eu-opers", changes: [IRCModeChange(action: .disable, mode: "l")]),
            "MODE #eu-opers -l"
        )
        try assertWire(.channelModeQuery(channel: "&oulu", mode: "b"), "MODE &oulu b")
        try assertWire(.channelModeQuery(channel: "#meditation", mode: "e"), "MODE #meditation e")
        try assertWire(.channelModeQuery(channel: "!12345ircd", mode: "O"), "MODE !12345ircd O")

        let combined = try IRCMessage.parse(line: "MODE &oulu +b *!*@*.edu +e *!*@*.bu.edu")
        guard case let .mode(target, changes) = combined?.decode() else {
            return XCTFail("expected channel mode")
        }
        XCTAssertEqual(target, "&oulu")
        XCTAssertEqual(changes, [
            IRCModeChange(action: .enable, mode: "b", parameter: "*!*@*.edu"),
            IRCModeChange(action: .enable, mode: "e", parameter: "*!*@*.bu.edu")
        ])

        let listed = try IRCMessage.parse(line: "MODE &oulu +b")
        XCTAssertEqual(
            listed?.decode(),
            .mode(target: "&oulu", changes: [IRCModeChange(action: .enable, mode: "b")])
        )
    }

    func testUserModesRejectAwayFlag() throws {
        XCTAssertThrowsError(
            try IRCCommand.userMode(
                nickname: "Wiz",
                changes: [IRCModeChange(action: .enable, mode: "a")]
            )
        ) { error in
            XCTAssertEqual(error as? IRCError, .awayModeIsNotSettable)
        }
        try assertWire(
            .userMode(nickname: "Wiz", changes: [
                IRCModeChange(action: .enable, mode: "i"),
                IRCModeChange(action: .enable, mode: "w")
            ]),
            "MODE Wiz +iw"
        )
    }

    func testModeParameterLimit() {
        let changes = (0 ..< 4).map { IRCModeChange(action: .enable, mode: "o", parameter: "n\($0)") }
        XCTAssertThrowsError(try IRCCommand.channelMode(channel: "#chan", changes: changes)) { error in
            XCTAssertEqual(error as? IRCError, .tooManyModeParameters)
        }
    }

    func testNamesAndRegistrationOrder() throws {
        let commands = try IRCRegistration.commands(
            password: "secret",
            nickname: "Wiz",
            username: "guest",
            realName: "Ronnie Reagan",
            mode: .invisible
        )
        XCTAssertEqual(commands.map { $0.name }, ["PASS", "NICK", "USER"])
        let lines = try commands.map { try IRCMessage(command: $0).serializedString() }
        XCTAssertEqual(lines, [
            "PASS secret\r\n",
            "NICK Wiz\r\n",
            "USER guest 8 * :Ronnie Reagan\r\n"
        ])
    }

    func testEmptyMessagesAreIgnoredAndCommandsAreCaseInsensitive() throws {
        XCTAssertNil(try IRCMessage.parse(line: ""))
        XCTAssertNil(try IRCMessage.parse(line: "\r\n"))
        var framer = IRCFramer()
        let messages = try framer.append(Array("\r\nNICK Wiz\r\n\r\nnick Kilroy\r\n".utf8))
        XCTAssertEqual(messages.map { $0.command }, ["NICK", "NICK"])
        XCTAssertEqual(messages.map { $0.parameters }, [["Wiz"], ["Kilroy"]])
    }

    func testRejectsNulAndOverlongMessages() throws {
        XCTAssertThrowsError(try IRCMessage.parse(octets: [0x4E, 0x49, 0x43, 0x4B, 0x00])) { error in
            XCTAssertEqual(error as? IRCError, .nulOctet)
        }
        var text = ""
        var fitting = ""
        while true {
            text.append("x")
            let message = try IRCMessage(command: .privmsg(target: "#a", text: text))
            let count = try message.serialized().count
            if count == IRC.maximumMessageLength {
                fitting = text
                break
            }
            if count > IRC.maximumMessageLength {
                return XCTFail("skipped the 512-octet boundary at \(count)")
            }
        }
        let exact = try IRCMessage(command: .privmsg(target: "#a", text: fitting))
        XCTAssertEqual(try exact.serialized().count, IRC.maximumMessageLength)
        XCTAssertNotNil(try IRCMessage.parse(octets: exact.serialized()))
        XCTAssertThrowsError(try IRCMessage(command: .privmsg(target: "#a", text: fitting + "x")).serialized()) { error in
            guard case IRCError.messageTooLong = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testFifteenthParameterAbsorbsTheRemainder() throws {
        var words = ["CMD"]
        for index in 1 ... 16 {
            words.append("p\(index)")
        }
        let message = try IRCMessage.parse(line: words.joined(separator: " "))
        XCTAssertEqual(message?.parameters.count, 15)
        XCTAssertEqual(message?.parameters.last, "p15 p16")
        XCTAssertThrowsError(try IRCCommand(name: "CMD", parameters: Array(repeating: "p", count: 16)))
    }

    func testNamingRulesAndCaseMapping() throws {
        XCTAssertTrue(IRCCaseMapping.equals("Foo[]\\~", "foo{}|^"))
        XCTAssertFalse(IRCCaseMapping.equals("a", "b"))
        try IRCNickname.validate("Wiz")
        try IRCNickname.validate("{nick")
        XCTAssertThrowsError(try IRCNickname.validate("-wiz"))
        XCTAssertThrowsError(try IRCNickname.validate("abcdefghij"))
        try IRCChannelName.validate("#finnish")
        try IRCChannelName.validate("&local")
        try IRCChannelName.validate("+modeless")
        try IRCChannelName.validate("!12345ircd")
        try IRCChannelName.validate("#chan:*.fi")
        XCTAssertThrowsError(try IRCChannelName.validate("!abcdeircd"))
        XCTAssertThrowsError(try IRCChannelName.validate("#has space"))
        XCTAssertThrowsError(try IRCChannelName.validate("#bell\u{0007}"))
        XCTAssertThrowsError(try IRCChannelName.validate(String(repeating: "a", count: 51)))
        try IRCChannelKey.validate("oulu")
        XCTAssertThrowsError(try IRCChannelKey.validate(String(repeating: "k", count: 24)))
        XCTAssertThrowsError(try IRCUsername.validate("guest user"))
        XCTAssertThrowsError(try IRCHostname.validate(String(repeating: "h", count: 64)))
        XCTAssertEqual(IRC.cleartextPort, 6667)
        XCTAssertEqual(IRC.tlsPort, 6697)
    }

    func testEveryNumericRoundTrips() {
        XCTAssertGreaterThanOrEqual(IRCNumeric.allKnown.count, 120)
        for numeric in IRCNumeric.allKnown {
            XCTAssertEqual(IRCNumeric(name: numeric.name)?.code, numeric.code)
            XCTAssertEqual(numeric.wire.count, 3)
            XCTAssertEqual(IRCNumeric(code: numeric.code).name, numeric.name)
        }
        XCTAssertEqual(IRCNumeric(name: "RPL_STATSSLINE")?.code, 244)
        XCTAssertEqual(IRCNumeric.bounce.code, 5)
        XCTAssertTrue(IRCNumeric.nicknameInUse.isError)
        XCTAssertTrue(IRCNumeric.welcome.isConnectionRegistration)
        XCTAssertTrue(IRCNumeric.whoReply.isCommandReply)
        XCTAssertNil(IRCNumeric(name: "NOT_A_REAL_NUMERIC"))
        XCTAssertEqual(IRCNumeric(code: 999).name, "UNKNOWN")
    }

    func testNJOINStatuses() throws {
        let message = try IRCMessage.parse(line: ":ircd.stealth.net NJOIN #Twilight_zone :@@WiZ,@+syrk,+avalon,plain")
        guard case let .njoin(channel, members) = message?.decode() else {
            return XCTFail("expected NJOIN")
        }
        XCTAssertEqual(channel, "#Twilight_zone")
        XCTAssertEqual(members, [
            IRCCommand.ChannelMember(nickname: "WiZ", isCreator: true),
            IRCCommand.ChannelMember(nickname: "syrk", isOperator: true, hasVoice: true),
            IRCCommand.ChannelMember(nickname: "avalon", hasVoice: true),
            IRCCommand.ChannelMember(nickname: "plain")
        ])
    }

    private func assertWire(_ command: IRCCommand, _ expected: String, file: StaticString = #file, line: UInt = #line) throws {
        let message = try IRCMessage(command: command)
        XCTAssertEqual(try message.serializedString(), expected + "\r\n", file: file, line: line)
        let parsed = try IRCMessage.parse(line: expected)
        XCTAssertEqual(parsed?.command, message.command, file: file, line: line)
        XCTAssertEqual(parsed?.parameters, message.parameters, file: file, line: line)
    }
}
