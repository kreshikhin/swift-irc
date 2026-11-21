# SwiftIRC

[![Swift 5.3](https://img.shields.io/badge/Swift-5.3+-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Swift Package Manager](https://img.shields.io/badge/Swift_Package_Manager-compatible-F05138?logo=swift&logoColor=white)](https://swift.org/package-manager/)
[![Platforms](https://img.shields.io/badge/platform-macOS-lightgrey)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

IRC client and server library for Swift.

Includes a message parser, encoder, typed IRC commands, TCP/TLS client, and a basic IRC server.

## Installation

```swift
// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "Example",
    dependencies: [
        .package(url: "https://github.com/kreshikhin/swift-irc.git", from: "0.1.0")
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

## Modules

| Product | Role |
|---|---|
| `SwiftIRCCore` | Parsing, serialization, and typed commands |
| `SwiftIRCClient` | TCP and TLS client |
| `SwiftIRCServer` | Single-process IRC server |

## Usage

### Messages

`SwiftIRCCore` provides IRC message parsing, serialization, and typed commands.

```swift
import SwiftIRCCore

let parsed = try IRCMessage.parse(line: ":Wiz PRIVMSG #swift :hello")
print(parsed?.decode() as Any)

let command = try IRCCommand.privmsg(target: "#swift", text: "hello")
let line = try IRCMessage(command: command).serializedString()
```

`IRCCommand` provides typed commands based on [RFC 1459](https://www.rfc-editor.org/rfc/rfc1459), [RFC 2812](https://www.rfc-editor.org/rfc/rfc2812), and [RFC 2813](https://www.rfc-editor.org/rfc/rfc2813).

### Client

Cleartext uses port 6667. `useTLS: true` uses port 6697. Replace `irc.example.net` with your server.

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

### Server

```swift
import SwiftIRCServer

let server = IRCServer(name: "irc.example.net")
try server.start()
defer { server.stop() }
```

`IRCServer` is one process and does not link to other servers. `port: 0` selects a free port, available as `server.port` after `start()`.

## Specifications

Client messages follow [RFC 1459](https://www.rfc-editor.org/rfc/rfc1459) and [RFC 2812](https://www.rfc-editor.org/rfc/rfc2812). Channel modes follow [RFC 2811](https://www.rfc-editor.org/rfc/rfc2811). The TLS port follows [RFC 7194](https://www.rfc-editor.org/rfc/rfc7194).

Copies of the source documents are in `docs/`:

- [`docs/rfc`](docs/rfc) — [RFC 1459](https://www.rfc-editor.org/rfc/rfc1459), [2810](https://www.rfc-editor.org/rfc/rfc2810), [2811](https://www.rfc-editor.org/rfc/rfc2811), [2812](https://www.rfc-editor.org/rfc/rfc2812), [2813](https://www.rfc-editor.org/rfc/rfc2813), and [7194](https://www.rfc-editor.org/rfc/rfc7194)
- [`docs/ircv3`](docs/ircv3) — [IRCv3](https://ircv3.net/irc/)
- [`docs/irc-client-protocol`](docs/irc-client-protocol) — [Modern IRC client protocol](https://modern.ircdocs.horse/)

## Testing

```sh
swift test
```

## License

This package is [MIT](LICENSE).

The documents under `docs/` keep their own licenses: [`docs/rfc/LICENSE`](docs/rfc/LICENSE), [`docs/ircv3/LICENSE`](docs/ircv3/LICENSE), and [`docs/irc-client-protocol/LICENSE`](docs/irc-client-protocol/LICENSE).
