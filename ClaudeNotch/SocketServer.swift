import Foundation
import Darwin

/// A tiny HTTP-over-Unix-socket server.
///
/// Why a Unix socket and not localhost HTTP? A file socket in your Library folder,
/// with permissions 0600, can only be opened by processes running as you. A
/// localhost port can be reached by any web page in your browser, which could
/// then press "Allow" on your behalf.
///
/// The hook script talks to it with `curl --unix-socket`.
final class SocketServer {
    struct Request {
        let path: String
        let headers: [String: String]
        let body: Data
    }

    let path: String
    /// Called on the main thread. Call the responder exactly once with the response body.
    var onRequest: ((Request, @escaping (String) -> Void) -> Void)?

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "notch.socket.accept")

    static var defaultPath: String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeNotch", isDirectory: true)
        return dir.appendingPathComponent("notch.sock").path
    }

    init(path: String = SocketServer.defaultPath) { self.path = path }

    func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard ok == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        chmod(path, 0o600)
        guard listen(fd, 32) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        if fd >= 0 { close(fd) }
        unlink(path)
    }

    private func acceptOne() {
        let c = accept(fd, nil, nil)
        guard c >= 0 else { return }
        // Only talk to processes running as the same user.
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else { close(c); return }
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let req = Self.read(c) else { close(c); return }
            let respond: (String) -> Void = { body in
                DispatchQueue.global().async {
                    let data = Array(body.utf8)
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
                    let out = Array(head.utf8) + data
                    out.withUnsafeBytes { p in
                        var off = 0
                        while off < out.count {
                            let n = write(c, p.baseAddress! + off, out.count - off)
                            if n <= 0 { break }
                            off += n
                        }
                    }
                    close(c)
                }
            }
            // Make sure we answer exactly once.
            let once = Once(respond)
            DispatchQueue.main.async {
                guard let handler = self.onRequest else { once.call(""); return }
                handler(req) { once.call($0) }
            }
        }
    }

    private static func read(_ c: Int32) -> Request? {
        var buf = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let limit = 16 * 1024 * 1024
        var headerEnd: Int?
        var contentLength = 0
        while true {
            let n = recv(c, &chunk, chunk.count, 0)
            if n <= 0 { break }
            buf.append(contentsOf: chunk[0..<n])
            if buf.count > limit { return nil }
            if headerEnd == nil, let r = find(buf, [13, 10, 13, 10]) {
                headerEnd = r + 4
                let head = String(decoding: buf[0..<r], as: UTF8.self)
                for line in head.split(separator: "\r\n").dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2, parts[0].lowercased() == "content-length" {
                        contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                }
            }
            if let h = headerEnd, buf.count - h >= contentLength { break }
        }
        guard let h = headerEnd else { return nil }
        let head = String(decoding: buf[0..<(h - 4)], as: UTF8.self)
        let lines = head.split(separator: "\r\n")
        guard let first = lines.first else { return nil }
        let reqParts = first.split(separator: " ")
        let path = reqParts.count > 1 ? String(reqParts[1]) : "/"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        let body = Data(buf[h..<min(buf.count, h + contentLength)])
        return Request(path: path, headers: headers, body: body)
    }

    private static func find(_ hay: [UInt8], _ needle: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] {
            if Array(hay[i..<(i + needle.count)]) == needle { return i }
        }
        return nil
    }
}

private final class Once {
    private var fn: ((String) -> Void)?
    private let lock = NSLock()
    init(_ fn: @escaping (String) -> Void) { self.fn = fn }
    func call(_ s: String) {
        lock.lock(); let f = fn; fn = nil; lock.unlock()
        f?(s)
    }
}
