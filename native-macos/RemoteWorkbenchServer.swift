import Foundation
import Network
import Darwin

// Lightweight HTTP + SSE server using Network.framework to expose only the
// Agent Workbench to a mobile/remote browser (e.g. over EasyTier) with token auth.
@MainActor
final class RemoteWorkbenchServer {
    private var listener: NWListener?
    private var sseConnections: [ObjectIdentifier: NWConnection] = [:]
    private var lastPayload: Data = Data("{}".utf8)
    private(set) var currentPort: UInt16 = 18080
    private var token: String = ""

    var onAction: ((String, [String: Any]) -> Void)?
    var onError: ((String) -> Void)?

    func start(port: UInt16, token: String) {
        stop()
        self.currentPort = port
        self.token = token
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onError?("无效端口：\(port)")
            return
        }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: nwPort)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .failed(let err):
                        self.onError?("远程工作台启动失败：\(err.localizedDescription)")
                        self.stop()
                    case .ready:
                        self.onError?("")
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in
                    self?.handleConnection(conn)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            onError?("无法监听端口 \(port)：\(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for (_, conn) in sseConnections {
            conn.cancel()
        }
        sseConnections.removeAll()
    }

    func updateToken(_ newToken: String) {
        self.token = newToken
    }

    func broadcastState(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        lastPayload = data
        guard !sseConnections.isEmpty, let json = String(data: data, encoding: .utf8) else { return }
        let frame = Data("data: \(json)\n\n".utf8)
        for (id, conn) in sseConnections {
            conn.send(content: frame, completion: .contentProcessed { [weak self] err in
                if err != nil {
                    Task { @MainActor in
                        self?.sseConnections.removeValue(forKey: id)?.cancel()
                    }
                }
            })
        }
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: .main)
        receiveRequest(conn, buffer: Data())
    }

    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { conn.cancel(); return }
                if error != nil { conn.cancel(); return }
                var acc = buffer
                if let data { acc.append(data) }
                // Cap the entire request, not just headers: reject oversized POST bodies.
                if acc.count > 262144 {
                    self.sendSimple(conn, status: "413 Payload Too Large", body: "Request too large")
                    return
                }
                if let range = acc.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = acc.subdata(in: 0..<range.lowerBound)
                    let rest = acc.subdata(in: range.upperBound..<acc.count)
                    guard let headerText = String(data: headerData, encoding: .utf8) else {
                        self.sendSimple(conn, status: "400 Bad Request", body: "Bad Request")
                        return
                    }
                    let lines = headerText.components(separatedBy: "\r\n")
                    let contentLength = self.parseContentLength(lines)
                    guard contentLength <= 65536 else {
                        self.sendSimple(conn, status: "413 Payload Too Large", body: "Request body too large")
                        return
                    }
                    if rest.count < contentLength && !isComplete {
                        self.receiveRequest(conn, buffer: acc)
                        return
                    }
                    let body = rest.prefix(contentLength)
                    self.route(conn, headerLines: lines, body: Data(body))
                } else if isComplete || acc.count > 262144 {
                    conn.cancel()
                } else {
                    self.receiveRequest(conn, buffer: acc)
                }
            }
        }
    }

    private func parseContentLength(_ lines: [String]) -> Int {
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return max(0, Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0)
            }
        }
        return 0
    }

    private func route(_ conn: NWConnection, headerLines: [String], body: Data) {
        guard let requestLine = headerLines.first else {
            sendSimple(conn, status: "400 Bad Request", body: "Bad Request")
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendSimple(conn, status: "400 Bad Request", body: "Bad Request")
            return
        }
        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])
        let comps = URLComponents(string: rawTarget)
        let path = comps?.path ?? rawTarget
        let queryToken = comps?.queryItems?.first(where: { $0.name == "token" })?.value ?? ""
        var bearerToken = ""
        for line in headerLines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2 && kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "authorization" {
                let val = kv[1].trimmingCharacters(in: .whitespaces)
                if val.lowercased().hasPrefix("bearer ") {
                    bearerToken = String(val.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        let providedToken = bearerToken.isEmpty ? queryToken : bearerToken

        if path == "/api/state" && method == "GET" {
            guard !token.isEmpty && providedToken == token else {
                sendSimple(conn, status: "401 Unauthorized", body: "Unauthorized")
                return
            }
            sendData(conn, status: "200 OK", contentType: "application/json; charset=utf-8", data: lastPayload)
            return
        }

        if path == "/api/events" && method == "GET" {
            guard !token.isEmpty && providedToken == token else {
                sendSimple(conn, status: "401 Unauthorized", body: "Unauthorized")
                return
            }
            let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nConnection: keep-alive\r\n\r\n"
            let initialJson = String(data: lastPayload, encoding: .utf8) ?? "{}"
            let initial = Data((headers + "data: \(initialJson)\n\n").utf8)
            let id = ObjectIdentifier(conn)
            sseConnections[id] = conn
            conn.stateUpdateHandler = { [weak self] st in
                if case .cancelled = st {
                    Task { @MainActor in self?.sseConnections.removeValue(forKey: id) }
                } else if case .failed = st {
                    Task { @MainActor in self?.sseConnections.removeValue(forKey: id) }
                }
            }
            conn.send(content: initial, completion: .contentProcessed { [weak self] err in
                if err != nil {
                    Task { @MainActor in
                        self?.sseConnections.removeValue(forKey: id)?.cancel()
                    }
                }
            })
            return
        }

        if path == "/api/action" && method == "POST" {
            guard !token.isEmpty && providedToken == token else {
                sendSimple(conn, status: "401 Unauthorized", body: "Unauthorized")
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let action = json["action"] as? String else {
                sendSimple(conn, status: "400 Bad Request", body: "Invalid JSON")
                return
            }
            let allowed: Set<String> = [
                "codexRun", "codexStop", "codexClear",
                "codexSelectSession", "codexNewSession", "codexDeleteSession",
                "codexRenameSession", "codexSetSessionConfig", "codexEditResend", "codexGitDiff",
                "refresh", "remoteVMStart", "remoteVMStop"
            ]
            guard allowed.contains(action) else {
                sendSimple(conn, status: "403 Forbidden", body: "Action not permitted")
                return
            }
            let payload = json["payload"] as? [String: Any] ?? [:]
            onAction?(action, payload)
            sendJSON(conn, status: "200 OK", body: "{\"ok\":true}")
            return
        }

        if method == "GET" {
            serveStatic(conn, path: path)
            return
        }

        sendSimple(conn, status: "404 Not Found", body: "Not Found")
    }

    private func serveStatic(_ conn: NWConnection, path: String) {
        guard let webRoot = Bundle.main.resourceURL?.appendingPathComponent("web").standardizedFileURL else {
            sendSimple(conn, status: "500 Internal Server Error", body: "Missing web resources")
            return
        }
        let rel = path == "/" ? "index.html" : String(path.drop(while: { $0 == "/" }))
        let candidate = webRoot.appendingPathComponent(rel).standardizedFileURL
        guard candidate.path.hasPrefix(webRoot.path + "/"),
              FileManager.default.fileExists(atPath: candidate.path),
              var data = try? Data(contentsOf: candidate) else {
            let fallback = webRoot.appendingPathComponent("index.html")
            if var htmlData = try? Data(contentsOf: fallback) {
                if var html = String(data: htmlData, encoding: .utf8) {
                    html = html.replacingOccurrences(of: "connect-src 'none'", with: "connect-src 'self'")
                    htmlData = Data(html.utf8)
                }
                sendData(conn, status: "200 OK", contentType: "text/html; charset=utf-8", data: htmlData)
                return
            }
            sendSimple(conn, status: "404 Not Found", body: "Not Found")
            return
        }
        let ext = candidate.pathExtension.lowercased()
        if ext == "html", var html = String(data: data, encoding: .utf8) {
            html = html.replacingOccurrences(of: "connect-src 'none'", with: "connect-src 'self'")
            data = Data(html.utf8)
        }
        let mime: String
        switch ext {
        case "html": mime = "text/html; charset=utf-8"
        case "js": mime = "application/javascript; charset=utf-8"
        case "css": mime = "text/css; charset=utf-8"
        case "svg": mime = "image/svg+xml"
        case "png": mime = "image/png"
        case "json": mime = "application/json; charset=utf-8"
        default: mime = "application/octet-stream"
        }
        sendData(conn, status: "200 OK", contentType: mime, data: data)
    }

    private func sendSimple(_ conn: NWConnection, status: String, body: String) {
        sendData(conn, status: status, contentType: "text/plain; charset=utf-8", data: Data(body.utf8))
    }

    private func sendJSON(_ conn: NWConnection, status: String, body: String) {
        sendData(conn, status: status, contentType: "application/json; charset=utf-8", data: Data(body.utf8))
    }

    private func sendData(_ conn: NWConnection, status: String, contentType: String, data: Data) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var packet = Data(header.utf8)
        packet.append(data)
        conn.send(content: packet, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    static func localIPv4Addresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let up = (flags & IFF_UP) != 0
            let loopback = (flags & IFF_LOOPBACK) != 0
            if up && !loopback, let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: hostname)
                    if !ip.hasPrefix("169.254.") && !result.contains(ip) {
                        result.append(ip)
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return result
    }
}
