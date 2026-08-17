import Darwin
import Foundation

public typealias StatusSink = @Sendable (String) -> Void

public enum SocketPath {
    public static let maximumUTF8Bytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    public static func validate(_ path: String) throws -> [UInt8] {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty else { throw SpeechIPCError.invalidSocketPath("path is empty") }
        guard !bytes.contains(0) else { throw SpeechIPCError.invalidSocketPath("path contains NUL") }
        guard bytes.count <= maximumUTF8Bytes else {
            throw SpeechIPCError.invalidSocketPath("UTF-8 length \(bytes.count) exceeds \(maximumUTF8Bytes)")
        }
        return bytes
    }
}

public final class UnixConnection: @unchecked Sendable {
    private var descriptor: Int32

    public init(socketPath: String, timeout: TimeInterval, status: @escaping StatusSink = { _ in }) throws {
        let pathBytes = try SocketPath.validate(socketPath)
        guard timeout > 0 else { throw SpeechIPCError.timeout("connect") }
        status("connect.wait")
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SpeechIPCError.systemCall(operation: "socket", code: errno) }
        descriptor = fd
        do {
            try Self.setNonBlocking(fd)
            var address = sockaddr_un()
            let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)!
            let addressLength = pathOffset + pathBytes.count + 1
            address.sun_len = UInt8(addressLength)
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.initializeMemory(as: UInt8.self, repeating: 0)
                raw.copyBytes(from: pathBytes)
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(addressLength))
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS else { throw SpeechIPCError.systemCall(operation: "connect", code: errno) }
                try Self.wait(fd: fd, events: Int16(POLLOUT), deadline: Deadline(timeout), operation: "connect")
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
                    throw SpeechIPCError.systemCall(operation: "getsockopt", code: errno)
                }
                guard socketError == 0 else { throw SpeechIPCError.systemCall(operation: "connect", code: socketError) }
            }
            status("connect.ready")
        } catch {
            Darwin.close(fd)
            descriptor = -1
            throw error
        }
    }

    deinit { close() }

    public func close() {
        guard descriptor >= 0 else { return }
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        descriptor = -1
    }

    public func write(_ data: Data, timeout: TimeInterval, status: @escaping StatusSink = { _ in }) throws {
        let deadline = Deadline(timeout)
        var written = 0
        try data.withUnsafeBytes { raw in
            while written < raw.count {
                status("write.wait")
                try Self.wait(fd: descriptor, events: Int16(POLLOUT), deadline: deadline, operation: "write")
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: written), raw.count - written)
                if count > 0 { written += count; continue }
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                throw SpeechIPCError.systemCall(operation: "write", code: errno)
            }
        }
        status("write.complete")
    }

    public func readFrame(timeout: TimeInterval, status: @escaping StatusSink = { _ in }) throws -> Frame {
        let deadline = Deadline(timeout)
        let header = try readExactly(4, deadline: deadline, status: status)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let bodyLength = Int(length)
        guard bodyLength >= 1 else { throw SpeechIPCError.frameTooSmall(bodyLength) }
        guard bodyLength <= FrameCodec.maximumFrameBytes else { throw SpeechIPCError.frameTooLarge(bodyLength) }
        let body = try readExactly(bodyLength, deadline: deadline, status: status)
        let rawType = body[body.startIndex]
        guard let type = FrameType(rawValue: rawType) else { throw SpeechIPCError.unknownFrameType(rawType) }
        return Frame(type: type, payload: body.dropFirst())
    }

    private func readExactly(_ count: Int, deadline: Deadline, status: @escaping StatusSink) throws -> Data {
        var data = Data(count: count)
        var received = 0
        try data.withUnsafeMutableBytes { raw in
            while received < count {
                status("read.wait")
                try Self.wait(fd: descriptor, events: Int16(POLLIN), deadline: deadline, operation: "read")
                let amount = Darwin.read(descriptor, raw.baseAddress!.advanced(by: received), count - received)
                if amount > 0 { received += amount; continue }
                if amount == 0 { throw SpeechIPCError.connectionClosed(expected: count, received: received) }
                if errno == EAGAIN || errno == EINTR { continue }
                throw SpeechIPCError.systemCall(operation: "read", code: errno)
            }
        }
        return data
    }

    private static func setNonBlocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw SpeechIPCError.systemCall(operation: "fcntl", code: errno)
        }
    }

    private static func wait(fd: Int32, events: Int16, deadline: Deadline, operation: String) throws {
        while true {
            let milliseconds = deadline.remainingMilliseconds
            guard milliseconds > 0 else { throw SpeechIPCError.timeout(operation) }
            var item = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, milliseconds)
            if result > 0 {
                if item.revents & Int16(POLLNVAL) != 0 { throw SpeechIPCError.systemCall(operation: operation, code: EBADF) }
                if item.revents & (events | Int16(POLLHUP) | Int16(POLLERR)) != 0 { return }
                continue
            }
            if result == 0 { throw SpeechIPCError.timeout(operation) }
            if errno == EINTR { continue }
            throw SpeechIPCError.systemCall(operation: "poll(\(operation))", code: errno)
        }
    }
}

private struct Deadline {
    private let end: UInt64

    init(_ timeout: TimeInterval) {
        let bounded = max(0, timeout)
        let nanoseconds = UInt64(min(bounded * 1_000_000_000, Double(UInt64.max / 2)))
        end = DispatchTime.now().uptimeNanoseconds &+ nanoseconds
    }

    var remainingMilliseconds: Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < end else { return 0 }
        let roundedUp = (end - now + 999_999) / 1_000_000
        return Int32(min(roundedUp, UInt64(Int32.max)))
    }
}
