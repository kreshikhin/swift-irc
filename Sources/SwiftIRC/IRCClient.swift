import Darwin
import Foundation
import Network

/// A client connection speaking the IRC client protocol. RFC 2812.
///
/// Cleartext connections use TCP. `useTLS` uses Network.framework and the
/// default port from RFC 7194.
public final class IRCClient {
    public let host: String
    public let port: UInt16
    public let useTLS: Bool
    public private(set) var nickname: String
    public private(set) var isRegistered: Bool

    private let queue = DispatchQueue(label: "swiftirc.client")
    private let condition = NSCondition()
    private var connection: NWConnection?
    private var socketFD: Int32 = -1
    private var framer = IRCFramer()
    private var pending: [IRCMessage] = []
    private var endOfStream = false
    private var failure: IRCError?
    private var sentRegistrationIdentity = false
    private var started = false

    public init(host: String, port: UInt16? = nil, useTLS: Bool = false) {
        self.host = host
        self.useTLS = useTLS
        self.port = port ?? (useTLS ? IRC.tlsPort : IRC.cleartextPort)
        nickname = ""
        isRegistered = false
    }

    deinit {
        close()
    }

    public func connect(timeout: TimeInterval = 30) throws {
        guard !started else {
            throw IRCError.connectionFailed("already connected")
        }
        if useTLS {
            try connectTLS(timeout: timeout)
        } else {
            socketFD = try IRCSocket.connect(host: host, port: port, timeout: timeout)
            started = true
            Thread.detachNewThread { [weak self] in
                self?.readSocket()
            }
        }
    }

    /// Sends PASS (optional), NICK, and USER, then reads until `RPL_WELCOME`.
    /// `PING` messages received during registration are answered with `PONG`.
    public func register(
        password: String? = nil,
        nickname: String,
        username: String,
        realName: String,
        mode: IRCInitialUserMode = [],
        timeout: TimeInterval = 30
    ) throws -> [IRCMessage] {
        guard !isRegistered else {
            throw IRCError.alreadyRegistered
        }
        let commands = try IRCRegistration.commands(
            password: password,
            nickname: nickname,
            username: username,
            realName: realName,
            mode: mode
        )
        for command in commands {
            try send(command)
        }
        self.nickname = nickname
        var received: [IRCMessage] = []
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw IRCError.timedOut
            }
            guard let message = try receive(timeout: remaining) else {
                throw IRCError.unexpectedEnd
            }
            if message.command == "PING" {
                let token = message.parameters.first ?? ""
                let second = message.parameters.count > 1 ? message.parameters[1] : nil
                try send(.pong(server: token, server2: second))
                continue
            }
            received.append(message)
            if message.command == "ERROR" {
                throw IRCError.registrationFailed(numeric: 0, message: message.parameters.last ?? "ERROR")
            }
            if let numeric = message.numeric {
                if numeric == IRCNumeric.welcome {
                    if let assigned = message.parameters.first, !assigned.isEmpty {
                        self.nickname = assigned
                    }
                    isRegistered = true
                    return received
                }
                if numeric.isError {
                    throw IRCError.registrationFailed(
                        numeric: numeric.code,
                        message: message.parameters.last ?? numeric.name
                    )
                }
            }
        }
    }

    public func send(_ command: IRCCommand) throws {
        try send(try IRCMessage(command: command))
    }

    public func send(_ message: IRCMessage) throws {
        guard started else {
            throw IRCError.notConnected
        }
        if message.command == "PASS" && (sentRegistrationIdentity || isRegistered) {
            throw IRCError.passwordSentTooLate
        }
        if message.command == "NICK" || message.command == "USER" || message.command == "SERVICE" {
            sentRegistrationIdentity = true
        }
        let bytes = try message.serialized()
        if socketFD >= 0 {
            try IRCSocket.sendAll(socketFD, bytes)
            return
        }
        guard let connection = connection else {
            throw IRCError.notConnected
        }
        let semaphore = DispatchSemaphore(value: 0)
        var sendError: IRCError?
        connection.send(content: Data(bytes), completion: .contentProcessed { error in
            if let error = error {
                sendError = .connectionFailed(String(describing: error))
            }
            semaphore.signal()
        })
        if semaphore.wait(timeout: .now() + 30) == .timedOut {
            throw IRCError.timedOut
        }
        if let sendError = sendError {
            throw sendError
        }
    }

    public func receive(timeout: TimeInterval = 30) throws -> IRCMessage? {
        guard started else {
            throw IRCError.notConnected
        }
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while pending.isEmpty && !endOfStream && failure == nil {
            if !condition.wait(until: deadline) {
                throw IRCError.timedOut
            }
        }
        if pending.isEmpty, let failure = failure {
            throw failure
        }
        if pending.isEmpty {
            return nil
        }
        return pending.removeFirst()
    }

    public func quit(message: String? = nil) throws {
        if started && !endOfStream {
            try send(.quit(message: message))
        }
        close()
    }

    public func close() {
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
        connection?.cancel()
        connection = nil
        condition.lock()
        endOfStream = true
        condition.signal()
        condition.unlock()
    }

    private func connectTLS(timeout: TimeInterval) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw IRCError.connectionFailed("invalid port \(port)")
        }
        let parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
        self.connection = connection

        let semaphore = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var finished = false
        var connectError: IRCError?
        connection.stateUpdateHandler = { state in
            stateLock.lock()
            defer { stateLock.unlock() }
            if finished {
                return
            }
            switch state {
            case .ready:
                finished = true
                semaphore.signal()
            case .failed(let error):
                finished = true
                connectError = .connectionFailed(String(describing: error))
                semaphore.signal()
            case .cancelled:
                finished = true
                connectError = .connectionFailed("cancelled")
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            stateLock.lock()
            defer { stateLock.unlock() }
            if finished {
                return
            }
            finished = true
            connectError = .timedOut
            semaphore.signal()
        }
        semaphore.wait()
        if let connectError = connectError {
            connection.cancel()
            self.connection = nil
            throw connectError
        }
        started = true
        readTLS(from: connection)
    }

    private func readSocket() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while socketFD >= 0 {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else {
                    return -1
                }
                return recv(socketFD, base, raw.count, 0)
            }
            condition.lock()
            if count > 0 {
                accept([UInt8](buffer.prefix(count)))
            } else {
                endOfStream = true
                if count < 0 && failure == nil {
                    failure = .connectionFailed(String(cString: strerror(errno)))
                }
            }
            condition.signal()
            condition.unlock()
            if count <= 0 {
                break
            }
        }
    }

    private func readTLS(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                return
            }
            self.condition.lock()
            if let data = data, !data.isEmpty {
                self.accept([UInt8](data))
            }
            if let error = error {
                self.failure = .connectionFailed(String(describing: error))
                self.endOfStream = true
            }
            if isComplete {
                self.endOfStream = true
            }
            self.condition.signal()
            self.condition.unlock()
            if error == nil && !isComplete {
                self.readTLS(from: connection)
            }
        }
    }

    private func accept(_ bytes: [UInt8]) {
        do {
            pending.append(contentsOf: try framer.append(bytes))
        } catch let ircError as IRCError {
            failure = ircError
        } catch {
            failure = .connectionFailed(String(describing: error))
        }
    }
}

enum IRCSocket {
    static func connect(host: String, port: UInt16, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        hints.ai_protocol = IPPROTO_TCP
        var resolved: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &resolved)
        guard status == 0, resolved != nil else {
            throw IRCError.connectionFailed(String(cString: gai_strerror(status)))
        }
        let addresses = resolved!
        defer { freeaddrinfo(addresses) }

        var lastError = "connection failed"
        var cursor: UnsafeMutablePointer<addrinfo>? = addresses
        while let current = cursor {
            let fd = socket(current.pointee.ai_family, current.pointee.ai_socktype, current.pointee.ai_protocol)
            if fd >= 0 {
                let flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                let connected = Darwin.connect(fd, current.pointee.ai_addr, current.pointee.ai_addrlen)
                if connected == 0 || errno == EINPROGRESS {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let waited = poll(&descriptor, 1, Int32(timeout * 1000))
                    if waited > 0 {
                        var socketError: Int32 = 0
                        var length = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
                        if socketError == 0 {
                            _ = fcntl(fd, F_SETFL, flags)
                            return fd
                        }
                        lastError = String(cString: strerror(socketError))
                    } else if waited == 0 {
                        lastError = "timed out"
                    } else {
                        lastError = String(cString: strerror(errno))
                    }
                } else {
                    lastError = String(cString: strerror(errno))
                }
                Darwin.close(fd)
            } else {
                lastError = String(cString: strerror(errno))
            }
            cursor = current.pointee.ai_next
        }
        throw IRCError.connectionFailed(lastError)
    }

    static func sendAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else {
                    return -1
                }
                return Darwin.send(fd, base.advanced(by: offset), bytes.count - offset, 0)
            }
            if sent < 0 {
                if errno == EINTR {
                    continue
                }
                throw IRCError.connectionFailed(String(cString: strerror(errno)))
            }
            if sent == 0 {
                throw IRCError.unexpectedEnd
            }
            offset += sent
        }
    }
}
