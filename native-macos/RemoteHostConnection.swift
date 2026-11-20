import Foundation
import AppKit

// A lightweight SSH tunnel to an existing Agent-VM workbench on another Mac.
// VM processes, sessions and browser profiles remain on the remote host.
struct RemoteHostProfile: Codable, Identifiable {
    var id: String
    var name: String
    var hostname: String
    var username: String
    var sshPort: Int
    var workbenchPort: Int
}

@MainActor
final class RemoteHostConnection {
    private var tunnel: Process?
    private(set) var activeHostID: String?
    var onStatus: ((String) -> Void)?

    func disconnect() {
        tunnel?.terminationHandler = nil
        if tunnel?.isRunning == true { tunnel?.terminate() }
        tunnel = nil
        activeHostID = nil
        onStatus?("未连接")
    }

    func connect(_ host: RemoteHostProfile) {
        disconnect()
        guard Self.isValidHost(host.hostname), Self.isValidUser(host.username),
              (1...65535).contains(host.sshPort),
              (1024...65535).contains(host.workbenchPort) else {
            onStatus?("主机配置无效")
            return
        }
        let localPort = UInt16.random(in: 20000...60000)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // Never disable host key verification, password prompts or SSH security checks.
        process.arguments = [
            "-N", "-T", "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-p", String(host.sshPort),
            "-L", "127.0.0.1:\(localPort):127.0.0.1:\(host.workbenchPort)",
            "--", "\(host.username)@\(host.hostname)"
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self, self.tunnel === process else { return }
                self.tunnel = nil
                self.activeHostID = nil
                self.onStatus?("SSH 连接已断开，请检查 SSH 密钥、known_hosts 和 EasyTier 网络")
            }
        }
        do {
            try process.run()
            tunnel = process
            activeHostID = host.id
            onStatus?("正在连接 \(host.name)…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.tunnel === process, process.isRunning else { return }
                self.onStatus?("已建立 SSH 隧道 · \(host.name)")
                guard let url = URL(string: "http://127.0.0.1:\(localPort)/") else { return }
                NSWorkspace.shared.open(url)
            }
        } catch {
            onStatus?("无法启动 SSH：\(error.localizedDescription)")
        }
    }

    private static func isValidHost(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253, !s.hasPrefix("-") else { return false }
        return s.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:").contains($0)
        }
    }

    private static func isValidUser(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 64, !s.hasPrefix("-") else { return false }
        return s.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-").contains($0)
        }
    }
}
