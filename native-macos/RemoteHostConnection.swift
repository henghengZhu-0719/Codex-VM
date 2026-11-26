import Foundation
import AppKit
import Darwin

// SSH forwarding only: the remote host owns its VMs, sessions, browser and files.
struct RemoteHostProfile: Codable, Identifiable, Sendable {
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

struct RemoteVMOption: Sendable {
    let name: String
    let displayName: String
    let status: String
}

struct RemoteVMList: Sendable {
    var loading = false
    var vms: [RemoteVMOption] = []
    var error = ""
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


    nonisolated private static func isValidVMName(_ name: String) -> Bool {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return !name.isEmpty && name.count <= 80 && !name.hasPrefix("-") && name != "." && name != ".."
            && name.unicodeScalars.allSatisfy { safe.contains($0) }
    }

    nonisolated static func listVMs(_ host: RemoteHostProfile) -> RemoteVMList {
        guard RemoteHostProfile.isValid(host) else {
            return RemoteVMList(error: "远程主机信息无效")
        }
        let process = Process()
        let output = Pipe()
        let quotedScript = vmListCommand.replacingOccurrences(of: "'", with: "'\\''")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-T"] + sshOptions(host) + ["/bin/sh -c '\(quotedScript)'"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return RemoteVMList(error: "无法启动 SSH（\(error.localizedDescription)）")
        }

        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard process.terminationReason == .exit else {
            return RemoteVMList(error: "读取远程 VM 超时")
        }
        guard process.terminationStatus == 0, lines.contains("agent-vm-list-end") else {
            let detail = lines.last.map { String($0.prefix(240)) } ?? "SSH 退出码 \(process.terminationStatus)"
            return RemoteVMList(error: "无法加载远程 VM（\(detail)）")
        }

        let aliasPrefix = "agent-vm-aliases "
        let namePrefix = "agent-vm-name "
        let aliasData = lines.first { $0.hasPrefix(aliasPrefix) }.map { Data($0.dropFirst(aliasPrefix.count).utf8) }
        let aliases = aliasData.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        let options: [RemoteVMOption] = lines.compactMap { line in
            guard line.hasPrefix(namePrefix) else { return nil }
            let rest = String(line.dropFirst(namePrefix.count))
            let parts = rest.split(separator: "\t", maxSplits: 1).map(String.init)
            let name = parts[0]
            let status = parts.count > 1 ? parts[1] : "Running"
            guard isValidVMName(name) else { return nil }
            let alias = aliases[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return RemoteVMOption(name: name, displayName: alias.isEmpty ? name : alias, status: status)
        }
        return RemoteVMList(vms: options.sorted { lhs, rhs in
            if lhs.status != rhs.status { return lhs.status == "Running" }
            let order = lhs.displayName.localizedStandardCompare(rhs.displayName)
            return order == .orderedSame ? lhs.name < rhs.name : order == .orderedAscending
        })
    }

    // Start or stop a VM on the remote host via its authenticated local daemon over SSH.
    nonisolated static func changeVM(_ host: RemoteHostProfile, vmName: String, action: String) -> (Bool, String) {
        guard RemoteHostProfile.isValid(host), isValidVMName(vmName), (action == "start" || action == "stop") else {
            return (false, "远程主机、VM 名称或操作无效")
        }
        let script = """
        cli='/Applications/Agent VM.app/Contents/MacOS/agent-vm'
        if [ ! -x "$cli" ]; then cli="$HOME/.local/bin/agent-vm"; fi
        if [ ! -x "$cli" ]; then cli=$(command -v agent-vm) || { echo '远端找不到 agent-vm' >&2; exit 1; }; fi
        "$cli" daemon vm-\(action) '\(vmName)'
        """
        let quoted = script.replacingOccurrences(of: "'", with: "'\\''")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-T"] + sshOptions(host) + ["/bin/sh -c '\(quoted)'"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return (false, "无法启动 SSH：\(error.localizedDescription)")
        }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus == 0 {
            return (true, text)
        }
        return (false, text.isEmpty ? "远程操作失败（退出码 \(process.terminationStatus)）" : String(text.prefix(240)))
    }

    nonisolated private static let vmListCommand = #"""
        cli='/Applications/Agent VM.app/Contents/MacOS/agent-vm'
        if [ ! -x "$cli" ]; then
            cli="$HOME/.local/bin/agent-vm"
        fi
        if [ ! -x "$cli" ]; then
            cli=$(command -v agent-vm) || { printf '%s\n' '远端找不到 agent-vm' >&2; exit 1; }
        fi
        vms=$("$cli" list) || exit $?
        aliases=$(/usr/bin/defaults export org.agentvm.desktop - 2>/dev/null |
            /usr/bin/plutil -extract vmAliases json -o - - 2>/dev/null) || aliases='{}'
        printf 'agent-vm-aliases %s\n' "$aliases"
        printf '%s\n' "$vms" | /usr/bin/awk '
            NR > 1 {
                offset = ($1 == ">")
                name = $(1 + offset)
                status = $(2 + offset)
                if (name != "" && status != "" && name != "base" && name != "base-building")
                    print "agent-vm-name " name "\t" status
            }
        ' || exit $?
        printf '%s\n' 'agent-vm-list-end'
        """#

    nonisolated private static func sshOptions(_ host: RemoteHostProfile) -> [String] {
        ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10",
         "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
         "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
         "-p", String(host.sshPort), "--", "\(host.username)@\(host.hostname)"]
    }

    // Enter a VM on the remote Mac using nested SSH.
    func openVMTerminal(_ host: RemoteHostProfile, vmName: String) {
        guard RemoteHostProfile.isValid(host), Self.isValidVMName(vmName) else {
            updateState("error", "远程主机或 VM 名称无效")
            return
        }
        // Remote SSH starts in the account home; cd explicitly to avoid
        // relying on an interactive login shell's working directory.
        let remoteCommand = "cd && exec /usr/bin/ssh -F .agent-vm/lima/" + vmName +
            "/ssh.config -o ForwardAgent=no -o ForwardX11=no -tt lima-" + vmName
        let command = (["exec", "/usr/bin/ssh", "-tt"] + Self.sshOptions(host) + ["'\(remoteCommand)'"]).joined(separator: " ")
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "agent-vm-remote-terminal-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let script = directory.appendingPathComponent("Connect.command")
            let contents = "#!/bin/sh\nrm -f -- \"$0\"\nrmdir -- \"$(dirname -- \"$0\")\" 2>/dev/null || true\n" +
                command + "\n"
            try contents.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open([script],
                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                    if let error {
                        try? FileManager.default.removeItem(at: directory)
                        Task { @MainActor [weak self] in
                            self?.updateState("error", "无法打开终端：\(error.localizedDescription)")
                        }
                    }
                }
            updateState("disconnected", "已打开 \(host.name) / \(vmName) 的终端，连接结果请查看 Terminal")
        } catch {
            updateState("error", "无法准备远程终端：\(error.localizedDescription)")
        }
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
