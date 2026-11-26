import Foundation
import Darwin

struct DaemonVM: Codable, Sendable {
    let name: String
    let status: String
    let cpus: Int
    let memoryBytes: Int64
    let diskBytes: Int64

    enum CodingKeys: String, CodingKey {
        case name, status, cpus
        case memoryBytes = "memory_bytes"
        case diskBytes = "disk_bytes"
    }
}

struct DaemonTask: Codable, Identifiable, Sendable {
    let id: String
    let kind: String
    let target: String?
    let status: String
    let createdAt: String
    let updatedAt: String
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, target, status, error
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

enum DaemonClientError: LocalizedError {
    case socketUnavailable(String)
    case httpError(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .socketUnavailable(let msg): return msg
        case .httpError(let code, let msg): return "Daemon HTTP \(code): \(msg)"
        case .invalidResponse: return "Invalid daemon response"
        }
    }
}

// Local-only Unix Domain Socket client for the Go Agent-VM daemon.
// Never opens TCP listeners or stops the daemon when the desktop app exits.
final class DaemonClient: Sendable {
    let socketPath: String

    init(stateDir: String? = nil) {
        let base = stateDir ?? ProcessInfo.processInfo.environment["AGENT_VM_STATE_DIR"] ?? (NSHomeDirectory() + "/.agent-vm")
        self.socketPath = base + "/run/agent-vm.sock"
    }

    func health() -> Bool {
        guard let (code, _) = try? request(method: "GET", path: "/health", body: nil, timeoutSec: 2) else {
            return false
        }
        return code == 200
    }

    func listVMs() throws -> [DaemonVM] {
        let (code, data) = try request(method: "GET", path: "/api/v1/vms", body: nil, timeoutSec: 10)
        guard code == 200 else { throw DaemonClientError.httpError(code, String(decoding: data, as: UTF8.self)) }
        return try JSONDecoder().decode([DaemonVM].self, from: data)
    }

    func listTasks() throws -> [DaemonTask] {
        let (code, data) = try request(method: "GET", path: "/api/v1/tasks", body: nil, timeoutSec: 5)
        guard code == 200 else { throw DaemonClientError.httpError(code, String(decoding: data, as: UTF8.self)) }
        return try JSONDecoder().decode([DaemonTask].self, from: data)
    }

    func changeVM(name: String, action: String) throws -> DaemonTask {
        let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let (code, data) = try request(method: "POST", path: "/api/v1/vms/\(escaped)/\(action)", body: nil, timeoutSec: 10)
        guard code == 202 else { throw DaemonClientError.httpError(code, String(decoding: data, as: UTF8.self)) }
        return try JSONDecoder().decode(DaemonTask.self, from: data)
    }

    func cancelTask(id: String) throws -> DaemonTask {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let (code, data) = try request(method: "POST", path: "/api/v1/tasks/\(escaped)/cancel", body: nil, timeoutSec: 5)
        guard code == 200 else { throw DaemonClientError.httpError(code, String(decoding: data, as: UTF8.self)) }
        return try JSONDecoder().decode(DaemonTask.self, from: data)
    }

    func connectUnixSocket(timeoutSec: Int) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DaemonClientError.socketUnavailable("socket() failed")
        }
        var tv = timeval(tv_sec: timeoutSec, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < maxLen else {
            Darwin.close(fd)
            throw DaemonClientError.socketUnavailable("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for i in 0..<pathBytes.count {
                buf[i] = pathBytes[i]
            }
            buf[pathBytes.count] = 0
        }
        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard res == 0 else {
            let err = errno
            Darwin.close(fd)
            throw DaemonClientError.socketUnavailable("connect failed (\(err))")
        }
        return fd
    }

    private func request(method: String, path: String, body: Data?, timeoutSec: Int) throws -> (Int, Data) {
        let fd = try connectUnixSocket(timeoutSec: timeoutSec)
        defer { Darwin.close(fd) }

        var req = "\(method) \(path) HTTP/1.1\r\nHost: agent-vm\r\nConnection: close\r\n"
        if let body {
            req += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        } else {
            req += "Content-Length: 0\r\n"
        }
        req += "\r\n"
        var payload = Data(req.utf8)
        if let body { payload.append(body) }

        try payload.withUnsafeBytes { raw in
            var sent = 0
            while sent < payload.count {
                let n = Darwin.send(fd, raw.baseAddress!.advanced(by: sent), payload.count - sent, 0)
                if n <= 0 { throw DaemonClientError.socketUnavailable("send failed") }
                sent += n
            }
        }

        var response = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            if n > 0 {
                response.append(contentsOf: buf[0..<n])
            } else {
                break
            }
        }

        let sep = Data("\r\n\r\n".utf8)
        guard let range = response.range(of: sep) else {
            throw DaemonClientError.invalidResponse
        }
        let headerText = String(decoding: response[..<range.lowerBound], as: UTF8.self)
        let statusLine = headerText.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else {
            throw DaemonClientError.invalidResponse
        }
        var respBody = Data(response[range.upperBound...])
        if headerText.lowercased().contains("transfer-encoding: chunked") {
            respBody = Self.decodeChunked(respBody)
        }
        return (code, respBody)
    }

    static func decodeChunked(_ data: Data) -> Data {
        var out = Data()
        var idx = data.startIndex
        let crlf = Data("\r\n".utf8)
        while idx < data.endIndex {
            guard let lineEnd = data.range(of: crlf, in: idx..<data.endIndex) else { break }
            let sizeStr = String(decoding: data[idx..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let chunkSize = Int(sizeStr, radix: 16), chunkSize > 0 else { break }
            let chunkStart = lineEnd.upperBound
            let chunkEnd = data.index(chunkStart, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
            out.append(data[chunkStart..<chunkEnd])
            idx = data.index(chunkEnd, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return out
    }
}

// Persistent SSE subscriber for /api/v1/events with automatic reconnect.
final class DaemonEventStream {
    private let client: DaemonClient
    private let queue = DispatchQueue(label: "org.agentvm.daemon.sse", qos: .utility)
    private var running = false
    private var activeFD: Int32 = -1
    private let lock = NSLock()

    var onStateChange: ((Bool, String) -> Void)?
    var onTasks: (([DaemonTask]) -> Void)?

    init(client: DaemonClient) {
        self.client = client
    }

    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        queue.async { [weak self] in self?.loop() }
    }

    func stop() {
        lock.lock()
        running = false
        let fd = activeFD
        activeFD = -1
        lock.unlock()
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func loop() {
        var backoff: TimeInterval = 2.0
        while isRunning() {
            do {
                let fd = try client.connectUnixSocket(timeoutSec: 30)
                lock.lock()
                if !running {
                    lock.unlock()
                    Darwin.close(fd)
                    return
                }
                activeFD = fd
                lock.unlock()

                let req = "GET /api/v1/events HTTP/1.1\r\nHost: agent-vm\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n"
                let reqBytes = Array(req.utf8)
                let sent = reqBytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, reqBytes.count, 0) }
                guard sent == reqBytes.count else { throw DaemonClientError.socketUnavailable("sse send failed") }

                onStateChange?(true, "connected")
                backoff = 2.0

                var buffer = ""
                var headersDone = false
                var readBuf = [UInt8](repeating: 0, count: 8192)
                while isRunning() {
                    let n = Darwin.recv(fd, &readBuf, readBuf.count, 0)
                    if n <= 0 { break }
                    buffer += String(decoding: readBuf[0..<n], as: UTF8.self)
                    if !headersDone {
                        if let range = buffer.range(of: "\r\n\r\n") {
                            buffer = String(buffer[range.upperBound...])
                            headersDone = true
                        } else {
                            continue
                        }
                    }
                    while let nl = buffer.range(of: "\n") {
                        let line = String(buffer[..<nl.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                        buffer = String(buffer[nl.upperBound...])
                        if line.hasPrefix("data: ") {
                            let jsonStr = String(line.dropFirst(6))
                            if let data = jsonStr.data(using: .utf8),
                               let tasks = try? JSONDecoder().decode([DaemonTask].self, from: data) {
                                onTasks?(tasks)
                            }
                        }
                    }
                }
                lock.lock()
                if activeFD == fd { activeFD = -1 }
                lock.unlock()
                Darwin.close(fd)
            } catch {
                // Daemon may not be started yet; retry with bounded backoff.
            }
            if isRunning() {
                onStateChange?(false, "reconnecting")
                Thread.sleep(forTimeInterval: backoff)
                backoff = min(backoff * 1.5, 8.0)
            }
        }
    }
}
