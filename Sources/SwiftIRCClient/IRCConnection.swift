import Darwin
import Foundation
import Network
import SwiftIRCCore

/// A TCP connection that frames IRC messages.
///
/// Cleartext connections use POSIX sockets. `useTLS` uses Network.framework
/// and the default port from RFC 7194.
///
/// One write lock covers an entire `send`, so concurrent callers cannot interleave
/// bytes. `close` shuts the descriptor down immediately, and the last in-flight
/// read or write closes it, so the number cannot be reused while a thread still
/// blocks in `recv` or `send`.
public final class IRCConnection {
    public let host: String
    public let port: UInt16
    public let useTLS: Bool

    public var isConnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return connected
    }

    private let queue = DispatchQueue(label: "swiftirc.connection")
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private let condition = NSCondition()
    private var managed: IRCManagedDescriptor?
    private var tlsConnection: NWConnection?
    private var connected = false
    private var started = false
    private var framer = IRCFramer()
    private var pending: [IRCMessage] = []
    private var endOfStream = false
    private var failure: IRCError?

    public init(host: String, port: UInt16? = nil, useTLS: Bool = false) {
        self.host = host
        self.useTLS = useTLS
        self.port = port ?? (useTLS ? IRC.tlsPort : IRC.cleartextPort)
    }

    deinit {
        close()
    }

    public func connect(timeout: TimeInterval = 30) throws {
        stateLock.lock()
        if started {
            stateLock.unlock()
            throw IRCError.connectionFailed("already connected")
        }
        started = true
        stateLock.unlock()
        do {
            if useTLS {
                try connectTLS(timeout: timeout)
            } else {
                let fd = try IRCSocket.connect(host: host, port: port, timeout: timeout)
                var noSignal: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                let descriptor = IRCManagedDescriptor(fd)
                stateLock.lock()
                managed = descriptor
                connected = true
                stateLock.unlock()
                Thread.detachNewThread { [weak self] in
                    self?.readSocket()
                }
            }
        } catch {
            stateLock.lock()
            if managed == nil {
                started = false
                connected = false
            }
            stateLock.unlock()
            throw error
        }
    }

    public func send(_ message: IRCMessage) throws {
        let bytes = try message.serialized()
        writeLock.lock()
        defer { writeLock.unlock() }
        stateLock.lock()
        let descriptor = managed
        let tls = tlsConnection
        let open = connected
        stateLock.unlock()
        guard open else {
            throw IRCError.notConnected
        }
        if let tls = tls {
            try sendTLS(bytes, over: tls)
            return
        }
        guard let openDescriptor = descriptor, let fd = openDescriptor.borrow() else {
            throw IRCError.notConnected
        }
        do {
            try IRCSocket.sendAll(fd, bytes)
            openDescriptor.release(fd)
        } catch {
            openDescriptor.release(fd)
            throw error
        }
    }

    public func receive(timeout: TimeInterval = 30) throws -> IRCMessage? {
        guard isConnected || endOfStream || failure != nil else {
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

    public func close() {
        stateLock.lock()
        let descriptor = managed
        managed = nil
        connected = false
        let tls = tlsConnection
        tlsConnection = nil
        stateLock.unlock()
        descriptor?.shutdownAndClose()
        tls?.cancel()
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
        stateLock.lock()
        tlsConnection = connection
        stateLock.unlock()

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
            self.stateLock.lock()
            if tlsConnection === connection {
                tlsConnection = nil
            }
            self.stateLock.unlock()
            throw connectError
        }
        self.stateLock.lock()
        connected = true
        self.stateLock.unlock()
        readTLS(from: connection)
    }

    private func sendTLS(_ bytes: [UInt8], over connection: NWConnection) throws {
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

    private func readSocket() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            stateLock.lock()
            let descriptor = managed
            stateLock.unlock()
            guard let openDescriptor = descriptor, let fd = openDescriptor.borrow() else {
                break
            }
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else {
                    return -1
                }
                return recv(fd, base, raw.count, 0)
            }
            let readError = count < 0 ? errno : 0
            openDescriptor.release(fd)
            condition.lock()
            if count > 0 {
                accept([UInt8](buffer.prefix(count)))
            } else {
                endOfStream = true
                if count < 0 && failure == nil {
                    failure = .connectionFailed(String(cString: strerror(readError)))
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
            guard let strongSelf = self else {
                return
            }
            strongSelf.condition.lock()
            if let data = data, !data.isEmpty {
                strongSelf.accept([UInt8](data))
            }
            if let error = error {
                strongSelf.failure = .connectionFailed(String(describing: error))
                strongSelf.endOfStream = true
            }
            if isComplete {
                strongSelf.endOfStream = true
            }
            strongSelf.condition.signal()
            strongSelf.condition.unlock()
            if error == nil && !isComplete {
                strongSelf.readTLS(from: connection)
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

/// Keeps a socket number alive until the last `borrow` returns.
/// `shutdownAndClose` unblocks `recv` and `send` without letting the system
/// reuse the number while those calls are still in progress.
private final class IRCManagedDescriptor {
    private let lock = NSLock()
    private var descriptor: Int32
    private var users = 0
    private var isClosed = false

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    func borrow() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else {
            return nil
        }
        users += 1
        return descriptor
    }

    func release(_ borrowed: Int32) {
        lock.lock()
        users -= 1
        let shouldClose = isClosed && users == 0
        lock.unlock()
        if shouldClose {
            Darwin.close(borrowed)
        }
    }

    func shutdownAndClose() {
        lock.lock()
        let borrowed = descriptor
        let busy = users
        if isClosed {
            lock.unlock()
            return
        }
        isClosed = true
        descriptor = -1
        lock.unlock()
        guard borrowed >= 0 else {
            return
        }
        _ = Darwin.shutdown(borrowed, SHUT_RDWR)
        if busy == 0 {
            Darwin.close(borrowed)
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
