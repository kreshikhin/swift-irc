import Foundation

/// Numeric replies from RFC 1459 section 6 and RFC 2812 section 5.
///
/// Code 005 is `RPL_BOUNCE`, as assigned by RFC 2812. Later networks reused
/// 005 for `RPL_ISUPPORT`; that assignment is not part of these RFCs.
public struct IRCNumeric: Equatable, Hashable {
    public let code: Int

    public init(code: Int) {
        self.code = code
    }

    public init?(name: String) {
        let key = name.uppercased()
        if let code = IRCNumeric.aliases[key] {
            self.code = code
            return
        }
        guard let code = IRCNumeric.byName[key] else {
            return nil
        }
        self.code = code
    }

    public var name: String {
        IRCNumeric.byCode[code] ?? "UNKNOWN"
    }

    public var isError: Bool {
        (400 ... 599).contains(code)
    }

    /// Connection registration replies. RFC 2812 section 5.1.
    public var isConnectionRegistration: Bool {
        (1 ... 99).contains(code)
    }

    /// Command replies. RFC 2812 section 5.1.
    public var isCommandReply: Bool {
        (200 ... 399).contains(code)
    }

    public var wire: String {
        String(format: "%03d", code)
    }

    public static let welcome = IRCNumeric(code: 1)
    public static let yourHost = IRCNumeric(code: 2)
    public static let created = IRCNumeric(code: 3)
    public static let myInfo = IRCNumeric(code: 4)
    public static let bounce = IRCNumeric(code: 5)
    public static let traceLink = IRCNumeric(code: 200)
    public static let traceConnecting = IRCNumeric(code: 201)
    public static let traceHandshake = IRCNumeric(code: 202)
    public static let traceUnknown = IRCNumeric(code: 203)
    public static let traceOperator = IRCNumeric(code: 204)
    public static let traceUser = IRCNumeric(code: 205)
    public static let traceServer = IRCNumeric(code: 206)
    public static let traceService = IRCNumeric(code: 207)
    public static let traceNewType = IRCNumeric(code: 208)
    public static let traceClass = IRCNumeric(code: 209)
    public static let traceReconnect = IRCNumeric(code: 210)
    public static let statsLinkInfo = IRCNumeric(code: 211)
    public static let statsCommands = IRCNumeric(code: 212)
    public static let statsCLine = IRCNumeric(code: 213)
    public static let statsNLine = IRCNumeric(code: 214)
    public static let statsILine = IRCNumeric(code: 215)
    public static let statsKLine = IRCNumeric(code: 216)
    public static let statsQLine = IRCNumeric(code: 217)
    public static let statsYLine = IRCNumeric(code: 218)
    public static let endOfStats = IRCNumeric(code: 219)
    public static let uModeIs = IRCNumeric(code: 221)
    public static let serviceInfo = IRCNumeric(code: 231)
    public static let endOfServices = IRCNumeric(code: 232)
    public static let service = IRCNumeric(code: 233)
    public static let servList = IRCNumeric(code: 234)
    public static let servListEnd = IRCNumeric(code: 235)
    public static let statsVLine = IRCNumeric(code: 240)
    public static let statsLLine = IRCNumeric(code: 241)
    public static let statsUptime = IRCNumeric(code: 242)
    public static let statsOLine = IRCNumeric(code: 243)
    public static let statsHLine = IRCNumeric(code: 244)
    public static let statsPing = IRCNumeric(code: 246)
    public static let statsBLine = IRCNumeric(code: 247)
    public static let statsDLine = IRCNumeric(code: 250)
    public static let luserClient = IRCNumeric(code: 251)
    public static let luserOp = IRCNumeric(code: 252)
    public static let luserUnknown = IRCNumeric(code: 253)
    public static let luserChannels = IRCNumeric(code: 254)
    public static let luserMe = IRCNumeric(code: 255)
    public static let adminMe = IRCNumeric(code: 256)
    public static let adminLoc1 = IRCNumeric(code: 257)
    public static let adminLoc2 = IRCNumeric(code: 258)
    public static let adminEmail = IRCNumeric(code: 259)
    public static let traceLog = IRCNumeric(code: 261)
    public static let traceEnd = IRCNumeric(code: 262)
    public static let tryAgain = IRCNumeric(code: 263)
    public static let none = IRCNumeric(code: 300)
    public static let away = IRCNumeric(code: 301)
    public static let userHost = IRCNumeric(code: 302)
    public static let isOn = IRCNumeric(code: 303)
    public static let unAway = IRCNumeric(code: 305)
    public static let nowAway = IRCNumeric(code: 306)
    public static let whoisUser = IRCNumeric(code: 311)
    public static let whoisServer = IRCNumeric(code: 312)
    public static let whoisOperator = IRCNumeric(code: 313)
    public static let whowasUser = IRCNumeric(code: 314)
    public static let endOfWho = IRCNumeric(code: 315)
    public static let whoisChanOp = IRCNumeric(code: 316)
    public static let whoisIdle = IRCNumeric(code: 317)
    public static let endOfWhois = IRCNumeric(code: 318)
    public static let whoisChannels = IRCNumeric(code: 319)
    public static let listStart = IRCNumeric(code: 321)
    public static let list = IRCNumeric(code: 322)
    public static let listEnd = IRCNumeric(code: 323)
    public static let channelModeIs = IRCNumeric(code: 324)
    public static let uniqOpIs = IRCNumeric(code: 325)
    public static let noTopic = IRCNumeric(code: 331)
    public static let topic = IRCNumeric(code: 332)
    public static let inviting = IRCNumeric(code: 341)
    public static let summoning = IRCNumeric(code: 342)
    public static let inviteList = IRCNumeric(code: 346)
    public static let endOfInviteList = IRCNumeric(code: 347)
    public static let exceptList = IRCNumeric(code: 348)
    public static let endOfExceptList = IRCNumeric(code: 349)
    public static let version = IRCNumeric(code: 351)
    public static let whoReply = IRCNumeric(code: 352)
    public static let nameReply = IRCNumeric(code: 353)
    public static let killDone = IRCNumeric(code: 361)
    public static let closing = IRCNumeric(code: 362)
    public static let closeEnd = IRCNumeric(code: 363)
    public static let links = IRCNumeric(code: 364)
    public static let endOfLinks = IRCNumeric(code: 365)
    public static let endOfNames = IRCNumeric(code: 366)
    public static let banList = IRCNumeric(code: 367)
    public static let endOfBanList = IRCNumeric(code: 368)
    public static let endOfWhowas = IRCNumeric(code: 369)
    public static let info = IRCNumeric(code: 371)
    public static let motd = IRCNumeric(code: 372)
    public static let infoStart = IRCNumeric(code: 373)
    public static let endOfInfo = IRCNumeric(code: 374)
    public static let motdStart = IRCNumeric(code: 375)
    public static let endOfMotd = IRCNumeric(code: 376)
    public static let youreOper = IRCNumeric(code: 381)
    public static let rehashing = IRCNumeric(code: 382)
    public static let youreService = IRCNumeric(code: 383)
    public static let myPortIs = IRCNumeric(code: 384)
    public static let time = IRCNumeric(code: 391)
    public static let usersStart = IRCNumeric(code: 392)
    public static let users = IRCNumeric(code: 393)
    public static let endOfUsers = IRCNumeric(code: 394)
    public static let noUsers = IRCNumeric(code: 395)
    public static let noSuchNick = IRCNumeric(code: 401)
    public static let noSuchServer = IRCNumeric(code: 402)
    public static let noSuchChannel = IRCNumeric(code: 403)
    public static let cannotSendToChan = IRCNumeric(code: 404)
    public static let tooManyChannels = IRCNumeric(code: 405)
    public static let wasNoSuchNick = IRCNumeric(code: 406)
    public static let tooManyTargets = IRCNumeric(code: 407)
    public static let noSuchService = IRCNumeric(code: 408)
    public static let noOrigin = IRCNumeric(code: 409)
    public static let noRecipient = IRCNumeric(code: 411)
    public static let noTextToSend = IRCNumeric(code: 412)
    public static let noTopLevel = IRCNumeric(code: 413)
    public static let wildTopLevel = IRCNumeric(code: 414)
    public static let badMask = IRCNumeric(code: 415)
    public static let unknownCommand = IRCNumeric(code: 421)
    public static let noMotd = IRCNumeric(code: 422)
    public static let noAdminInfo = IRCNumeric(code: 423)
    public static let fileError = IRCNumeric(code: 424)
    public static let noNicknameGiven = IRCNumeric(code: 431)
    public static let erroneusNickname = IRCNumeric(code: 432)
    public static let nicknameInUse = IRCNumeric(code: 433)
    public static let nickCollision = IRCNumeric(code: 436)
    public static let unavailResource = IRCNumeric(code: 437)
    public static let userNotInChannel = IRCNumeric(code: 441)
    public static let notOnChannel = IRCNumeric(code: 442)
    public static let userOnChannel = IRCNumeric(code: 443)
    public static let noLogin = IRCNumeric(code: 444)
    public static let summonDisabled = IRCNumeric(code: 445)
    public static let usersDisabled = IRCNumeric(code: 446)
    public static let notRegistered = IRCNumeric(code: 451)
    public static let needMoreParams = IRCNumeric(code: 461)
    public static let alreadyRegistered = IRCNumeric(code: 462)
    public static let noPermForHost = IRCNumeric(code: 463)
    public static let passwordMismatch = IRCNumeric(code: 464)
    public static let youreBannedCreep = IRCNumeric(code: 465)
    public static let youWillBeBanned = IRCNumeric(code: 466)
    public static let keySet = IRCNumeric(code: 467)
    public static let channelIsFull = IRCNumeric(code: 471)
    public static let unknownMode = IRCNumeric(code: 472)
    public static let inviteOnlyChan = IRCNumeric(code: 473)
    public static let bannedFromChan = IRCNumeric(code: 474)
    public static let badChannelKey = IRCNumeric(code: 475)
    public static let badChanMask = IRCNumeric(code: 476)
    public static let noChanModes = IRCNumeric(code: 477)
    public static let banListFull = IRCNumeric(code: 478)
    public static let noPrivileges = IRCNumeric(code: 481)
    public static let chanOpPrivsNeeded = IRCNumeric(code: 482)
    public static let cantKillServer = IRCNumeric(code: 483)
    public static let restricted = IRCNumeric(code: 484)
    public static let uniqOpPrivsNeeded = IRCNumeric(code: 485)
    public static let noOperHost = IRCNumeric(code: 491)
    public static let noServiceHost = IRCNumeric(code: 492)
    public static let uModeUnknownFlag = IRCNumeric(code: 501)
    public static let usersDontMatch = IRCNumeric(code: 502)

    public static let allKnown: [IRCNumeric] = entries.map { IRCNumeric(code: $0.0) }

    private static let entries: [(Int, String)] = [
        (1, "RPL_WELCOME"), (2, "RPL_YOURHOST"), (3, "RPL_CREATED"), (4, "RPL_MYINFO"),
        (5, "RPL_BOUNCE"),
        (200, "RPL_TRACELINK"), (201, "RPL_TRACECONNECTING"), (202, "RPL_TRACEHANDSHAKE"),
        (203, "RPL_TRACEUNKNOWN"), (204, "RPL_TRACEOPERATOR"), (205, "RPL_TRACEUSER"),
        (206, "RPL_TRACESERVER"), (207, "RPL_TRACESERVICE"), (208, "RPL_TRACENEWTYPE"),
        (209, "RPL_TRACECLASS"), (210, "RPL_TRACERECONNECT"),
        (211, "RPL_STATSLINKINFO"), (212, "RPL_STATSCOMMANDS"), (213, "RPL_STATSCLINE"),
        (214, "RPL_STATSNLINE"), (215, "RPL_STATSILINE"), (216, "RPL_STATSKLINE"),
        (217, "RPL_STATSQLINE"), (218, "RPL_STATSYLINE"), (219, "RPL_ENDOFSTATS"),
        (221, "RPL_UMODEIS"),
        (231, "RPL_SERVICEINFO"), (232, "RPL_ENDOFSERVICES"), (233, "RPL_SERVICE"),
        (234, "RPL_SERVLIST"), (235, "RPL_SERVLISTEND"),
        (240, "RPL_STATSVLINE"), (241, "RPL_STATSLLINE"), (242, "RPL_STATSUPTIME"),
        (243, "RPL_STATSOLINE"), (244, "RPL_STATSHLINE"), (246, "RPL_STATSPING"),
        (247, "RPL_STATSBLINE"), (250, "RPL_STATSDLINE"),
        (251, "RPL_LUSERCLIENT"), (252, "RPL_LUSEROP"), (253, "RPL_LUSERUNKNOWN"),
        (254, "RPL_LUSERCHANNELS"), (255, "RPL_LUSERME"),
        (256, "RPL_ADMINME"), (257, "RPL_ADMINLOC1"), (258, "RPL_ADMINLOC2"), (259, "RPL_ADMINEMAIL"),
        (261, "RPL_TRACELOG"), (262, "RPL_TRACEEND"), (263, "RPL_TRYAGAIN"),
        (300, "RPL_NONE"), (301, "RPL_AWAY"), (302, "RPL_USERHOST"), (303, "RPL_ISON"),
        (305, "RPL_UNAWAY"), (306, "RPL_NOWAWAY"),
        (311, "RPL_WHOISUSER"), (312, "RPL_WHOISSERVER"), (313, "RPL_WHOISOPERATOR"),
        (314, "RPL_WHOWASUSER"), (315, "RPL_ENDOFWHO"), (316, "RPL_WHOISCHANOP"),
        (317, "RPL_WHOISIDLE"), (318, "RPL_ENDOFWHOIS"), (319, "RPL_WHOISCHANNELS"),
        (321, "RPL_LISTSTART"), (322, "RPL_LIST"), (323, "RPL_LISTEND"),
        (324, "RPL_CHANNELMODEIS"), (325, "RPL_UNIQOPIS"),
        (331, "RPL_NOTOPIC"), (332, "RPL_TOPIC"),
        (341, "RPL_INVITING"), (342, "RPL_SUMMONING"),
        (346, "RPL_INVITELIST"), (347, "RPL_ENDOFINVITELIST"),
        (348, "RPL_EXCEPTLIST"), (349, "RPL_ENDOFEXCEPTLIST"),
        (351, "RPL_VERSION"), (352, "RPL_WHOREPLY"), (353, "RPL_NAMREPLY"),
        (361, "RPL_KILLDONE"), (362, "RPL_CLOSING"), (363, "RPL_CLOSEEND"),
        (364, "RPL_LINKS"), (365, "RPL_ENDOFLINKS"), (366, "RPL_ENDOFNAMES"),
        (367, "RPL_BANLIST"), (368, "RPL_ENDOFBANLIST"), (369, "RPL_ENDOFWHOWAS"),
        (371, "RPL_INFO"), (372, "RPL_MOTD"), (373, "RPL_INFOSTART"), (374, "RPL_ENDOFINFO"),
        (375, "RPL_MOTDSTART"), (376, "RPL_ENDOFMOTD"),
        (381, "RPL_YOUREOPER"), (382, "RPL_REHASHING"), (383, "RPL_YOURESERVICE"),
        (384, "RPL_MYPORTIS"), (391, "RPL_TIME"),
        (392, "RPL_USERSSTART"), (393, "RPL_USERS"), (394, "RPL_ENDOFUSERS"), (395, "RPL_NOUSERS"),
        (401, "ERR_NOSUCHNICK"), (402, "ERR_NOSUCHSERVER"), (403, "ERR_NOSUCHCHANNEL"),
        (404, "ERR_CANNOTSENDTOCHAN"), (405, "ERR_TOOMANYCHANNELS"), (406, "ERR_WASNOSUCHNICK"),
        (407, "ERR_TOOMANYTARGETS"), (408, "ERR_NOSUCHSERVICE"), (409, "ERR_NOORIGIN"),
        (411, "ERR_NORECIPIENT"), (412, "ERR_NOTEXTTOSEND"), (413, "ERR_NOTOPLEVEL"),
        (414, "ERR_WILDTOPLEVEL"), (415, "ERR_BADMASK"),
        (421, "ERR_UNKNOWNCOMMAND"), (422, "ERR_NOMOTD"), (423, "ERR_NOADMININFO"),
        (424, "ERR_FILEERROR"),
        (431, "ERR_NONICKNAMEGIVEN"), (432, "ERR_ERRONEUSNICKNAME"), (433, "ERR_NICKNAMEINUSE"),
        (436, "ERR_NICKCOLLISION"), (437, "ERR_UNAVAILRESOURCE"),
        (441, "ERR_USERNOTINCHANNEL"), (442, "ERR_NOTONCHANNEL"), (443, "ERR_USERONCHANNEL"),
        (444, "ERR_NOLOGIN"), (445, "ERR_SUMMONDISABLED"), (446, "ERR_USERSDISABLED"),
        (451, "ERR_NOTREGISTERED"),
        (461, "ERR_NEEDMOREPARAMS"), (462, "ERR_ALREADYREGISTRED"), (463, "ERR_NOPERMFORHOST"),
        (464, "ERR_PASSWDMISMATCH"), (465, "ERR_YOUREBANNEDCREEP"), (466, "ERR_YOUWILLBEBANNED"),
        (467, "ERR_KEYSET"),
        (471, "ERR_CHANNELISFULL"), (472, "ERR_UNKNOWNMODE"), (473, "ERR_INVITEONLYCHAN"),
        (474, "ERR_BANNEDFROMCHAN"), (475, "ERR_BADCHANNELKEY"), (476, "ERR_BADCHANMASK"),
        (477, "ERR_NOCHANMODES"), (478, "ERR_BANLISTFULL"),
        (481, "ERR_NOPRIVILEGES"), (482, "ERR_CHANOPRIVSNEEDED"), (483, "ERR_CANTKILLSERVER"),
        (484, "ERR_RESTRICTED"), (485, "ERR_UNIQOPPRIVSNEEDED"),
        (491, "ERR_NOOPERHOST"), (492, "ERR_NOSERVICEHOST"),
        (501, "ERR_UMODEUNKNOWNFLAG"), (502, "ERR_USERSDONTMATCH")
    ]

    /// RFC 2812 lists both names for 244 in the reserved section.
    private static let aliases: [String: Int] = [
        "RPL_STATSSLINE": 244
    ]

    private static let byCode: [Int: String] = {
        var map: [Int: String] = [:]
        for entry in entries {
            map[entry.0] = entry.1
        }
        return map
    }()

    private static let byName: [String: Int] = {
        var map: [String: Int] = [:]
        for entry in entries {
            map[entry.1] = entry.0
        }
        return map
    }()
}
