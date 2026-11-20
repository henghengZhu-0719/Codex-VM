import Foundation
import AppKit
import Darwin

// SSH forwarding only: the remote host owns its VMs, sessions, browser and files.
struct RemoteHostProfile: Codable, Identifiable {
    var id: String
    var name: String
    var hostname: String
    var username: String
    var sshPort: Int
    var workbenchPort: Int

    static func isValid(_ host: RemoteHostProfile) -> Bool {
        let name = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.count <= 80
            && isValidHost(host.hostname) && isValidUser(host.username)
            && (1...65535).contains(host.sshPort)
            && (1024...65535).contains(host.workbenchPort)
    }

    private static func isValidHost(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253, !s.hasPrefix("-"), !s.contains("..") else { return false }
        let chars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return s.unicodeScalars.allSatisfy { chars.contains($0) }
    }

    private static func isValidUser(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 64, !s.hasPrefix("-") else { return false }
        let chars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        return s.unicodeScalars.allSatisfy { chars.contains($0) }
    }
}

@MainActor
final class RemoteHostConnection {
    private var tunnel: Process?
    private var connectionID = UUID()
    private(set) var activeHostID: String?
    private(set) var localURL: URL?
    private(set) var state = "disconnected"
    var onStatus: ((String) -> Void)?
    var onChange: (() -> Void)?

    private func updateState(_ next: String, _ message: String) {
        state = next
        onStatus?(message)
        onChange?()
    }

    func disconnect() {
        connectionID = UUID()
        let old = tunnel
        tunnel = nil
        activeHostID = nil
        localURL = nil
        old?.terminationHandler = nil
        if old?.isRunning == true { old?.terminate() }
        updateState("disconnected", "未连接")
    }

    func openWorkbench() {
        guard state == "connected", let localURL else { return }
        NSWorkspace.shared.open(localURL)
    }

    func connect(_ host: RemoteHostProfile) {
        disconnect()
        guard RemoteHostProfile.isValid(host) else {
            updateState("error", "远程主机信息无效，请检查主机名、用户名和端口")
            return
        }
        // Only a loopback listener is exposed on the client. The remote workbench
        // always remains on the server's loopback interface.
        guard let port = Self.availableLoopbackPort() else {
            updateState("error", "无法分配本机 SSH 转发端口")
            return
        }
        let endpoint = URL(string: "http://127.0.0.1:\(port)/")!
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-N", "-T",
            "-o", "BatchMode=yes",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ClearAllForwardings=yes",
            "-p", String(host.sshPort),
            "-L", "127.0.0.1:\(port):127.0.0.1:\(host.workbenchPort)",
            "--", "\(host.username)@\(host.hostname)"
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let attemptID = connectionID
        process.terminationHandler = { [weak self] stopped in
            Task { @MainActor [weak self] in
                guard let self, self.connectionID == attemptID, self.tunnel === stopped else { return }
                self.tunnel = nil
                self.activeHostID = nil
                self.localURL = nil
                self.updateState("error", "SSH 已断开（退出码 \(stopped.terminationStatus)）。请检查 EasyTier、SSH 密钥和 known_hosts")
            }
        }
        do {
            try process.run()
            tunnel = process
            activeHostID = host.id
            updateState("connecting", "正在检查 \(host.name) 的 SSH 隧道和远程工作台…")
            Task { [weak self] in
                guard let self else { return }
                var ready = false
                // A 401 is expected without the workbench token: it proves the
                // forwarded endpoint is the authenticated Agent-VM service.
                for _ in 0..<15 {
                    guard self.connectionID == attemptID, process.isRunning else { return }
                    var request = URLRequest(url: endpoint.appendingPathComponent("api/state"))
                    request.timeoutInterval = 2
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    if let (_, response) = try? await URLSession.shared.data(for: request),
                       let http = response as? HTTPURLResponse,
                       http.statusCode == 401 {
                        ready = true
                        break
                    }
                    try? await Task.sleep(nanoseconds: 450_000_000)
                }
                guard self.connectionID == attemptID, self.tunnel === process else { return }
                if ready {
                    self.localURL = endpoint
                    self.updateState("connected", "已连接 \(host.name) · SSH 隧道和远程工作台正常")
                    self.openWorkbench()
                } else {
                    self.disconnect()
                    self.updateState("error", "SSH 隧道未连通远程工作台：确认 Mac Pro 已启用工作台且端口正确")
                }
            }
        } catch {
            updateState("error", "无法启动 SSH：\(error.localizedDescription)")
        }
    }

    private static func availableLoopbackPort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: in_addr_t(0x0100007f))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { return nil }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &size)
            }
        }
        guard status == 0 else { return nil }
        return UInt16(bigEndian: addr.sin_port)
    }
}
