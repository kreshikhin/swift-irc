import Darwin
import Foundation
import SwiftIRCCore

/// One accepted client socket and the user attached to it.
public final class IRCServerSession {
    public let user: IRCUser

    private let lock = NSLock()
    private var fileDescriptor: Int32
    private weak var server: IRCServer?
    private var framer = IRCFramer()

    init(fileDescriptor: Int32, user: IRCUser, server: IRCServer) {
        self.fileDescriptor = fileDescriptor
        self.user = user
        self.server = server
    }

    func start() {
        Thread.detachNewThread { [weak self] in
            self?.readLoop()
        }
    }

    func send(_ message: IRCMessage) {
        guard let bytes = try? IRCEncoder.encode(message) else {
            return
        }
        lock.lock()
        let descriptor = fileDescriptor
        lock.unlock()
        guard descriptor >= 0 else {
            return
        }
        try? IRCServerSocket.sendAll(descriptor, bytes)
    }

    func close() {
        lock.lock()
        let descriptor = fileDescriptor
        fileDescriptor = -1
        lock.unlock()
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            lock.lock()
            let descriptor = fileDescriptor
            lock.unlock()
            if descriptor < 0 {
                break
            }
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else {
                    return -1
                }
                return recv(descriptor, base, raw.count, 0)
            }
            if count <= 0 {
                break
            }
            let bytes = [UInt8](buffer.prefix(count))
            do {
                let messages = try framer.append(bytes)
                for message in messages {
                    server?.receive(message, from: self)
                }
            } catch {
                if let failure = try? IRCMessage(command: .error("Closing link: bad message")) {
                    send(failure)
                }
                break
            }
        }
        server?.remove(self)
    }
}

enum IRCServerSocket {
    static func sendAll(_ descriptor: Int32, _ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else {
                    return -1
                }
                return Darwin.send(descriptor, base.advanced(by: offset), bytes.count - offset, 0)
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
