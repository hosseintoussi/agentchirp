import Foundation
import Darwin
import CryptoKit

/// Minimal RFC 6455 text transport over Codex's owner-only Unix socket.
/// Confined to the session-store queue; all I/O has a deadline and size bound.
final class UnixWebSocket {
    enum Failure: Error { case unavailable, timeout, protocolError }
    private var fd: Int32 = -1
    private var deadline = Date.distantPast
    private let maximum = 4 * 1024 * 1024
    deinit { closeConnection() }
    func closeConnection() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
    func begin(timeout: TimeInterval) { deadline = Date(timeIntervalSinceNow: timeout) }
    private func ready(_ events: Int16) throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw Failure.timeout }
        var item = pollfd(fd: fd, events: events, revents: 0)
        guard poll(&item, 1, Int32(min(remaining * 1000, 2000))) > 0,
              item.revents & events != 0 else { throw Failure.timeout }
    }
    private func read(_ count: Int) throws -> [UInt8] {
        guard count <= maximum else { throw Failure.protocolError }
        var data = [UInt8](repeating: 0, count: count), offset = 0
        while offset < count {
            try ready(Int16(POLLIN))
            let n = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            guard n > 0 else { throw Failure.unavailable }
            offset += n
        }
        return data
    }
    private func write(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            try ready(Int16(POLLOUT))
            let n = bytes.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0) }
            guard n > 0 else { throw Failure.unavailable }
            offset += n
        }
    }
    func connect(path: String) throws {
        closeConnection()
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.unavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.unavailable }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw Failure.unavailable }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw Failure.unavailable }
            try ready(Int16(POLLOUT))
            var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
            guard error == 0 else { throw Failure.unavailable }
        }
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try write(Array(request.utf8))
        var header: [UInt8] = []
        while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard header.count < 8192 else { throw Failure.protocolError }
            header += try read(1)
        }
        let text = String(decoding: header, as: UTF8.self)
        let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        guard text.hasPrefix("HTTP/1.1 101 "), text.components(separatedBy: "\r\n").contains(where: {
            let parts = $0.split(separator: ":", maxSplits: 1)
            return parts.count == 2 && parts[0].lowercased() == "sec-websocket-accept"
                && parts[1].trimmingCharacters(in: .whitespaces) == expected
        }) else { throw Failure.protocolError }
    }
    private func frame(_ payload: [UInt8], opcode: UInt8) throws {
        guard payload.count <= maximum else { throw Failure.protocolError }
        var header: [UInt8] = [0x80 | opcode]
        if payload.count < 126 { header.append(0x80 | UInt8(payload.count)) }
        else if payload.count <= 65535 {
            header += [0xfe, UInt8(payload.count >> 8), UInt8(payload.count & 255)]
        } else {
            header.append(0xff)
            header += (0..<8).reversed().map { UInt8((UInt64(payload.count) >> ($0 * 8)) & 255) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        try write(header + mask + payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
    }
    func sendJSON(_ object: [String: Any]) throws {
        try frame(Array(JSONSerialization.data(withJSONObject: object)), opcode: 1)
    }
    func receiveJSON() throws -> [String: Any] {
        var message: [UInt8] = [], fragmented = false
        while true {
            let header = try read(2)
            let opcode = header[0] & 15, final = header[0] & 0x80 != 0
            guard header[0] & 0x70 == 0, header[1] & 0x80 == 0 else { throw Failure.protocolError }
            var length = UInt64(header[1] & 0x7f)
            if length == 126 { length = try read(2).reduce(0) { ($0 << 8) | UInt64($1) } }
            else if length == 127 { length = try read(8).reduce(0) { ($0 << 8) | UInt64($1) } }
            guard length <= maximum else { throw Failure.protocolError }
            let payload = try read(Int(length))
            if opcode == 8 { throw Failure.unavailable }
            if opcode == 9 { guard final, length <= 125 else { throw Failure.protocolError }; try frame(payload, opcode: 10); continue }
            if opcode == 10 { continue }
            guard (opcode == 1 && !fragmented) || (opcode == 0 && fragmented), message.count + payload.count <= maximum else { throw Failure.protocolError }
            message += payload
            if final {
                guard let object = try JSONSerialization.jsonObject(with: Data(message)) as? [String: Any] else { throw Failure.protocolError }
                return object
            }
            fragmented = true
        }
    }
}
