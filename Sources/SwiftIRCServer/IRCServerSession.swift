import Darwin
import Foundation
import SwiftIRCCore

/// One accepted client socket and the user attached to it.
///
/// The shared reactor is the only thread that reads or writes the descriptor.
/// `send` appends one whole message to that session's queue, so concurrent
/// deliveries cannot interleave bytes. A full queue closes the session.
public final class IRCServerSession {
    public let user: IRCUser

    static let maximumSendQueueBytes = 256 * 1024

    weak var server: IRCServer?
    private let reactor: IRCServerReactor
    private let queueLock = NSLock()
    private var socketFD: Int32
    private var outbound: [UInt8] = []
    private var wantsClose = false
    private var framer = IRCFramer()

    init(fileDescriptor: Int32, user: IRCUser, server: IRCServer, reactor: IRCServerReactor) {
        socketFD = fileDescriptor
        self.user = user
        self.server = server
        self.reactor = reactor
    }

    func send(_ message: IRCMessage) {
        guard let bytes = try? IRCEncoder.encode(message) else {
            return
        }
        let accepted = enqueue(bytes)
        if accepted {
            reactor.sessionDidRequestAttention(self)
            return
        }
        if !user.didQuit {
            server?.remove(self)
        }
    }

    func close() {
        queueLock.lock()
        wantsClose = true
        queueLock.unlock()
        reactor.sessionDidRequestAttention(self)
    }

    func pollInterest() -> (fd: Int32, events: Int32, closeNow: Bool) {
        queueLock.lock()
        defer { queueLock.unlock() }
        var events = Int32(POLLIN)
        if !outbound.isEmpty {
            events |= Int32(POLLOUT)
        }
        let closeNow = wantsClose && outbound.isEmpty
        return (socketFD, events, closeNow || socketFD < 0)
    }

    func writeReady() {
        queueLock.lock()
        defer { queueLock.unlock() }
        guard socketFD >= 0, !outbound.isEmpty else {
            return
        }
        let written = outbound.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else {
                return -1
            }
            return Darwin.send(socketFD, base, outbound.count, 0)
        }
        if written > 0 {
            outbound.removeFirst(written)
            return
        }
        if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
            return
        }
        outbound.removeAll()
        wantsClose = true
    }

    func readReady() -> [IRCMessage] {
        var messages: [IRCMessage] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            queueLock.lock()
            let fd = socketFD
            queueLock.unlock()
            if fd < 0 {
                break
            }
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else {
                    return -1
                }
                return recv(fd, base, raw.count, 0)
            }
            if count > 0 {
                do {
                    messages.append(contentsOf: try framer.append([UInt8](buffer.prefix(count))))
                } catch {
                    if let failure = try? IRCMessage(command: .error("Closing link: bad message")) {
                        _ = enqueue(failure)
                    }
                    queueLock.lock()
                    wantsClose = true
                    queueLock.unlock()
                    break
                }
                continue
            }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                break
            }
            queueLock.lock()
            wantsClose = true
            queueLock.unlock()
            break
        }
        return messages
    }

    func takeDescriptor() -> Int32 {
        queueLock.lock()
        defer { queueLock.unlock() }
        let fd = socketFD
        socketFD = -1
        wantsClose = true
        outbound.removeAll()
        return fd
    }

    private func enqueue(_ bytes: [UInt8]) -> Bool {
        queueLock.lock()
        defer { queueLock.unlock() }
        if wantsClose || socketFD < 0 {
            return false
        }
        if outbound.count + bytes.count > IRCServerSession.maximumSendQueueBytes {
            outbound.removeAll()
            wantsClose = true
            return false
        }
        outbound.append(contentsOf: bytes)
        return true
    }

    private func enqueue(_ message: IRCMessage) -> Bool {
        guard let bytes = try? IRCEncoder.encode(message) else {
            return false
        }
        return enqueue(bytes)
    }
}
