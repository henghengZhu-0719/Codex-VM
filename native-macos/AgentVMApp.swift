import SwiftUI
import AppKit

final class CapturedData: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()
    func set(_ data: Data) { lock.lock(); value = data; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return value }
}

struct ProjectMount: Decodable, Identifiable {
    let location: String
    let mountPoint: String?
    let writable: Bool
    var id: String { location }
    var guestPath: String { (mountPoint?.isEmpty == false ? mountPoint : nil) ?? location }
}

struct VM: Identifiable {
    let name: String, status: String, ssh: String, vmType: String, arch: String, cpus: String, memory: String, disk: String
    var id: String { name }
}

struct ManagedFolder: Identifiable {
    let path: String, mode: String
    var id: String { path + ":" + mode }
}

struct CodexWindowQuota: Codable {
    let usedPercent: Int
    let resetAfterSeconds: Int?
    let resetAt: Int64?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }

    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }
}

struct CodexQuotaStatus: Decodable {
    let status: String
    let planType: String?
    let fiveHour: CodexWindowQuota?
    let weekly: CodexWindowQuota?
    let error: String?
    let fetchedAt: Date?

    enum CodingKeys: String, CodingKey {
        case status, error
        case planType = "plan_type"
        case fiveHour = "five_hour"
        case weekly
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        planType = try c.decodeIfPresent(String.self, forKey: .planType)
        fiveHour = try c.decodeIfPresent(CodexWindowQuota.self, forKey: .fiveHour)
        weekly = try c.decodeIfPresent(CodexWindowQuota.self, forKey: .weekly)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        fetchedAt = Date()
    }

    init(status: String, planType: String? = nil, fiveHour: CodexWindowQuota? = nil, weekly: CodexWindowQuota? = nil, error: String? = nil, fetchedAt: Date? = Date()) {
        self.status = status
        self.planType = planType
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.error = error
        self.fetchedAt = fetchedAt
    }
}

@MainActor final class Model: ObservableObject {
    @Published var machines: [VM] = []
    @Published var vmMounts: [String: [ProjectMount]] = [:]
    @Published var managedFolders: [String: [ManagedFolder]] = [:]
    @Published var output = ""
    @Published var busy = false
    @Published var project = ""
    @Published var includeCodeServer = false
    @Published var rebuildBase = false
    @Published var reusedBase = false
    @Published var useProxy = UserDefaults.standard.object(forKey: "useProxy") as? Bool ?? true
    @Published var step = 0
    @Published var memory = 3
    @Published var cpus = 1
    @Published var disk = 10
    @Published var operationFailed = false
    @Published var confirmation = false
    @Published var buildStarted = false
    @Published var buildStage = 0
    @Published var buildComplete = false
    @Published var syncRegion = UserDefaults.standard.object(forKey: "syncRegion") as? Bool ?? true
    @Published var regionMessage = ""
    @Published var proxyStatus: ProxyStatusResponse?
    @Published var proxyBusy = false
    @Published var proxyMessage = ""
    @Published var proxyError = ""
    @Published var nodeDelays: [String: String] = [:]
    @Published var proxyConnections: [ProxyConnectionItem] = []
    @Published var proxyUploadTotal: Int64 = 0
    @Published var proxyDownloadTotal: Int64 = 0
    @Published var vmAliases: [String: String] = UserDefaults.standard.dictionary(forKey: "vmAliases") as? [String: String] ?? [:]
    @Published var vmQuotas: [String: CodexQuotaStatus] = [:]
    @Published var quotaPolling: Set<String> = []
    @Published var lastQuotaPollAt: Date?
    private var quotaTimer: Timer?
    let executable: String

    init() {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agent-vm").path
        executable = ProcessInfo.processInfo.environment["AGENT_VM_BINARY"] ?? (FileManager.default.isExecutableFile(atPath: bundled) ? bundled : Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("bin/agent-vm").path)
        refresh()
        refreshProxyStatus()
        quotaTimer = Timer.scheduledTimer(withTimeInterval: 20 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollAllRunningQuotas()
            }
        }
    }
    func run(_ arguments: [String], cwd: String? = nil, input: String? = nil, progress: ((String) -> Void)? = nil, completion: @escaping (Int32, String) -> Void) {
        let path = executable
        var environment = ProcessInfo.processInfo.environment
        let activeUseProxy = proxyStatus?.useProxy ?? useProxy
        let proxyMode = proxyStatus?.proxyMode ?? "custom"
        let managedMode = activeUseProxy && (proxyMode == "mihomo" || (proxyStatus?.managedEnabled ?? false))
        let customEndpoint = proxyStatus?.customProxyUrl ?? "http://10.126.126.1:8787"
        let legacyEnvProxy = (activeUseProxy && !managedMode && proxyMode == "custom") ? customEndpoint : ""
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] {
            environment[key] = legacyEnvProxy
        }
        environment["ALL_PROXY"] = ""; environment["all_proxy"] = ""
        if !legacyEnvProxy.isEmpty {
            environment["NO_PROXY"] = "localhost,127.0.0.1,::1"
            environment["no_proxy"] = "localhost,127.0.0.1,::1"
        }
        if arguments.first != "proxy", managedMode, let st = proxyStatus, !st.managedConfigPath.isEmpty {
            environment["AGENT_VM_MANAGED_NETWORK_CONFIG"] = st.managedConfigPath
        } else {
            environment.removeValue(forKey: "AGENT_VM_MANAGED_NETWORK_CONFIG")
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process(); let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.environment = environment
            if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            process.standardOutput = pipe
            let errorPipe = Pipe()
            process.standardError = errorPipe
            let stdin = Pipe()
            process.standardInput = input == nil ? FileHandle.nullDevice : stdin
            do {
                try process.run()
                let errors = CapturedData()
                let drained = DispatchGroup()
                drained.enter()
                DispatchQueue.global().async {
                    errors.set(errorPipe.fileHandleForReading.readDataToEndOfFile())
                    drained.leave()
                }
                if let input {
                    try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                    try stdin.fileHandleForWriting.close()
                }
                var data = Data()
                var recent = ""
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    data.append(chunk)
                    if let progress, let text = String(data: chunk, encoding: .utf8) {
                        recent = String((recent + text).suffix(1024))
                        let snapshot = recent
                        DispatchQueue.main.async { progress(snapshot) }
                    }
                }
                process.waitUntilExit()
                drained.wait()
                var text = String(data: data, encoding: .utf8) ?? ""
                if process.terminationStatus != 0 { text += String(data: errors.get(), encoding: .utf8) ?? "" }
                DispatchQueue.main.async { completion(process.terminationStatus, text) }
            } catch { DispatchQueue.main.async { completion(1, error.localizedDescription) } }
        }
    }
    func saveNetworkSettings() -> Bool {
        do {
            let state = ProcessInfo.processInfo.environment["AGENT_VM_STATE_DIR"] ?? NSHomeDirectory() + "/.agent-vm"
            let directory = URL(fileURLWithPath: state)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("network")
            let existing = FileManager.default.fileExists(atPath: file.path) ? try String(contentsOf: file, encoding: .utf8) : ""
            let marker = " # Agent VM HTTP proxy"
            var lines = existing.components(separatedBy: .newlines).filter { !$0.hasSuffix(marker) }
            while lines.last == "" { lines.removeLast() }
            let proxyMode = proxyStatus?.proxyMode ?? "custom"
            let customURL = proxyStatus?.customProxyUrl ?? "http://10.126.126.1:8787"
            if useProxy && proxyMode == "custom", let u = URL(string: customURL), let host = u.host, let port = u.port {
                lines.append("allow \(host):\(port)\(marker)")
            }
            let updated = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
            if updated != existing { try updated.write(to: file, atomically: true, encoding: .utf8) }
            UserDefaults.standard.set(useProxy, forKey: "useProxy")
            return true
        } catch {
            output = "无法保存网络设置：\(error.localizedDescription)"
            operationFailed = true
            return false
        }
    }
    func prepareSharedFolder() -> Bool {
        do {
            let state = ProcessInfo.processInfo.environment["AGENT_VM_STATE_DIR"] ?? NSHomeDirectory() + "/.agent-vm"
            let directory = URL(fileURLWithPath: state)
            let shared = NSHomeDirectory() + "/AgentVM-Shared"
            guard shared.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  shared.rangeOfCharacter(from: CharacterSet(charactersIn: ":#\"\\|")) == nil else {
                throw NSError(domain: "AgentVM", code: 1, userInfo: [NSLocalizedDescriptionKey: "共享文件夹的路径包含不支持的字符。"])
            }
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: shared), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("volumes")
            let existing = FileManager.default.fileExists(atPath: file.path) ? try String(contentsOf: file, encoding: .utf8) : ""
            let rule = "\(shared):/mnt/agent-vm-shared:rw # Agent VM shared folder"
            if !existing.components(separatedBy: .newlines).contains(rule) {
                let updated = existing + (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n") + rule + "\n"
                try updated.write(to: file, atomically: true, encoding: .utf8)
            }
            return true
        } catch {
            output = "无法准备共享文件夹：\(error.localizedDescription)"
            operationFailed = true
            return false
        }
    }
    func updateRegion(project: String, completion: @escaping () -> Void) {
        let enabled = syncRegion
        let activeUseProxy = proxyStatus?.useProxy ?? useProxy
        let proxyMode = proxyStatus?.proxyMode ?? "custom"
        let managedMode = activeUseProxy && (proxyMode == "mihomo" || (proxyStatus?.managedEnabled ?? false))
        let customEndpoint = proxyStatus?.customProxyUrl ?? "http://10.126.126.1:8787"
        let proxy = (activeUseProxy && !managedMode && proxyMode == "custom") ? customEndpoint : ""
        let script: String
        if enabled {
            script = "printf '%s\\n' 'HTTPS_PROXY=" + proxy + "' 'https_proxy=" + proxy + "' 'HTTP_PROXY=" + proxy + "' 'http_proxy=" + proxy + "' | sudo tee /etc/default/agent-vm-region >/dev/null\n" + Self.regionInstaller
        } else {
            script = "if systemctl list-unit-files --no-legend agent-vm-region.timer | grep -q '^agent-vm-region.timer'; then sudo systemctl disable --now agent-vm-region.timer; fi"
        }
        run(["run", "sh", "-c", script], cwd: project) { code, text in
            if enabled && code != 0 {
                self.regionMessage = "地区同步未完成：无法查询出口或设置时区、语言；现有设置可能未改变，请检查网络后重试。"
            } else if enabled, let range = text.range(of: "AGENT_VM_REGION:", options: .backwards) {
                let value = text[range.upperBound...].components(separatedBy: .newlines).first ?? ""
                self.regionMessage = "出口地区已同步：" + value
            } else if !enabled && code != 0 { self.regionMessage = "无法关闭自动地区同步，请检查虚拟机设置。" }
            else { self.regionMessage = enabled ? "地区同步结果暂不可用。" : "已关闭自动地区同步。" }
            completion()
        }
    }
    private static let regionInstaller = #"""
set -eu
sudo install -d -m 0755 /usr/local/lib/agent-vm
sudo tee /usr/local/lib/agent-vm/region-sync >/dev/null <<'REGION_HELPER'
#!/bin/sh
set -eu
response=$(curl -fsS --max-time 12 https://ipwho.is/)
printf '%s' "$response" | jq -e '.success == true' >/dev/null
country=$(printf '%s' "$response" | jq -r '.country_code // empty')
zone=$(printf '%s' "$response" | jq -r '.timezone.id // empty')
ip=$(printf '%s' "$response" | jq -r '.ip // empty')
case "$country" in [A-Z][A-Z]) ;; *) exit 1;; esac
case "$zone" in ''|/*|*..*|*[!A-Za-z0-9_+./-]*) exit 1;; esac
[ -f "/usr/share/zoneinfo/$zone" ] || exit 1
case "$country" in
 US) preferred=en_US;; GB) preferred=en_GB;; CN) preferred=zh_CN;; HK) preferred=zh_HK;; TW) preferred=zh_TW;; SG) preferred=en_SG;; JP) preferred=ja_JP;; KR) preferred=ko_KR;; *) preferred=;;
esac
locale_name=$(awk -v country="$country" -v preferred="$preferred" '
 $2 == "UTF-8" && $1 ~ ("^[A-Za-z]+_" country "\\.UTF-8$") {
  if (!fallback) fallback=$1
  if ($1 == preferred ".UTF-8") selected=$1
 }
 END {if (selected) print selected; else if (fallback) print fallback}
' /usr/share/i18n/SUPPORTED)
[ -n "$locale_name" ] || exit 1
normalized=$(printf '%s' "$locale_name" | tr '[:upper:]' '[:lower:]' | tr -d '-')
if ! locale -a | tr '[:upper:]' '[:lower:]' | grep -Fx "$normalized" >/dev/null; then
 localedef -i "${locale_name%.UTF-8}" -f UTF-8 "$locale_name"
fi
[ "$(timedatectl show -p Timezone --value)" = "$zone" ] || timedatectl set-timezone "$zone"
if ! grep -Fx "LANG=$locale_name" /etc/default/locale >/dev/null 2>&1 && ! grep -Fx "LANG=\"$locale_name\"" /etc/default/locale >/dev/null 2>&1; then
 update-locale --reset "LANG=$locale_name"
fi
install -d -m 0755 /var/lib/agent-vm-region
printf '%s %s %s %s\n' "$ip" "$country" "$zone" "$locale_name" > /var/lib/agent-vm-region/status
REGION_HELPER
sudo chmod 0755 /usr/local/lib/agent-vm/region-sync
sudo tee /etc/systemd/system/agent-vm-region.service >/dev/null <<'REGION_SERVICE'
[Unit]
Description=Synchronize VM region with its egress IP
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
EnvironmentFile=-/etc/default/agent-vm-region
ExecStart=/usr/local/lib/agent-vm/region-sync
TimeoutStartSec=45
REGION_SERVICE
sudo tee /etc/systemd/system/agent-vm-region.timer >/dev/null <<'REGION_TIMER'
[Unit]
Description=Periodically synchronize VM region
[Timer]
OnBootSec=45s
OnUnitActiveSec=15min
Unit=agent-vm-region.service
[Install]
WantedBy=timers.target
REGION_TIMER
sudo systemctl daemon-reload
sudo systemctl enable --now agent-vm-region.timer >/dev/null
sudo systemctl start agent-vm-region.service
printf 'AGENT_VM_REGION:'
cat /var/lib/agent-vm-region/status
"""#
    func setup() {
        buildStarted = true
        regionMessage = ""
        buildComplete = false
        buildStage = 0
        operationFailed = false
        let selectedProject = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedProject.isEmpty else { output = "请选择项目文件夹。"; operationFailed = true; return }
        guard saveNetworkSettings(), prepareSharedFolder() else { return }
        if includeCodeServer && memory < 4 { memory = 4 }
        busy = true
        reusedBase = false
        output = "正在检查基础环境…\n"
        run(["info", selectedProject]) { code, info in
            guard code == 0 else { self.output = info; self.operationFailed = true; self.busy = false; return }
            let fields = Set(info.components(separatedBy: .newlines))
            guard fields.contains("base_exists=1") || fields.contains("base_exists=0") else {
                self.output = "无法确认基础模板状态，请运行 agent-vm doctor 检查。\n" + info
                self.operationFailed = true; self.busy = false; return
            }
            let startProject = {
            self.buildStage = 3
            let options = fields.contains("vm_exists=0") ? ["--memory", String(self.memory), "--cpus", String(self.cpus), "--disk", String(self.disk)] : []
            self.run(options + ["run", "true"], cwd: selectedProject) { startCode, startText in
                self.output += startText
                self.operationFailed = startCode != 0
                guard startCode == 0 else { self.busy = false; self.refresh(); return }
                self.updateRegion(project: selectedProject) {
                    self.buildComplete = true
                    self.rebuildBase = false
                    self.busy = false
                    self.refresh()
                }
            }
            }
            if fields.contains("base_exists=1") && !self.rebuildBase {
                self.reusedBase = true
                self.output = "使用已有基础模板。\n"
                startProject()
                return
            }
            var packages = ["codex"]
            if self.includeCodeServer { packages.append("code-server") }
            let args = ["setup", "--preinstall=" + packages.joined(separator: ","), "--memory", String(self.memory), "--cpus", String(self.cpus), "--disk", String(self.disk)]
            self.run(args, progress: { text in
                if text.contains("Installing packages inside VM") { self.buildStage = max(self.buildStage, 2) }
                else if text.contains("Starting base VM") { self.buildStage = max(self.buildStage, 1) }
            }) { code, text in
                self.output = text
                self.operationFailed = code != 0
                guard code == 0 else { self.busy = false; self.refresh(); return }
                startProject()
            }
        }
    }
    func refresh() {
        run(["list"]) { code, text in
            guard code == 0 else { self.output = text; return }
            self.machines = text.components(separatedBy: .newlines).dropFirst().compactMap { line in
                let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0 != ">" }
                guard parts.count >= 8 else { return nil }
                return VM(name: parts[0], status: parts[1], ssh: parts[2], vmType: parts[3], arch: parts[4], cpus: parts[5], memory: parts[6], disk: parts[7])
            }
            for vm in self.machines {
                self.run(["vm-mounts", vm.name]) { code, text in
                    if code == 0, let data = text.data(using: .utf8), let mounts = try? JSONDecoder().decode([ProjectMount]?.self, from: data) {
                        self.vmMounts[vm.name] = mounts
                    }
                }
                if vm.status == "Running", vm.name != "base", vm.name != "base-building", self.vmQuotas[vm.name] == nil {
                    self.pollQuota(for: vm)
                }
            }
            self.refreshManagedFolders()
        }
    }
    func refreshManagedFolders() {
        let state = ProcessInfo.processInfo.environment["AGENT_VM_STATE_DIR"] ?? NSHomeDirectory() + "/.agent-vm"
        let content = (try? String(contentsOfFile: state + "/volumes", encoding: .utf8)) ?? ""
        var folders: [String: [ManagedFolder]] = [:]
        for line in content.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: " # Agent VM ")
            guard parts.count == 2 else { continue }
            let fields = parts[0].components(separatedBy: ":")
            guard fields.count == 4, fields[1].isEmpty, ["ro", "rw"].contains(fields[2]) else { continue }
            folders[parts[1], default: []].append(ManagedFolder(path: fields[0], mode: fields[2]))
        }
        managedFolders = folders
    }
    func terminal(_ vm: VM) {
        let state = ProcessInfo.processInfo.environment["AGENT_VM_STATE_DIR"] ?? NSHomeDirectory() + "/.agent-vm"
        let lima = ProcessInfo.processInfo.environment["AGENT_VM_LIMA_HOME"] ?? state + "/lima"
        let config = URL(fileURLWithPath: lima).appendingPathComponent(vm.name).appendingPathComponent("ssh.config").path
        guard FileManager.default.fileExists(atPath: config) else {
            output = "找不到该虚拟机的 SSH 配置，请启动虚拟机后刷新。"
            return
        }
        func quote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-vm-terminal-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let script = directory.appendingPathComponent("Connect.command")
            var command = "exec /usr/bin/ssh -F \(quote(config)) -o ForwardAgent=no -o ForwardX11=no -tt \(quote("lima-" + vm.name))"
            if let projectPath = vmMounts[vm.name]?.first?.guestPath {
                let remote = "cd -- " + quote(projectPath) + " && exec \"$SHELL\" -l"
                command += " " + quote(remote)
            }
            let contents = "#!/bin/sh\nrm -f -- \"$0\"\nrmdir -- \"$(dirname -- \"$0\")\" 2>/dev/null || true\n" + command + "\n"
            try contents.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    try? FileManager.default.removeItem(at: directory)
                    DispatchQueue.main.async { self.output = "无法打开终端：\(error.localizedDescription)"; self.operationFailed = true }
                }
            }
        } catch {
            output = "无法准备终端连接：\(error.localizedDescription)"
            operationFailed = true
        }
    }
    func remove(_ vm: VM) {
        busy = true
        run(["rm", vm.name]) { code, text in
            self.output = text
            self.operationFailed = code != 0
            self.busy = false
            self.refresh()
        }
    }
    func stop(_ vm: VM) {
        busy = true
        run(["stop", vm.name]) { code, text in self.output = text; self.operationFailed = code != 0; self.busy = false; self.refresh() }
    }
    func chooseProject() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK { project = panel.url?.path ?? "" }
    }
    func start(_ vm: VM) {
        guard let project = vmMounts[vm.name]?.first?.location else {
            output = "无法确定该虚拟机的项目文件夹。"; operationFailed = true; return
        }
        guard saveNetworkSettings(), prepareSharedFolder() else { return }
        busy = true
        regionMessage = ""
        output = "正在启动项目虚拟机…\n"
        run(["name", project]) { code, name in
            guard code == 0, name.trimmingCharacters(in: .whitespacesAndNewlines) == vm.name else {
                self.output = "项目文件夹与虚拟机身份不匹配，无法启动。\n" + name
                self.operationFailed = true; self.busy = false; return
            }
            self.run(["run", "true"], cwd: project) { code, text in
                self.output = text
                self.operationFailed = code != 0
                guard code == 0 else { self.busy = false; self.refresh(); return }
                self.updateRegion(project: project) {
                    self.busy = false
                    self.refresh()
                }
            }
        }
    }
    func changeFolder(_ vm: VM, action: String, path: String, mode: String) {
        guard !busy else { return }
        busy = true
        run(["vm-volume", action, vm.name, path, mode]) { code, text in
            self.busy = false
            self.operationFailed = code != 0
            self.output = text
            self.refreshManagedFolders()
        }
    }
    func addFolder(_ vm: VM, writable: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let path = panel.url?.path {
            changeFolder(vm, action: "add", path: path, mode: writable ? "rw" : "ro")
        }
    }
    func doctor() {
        busy = true
        output = "正在检查环境…\n"
        run(["doctor"]) { code, text in
            self.output = text
            self.operationFailed = code != 0
            self.busy = false
        }
    }
    var errorSummary: String {
        let lines = output.components(separatedBy: .newlines).filter {
            let lower = $0.lowercased()
            return lower.contains("error:") || lower.contains("failed") || lower.contains("错误") || lower.contains("无法")
        }
        let summary = lines.suffix(3).joined(separator: "\n")
        return summary.isEmpty ? String(output.suffix(500)) : String(summary.suffix(500))
    }
    func clearOutput() {
        output = ""
        operationFailed = false
    }

    private func runProxyStatusCommand(_ arguments: [String], payload: [String: Any]? = nil, message: String? = nil, completion: (() -> Void)? = nil) {
        var jsonInput: String? = nil
        if let payload {
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let text = String(data: data, encoding: .utf8) else {
                proxyError = "无法编码请求参数"
                return
            }
            jsonInput = text
        }
        proxyBusy = true
        proxyError = ""
        if let message { proxyMessage = message }
        run(["proxy"] + arguments, input: jsonInput) { code, text in
            self.proxyBusy = false
            guard code == 0 else {
                self.proxyError = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return
            }
            if let data = text.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(ProxyStatusResponse.self, from: data) {
                self.proxyStatus = decoded
                self.useProxy = decoded.useProxy
                UserDefaults.standard.set(decoded.useProxy, forKey: "useProxy")
            }
            if message == nil { self.proxyMessage = "" }
            completion?()
        }
    }

    func refreshProxyStatus(completion: (() -> Void)? = nil) {
        runProxyStatusCommand(["status"], completion: completion)
    }

    func saveProxyConfig(proxyMode: String, managedEnabled: Bool, useProxy: Bool, customProxyURL: String, dnsURL: String, port: Int, completion: (() -> Void)? = nil) {
        let payload: [String: Any] = [
            "proxy_mode": proxyMode,
            "managed_enabled": managedEnabled,
            "use_proxy": useProxy,
            "custom_proxy_url": customProxyURL,
            "dns_url": dnsURL,
            "port": port
        ]
        runProxyStatusCommand(["config"], payload: payload, message: "网关配置已保存并同步", completion: completion)
    }

    func importProxySource(name: String, url: String, content: String, interval: Int, hostDownload: Bool, completion: (() -> Void)? = nil) {
        let payload: [String: Any] = [
            "name": name,
            "url": url,
            "content": content,
            "interval_hours": interval,
            "host_download": hostDownload
        ]
        runProxyStatusCommand(["import"], payload: payload, message: "节点来源已导入", completion: completion)
    }

    func addManualNode(name: String, type: String, server: String, port: Int, username: String, password: String, uuid: String, cipher: String, sni: String, tls: Bool, skipCertVerify: Bool, completion: (() -> Void)? = nil) {
        let payload: [String: Any] = [
            "source_name": "手动节点",
            "name": name,
            "type": type,
            "server": server,
            "port": port,
            "username": username,
            "password": password,
            "uuid": uuid,
            "cipher": cipher,
            "sni": sni,
            "tls": tls,
            "skip_cert_verify": skipCertVerify
        ]
        runProxyStatusCommand(["manual"], payload: payload, message: "手动节点已添加", completion: completion)
    }

    func refreshSubscription(id: String, hostDownload: Bool, completion: (() -> Void)? = nil) {
        var args = ["refresh", id]
        if hostDownload { args.append("--host") }
        runProxyStatusCommand(args, message: "订阅已更新", completion: completion)
    }

    func deleteSource(id: String, completion: (() -> Void)? = nil) {
        runProxyStatusCommand(["delete", id], message: "订阅来源已删除", completion: completion)
    }

    func applyProxyRoute(route: [String], port: Int, completion: (() -> Void)? = nil) {
        let payload: [String: Any] = [
            "route": route,
            "selected": route.last ?? "",
            "port": port
        ]
        runProxyStatusCommand(["apply"], payload: payload, message: "Mihomo 核心已应用并启动", completion: completion)
    }

    func stopProxyCore(completion: (() -> Void)? = nil) {
        runProxyStatusCommand(["stop"], message: "Mihomo 核心及门禁已停止", completion: completion)
    }

    func measureDelay(nodeID: String?) {
        proxyBusy = true
        proxyError = ""
        proxyMessage = nodeID == nil ? "正在测速全部节点…" : "正在测速节点…"
        let args = nodeID.map { ["proxy", "delay", $0] } ?? ["proxy", "delay"]
        run(args) { code, text in
            self.proxyBusy = false
            guard code == 0, let data = text.data(using: .utf8),
                  let res = try? JSONDecoder().decode(ProxyDelayResponse.self, from: data) else {
                self.proxyError = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return
            }
            for (id, ms) in res.delays ?? [:] {
                self.nodeDelays[id] = ms > 0 ? "\(ms) ms" : "超时"
            }
            for (id, _) in res.errors ?? [:] {
                self.nodeDelays[id] = "失败"
            }
            self.proxyMessage = "测速完成"
        }
    }

    func runGateProbe() {
        proxyBusy = true
        proxyError = ""
        proxyMessage = "正在通过代理隧道与 DoH 执行安全自检…"
        run(["proxy", "probe"]) { code, text in
            self.proxyBusy = false
            if code != 0 && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.proxyError = "安全自检失败"
                return
            }
            if let data = text.data(using: .utf8),
               let result = try? JSONDecoder().decode(ProbeResultItem.self, from: data) {
                if let err = result.error, !err.isEmpty {
                    self.proxyError = err
                } else {
                    self.proxyMessage = result.exitIp.map { "自检完成，当前出口 IP：\($0)" } ?? "自检完成，请查看门禁检查详情"
                }
            } else if code != 0 {
                self.proxyError = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            self.refreshProxyStatus()
        }
    }

    func closeGate() {
        proxyBusy = true
        proxyError = ""
        run(["proxy", "gate-close"]) { code, text in
            self.proxyBusy = false
            if code != 0 {
                self.proxyError = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return
            }
            self.proxyMessage = "已撤销全部托管连接门禁"
            self.refreshProxyStatus()
        }
    }

    func refreshConnections() {
        run(["proxy", "connections"]) { code, text in
            guard code == 0, let data = text.data(using: .utf8),
                  let snap = try? JSONDecoder().decode(ConnectionsSnapshotItem.self, from: data) else {
                return
            }
            self.proxyUploadTotal = snap.uploadTotal
            self.proxyDownloadTotal = snap.downloadTotal
            self.proxyConnections = snap.connections ?? []
        }
    }

    func displayName(for vm: VM) -> String {
        if vm.name == "base" { return "基础模板" }
        if vm.name == "base-building" { return "基础环境构建机" }
        if let custom = vmAliases[vm.name]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        return vm.name
    }

    func renameVM(_ vm: VM, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == vm.name {
            vmAliases.removeValue(forKey: vm.name)
        } else {
            vmAliases[vm.name] = trimmed
        }
        UserDefaults.standard.set(vmAliases, forKey: "vmAliases")
    }

    func pollAllRunningQuotas() {
        for vm in machines where vm.status == "Running" && vm.name != "base" && vm.name != "base-building" {
            pollQuota(for: vm)
        }
    }

    func pollQuota(for vm: VM) {
        guard vm.status == "Running", vm.name != "base", vm.name != "base-building" else { return }
        guard !quotaPolling.contains(vm.name) else { return }
        let state = ProcessInfo.processInfo.environment["AGENT_VM_STATE_DIR"] ?? NSHomeDirectory() + "/.agent-vm"
        let lima = ProcessInfo.processInfo.environment["AGENT_VM_LIMA_HOME"] ?? state + "/lima"
        let config = URL(fileURLWithPath: lima).appendingPathComponent(vm.name).appendingPathComponent("ssh.config").path
        guard FileManager.default.fileExists(atPath: config) else { return }

        quotaPolling.insert(vm.name)
        let vmName = vm.name
        let script = """
import json, os, urllib.error, urllib.request
p = os.path.expanduser("~/.codex/auth.json")
if not os.path.exists(p):
    print(json.dumps({"status": "not_logged_in"}))
    raise SystemExit(0)
try:
    d = json.load(open(p))
    tok = d.get("tokens", {}).get("access_token", "")
    acc = d.get("tokens", {}).get("account_id", "")
    if not tok:
        print(json.dumps({"status": "not_logged_in"}))
        raise SystemExit(0)
    req = urllib.request.Request("https://chatgpt.com/backend-api/wham/usage", headers={
        "Authorization": "Bearer " + tok,
        "ChatGPT-Account-Id": acc,
        "Accept": "application/json",
        "User-Agent": "codex-cli/0.169.0",
    })
    with urllib.request.urlopen(req, timeout=12) as r:
        u = json.loads(r.read().decode())
    rl = u.get("rate_limit", {})
    print(json.dumps({
        "status": "ok",
        "plan_type": u.get("plan_type"),
        "five_hour": rl.get("primary_window"),
        "weekly": rl.get("secondary_window"),
    }))
except urllib.error.HTTPError as e:
    if e.code in (401, 403):
        print(json.dumps({"status": "unauthorized", "error": f"Codex 登录已过期 (HTTP {e.code})"}))
    else:
        print(json.dumps({"status": "error", "error": f"HTTP {e.code}"}))
except Exception as e:
    print(json.dumps({"status": "error", "error": str(e)[:120]}))
"""
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()
            let inPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-F", config,
                "-o", "ForwardAgent=no",
                "-o", "ForwardX11=no",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                "lima-" + vmName,
                "python3", "-"
            ]
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = inPipe
            var result = CodexQuotaStatus(status: "error", error: "连接失败")
            do {
                try process.run()
                try inPipe.fileHandleForWriting.write(contentsOf: Data(script.utf8))
                try inPipe.fileHandleForWriting.close()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0,
                   let line = (String(data: data, encoding: .utf8) ?? "").components(separatedBy: .newlines).last(where: { $0.contains("{") }),
                   let jsonData = line.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(CodexQuotaStatus.self, from: jsonData) {
                    result = decoded
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = (String(data: errData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    result = CodexQuotaStatus(status: "error", error: errMsg.isEmpty ? "无法查询 Codex 额度" : String(errMsg.prefix(120)))
                }
            } catch {
                result = CodexQuotaStatus(status: "error", error: error.localizedDescription)
            }
            DispatchQueue.main.async {
                self.quotaPolling.remove(vmName)
                self.vmQuotas[vmName] = result
                self.lastQuotaPollAt = Date()
            }
        }
    }
}

private enum AgentTheme {
    static let accent = Color(red: 0.14, green: 0.31, blue: 0.22)
    static let panel = Color(nsColor: .controlBackgroundColor)
}

private struct StatusBadge: View {
    let status: String
    var body: some View {
        let running = status == "Running"
        Text(running ? "运行中" : status == "Stopped" ? "已停止" : status)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((running ? Color.green : Color.secondary).opacity(0.18), in: Capsule())
            .foregroundStyle(running ? .green : .secondary)
    }
}

struct MachineRow: View {
    let vm: VM
    @ObservedObject var model: Model
    @State private var deleting = false
    @State private var managingFolders = false
    @State private var showDetails = false
    @State private var renaming = false
    @State private var renameDraft = ""
    @AppStorage("showVMDetails") private var showVMDetails = false
    private var isBase: Bool { vm.name == "base" || vm.name == "base-building" }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isBase ? "internaldrive" : "desktopcomputer")
                    .font(.title3).foregroundStyle(AgentTheme.accent).frame(width: 34, height: 34)
                    .background(AgentTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(model.displayName(for: vm)).font(.headline)
                        if !isBase {
                            Button {
                                renameDraft = model.vmAliases[vm.name] ?? ""
                                renaming = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("修改虚拟机显示名称")
                            .popover(isPresented: $renaming) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("修改虚拟机名称").font(.headline)
                                    Text("实例 ID：\(vm.name)").font(.caption).foregroundStyle(.secondary)
                                    TextField("输入自定义名称", text: $renameDraft)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 240)
                                    HStack {
                                        Button("恢复默认") {
                                            model.renameVM(vm, to: "")
                                            renaming = false
                                        }
                                        Spacer()
                                        Button("取消") { renaming = false }
                                        Button("保存") {
                                            model.renameVM(vm, to: renameDraft)
                                            renaming = false
                                        }
                                        .buttonStyle(.borderedProminent)
                                    }
                                }
                                .padding(14)
                            }
                        }
                        StatusBadge(status: vm.status)
                    }
                    if !isBase, let alias = model.vmAliases[vm.name], !alias.isEmpty {
                        Text("项目虚拟机 · 实例 \(vm.name)").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(isBase ? "用于创建项目虚拟机" : "项目虚拟机")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(showDetails ? "收起详情" : "查看详情") { showDetails.toggle() }
                    .buttonStyle(.borderless).disabled(showVMDetails)
            }
            HStack(alignment: .top, spacing: 20) {
                resource("CPU", value: "\(vm.cpus) 核")
                resource("内存", value: vm.memory)
                resource("磁盘", value: vm.disk)
                if !isBase {
                    Divider().frame(height: 34)
                    codexQuotaSummary
                }
                Spacer(minLength: 0)
            }
            if vm.name != "base" && vm.name != "base-building" {
                VStack(alignment: .leading, spacing: 3) {
                    Text("项目文件夹").font(.caption).foregroundStyle(.secondary)
                    Text(model.vmMounts[vm.name]?.first?.location ?? "尚未获取项目文件夹")
                        .font(.callout).textSelection(.enabled).lineLimit(2)
                }
            }
            if showDetails || showVMDetails {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("虚拟机信息").font(.subheadline.weight(.semibold))
                    detail("名称", value: vm.name)
                    detail("状态", value: vm.status == "Running" ? "运行中" : vm.status == "Stopped" ? "已停止" : vm.status)
                    detail("架构", value: vm.arch)
                    detail("类型", value: vm.vmType)
                    detail("SSH", value: vm.status == "Running" ? vm.ssh : "未运行")
                    if let mounts = model.vmMounts[vm.name] {
                        Text("当前挂载（\(mounts.count)）").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if mounts.isEmpty { Text("无挂载文件夹").font(.caption).foregroundStyle(.secondary) }
                        ForEach(mounts) { mount in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mount.location).textSelection(.enabled)
                                Text("虚拟机：\(mount.guestPath) · \(mount.writable ? "读写" : "只读")").foregroundStyle(.secondary).textSelection(.enabled)
                            }.font(.caption)
                        }
                    } else { Text("挂载信息暂不可用").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Divider()
            HStack(spacing: 8) {
                Button("启动") { model.start(vm) }.disabled(model.busy || vm.status != "Stopped" || model.vmMounts[vm.name]?.isEmpty != false)
                Button("终端") { model.terminal(vm) }.disabled(vm.status != "Running")
                Button("停止") { model.stop(vm) }.disabled(model.busy || vm.status != "Running")
                Button("挂载文件夹") { managingFolders = true }.disabled(model.busy || model.vmMounts[vm.name]?.isEmpty != false)
                if !isBase {
                    Button("刷新额度") { model.pollQuota(for: vm) }.disabled(vm.status != "Running" || model.quotaPolling.contains(vm.name))
                }
                Spacer()
                Button("删除", role: .destructive) { deleting = true }.disabled(model.busy || vm.name == "base")
            }.controlSize(.small)
        }
        .padding(14)
        .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
        .confirmationDialog("删除虚拟机 \(vm.name)？", isPresented: $deleting) {
            Button("删除虚拟机", role: .destructive) { model.remove(vm) }
        } message: { Text("此操作会删除虚拟磁盘中的文件。项目共享目录会保留。") }
        .sheet(isPresented: $managingFolders) {
            VStack(alignment: .leading, spacing: 14) {
                Text("管理挂载文件夹 · \(vm.name)").font(.headline)
                Text("项目文件夹：\(model.vmMounts[vm.name]?.first?.location ?? "")").textSelection(.enabled)
                Text("所有虚拟机共享：~/AgentVM-Shared → /mnt/agent-vm-shared（读写）")
                    .font(.caption).textSelection(.enabled)
                Text("项目文件夹确定虚拟机身份；下方管理额外挂载。更改后停止并重新启动虚拟机生效。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.managedFolders[vm.name] ?? []) { folder in
                    HStack {
                        Text(folder.path).textSelection(.enabled)
                        Text(folder.mode == "rw" ? "读写" : "只读").foregroundStyle(.secondary)
                        Spacer()
                        Button("移除") { model.changeFolder(vm, action: "remove", path: folder.path, mode: folder.mode) }.disabled(model.busy)
                    }
                }
                HStack {
                    Button("添加只读文件夹…") { model.addFolder(vm, writable: false) }.disabled(model.busy)
                    Button("添加读写文件夹…") { model.addFolder(vm, writable: true) }.disabled(model.busy)
                    Spacer()
                    Button("完成") { managingFolders = false }
                }
                if model.operationFailed { Text(model.output).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }
            .padding(24).frame(minWidth: 600)
        }
    }
    private func resource(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium))
        }
    }
    private func detail(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
            Text(value).textSelection(.enabled)
        }.font(.caption)
    }
    @ViewBuilder
    private var codexQuotaSummary: some View {
        let polling = model.quotaPolling.contains(vm.name)
        let quota = model.vmQuotas[vm.name]
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Codex 额度").font(.caption).foregroundStyle(.secondary)
                if let plan = quota?.planType, !plan.isEmpty {
                    Text(plan.uppercased())
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(AgentTheme.accent.opacity(0.14), in: Capsule())
                        .foregroundStyle(AgentTheme.accent)
                }
                if polling {
                    ProgressView().controlSize(.mini)
                }
            }
            if let quota {
                if quota.status == "ok" {
                    HStack(spacing: 14) {
                        if let five = quota.fiveHour {
                            quotaPill(label: "5小时", window: five)
                        }
                        if let wk = quota.weekly {
                            quotaPill(label: "周额度", window: wk)
                        }
                    }
                } else if quota.status == "not_logged_in" {
                    Text("VM 内 Codex 未登录").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(quota.error ?? "额度查询失败").font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
            } else {
                Text(vm.status == "Running" ? "等待检测…" : "未运行").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func quotaPill(label: String, window: CodexWindowQuota) -> some View {
        let rem = window.remainingPercent
        let tint: Color = rem > 30 ? .green : rem > 10 ? .orange : .red
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("\(label) 剩 \(rem)%").font(.caption.weight(.medium)).foregroundStyle(tint)
                if let sec = window.resetAfterSeconds, sec > 0 {
                    Text("(\(formatReset(sec)))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: Double(rem), total: 100)
                .tint(tint)
                .frame(width: 110)
        }
    }
    private func formatReset(_ seconds: Int) -> String {
        let d = seconds / 86400
        let h = (seconds % 86400) / 3600
        let m = (seconds % 3600) / 60
        if d > 0 { return "\(d)d\(h)h后重置" }
        if h > 0 { return "\(h)h\(m)m后重置" }
        return "\(max(1, m))m后重置"
    }
}

struct MachinesView: View {
    @ObservedObject var model: Model
    @AppStorage("showVMDetails") private var showVMDetails = false
    @State private var showBaseInfo = false
    private var projects: [VM] { model.machines.filter { $0.name != "base" && $0.name != "base-building" } }
    private var bases: [VM] { model.machines.filter { $0.name == "base" || $0.name == "base-building" } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("虚拟机").font(.largeTitle.bold())
                        Button { showBaseInfo.toggle() } label: { Image(systemName: "info.circle") }
                            .buttonStyle(.borderless)
                            .help("查看基础环境")
                            .accessibilityLabel("查看基础环境")
                            .popover(isPresented: $showBaseInfo) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("基础环境").font(.headline)
                                    Text("基础模板用于创建项目虚拟机。") .font(.caption).foregroundStyle(.secondary)
                                    if bases.isEmpty {
                                        Text("暂无基础环境").foregroundStyle(.secondary)
                                    } else {
                                        ForEach(bases) { vm in MachineRow(vm: vm, model: model) }
                                    }
                                }.padding().frame(width: 420)
                            }
                    }
                    Text("管理已有 Lima 实例并打开终端。").foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.pollAllRunningQuotas() } label: { Label("刷新额度", systemImage: "gauge.with.dots.needle.33percent") }
                    .disabled(model.busy)
                Button { model.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(model.busy)
            }
            HStack(spacing: 16) {
                Text("总计 \(projects.count)")
                Text("运行中 \(projects.filter { $0.status == "Running" }.count)")
                Text("已停止 \(projects.filter { $0.status == "Stopped" }.count)")
                Text("· 每 20 分钟自动轮询 Codex 额度")
                Spacer()
                Toggle("默认展开详情", isOn: $showVMDetails).toggleStyle(.checkbox)
            }.font(.caption).foregroundStyle(.secondary)
            if !model.regionMessage.isEmpty {
                Text(model.regionMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if model.operationFailed && !model.output.isEmpty {
                HStack {
                    Label("上一次操作失败", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Spacer()
                }.font(.caption)
                Text(model.errorSummary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if projects.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "desktopcomputer").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("暂无虚拟机").font(.title3.bold())
                    Text("在「创建环境」中创建项目虚拟机。").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !projects.isEmpty {
                        Text("项目虚拟机").font(.headline).padding(.top, 4)
                        ForEach(projects) { vm in MachineRow(vm: vm, model: model) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WizardView: View {
    @ObservedObject var model: Model
    var onMachines: () -> Void = {}
    var onProxy: () -> Void = {}
    private let stepTitles = ["资源配置", "确认并开始"]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.buildStarted {
                buildProgress
            } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("创建环境").font(.largeTitle.bold())
                Text(stepTitles[model.step]).font(.title3).foregroundStyle(AgentTheme.accent)
                ProgressView(value: Double(model.step + 1), total: 2).tint(AgentTheme.accent)
            }
            Group {
                switch model.step {
                case 0: configuration
                default: confirmation
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            HStack {
                Button("上一步") { model.step -= 1 }.disabled(model.step == 0 || model.busy)
                Spacer()
                if model.step < 1 {
                    Button("下一步") { model.step += 1 }
                        .buttonStyle(.borderedProminent)
                        .tint(AgentTheme.accent)
                        .disabled(model.busy)
                }
            }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var buildProgress: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.buildComplete ? "虚拟机已就绪" : model.operationFailed ? "创建未完成" : "正在创建虚拟机")
                .font(.largeTitle.bold())
            Text(model.project).foregroundStyle(.secondary).textSelection(.enabled)
            if model.busy { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(["准备基础环境", "启动基础虚拟机", "安装系统和应用", "启动项目虚拟机"].enumerated()), id: \.offset) { index, title in
                    HStack(spacing: 12) {
                        let finished = model.buildComplete || index < model.buildStage
                        let current = index == model.buildStage && !model.buildComplete
                        Image(systemName: finished ? "checkmark.circle.fill" : (current && model.operationFailed ? "xmark.circle.fill" : "circle"))
                            .foregroundStyle(finished ? Color.green : (current && model.operationFailed ? Color.red : Color.secondary))
                        Text(title).fontWeight(current ? .semibold : .regular)
                        Spacer()
                        Text(model.reusedBase && index < 3 ? "已复用" : finished ? "已完成" : current && model.operationFailed ? "失败" : current ? "进行中" : "等待中")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(20).background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            if !model.regionMessage.isEmpty && model.buildComplete {
                Text(model.regionMessage).font(.caption).foregroundStyle(.secondary)
            }
            if model.operationFailed {
                Text(model.errorSummary).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                Text("可检查网络或配置后返回重试。基础环境详细日志保存在 ~/.agent-vm/setup.log。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.busy {
                HStack {
                    Button(model.buildComplete ? "创建其他虚拟机" : "返回配置") { model.buildStarted = false }
                    if model.buildComplete { Button("查看虚拟机", action: onMachines).buttonStyle(.borderedProminent) }
                }
            }
        }.frame(maxWidth: 560, alignment: .leading)
    }
    private var configuration: some View {
        Form {
            Section("系统与应用") {
                Text("Debian · Codex CLI（含 Node.js）").foregroundStyle(.secondary)
                Toggle("重新构建基础模板", isOn: $model.rebuildBase)
                Text("默认复用已有模板；首次创建或选择重新构建时安装下方应用。已有项目虚拟机不受影响。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("安装 code-server", isOn: $model.includeCodeServer)
                    .onChange(of: model.includeCodeServer) { on in
                        if on && model.memory < 4 { model.memory = 4 }
                    }
                Stepper("CPU：\(model.cpus) 核", value: $model.cpus, in: 1...64)
                Stepper("内存：\(model.memory) GiB", value: $model.memory, in: 1...128)
                Stepper("磁盘：\(model.disk) GiB", value: $model.disk, in: 10...1000, step: 10)
                Text("新虚拟机的磁盘不能小于基础模板。") .font(.caption).foregroundStyle(.secondary)
            }
            Section("项目文件夹") {
                HStack {
                    TextField("项目目录绝对路径", text: $model.project)
                    Button("选择…") { model.chooseProject() }
                }
                Text("创建时将此文件夹映射到虚拟机。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("共享文件夹：~/AgentVM-Shared → /mnt/agent-vm-shared（所有虚拟机可读写）")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("地区与语言") {
                Toggle("根据出口 IP 自动同步时区、地区和语言", isOn: $model.syncRegion)
                    .onChange(of: model.syncRegion) { UserDefaults.standard.set($0, forKey: "syncRegion") }
                Text("启动后及运行期间定期通过 ipwho.is 查询；多语言地区使用默认语言。设置在下次启动虚拟机时应用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("网络") {
                Toggle("启用代理（\(model.proxyStatus?.displayProxyUrl ?? "http://10.126.126.1:8787")）", isOn: $model.useProxy)
                    .onChange(of: model.useProxy) { newValue in
                        if let st = model.proxyStatus {
                            model.saveProxyConfig(
                                proxyMode: st.proxyMode,
                                managedEnabled: st.managedEnabled,
                                useProxy: newValue,
                                customProxyURL: st.customProxyUrl,
                                dnsURL: st.dnsUrl,
                                port: st.port
                            )
                        } else {
                            _ = model.saveNetworkSettings()
                        }
                    }
                HStack {
                    Text("DoH：\(model.proxyStatus?.dnsUrl ?? "https://1.1.1.1/dns-query") · \(model.proxyStatus?.managedEnabled == true ? "托管门禁已开启" : "常规模式")")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("打开代理与门禁设置…") { onProxy() }.controlSize(.small)
                }
                Text("更改代理后须重新启动已运行的虚拟机。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 520)
    }
    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("确认配置").font(.headline)
            Text("新虚拟机：\(model.cpus) 核 · \(model.memory) GiB · \(model.disk) GiB；已有虚拟机保留原有配置。")
            Text(model.rebuildBase ? "将重新构建模板：Codex\(model.includeCodeServer ? " · code-server" : "")。" : "优先复用已有模板；首次创建时安装 Codex\(model.includeCodeServer ? " · code-server" : "")。")
            Text("项目文件夹：\(model.project)").textSelection(.enabled)
            Button("创建虚拟机") { model.confirmation = true }
                .buttonStyle(.borderedProminent)
                .tint(AgentTheme.accent)
                .disabled(model.project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
            Text("使用基础模板启动所选项目的虚拟机。若项目已有虚拟机，将启动已有虚拟机。\n项目目录不能包含正在运行的 Agent VM 程序。")
                .font(.caption).foregroundStyle(.secondary)
        }.confirmationDialog("创建或启动项目虚拟机？", isPresented: $model.confirmation) {
            Button("确认创建") {
                model.setup()
            }
        } message: { Text("现有项目虚拟机继续保留。后续新建项目使用新模板。") }
    }
}

enum WorkbenchSection: String, CaseIterable, Identifiable, Hashable {
    case machines, setup, proxy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .machines: return "虚拟机"
        case .setup: return "创建环境"
        case .proxy: return "代理与门禁"
        }
    }
    var symbol: String {
        switch self {
        case .machines: return "desktopcomputer"
        case .setup: return "plus.square.fill"
        case .proxy: return "network"
        }
    }
}

struct WorkbenchSidebar: View {
    @Binding var selection: WorkbenchSection
    let busy: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("▰").foregroundStyle(AgentTheme.accent)
                Text("Agent VM").font(.title2.bold())
            }
            .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 12)
            Text("工作空间").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 6)
            ForEach(WorkbenchSection.allCases) { item in
                Button {
                    selection = item
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol).frame(width: 18)
                        Text(item.title)
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(selection == item ? AgentTheme.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(selection == item ? AgentTheme.accent : Color.primary)
                .padding(.horizontal, 10)
            }
            Spacer()
            HStack {
                Text("本机连接").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }.padding(16)
        }
        .frame(width: 220)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

struct ContentView: View {
    @StateObject var model = Model()
    @State private var section: WorkbenchSection = .machines
    var body: some View {
        HStack(spacing: 0) {
            WorkbenchSidebar(selection: $section, busy: model.busy)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    Group {
                        switch section {
                        case .machines: MachinesView(model: model)
                        case .setup: WizardView(model: model, onMachines: { section = .machines }, onProxy: { section = .proxy })
                        case .proxy: ProxyGatewayView(model: model)
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 920, minHeight: 640)
        .tint(AgentTheme.accent)
    }
}

@main struct AgentVMApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
