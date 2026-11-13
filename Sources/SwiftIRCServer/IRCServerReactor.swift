import Darwin
import Foundation
import SwiftIRCCore

/// One nonblocking poll loop for every accepted client.
///
/// Each session keeps its own send queue. The loop writes only while a socket
/// is ready, so a slow client does not block the others. Crossing
/// `IRCServerSession.maximumSendQueueBytes` closes that session.
/// A single-threaded reactor is the backpressure path that fits this process;
/// SwiftNIO would replace the loop if the server later needs a larger connection budget.
final class IRCServerReactor {
    private let lock = NSLock()
    private let stopped = NSCondition()
    private var sessions: [Int32: IRCServerSession] = [:]
    private var running = false
    private var threadAlive = false
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1

    func start() throws {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        var ends = [Int32](repeating: -1, count: 2)
        let created = ends.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else {
                return -1
            }
            return pipe(base)
        }
        guard created == 0 else {
            lock.unlock()
            throw IRCError.connectionFailed(String(cString: strerror(errno)))
        }
        setNonblocking(ends[0])
        setNonblocking(ends[1])
        wakeRead = ends[0]
        wakeWrite = ends[1]
        running = true
        lock.unlock()
        stopped.lock()
        threadAlive = true
        stopped.unlock()
        Thread.detachNewThread { [weak self] in
            self?.loop()
        }
    }

    func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        guard wasRunning else {
            return
        }
        poke()
        stopped.lock()
        while threadAlive {
            stopped.wait()
        }
        stopped.unlock()
    }

    func add(_ session: IRCServerSession) {
        let fd = session.pollInterest().fd
        lock.lock()
        let alive = running
        if alive && fd >= 0 {
            sessions[fd] = session
        }
        lock.unlock()
        if alive {
            poke()
        } else if fd >= 0 {
            let taken = session.takeDescriptor()
            if taken >= 0 {
                Darwin.close(taken)
            }
        }
    }

    func sessionDidRequestAttention(_ session: IRCServerSession) {
        lock.lock()
        let alive = threadAlive
        lock.unlock()
        if alive {
            poke()
        } else {
            let taken = session.takeDescriptor()
            if taken >= 0 {
                Darwin.close(taken)
            }
        }
    }

    private func loop() {
        defer {
            lock.lock()
            let leftover = Array(sessions.values)
            sessions.removeAll()
            running = false
            let readEnd = wakeRead
            let writeEnd = wakeWrite
            wakeRead = -1
            wakeWrite = -1
            lock.unlock()
            for session in leftover {
                let fd = session.takeDescriptor()
                if fd >= 0 {
                    Darwin.close(fd)
                }
            }
            if readEnd >= 0 {
                Darwin.close(readEnd)
            }
            if writeEnd >= 0 {
                Darwin.close(writeEnd)
            }
            stopped.lock()
            threadAlive = false
            stopped.signal()
            stopped.unlock()
        }

        while true {
            lock.lock()
            if !running {
                lock.unlock()
                break
            }
            let watched = Array(sessions.values)
            lock.unlock()

            var closing: [IRCServerSession] = []
            var polling: [(IRCServerSession, Int32, Int32)] = []
            for session in watched {
                let interest = session.pollInterest()
                if interest.closeNow || interest.fd < 0 {
                    closing.append(session)
                } else {
                    polling.append((session, interest.fd, interest.events))
                }
            }
            if !closing.isEmpty {
                forget(closing)
            }

            var polls = [pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            for entry in polling {
                polls.append(pollfd(fd: entry.1, events: Int16(entry.2), revents: 0))
            }
            let ready = polls.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else {
                    return -1
                }
                return poll(base, nfds_t(buffer.count), -1)
            }
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }
            if polls[0].revents != 0 {
                drainWake()
            }
            var incoming: [(IRCServerSession, IRCMessage)] = []
            for index in polling.indices {
                let events = polls[index + 1].revents
                if events == 0 {
                    continue
                }
                let session = polling[index].0
                if events & Int16(POLLOUT) != 0 {
                    session.writeReady()
                }
                let readable = Int16(POLLIN) | Int16(POLLHUP) | Int16(POLLERR) | Int16(POLLNVAL)
                if events & readable != 0 {
                    for message in session.readReady() {
                        incoming.append((session, message))
                    }
                }
            }
            for entry in incoming {
                entry.0.server?.receive(entry.1, from: entry.0)
            }
        }
    }

    private func forget(_ closing: [IRCServerSession]) {
        var descriptors: [Int32] = []
        lock.lock()
        for session in closing {
            let fd = session.takeDescriptor()
            if fd >= 0 {
                sessions.removeValue(forKey: fd)
                descriptors.append(fd)
            }
        }
        lock.unlock()
        for fd in descriptors {
            Darwin.close(fd)
        }
    }

    private func poke() {
        lock.lock()
        let fd = wakeWrite
        lock.unlock()
        guard fd >= 0 else {
            return
        }
        var byte: UInt8 = 1
        _ = Darwin.write(fd, &byte, 1)
    }

    private func drainWake() {
        lock.lock()
        let fd = wakeRead
        lock.unlock()
        guard fd >= 0 else {
            return
        }
        var buffer = [UInt8](repeating: 0, count: 64)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else {
                    return -1
                }
                return read(fd, base, raw.count)
            }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                return
            }
            if count <= 0 {
                return
            }
        }
    }

    private func setNonblocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
}
