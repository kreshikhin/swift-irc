# SwiftIRC

Swift package for the IRC client protocol. It parses and serializes messages, connects as a client, and runs a single local server.

The library targets Swift 5.3. The client and server use BSD sockets and [Network](https://developer.apple.com/documentation/network), so they build on Apple platforms.

## Package

```swift
// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "Example",
    dependencies: [
        .package(url: "https://github.com/kreshikhin/swift-irc.git", .branch("main"))
    ],
    targets: [
        .target(
            name: "Example",
            dependencies: [
                .product(name: "SwiftIRCClient", package: "swift-irc")
            ]
        )
    ]
)
```

Three products share no extra dependencies:

| Product | Role |
|---|---|
| `SwiftIRCCore` | Messages, commands, parser, encoder, IRCv3 tags |
| `SwiftIRCClient` | TCP and TLS connection, registration, send and receive |
| `SwiftIRCServer` | One local server: users, channels, and the client commands it implements |

`SwiftIRCClient` and `SwiftIRCServer` depend on `SwiftIRCCore`.

## Messages

`SwiftIRCCore` reads a line into `IRCMessage` and writes it back with the trailing CR-LF. The command is stored in uppercase. A trailing parameter is prefixed with `:` only when it is empty, contains a space, or starts with `:`.

```swift
import SwiftIRCCore

let parsed = try IRCMessage.parse(line: ":Wiz PRIVMSG #swift :hello")
print(parsed?.decode() as Any)

let command = try IRCCommand.privmsg(target: "#swift", text: "hello")
let line = try IRCMessage(command: command).serializedString()
```

`IRCCommand` builds the client commands from RFC 1459 and RFC 2812, plus the server forms whose shape differs in RFC 2813 (`SERVER`, `NJOIN`, server `PASS` and `NICK`). `IRCMessage.decode()` turns a message back into `IRCDecodedCommand`. Nicknames, channels, keys, and RFC 1459 casemapping are checked before a command is built.

IRCv3 tags sit on `IRCMessage.tags`. An empty tag list is left off the wire. Values escape space, `;`, `\`, CR, and LF.

## Client

The default cleartext port is 6667. `useTLS: true` uses port 6697.

```swift
import SwiftIRCClient

let client = IRCClient(host: "irc.example.net")
try client.connect()
defer { client.close() }

let welcome = try client.register(
    nickname: "Wiz",
    username: "guest",
    realName: "Ronnie Reagan",
    mode: .invisible
)
print(welcome.first?.numeric?.name ?? "")

try client.send(.join(channels: ["#swift"]))
try client.send(.privmsg(target: "#swift", text: "hello"))

while let message = try client.receive() {
    print(message.command, message.parameters)
}
```

`PASS`, when present, is sent before `NICK` and `USER`. A `PASS` after `NICK`, `USER`, or `SERVICE` throws `IRCError.passwordSentTooLate`. During registration a `PING` is answered with `PONG`. Registration finishes at `RPL_WELCOME` (001). An `ERROR` or any 4xx numeric fails it.

`IRCClient.connection` is the socket. `IRCClient.session` keeps the nickname and registration state.

## Server

`IRCServer` listens on one host, accepts clients, and answers the registration and channel commands it implements. `port: 0` asks the system for a free port. `server.port` is that port after `start()`.

```swift
import SwiftIRCServer

let server = IRCServer(name: "irc.example.net")
try server.start()
defer { server.stop() }
```

A registered client can `JOIN`, `PART`, `PRIVMSG`, `NOTICE`, `TOPIC`, `NAMES`, `MODE`, `WHOIS`, `USERHOST`, `ISON`, `AWAY`, and the registration and query commands the server handles. Anything else gets `ERR_UNKNOWNCOMMAND`. This is one server process, not a server-to-server network.

## Layout

```
Sources/
├── SwiftIRCCore/
│   ├── IRCMessage.swift
│   ├── IRCCommand.swift
│   ├── IRCParser.swift
│   ├── IRCEncoder.swift
│   └── IRCTags.swift
├── SwiftIRCClient/
│   ├── IRCClient.swift
│   ├── IRCConnection.swift
│   └── IRCClientSession.swift
└── SwiftIRCServer/
    ├── IRCServer.swift
    ├── IRCServerSession.swift
    ├── IRCChannel.swift
    └── IRCUser.swift
```

## Specifications

The codec follows the client protocol in RFC 1459 and RFC 2812, channel modes in RFC 2811, and the TLS port in RFC 7194. Numeric 005 is `RPL_BOUNCE`, as assigned by RFC 2812.

Copies of the source documents live under `docs/`:

- `docs/rfc` — RFC 1459, 2810, 2811, 2812, 2813, and 7194
- `docs/ircv3` — IRCv3 specifications
- `docs/irc-client-protocol` — Modern IRC client protocol

Those copies keep the license that came with each document. See `docs/rfc/LICENSE`, `docs/ircv3/LICENSE`, and `docs/irc-client-protocol/LICENSE`. The root `LICENSE` is MIT and covers this package, not those documents.

## Tests

```sh
swift test
```
