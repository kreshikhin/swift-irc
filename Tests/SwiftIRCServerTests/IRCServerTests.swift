import Foundation
import XCTest
@testable import SwiftIRCClient
@testable import SwiftIRCCore
@testable import SwiftIRCServer

final class IRCServerTests: XCTestCase {
    func testChannelTracksMembershipAndTopicLock() {
        let channel = IRCChannel(name: "#Swift")
        XCTAssertTrue(channel.noExternalMessages)
        XCTAssertTrue(channel.topicLocked)
        channel.add(nickname: "Wiz", membership: IRCMembership(isOperator: true))
        channel.add(nickname: "Kilroy", membership: IRCMembership(hasVoice: true))
        XCTAssertEqual(channel.membership(for: "wiz")?.isOperator, true)
        XCTAssertEqual(channel.membership(for: "Kilroy")?.namesPrefix, "+")
        channel.rename(from: "Kilroy", to: "Kit")
        XCTAssertNil(channel.membership(for: "Kilroy"))
        XCTAssertEqual(channel.membership(for: "Kit")?.hasVoice, true)
        channel.remove(nickname: "Wiz")
        XCTAssertNil(channel.membership(for: "Wiz"))
    }
}
