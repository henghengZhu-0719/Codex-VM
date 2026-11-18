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

struct VMUsage {
    let cpuPercent: Double
    let usedMemoryMB: Double
    let totalMemoryMB: Double
    var memoryPercent: Double {
        guard totalMemoryMB > 0 else { return 0 }
        return min(100, max(0, usedMemoryMB / totalMemoryMB * 100))
    }
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
    var isLow: Bool { remainingPercent <= 15 }
}

struct QuotaWindowItem: Codable {
    let label: String
    let usedPercent: Int
    let resetAfterSeconds: Int?
    let resetAt: Int64?

    enum CodingKeys: String, CodingKey {
        case label
        case usedPercent = "used_percent"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }

    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }
    var isLow: Bool { remainingPercent <= 15 }
}

struct AgentQuotaResult: Decodable {
    let status: String
    let planType: String?
    let windows: [QuotaWindowItem]?
    let error: String?
    let fetchedAt: Date?

    enum CodingKeys: String, CodingKey {
        case status, windows, error
        case planType = "plan_type"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        planType = try c.decodeIfPresent(String.self, forKey: .planType)
        windows = try c.decodeIfPresent([QuotaWindowItem].self, forKey: .windows)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        fetchedAt = Date()
    }

    init(status: String, planType: String? = nil, windows: [QuotaWindowItem]? = nil, error: String? = nil, fetchedAt: Date? = Date()) {
        self.status = status
        self.planType = planType
        self.windows = windows
        self.error = error
        self.fetchedAt = fetchedAt
    }
}

struct VMQuotasEnvelope: Decodable {
    let agents: [String: AgentQuotaResult]?
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
    @Published var newVMName = ""
    @Published var includeCodex = true
    @Published var includeClaude = false
    @Published var includeBrowser = false
    @Published var includeAgy = false
    @Published var includeCodeServer = true
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
    @Published var vmProxyRoutes: [String: String] = UserDefaults.standard.dictionary(forKey: "vmProxyRoutes") as? [String: String] ?? [:]
    @Published var vmSelectedAgents: [String: [String]] = UserDefaults.standard.dictionary(forKey: "vmSelectedAgents") as? [String: [String]] ?? [:]
    @Published var vmQuotas: [String: CodexQuotaStatus] = [:]
    @Published var vmAgentQuotas: [String: [String: AgentQuotaResult]] = [:]
    @Published var vmUsage: [String: VMUsage] = [:]
    @Published var vmAgents: [String: [String]] = [:]
    @Published var usageErrors: Set<String> = []
    @Published var quotaPolling: Set<String> = []
    @Published var lastQuotaPollAt: Date?
    @Published var codeEditors: [String: CodeEditorState] = [:]
    @Published var linuxBrowsers: [String: LinuxBrowserState] = [:]
    @Published var activeBrowserVM: String = ""
    @Published var browserSlot: CGRect = .zero
    @Published var browserSlotVisible: Bool = false
    @Published var browserReloadToken: Int = 0
    @Published var browserFocusAddressNonce: Int = 0
    @Published var browserShortcutSignal: [String: Any] = [:]
    @Published var codexDesktops: [String: CodexDesktopState] = [:]
    @Published var activeCodexDesktopVM: String = ""
    @Published var codexDesktopSlot: CGRect = .zero
    @Published var codexDesktopSlotVisible: Bool = false
    @Published var codexDesktopReloadToken: Int = 0
    @Published var cliRevision: Int = 0
    @Published var chatRevision: Int = 0
    @Published var runningSessions: Set<String> = []
    @Published var runningSessionVMs: [String: String] = [:]
    @Published var stagedAttachments: [String: [[String: Any]]] = [:]
    @Published var gitDiffState: [String: Any] = [:]
    @Published var toasts: [[String: Any]] = []
    @Published var requestedPage: [String: Any] = [:]
    @Published var remoteWorkbenchEnabled: Bool = UserDefaults.standard.bool(forKey: "remoteWorkbenchEnabled")
    @Published var remoteWorkbenchPort: Int = {
        let p = UserDefaults.standard.integer(forKey: "remoteWorkbenchPort")
        return (1024...65535).contains(p) ? p : 18080
    }()
    @Published var remoteWorkbenchToken: String = {
        let t = UserDefaults.standard.string(forKey: "remoteWorkbenchToken") ?? ""
        return t.isEmpty ? "Zhuyq020110" : t
    }()
    @Published var remoteWorkbenchError: String = ""
    let remoteWorkbenchServer = RemoteWorkbenchServer()
    let chatStore = AgentChatStore()
    private var codexProcesses: [String: Process] = [:]
    private var stoppedSessions: Set<String> = []
    private var vmMihomoProcesses: [String: Process] = [:]
    private let codeEditorManager = CodeEditorManager()
    private let linuxBrowserManager = LinuxBrowserManager()
    private let codexDesktopManager = CodexDesktopManager()
    let cliVersionManager = CLIVersionManager()
    private var terminationObserver: NSObjectProtocol?
    private var quotaTimer: Timer?
    private var cliTimer: Timer?
    private var usageTimer: Timer?
    private var usagePolling: Set<String> = []
    private var codexDesktopLastActiveAt: [String: Date] = [:]
    private var browserLastActiveAt: [String: Date] = [:]
    private let guiIdleLimitSeconds: TimeInterval = 600
    let executable: String

    init() {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agent-vm").path
        executable = ProcessInfo.processInfo.environment["AGENT_VM_BINARY"] ?? (FileManager.default.isExecutableFile(atPath: bundled) ? bundled : Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("bin/agent-vm").path)
        codeEditorManager.onChange = { [weak self] states in self?.codeEditors = states }
        linuxBrowserManager.onChange = { [weak self] states in self?.linuxBrowsers = states }
        linuxBrowserManager.onOpen = { [weak self] vmName, _ in
            self?.activeBrowserVM = vmName
        }
        codexDesktopManager.onChange = { [weak self] states in self?.codexDesktops = states }
        codexDesktopManager.onOpen = { [weak self] vmName, _ in
            self?.activeCodexDesktopVM = vmName
        }
        cliVersionManager.onChange = { [weak self] in
            self?.cliRevision += 1
        }
        cliVersionManager.onAutoUpdateComplete = { [weak self] updatedCount, failedCount in
            guard let self else { return }
            if failedCount == 0 && updatedCount > 0 {
                self.pushToast(title: "CLI 自动更新完成", message: "已更新 \(updatedCount) 项工具", level: "ok")
            } else if failedCount > 0 {
                self.pushToast(title: "部分 CLI 更新失败", message: "成功 \(updatedCount) · 失败 \(failedCount)", level: "error")
            }
        }
        remoteWorkbenchServer.onError = { [weak self] err in
            self?.remoteWorkbenchError = err
        }
        if remoteWorkbenchToken.isEmpty {
            remoteWorkbenchToken = Self.generateToken()
            UserDefaults.standard.set(remoteWorkbenchToken, forKey: "remoteWorkbenchToken")
        }
        if remoteWorkbenchEnabled {
            remoteWorkbenchServer.start(port: UInt16(remoteWorkbenchPort), token: remoteWorkbenchToken)
        }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.codeEditorManager.stopAll()
                self?.stopAllVMMihomo()
                self?.stopAllAgents()
                self?.chatStore.flushAll()
                self?.remoteWorkbenchServer.stop()
            }
        }
        refresh()
        refreshProxyStatus()
        quotaTimer = Timer.scheduledTimer(withTimeInterval: 20 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollAllRunningQuotas()
            }
        }
        cliTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkCLIVersions(triggerAutoUpdate: true)
            }
        }
        usageTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollRunningUsage()
                self?.refreshCodeEditors()
                self?.reclaimIdleGUIs()
            }
        }
    }
    func run(_ arguments: [String], cwd: String? = nil, input: String? = nil, vmName: String? = nil, progress: ((String) -> Void)? = nil, completion: @escaping (Int32, String) -> Void) {
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
            if let vmName, let customNode = vmProxyRoutes[vmName], !customNode.isEmpty, proxyMode == "mihomo",
               let customCfg = prepareVMManagedNetworkConfig(for: vmName, nodeId: customNode) {
                environment["AGENT_VM_MANAGED_NETWORK_CONFIG"] = customCfg
            } else {
                environment["AGENT_VM_MANAGED_NETWORK_CONFIG"] = st.managedConfigPath
            }
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
        regionMessage = ""
        buildComplete = false
        buildStage = 0
        operationFailed = false
        // Use a unique, ordinary host directory for VM identity, never the common share.
        if project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("AgentVM-Workspaces", isDirectory: true)
            let identity = root.appendingPathComponent("vm-" + UUID().uuidString.lowercased(), isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: identity, withIntermediateDirectories: true)
                project = identity.path
            } catch {
                output = "无法创建虚拟机工作目录：" + error.localizedDescription
                operationFailed = true
                buildStarted = true
                return
            }
        }
        let selectedProject = project.trimmingCharacters(in: .whitespacesAndNewlines)
        buildStarted = true
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
                self.installSelectedApps(project: selectedProject) { installOk in
                    guard installOk else { self.busy = false; self.refresh(); return }
                    self.updateRegion(project: selectedProject) {
                        self.buildComplete = true
                        self.rebuildBase = false
                        self.busy = false
                        let selectedList = [
                            self.includeCodex ? "codex" : nil,
                            self.includeAgy ? "agy" : nil,
                            self.includeClaude ? "claude" : nil
                        ].compactMap { $0 }
                        self.run(["name", selectedProject]) { code, rawName in
                            guard code == 0 else { self.refresh(); return }
                            let vmName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !vmName.isEmpty else { self.refresh(); return }
                            self.vmSelectedAgents[vmName] = selectedList
                            UserDefaults.standard.set(self.vmSelectedAgents, forKey: "vmSelectedAgents")
                            self.vmAgents[vmName] = selectedList
                            if selectedProject.hasPrefix(NSHomeDirectory() + "/AgentVM-Workspaces/") {
                                let label = self.newVMName.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !label.isEmpty {
                                    self.vmAliases[vmName] = label
                                    UserDefaults.standard.set(self.vmAliases, forKey: "vmAliases")
                                }
                            }
                            self.refresh()
                        }
                    }
                }
            }
            }
            if fields.contains("base_exists=1") && !self.rebuildBase {
                self.reusedBase = true
                self.output = "使用已有基础模板。\n"
                startProject()
                return
            }
            // Keep shared base free of per-app CLIs (codex/claude) so unchecked apps don't leak into cloned VMs.
            let preinstall = self.includeCodeServer ? "code-server" : "none"
            let args = ["setup", "--preinstall=" + preinstall, "--memory", String(self.memory), "--cpus", String(self.cpus), "--disk", String(self.disk)]
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
    private func installSelectedApps(project: String, completion: @escaping (Bool) -> Void) {
        var steps: [String] = [
            "set -euo pipefail",
            "export PATH=\"$HOME/.local/bin:$HOME/.claude/local/bin:$PATH\""
        ]
        if includeCodex {
            steps.append("""
            if ! command -v codex >/dev/null 2>&1; then
              if ! command -v npm >/dev/null 2>&1; then
                sudo apt-get update && sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs npm </dev/null
              fi
              sudo npm i -g @openai/codex </dev/null
            fi
            """)
        } else {
            steps.append("""
            if command -v npm >/dev/null 2>&1 && command -v codex >/dev/null 2>&1; then
              sudo npm uninstall -g @openai/codex </dev/null || true
            fi
            """)
        }
        if includeClaude {
            steps.append("""
            if ! command -v claude >/dev/null 2>&1; then
              curl -fsSL https://claude.ai/install.sh | bash
              grep -q '.claude/local/bin' ~/.zshenv 2>/dev/null || echo 'export PATH=$HOME/.claude/local/bin:$PATH' >> ~/.zshenv
              sudo mkdir -p /etc/claude-code
              printf '{"permissions":{"defaultMode":"bypassPermissions"},"tui":"fullscreen"}\n' | sudo tee /etc/claude-code/managed-settings.json >/dev/null
            fi
            """)
        } else {
            steps.append("""
            rm -f "$HOME/.local/bin/claude" "$HOME/.claude/local/bin/claude"
            """)
        }
        if includeClaude && includeBrowser {
            steps.append("""
            if ! command -v chromium >/dev/null 2>&1 || ! command -v Xtigervnc >/dev/null 2>&1 || ! command -v websockify >/dev/null 2>&1 || [ ! -f /usr/share/novnc/vnc.html ]; then
              sudo apt-get update && sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends chromium fonts-liberation fonts-dejavu-core fonts-noto-cjk tigervnc-standalone-server xvfb xauth openbox x11vnc novnc websockify x11-xserver-utils xclip xdotool </dev/null
              sudo ln -sf /usr/bin/chromium /usr/bin/google-chrome
              sudo ln -sf /usr/bin/chromium /usr/bin/google-chrome-stable
              sudo mkdir -p /opt/google/chrome
              sudo ln -sf /usr/bin/chromium /opt/google/chrome/chrome
            fi
            if command -v npx >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
              python3 -c "import json, pathlib; p = pathlib.Path.home()/'.claude.json'; d = json.loads(p.read_text()) if p.exists() else {}; d.setdefault('mcpServers', {})['chrome-devtools'] = {'command': 'npx', 'args': ['-y', 'chrome-devtools-mcp@latest', '--browserUrl', 'http://127.0.0.1:9222']}; p.write_text(json.dumps(d, indent=2) + '\\n')"
            fi
            """)
        }
        if includeAgy {
            steps.append("""
            if ! command -v agy >/dev/null 2>&1; then
              curl -fsSL https://antigravity.google/cli/install.sh | bash
              grep -q '.local/bin' ~/.zshenv 2>/dev/null || echo 'export PATH=$HOME/.local/bin:$PATH' >> ~/.zshenv
            fi
            """)
        }
        if includeCodeServer {
            steps.append("""
            if ! command -v code-server >/dev/null 2>&1; then
              curl -fsSL https://code-server.dev/install.sh | sh
            fi
            """)
        }
        let selectedCSV = [includeCodex ? "codex" : nil, includeAgy ? "agy" : nil, includeClaude ? "claude" : nil].compactMap { $0 }.joined(separator: ",")
        steps.append("""
        mkdir -p "$HOME/.config"
        printf '%s\\n' '\(selectedCSV)' > "$HOME/.config/agent-vm-selected-agents"
        """)
        let script = steps.joined(separator: "\n")
        run(["run", "--", "bash", "-lc", script], cwd: project) { code, text in
            if !text.isEmpty { self.output += text }
            self.operationFailed = code != 0
            completion(code == 0)
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
            let runningNames = Set(self.machines.filter { $0.status == "Running" }.map(\.name))
            self.codeEditorManager.retain(runningNames)
            self.linuxBrowserManager.retain(runningNames)
            self.codexDesktopManager.retain(runningNames)
            self.cliVersionManager.retain(runningNames)
            self.vmUsage = self.vmUsage.filter { runningNames.contains($0.key) }
            self.usageErrors = self.usageErrors.filter { runningNames.contains($0) }
            self.pollRunningUsage()
            for vm in self.machines {
                self.run(["vm-mounts", vm.name]) { code, text in
                    if code == 0, let data = text.data(using: .utf8), let mounts = try? JSONDecoder().decode([ProjectMount]?.self, from: data) {
                        self.vmMounts[vm.name] = mounts
                        self.prepareCodeEditor(vm)
                    }
                }
                if vm.status == "Running", vm.name != "base", vm.name != "base-building" {
                    if self.vmAgentQuotas[vm.name] == nil {
                        self.pollQuota(for: vm)
                    }
                    if self.codexDesktops[vm.name]?.checked != true {
                        self.checkCodexDesktop(vm)
                    }
                    if self.linuxBrowsers[vm.name]?.checked != true {
                        self.checkLinuxBrowser(vm)
                    }
                }
            }
            self.refreshManagedFolders()
            let runningCheckable = self.machines.filter { $0.status == "Running" && $0.name != "base" && $0.name != "base-building" }
            if self.cliVersionManager.latestCheckedAt == nil,
               !runningCheckable.isEmpty,
               runningCheckable.allSatisfy({ self.allowedCLIAgents(for: $0.name) != nil }) {
                self.checkCLIVersions(triggerAutoUpdate: true)
            }
        }
    }
    func allowedCLIAgents(for vmName: String) -> [String]? {
        if let saved = vmSelectedAgents[vmName], !saved.isEmpty { return saved }
        if let effective = vmAgents[vmName] { return effective }
        return nil
    }
    func checkCLIVersions(triggerAutoUpdate: Bool = true) {
        cliVersionManager.checkAll(
            vms: machines,
            sshConfigForVM: { self.sshConfigPath(for: $0) },
            allowedAgentsForVM: { self.allowedCLIAgents(for: $0) ?? CLIVersionManager.trackedAgents },
            triggerAutoUpdate: triggerAutoUpdate
        )
    }
    func updateAllCLIs() {
        cliVersionManager.updateAllOutdated(
            vms: machines,
            sshConfigForVM: { self.sshConfigPath(for: $0) },
            allowedAgentsForVM: { self.allowedCLIAgents(for: $0) ?? CLIVersionManager.trackedAgents }
        )
    }
    func updateSingleCLI(_ vm: VM, agent: String) {
        guard vm.status == "Running" else { return }
        cliVersionManager.updateSingle(vmName: vm.name, agent: agent, config: sshConfigPath(for: vm.name)) { [weak self] ok, _ in
            guard let self else { return }
            if ok {
                self.pushToast(title: "\(agent) 更新完成", message: self.displayName(for: vm), level: "ok", vmName: vm.name)
            } else {
                self.pushToast(title: "\(agent) 更新失败", message: self.displayName(for: vm), level: "error", vmName: vm.name)
            }
        }
    }
    func setCLIAutoUpdate(_ enabled: Bool) {
        cliVersionManager.autoUpdate = enabled
        cliRevision += 1
        if enabled && cliVersionManager.hasAnyUpdate() {
            updateAllCLIs()
        }
    }
    func refreshCodeEditors() {
        for vm in machines where vm.status == "Running" { prepareCodeEditor(vm) }
    }
    func prepareCodeEditor(_ vm: VM, retry: Bool = false) {
        guard vm.status == "Running", vm.name != "base", vm.name != "base-building",
              let mount = vmMounts[vm.name]?.first else { return }
        let state = ProcessInfo.processInfo.environment["AGENT_VM_STATE_DIR"] ?? NSHomeDirectory() + "/.agent-vm"
        let lima = ProcessInfo.processInfo.environment["AGENT_VM_LIMA_HOME"] ?? state + "/lima"
        let config = URL(fileURLWithPath: lima).appendingPathComponent(vm.name).appendingPathComponent("ssh.config").path
        let directory = mount.location.hasPrefix(NSHomeDirectory() + "/AgentVM-Workspaces/") ? "/mnt/agent-vm-shared" : mount.guestPath
        codeEditorManager.ensure(name: vm.name, config: config, directory: directory, retry: retry)
    }
    func openCodeEditor(_ vm: VM) {
        guard vm.status == "Running", let editor = codeEditors[vm.name], editor.status == "ready",
              let url = URL(string: editor.url) else { prepareCodeEditor(vm, retry: true); return }
        NSWorkspace.shared.open(url)
    }
    func sshConfigPath(for vmName: String) -> String {
        let state = ProcessInfo.processInfo.environment["AGENT_VM_STATE_DIR"] ?? NSHomeDirectory() + "/.agent-vm"
        let lima = ProcessInfo.processInfo.environment["AGENT_VM_LIMA_HOME"] ?? state + "/lima"
        return URL(fileURLWithPath: lima).appendingPathComponent(vmName).appendingPathComponent("ssh.config").path
    }
    func pushToast(title: String, message: String = "", level: String = "info", vmName: String = "") {
        let id = UUID().uuidString
        let item: [String: Any] = [
            "id": id,
            "title": title,
            "message": message,
            "level": level,
            "vm": vmName,
            "ts": Date().timeIntervalSince1970
        ]
        toasts.append(item)
        if toasts.count > 6 { toasts.removeFirst(toasts.count - 6) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { [weak self] in
            self?.dismissToast(id: id)
        }
    }
    func dismissToast(id: String) {
        toasts.removeAll { ($0["id"] as? String) == id }
    }
    func checkLinuxBrowser(_ vm: VM) {
        guard vm.status == "Running", vm.name != "base", vm.name != "base-building" else { return }
        linuxBrowserManager.checkStatus(name: vm.name, config: sshConfigPath(for: vm.name))
    }
    func openLinuxBrowser(_ vm: VM, width: Int = 1280, height: Int = 800, qualityMode: String? = nil) {
        guard vm.status == "Running", vm.name != "base", vm.name != "base-building" else { return }
        let w = width > 100 ? width : max(800, Int(browserSlot.width))
        let h = height > 100 ? height : max(500, Int(browserSlot.height))
        linuxBrowserManager.open(name: vm.name, config: sshConfigPath(for: vm.name), width: w, height: h, qualityMode: qualityMode)
    }
    func resizeLinuxBrowser(_ vm: VM, width: Int, height: Int) {
        guard vm.status == "Running", width > 100, height > 100 else { return }
        linuxBrowserManager.resize(name: vm.name, config: sshConfigPath(for: vm.name), width: width, height: height)
    }
    func setBrowserQuality(_ vm: VM, qualityMode: String) {
        linuxBrowserManager.setQuality(name: vm.name, qualityMode: qualityMode)
    }
    func setBrowserAutoResize(_ vm: VM, enabled: Bool) {
        let w = max(800, Int(browserSlot.width))
        let h = max(500, Int(browserSlot.height))
        linuxBrowserManager.setAutoResize(name: vm.name, enabled: enabled, config: sshConfigPath(for: vm.name), width: w, height: h)
    }
    func restartLinuxBrowser(_ vm: VM, width: Int = 0, height: Int = 0) {
        guard vm.status == "Running" else { return }
        let w = width > 100 ? width : max(800, Int(browserSlot.width))
        let h = height > 100 ? height : max(500, Int(browserSlot.height))
        linuxBrowserManager.restartApp(name: vm.name, config: sshConfigPath(for: vm.name), width: w, height: h)
    }
    func requestBrowserPicker() {
        requestedPage = ["page": "browser", "pick": true, "nonce": UUID().uuidString]
    }
    func stopLinuxBrowser(_ vm: VM, reasonToast: String? = nil) {
        browserLastActiveAt.removeValue(forKey: vm.name)
        linuxBrowserManager.stopSession(name: vm.name, config: sshConfigPath(for: vm.name)) { [weak self] in
            self?.pollUsage(for: vm)
            if let reasonToast {
                self?.pushToast(title: reasonToast, message: self?.displayName(for: vm) ?? vm.name, level: "info", vmName: vm.name)
            }
        }
    }
    func browserInspect(_ vm: VM) {
        guard vm.status == "Running" else { return }
        linuxBrowserManager.inspect(name: vm.name, config: sshConfigPath(for: vm.name))
    }
    func browserNavigate(_ vm: VM, url: String, tabId: String = "") {
        guard vm.status == "Running" else { return }
        let cfg = sshConfigPath(for: vm.name)
        linuxBrowserManager.navigate(name: vm.name, config: cfg, url: url, tabId: tabId)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.linuxBrowserManager.inspect(name: vm.name, config: cfg)
        }
    }
    func browserBack(_ vm: VM, tabId: String = "") {
        guard vm.status == "Running" else { return }
        let cfg = sshConfigPath(for: vm.name)
        linuxBrowserManager.back(name: vm.name, config: cfg, tabId: tabId)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.linuxBrowserManager.inspect(name: vm.name, config: cfg)
        }
    }
    func browserForward(_ vm: VM, tabId: String = "") {
        guard vm.status == "Running" else { return }
        let cfg = sshConfigPath(for: vm.name)
        linuxBrowserManager.forward(name: vm.name, config: cfg, tabId: tabId)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.linuxBrowserManager.inspect(name: vm.name, config: cfg)
        }
    }
    func browserPageReload(_ vm: VM, tabId: String = "") {
        guard vm.status == "Running" else { return }
        let cfg = sshConfigPath(for: vm.name)
        linuxBrowserManager.reloadPage(name: vm.name, config: cfg, tabId: tabId)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.linuxBrowserManager.inspect(name: vm.name, config: cfg)
        }
    }
    func browserNewTab(_ vm: VM, url: String = "about:blank") {
        guard vm.status == "Running" else { return }
        linuxBrowserManager.newTab(name: vm.name, config: sshConfigPath(for: vm.name), url: url)
    }
    func browserActivateTab(_ vm: VM, tabId: String) {
        guard vm.status == "Running", !tabId.isEmpty else { return }
        linuxBrowserManager.activateTab(name: vm.name, config: sshConfigPath(for: vm.name), tabId: tabId)
    }
    func browserCloseTab(_ vm: VM, tabId: String) {
        guard vm.status == "Running", !tabId.isEmpty else { return }
        linuxBrowserManager.closeTab(name: vm.name, config: sshConfigPath(for: vm.name), tabId: tabId)
    }
    func browserInsertText(_ vm: VM, text: String, tabId: String = "") {
        guard vm.status == "Running", !text.isEmpty else { return }
        linuxBrowserManager.insertText(name: vm.name, config: sshConfigPath(for: vm.name), text: text, tabId: tabId)
    }
    func browserScreenshotToChat(_ vm: VM, tabId: String = "", jumpToChat: Bool = true) {
        guard vm.status == "Running", prepareSharedFolder() else { return }
        linuxBrowserManager.captureScreenshot(name: vm.name, config: sshConfigPath(for: vm.name), tabId: tabId) { [weak self] data, err in
            guard let self else { return }
            guard let data else {
                self.pushToast(title: "截图失败", message: err ?? "无法捕获当前页面", level: "error", vmName: vm.name)
                return
            }
            let dir = URL(fileURLWithPath: NSHomeDirectory() + "/AgentVM-Shared/.attachments", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = "browser-\(Int(Date().timeIntervalSince1970)).png"
            let hostFile = dir.appendingPathComponent(name)
            do {
                try data.write(to: hostFile, options: .atomic)
                let guestPath = "/mnt/agent-vm-shared/.attachments/" + name
                var list = self.stagedAttachments[vm.name] ?? []
                list.append([
                    "id": UUID().uuidString,
                    "name": name,
                    "guestPath": guestPath,
                    "hostPath": hostFile.path,
                    "isImage": true
                ])
                self.stagedAttachments[vm.name] = list
                if jumpToChat {
                    self.requestedPage = ["page": "codex", "vm": vm.name, "nonce": UUID().uuidString]
                }
                self.pushToast(title: "已截取浏览器画面", message: "已添加到 \(self.displayName(for: vm)) 对话附件", level: "ok", vmName: vm.name)
            } catch {
                self.pushToast(title: "保存截图失败", message: error.localizedDescription, level: "error", vmName: vm.name)
            }
        }
    }
    func browserInstallComponents(_ vm: VM) {
        guard vm.status == "Running" else { return }
        let cfg = sshConfigPath(for: vm.name)
        linuxBrowserManager.installComponents(name: vm.name, config: cfg) { [weak self] ok, msg in
            guard let self else { return }
            if ok {
                self.pushToast(title: "浏览器组件已安装", message: "正在启动 Linux 浏览器…", level: "ok", vmName: vm.name)
                self.openLinuxBrowser(vm)
            } else {
                self.pushToast(title: "安装浏览器组件失败", message: msg, level: "error", vmName: vm.name)
            }
        }
    }
    func browserFetchLogs(_ vm: VM) {
        guard vm.status == "Running" else { return }
        linuxBrowserManager.fetchLogs(name: vm.name, config: sshConfigPath(for: vm.name))
    }
    func browserOpenDownloads() {
        let dl = NSHomeDirectory() + "/AgentVM-Shared/Downloads"
        try? FileManager.default.createDirectory(atPath: dl, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: dl))
    }
    func checkCodexDesktop(_ vm: VM) {
        guard vm.status == "Running", vm.name != "base", vm.name != "base-building" else { return }
        codexDesktopManager.checkStatus(name: vm.name, config: sshConfigPath(for: vm.name))
    }
    func openCodexDesktop(_ vm: VM, width: Int = 1280, height: Int = 800, qualityMode: String? = nil) {
        guard vm.status == "Running", vm.name != "base", vm.name != "base-building" else { return }
        let w = width > 100 ? width : max(800, Int(codexDesktopSlot.width))
        let h = height > 100 ? height : max(500, Int(codexDesktopSlot.height))
        codexDesktopManager.open(name: vm.name, config: sshConfigPath(for: vm.name), width: w, height: h, qualityMode: qualityMode)
    }
    func resizeCodexDesktop(_ vm: VM, width: Int, height: Int) {
        guard vm.status == "Running", width > 100, height > 100 else { return }
        codexDesktopManager.resize(name: vm.name, config: sshConfigPath(for: vm.name), width: width, height: height)
    }
    func setCodexDesktopQuality(_ vm: VM, qualityMode: String) {
        codexDesktopManager.setQuality(name: vm.name, qualityMode: qualityMode)
    }
    func setCodexDesktopAutoResize(_ vm: VM, enabled: Bool) {
        let w = max(800, Int(codexDesktopSlot.width))
        let h = max(500, Int(codexDesktopSlot.height))
        codexDesktopManager.setAutoResize(name: vm.name, enabled: enabled, config: sshConfigPath(for: vm.name), width: w, height: h)
    }
    func requestCodexDesktopPicker() {
        requestedPage = ["page": "codexDesktop", "pick": true, "nonce": UUID().uuidString]
    }
    func stopCodexDesktop(_ vm: VM, reasonToast: String? = nil) {
        codexDesktopLastActiveAt.removeValue(forKey: vm.name)
        codexDesktopManager.stopSession(name: vm.name, config: sshConfigPath(for: vm.name)) { [weak self] in
            self?.pollUsage(for: vm)
            if let reasonToast {
                self?.pushToast(title: reasonToast, message: self?.displayName(for: vm) ?? vm.name, level: "info", vmName: vm.name)
            }
        }
    }
    func reclaimIdleGUIs() {
        let now = Date()
        for vm in machines where vm.status == "Running" && vm.name != "base" && vm.name != "base-building" {
            let desktopActive = codexDesktopSlotVisible && activeCodexDesktopVM == vm.name
            if desktopActive {
                codexDesktopLastActiveAt[vm.name] = now
            } else if let st = codexDesktops[vm.name], (st.status == "ready" || st.appRunning), !st.installing {
                if let last = codexDesktopLastActiveAt[vm.name] {
                    if now.timeIntervalSince(last) >= guiIdleLimitSeconds {
                        stopCodexDesktop(vm, reasonToast: "已休眠闲置桌面以释放内存")
                    }
                } else {
                    codexDesktopLastActiveAt[vm.name] = now
                }
            } else {
                codexDesktopLastActiveAt.removeValue(forKey: vm.name)
            }

            let browserActive = browserSlotVisible && activeBrowserVM == vm.name
            if browserActive {
                browserLastActiveAt[vm.name] = now
            } else if let bst = linuxBrowsers[vm.name], (bst.status == "ready" || bst.appRunning), !bst.installing {
                if let last = browserLastActiveAt[vm.name] {
                    if now.timeIntervalSince(last) >= guiIdleLimitSeconds {
                        stopLinuxBrowser(vm, reasonToast: "已休眠闲置浏览器以释放内存")
                    }
                } else {
                    browserLastActiveAt[vm.name] = now
                }
            } else {
                browserLastActiveAt.removeValue(forKey: vm.name)
            }
        }
    }
    func installCodexDesktop(_ vm: VM, width: Int = 1280, height: Int = 800) {
        guard vm.status == "Running", vm.name != "base", vm.name != "base-building" else { return }
        let w = width > 100 ? width : max(800, Int(codexDesktopSlot.width))
        let h = height > 100 ? height : max(500, Int(codexDesktopSlot.height))
        codexDesktopManager.install(name: vm.name, config: sshConfigPath(for: vm.name), width: w, height: h) { [weak self] ok, msg in
            guard let self else { return }
            if ok {
                self.pushToast(title: "官方 Codex 桌面端已安装", message: "正在启动桌面窗口…", level: "ok", vmName: vm.name)
            } else {
                self.pushToast(title: "官方 Codex 桌面端安装失败", message: msg, level: "error", vmName: vm.name)
            }
        }
    }
    func restartCodexDesktop(_ vm: VM, width: Int = 0, height: Int = 0) {
        guard vm.status == "Running" else { return }
        let w = width > 100 ? width : max(800, Int(codexDesktopSlot.width))
        let h = height > 100 ? height : max(500, Int(codexDesktopSlot.height))
        codexDesktopManager.restartApp(name: vm.name, config: sshConfigPath(for: vm.name), width: w, height: h)
    }
    func codexDesktopSendText(_ vm: VM, text: String) {
        guard vm.status == "Running", !text.isEmpty else { return }
        codexDesktopManager.sendText(name: vm.name, config: sshConfigPath(for: vm.name), text: text)
    }
    func codexDesktopFetchLogs(_ vm: VM) {
        guard vm.status == "Running" else { return }
        codexDesktopManager.fetchLogs(name: vm.name, config: sshConfigPath(for: vm.name))
    }
    func pollRunningUsage() {
        for vm in machines where vm.status == "Running" && vm.name != "base" && vm.name != "base-building" {
            pollUsage(for: vm)
        }
    }
    func pollUsage(for vm: VM) {
        guard vm.status == "Running", !usagePolling.contains(vm.name) else { return }
        let state = ProcessInfo.processInfo.environment["AGENT_VM_STATE_DIR"] ?? NSHomeDirectory() + "/.agent-vm"
        let lima = ProcessInfo.processInfo.environment["AGENT_VM_LIMA_HOME"] ?? state + "/lima"
        let config = URL(fileURLWithPath: lima).appendingPathComponent(vm.name).appendingPathComponent("ssh.config").path
        guard FileManager.default.fileExists(atPath: config) else {
            vmUsage.removeValue(forKey: vm.name)
            usageErrors.insert(vm.name)
            return
        }
        usagePolling.insert(vm.name)
        let name = vm.name
        // Read two Linux /proc/stat snapshots to calculate a short-window guest CPU percentage.
        // MemAvailable excludes reclaimable cache from used memory.
        let script = #"""
        set -- $(awk '/^cpu / { total=0; for(i=2;i<=NF;i++) total+=$i; print $5+$6, total; exit }' /proc/stat)
        idle1=$1; total1=$2
        sleep 0.3
        set -- $(awk '/^cpu / { total=0; for(i=2;i<=NF;i++) total+=$i; print $5+$6, total; exit }' /proc/stat)
        idle2=$1; total2=$2
        cpu=$(awk -v i1="$idle1" -v t1="$total1" -v i2="$idle2" -v t2="$total2" 'BEGIN { dt=t2-t1; di=i2-i1; if(dt<=0) print "0"; else printf "%.1f", 100*(dt-di)/dt }')
        mem=$(awk '/^MemTotal:/ { total=$2 } /^MemAvailable:/ { available=$2 } END { if(total>0 && available>=0) printf "%.0f|%.0f", (total-available)/1024, total/1024 }' /proc/meminfo)
        agents=""
        PATH="$HOME/.local/bin:$HOME/.claude/local/bin:$PATH"
        for a in codex claude agy; do
          command -v "$a" >/dev/null 2>&1 && agents="${agents:+$agents,}$a"
        done
        selected=""
        if [ -f "$HOME/.config/agent-vm-selected-agents" ]; then
          selected=$(tr -d '\r\n ' < "$HOME/.config/agent-vm-selected-agents")
        fi
        auths=""
        [ -f "$HOME/.codex/auth.json" ] && auths="${auths:+$auths,}codex"
        [ -f "$HOME/.gemini/antigravity-cli/antigravity-oauth-token" ] && auths="${auths:+$auths,}agy"
        [ -f "$HOME/.claude/.credentials.json" ] && auths="${auths:+$auths,}claude"
        printf '%s|%s|%s|%s|%s\n' "$cpu" "$mem" "$agents" "$selected" "$auths"
        """#
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            let quotedScript = "'" + script.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
            process.arguments = ["-F", config, "-o", "BatchMode=yes", "-o", "ConnectTimeout=3",
                                 "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=2",
                                 "-o", "ServerAliveCountMax=1", "lima-" + name, "sh -c " + quotedScript]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            var result: VMUsage?
            var detectedAgents: [String]?
            var guestSelected: [String]?
            var authFlags: Set<String> = []
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0,
                   let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let last = line.components(separatedBy: .newlines).last {
                    let parts = last.split(separator: "|", omittingEmptySubsequences: false)
                    if parts.count >= 3,
                       let cpu = Double(parts[0]), let used = Double(parts[1]),
                       let total = Double(parts[2]), total > 0,
                       cpu.isFinite, used.isFinite, total.isFinite {
                        result = VMUsage(cpuPercent: min(100, max(0, cpu)),
                                         usedMemoryMB: max(0, used), totalMemoryMB: total)
                    }
                    if parts.count >= 4 {
                        detectedAgents = parts[3].split(separator: ",").map(String.init).filter { !$0.isEmpty }
                    }
                    if parts.count >= 5 {
                        let rawSel = parts[4].split(separator: ",").map(String.init).filter { ["codex", "agy", "claude"].contains($0) }
                        if !rawSel.isEmpty { guestSelected = rawSel }
                    }
                    if parts.count >= 6 {
                        authFlags = Set(parts[5].split(separator: ",").map(String.init).filter { !$0.isEmpty })
                    }
                }
            } catch {
                // SSH errors should not affect VM operations or overwrite the main error banner.
            }
            DispatchQueue.main.async {
                self.usagePolling.remove(name)
                guard self.machines.contains(where: { $0.name == name && $0.status == "Running" }) else {
                    self.vmUsage.removeValue(forKey: name)
                    self.vmAgents.removeValue(forKey: name)
                    self.usageErrors.remove(name)
                    return
                }
                if let result {
                    self.vmUsage[name] = result
                    self.usageErrors.remove(name)
                } else {
                    self.vmUsage.removeValue(forKey: name)
                    self.usageErrors.insert(name)
                }
                let effective: [String]
                if let saved = self.vmSelectedAgents[name], !saved.isEmpty {
                    effective = saved
                } else if let guestSel = guestSelected, !guestSel.isEmpty {
                    effective = guestSel
                    self.vmSelectedAgents[name] = guestSel
                    UserDefaults.standard.set(self.vmSelectedAgents, forKey: "vmSelectedAgents")
                } else if let detected = detectedAgents {
                    let detSet = Set(detected)
                    var inferred: [String] = []
                    if detSet.contains("codex") && (authFlags.contains("codex") || (!detSet.contains("agy") && !detSet.contains("claude"))) {
                        inferred.append("codex")
                    }
                    if detSet.contains("agy") { inferred.append("agy") }
                    if detSet.contains("claude") { inferred.append("claude") }
                    effective = inferred
                } else {
                    effective = []
                }
                let prev = self.vmAgents[name]
                if detectedAgents != nil || !effective.isEmpty {
                    self.vmAgents[name] = effective
                    self.cliVersionManager.pruneUnallowed(vmName: name, allowed: effective)
                    if prev != effective, let vmObj = self.machines.first(where: { $0.name == name }) {
                        self.pollQuota(for: vmObj)
                    }
                }
                let runningCheckable = self.machines.filter { $0.status == "Running" && $0.name != "base" && $0.name != "base-building" }
                if (self.cliVersionManager.latestCheckedAt == nil || !self.cliVersionManager.hasChecked(vmName: name)),
                   !runningCheckable.isEmpty,
                   runningCheckable.allSatisfy({ self.allowedCLIAgents(for: $0.name) != nil }) {
                    self.checkCLIVersions(triggerAutoUpdate: true)
                }
            }
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
    // Resume uses the agent's interactive history picker; never attaches to an
    // unknown live process or guesses a session ID.
    func resumeSession(_ vm: VM, agent: String) {
        guard vm.status == "Running", ["codex", "claude", "agy", "opencode", "vibe", "pi"].contains(agent) else { return }
        terminal(vm, resumeAgent: agent)
    }
    func stopAllAgents() {
        for (sid, proc) in codexProcesses where proc.isRunning {
            stoppedSessions.insert(sid)
            proc.terminate()
        }
        codexProcesses.removeAll()
        runningSessions.removeAll()
        runningSessionVMs.removeAll()
    }
    func stopCodex(sessionId: String? = nil, vmName: String? = nil) {
        let targets: [String]
        if let sessionId {
            targets = [sessionId]
        } else if let vmName {
            targets = runningSessionVMs.filter { $0.value == vmName }.map(\.key)
        } else {
            targets = Array(codexProcesses.keys)
        }
        for sid in targets {
            stoppedSessions.insert(sid)
            if let proc = codexProcesses[sid], proc.isRunning {
                proc.terminate()
            }
            codexProcesses.removeValue(forKey: sid)
            runningSessions.remove(sid)
            runningSessionVMs.removeValue(forKey: sid)
        }
    }
    func selectChatSession(vmName: String, sessionId: String) {
        chatStore.selectSession(vmName: vmName, sessionId: sessionId)
        chatRevision += 1
    }
    func newChatSession(vmName: String, agent: String = "codex", workdir: String = "/mnt/agent-vm-shared", mode: String = "full-auto") {
        _ = chatStore.createSession(vmName: vmName, agent: agent, workdir: workdir, mode: mode)
        chatRevision += 1
    }
    func renameChatSession(vmName: String, sessionId: String, title: String) {
        chatStore.renameSession(vmName: vmName, sessionId: sessionId, title: title)
        chatRevision += 1
    }
    func deleteChatSession(vmName: String, sessionId: String) {
        guard !runningSessions.contains(sessionId) else { return }
        chatStore.deleteSession(vmName: vmName, sessionId: sessionId)
        chatRevision += 1
    }
    func updateChatSessionConfig(vmName: String, sessionId: String, workdir: String?, mode: String?, agent: String?) {
        chatStore.updateSession(vmName: vmName, sessionId: sessionId, immediateSave: true) { s in
            if let workdir, !workdir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                s.workdir = workdir.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let mode, ["default", "full-auto", "read-only", "bypass"].contains(mode) {
                s.mode = mode
            }
            if let agent, ["codex", "claude"].contains(agent) {
                s.agent = agent
            }
        }
        chatRevision += 1
    }
    func clearCodexSession(vmName: String, sessionId: String? = nil) {
        let activeId = chatStore.activeSessionByVM[vmName]
        let current = chatStore.sessions(for: vmName).first { $0.id == activeId } ?? chatStore.sessions(for: vmName).first
        let agent = current?.agent ?? "codex"
        let workdir = current?.workdir ?? "/mnt/agent-vm-shared"
        let mode = current?.mode ?? "full-auto"
        _ = chatStore.createSession(vmName: vmName, agent: agent, workdir: workdir, mode: mode)
        chatRevision += 1
    }
    func stageChatAttachment(vmName: String) {
        guard prepareSharedFolder() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "选择要附加到对话的文件或图片（将复制到共享目录）"
        guard panel.runModal() == .OK else { return }
        let dir = URL(fileURLWithPath: NSHomeDirectory() + "/AgentVM-Shared/.attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var list = stagedAttachments[vmName] ?? []
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp"]
        let stamp = Int(Date().timeIntervalSince1970)
        for src in panel.urls {
            let base = src.lastPathComponent.replacingOccurrences(of: "/", with: "_")
            let dstName = "\(stamp)-\(base)"
            let dst = dir.appendingPathComponent(dstName)
            do {
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.copyItem(at: src, to: dst)
                let isImage = imageExts.contains(src.pathExtension.lowercased())
                list.append([
                    "id": UUID().uuidString,
                    "name": base,
                    "guestPath": "/mnt/agent-vm-shared/.attachments/" + dstName,
                    "hostPath": dst.path,
                    "isImage": isImage
                ])
            } catch {
                pushToast(title: "附加文件失败", message: error.localizedDescription, level: "error", vmName: vmName)
            }
        }
        stagedAttachments[vmName] = list
    }
    func removeChatAttachment(vmName: String, id: String) {
        stagedAttachments[vmName]?.removeAll { ($0["id"] as? String) == id }
    }
    func fetchGitDiff(vm: VM, workdir: String, filePath: String? = nil) {
        guard vm.status == "Running" else { return }
        let config = sshConfigPath(for: vm.name)
        guard FileManager.default.fileExists(atPath: config) else { return }
        func quote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }
        let targetDir = workdir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/mnt/agent-vm-shared" : workdir.trimmingCharacters(in: .whitespacesAndNewlines)
        gitDiffState = [
            "vm": vm.name,
            "workdir": targetDir,
            "file": filePath ?? "",
            "loading": true,
            "diff": "",
            "status": "",
            "error": ""
        ]
        let fileArg = (filePath?.isEmpty == false) ? " -- \(quote(filePath!))" : ""
        let remoteCmd = "git -C \(quote(targetDir)) status --short && echo '---AVM-DIFF---' && git -C \(quote(targetDir)) diff --no-color\(fileArg)"
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process(), out = Pipe(), err = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = ["-F", config, "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "lima-" + vm.name, remoteCmd]
            proc.standardOutput = out
            proc.standardError = err
            do {
                try proc.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let parts = text.components(separatedBy: "---AVM-DIFF---\n")
                let statusPart = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let diffPart = parts.count > 1 ? parts[1] : ""
                let clippedDiff = diffPart.count > 120000 ? String(diffPart.prefix(120000)) + "\n... (diff 已截断)" : diffPart
                DispatchQueue.main.async {
                    self.gitDiffState = [
                        "vm": vm.name,
                        "workdir": targetDir,
                        "file": filePath ?? "",
                        "loading": false,
                        "status": statusPart,
                        "diff": clippedDiff,
                        "error": proc.terminationStatus == 0 ? "" : (errText.isEmpty ? "当前目录不是 Git 仓库或无法读取 diff" : errText)
                    ]
                }
            } catch {
                DispatchQueue.main.async {
                    self.gitDiffState = [
                        "vm": vm.name,
                        "workdir": targetDir,
                        "file": filePath ?? "",
                        "loading": false,
                        "status": "",
                        "diff": "",
                        "error": error.localizedDescription
                    ]
                }
            }
        }
    }
    static func generateToken() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<24).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }
    func toggleRemoteWorkbench(_ enabled: Bool) {
        remoteWorkbenchEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "remoteWorkbenchEnabled")
        if enabled {
            if remoteWorkbenchToken.isEmpty {
                remoteWorkbenchToken = "Zhuyq020110"
                UserDefaults.standard.set(remoteWorkbenchToken, forKey: "remoteWorkbenchToken")
            }
            remoteWorkbenchServer.start(port: UInt16(remoteWorkbenchPort), token: remoteWorkbenchToken)
            refresh()
        } else {
            remoteWorkbenchError = ""
            remoteWorkbenchServer.stop()
        }
    }
    func setRemoteWorkbenchToken(_ newToken: String) {
        let trimmed = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        remoteWorkbenchToken = trimmed
        UserDefaults.standard.set(trimmed, forKey: "remoteWorkbenchToken")
        remoteWorkbenchServer.updateToken(trimmed)
    }
    func regenerateRemoteWorkbenchToken() {
        remoteWorkbenchToken = Self.generateToken()
        UserDefaults.standard.set(remoteWorkbenchToken, forKey: "remoteWorkbenchToken")
        remoteWorkbenchServer.updateToken(remoteWorkbenchToken)
    }
    func setRemoteWorkbenchPort(_ port: Int) {
        guard (1024...65535).contains(port), port != remoteWorkbenchPort else { return }
        remoteWorkbenchPort = port
        UserDefaults.standard.set(port, forKey: "remoteWorkbenchPort")
        if remoteWorkbenchEnabled {
            remoteWorkbenchServer.start(port: UInt16(port), token: remoteWorkbenchToken)
        }
    }
    func remoteWorkbenchURLs() -> [String] {
        let ips = RemoteWorkbenchServer.localIPv4Addresses()
        let q = remoteWorkbenchToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? remoteWorkbenchToken
        return ips.map { "http://\($0):\(remoteWorkbenchPort)/?token=\(q)" }
    }
    func runCodex(vm: VM, sessionId: String? = nil, workdir: String, prompt: String, mode: String, agent: String = "codex", resume: Bool, truncateFromMsgId: String? = nil) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard vm.status == "Running", !trimmed.isEmpty else { return }
        let targetDir = workdir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/mnt/agent-vm-shared" : workdir.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeSession: AgentSession
        if let sessionId, let found = chatStore.session(vmName: vm.name, sessionId: sessionId) {
            chatStore.selectSession(vmName: vm.name, sessionId: found.id)
            activeSession = found
        } else {
            activeSession = chatStore.ensureActiveSession(vmName: vm.name, defaultWorkdir: targetDir, defaultMode: mode)
        }
        let sid = activeSession.id
        guard !runningSessions.contains(sid) else { return }

        let config = sshConfigPath(for: vm.name)
        guard FileManager.default.fileExists(atPath: config) else {
            pushToast(title: "无法启动对话", message: "找不到该虚拟机的 SSH 配置，请启动虚拟机后刷新。", level: "error", vmName: vm.name)
            return
        }
        func quote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }

        let chosenAgent = ["codex", "claude"].contains(agent) ? agent : activeSession.agent
        let attachments = stagedAttachments[vm.name] ?? []
        let attachmentPaths = attachments.compactMap { $0["guestPath"] as? String }
        stagedAttachments[vm.name] = []

        var fullPrompt = trimmed
        if !attachmentPaths.isEmpty {
            let listText = attachmentPaths.map { "- \($0)" }.joined(separator: "\n")
            fullPrompt += "\n\n[附加文件（位于虚拟机共享目录）]\n" + listText
        }

        let threadId = (resume && truncateFromMsgId == nil) ? activeSession.threadId : ""
        let agentCmd: String
        if chosenAgent == "claude" {
            let permFlag: String
            switch mode {
            case "read-only": permFlag = "--permission-mode plan"
            case "bypass": permFlag = "--dangerously-skip-permissions"
            case "full-auto": permFlag = "--permission-mode acceptEdits"
            default: permFlag = ""
            }
            let resumeFlag = !threadId.isEmpty ? "--resume \(quote(threadId)) " : ""
            agentCmd = "claude -p --verbose --output-format stream-json \(resumeFlag)\(permFlag) -"
        } else {
            let modeFlags: String
            switch mode {
            case "full-auto": modeFlags = "--full-auto"
            case "read-only": modeFlags = "-s read-only"
            case "bypass": modeFlags = "--dangerously-bypass-approvals-and-sandbox"
            default: modeFlags = ""
            }
            if !threadId.isEmpty {
                agentCmd = "codex exec resume \(quote(threadId)) --json --skip-git-repo-check \(modeFlags) -"
            } else {
                agentCmd = "codex exec --json --skip-git-repo-check \(modeFlags) -"
            }
        }
        let remoteCmd = "cd -- \(quote(targetDir)) && exec zsh -lc \(quote(agentCmd))"

        let now = Date().timeIntervalSince1970
        let userMsgId = UUID().uuidString
        let assistantMsgId = UUID().uuidString
        let userMsg = ChatMessage(id: userMsgId, role: "user", text: trimmed, status: "done", startedAt: now, finishedAt: now, attachments: attachmentPaths.isEmpty ? nil : attachmentPaths)
        let assistantMsg = ChatMessage(id: assistantMsgId, role: "assistant", text: "", status: "running", startedAt: now, items: [])

        chatStore.updateSession(vmName: vm.name, sessionId: sid, immediateSave: true) { s in
            s.agent = chosenAgent
            s.workdir = targetDir
            s.mode = mode
            if let cutId = truncateFromMsgId, let cutIdx = s.messages.firstIndex(where: { $0.id == cutId }) {
                s.messages.removeSubrange(cutIdx..<s.messages.count)
                if cutIdx == 0 { s.threadId = "" }
            }
            if s.messages.isEmpty || s.title == "新对话" {
                s.title = AgentChatStore.deriveTitle(from: trimmed)
            }
            s.messages.append(userMsg)
            s.messages.append(assistantMsg)
        }
        stoppedSessions.remove(sid)
        runningSessions.insert(sid)
        runningSessionVMs[sid] = vm.name
        chatRevision += 1

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-F", config, "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                             "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
                             "lima-" + vm.name, remoteCmd]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        codexProcesses[sid] = process

        final class StreamBuffers: @unchecked Sendable {
            let lock = NSLock()
            var out = Data()
            var err = Data()
        }
        let buffers = StreamBuffers()

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            buffers.lock.lock()
            buffers.out.append(chunk)
            var lines: [String] = []
            while let nl = buffers.out.firstIndex(of: 0x0a) {
                let lineData = buffers.out.subdata(in: buffers.out.startIndex..<nl)
                buffers.out.removeSubrange(buffers.out.startIndex...nl)
                if let line = String(data: lineData, encoding: .utf8), !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append(line)
                }
            }
            buffers.lock.unlock()
            if !lines.isEmpty {
                DispatchQueue.main.async {
                    for line in lines {
                        self?.applyAgentEventLine(vmName: vm.name, sessionId: sid, agent: chosenAgent, assistantMsgId: assistantMsgId, line: line)
                    }
                }
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            buffers.lock.lock()
            buffers.err.append(chunk)
            buffers.lock.unlock()
        }

        process.terminationHandler = { [weak self] proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            buffers.lock.lock()
            let remOut = buffers.out
            let remErr = buffers.err
            buffers.out.removeAll()
            buffers.err.removeAll()
            buffers.lock.unlock()

            let tailLines = (String(data: remOut, encoding: .utf8) ?? "")
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let stderrText = (String(data: remErr, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            DispatchQueue.main.async {
                guard let self else { return }
                for line in tailLines {
                    self.applyAgentEventLine(vmName: vm.name, sessionId: sid, agent: chosenAgent, assistantMsgId: assistantMsgId, line: line)
                }
                self.finishAgentMessage(vm: vm, sessionId: sid, assistantMsgId: assistantMsgId, status: proc.terminationStatus, stderrText: stderrText)
                if self.codexProcesses[sid] === proc {
                    self.codexProcesses.removeValue(forKey: sid)
                }
                self.runningSessions.remove(sid)
                self.runningSessionVMs.removeValue(forKey: sid)
                self.chatRevision += 1
            }
        }

        do {
            try process.run()
            if let inputData = (fullPrompt + "\n").data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(inputData)
            }
            try? stdinPipe.fileHandleForWriting.close()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            codexProcesses.removeValue(forKey: sid)
            runningSessions.remove(sid)
            runningSessionVMs.removeValue(forKey: sid)
            finishAgentMessage(vm: vm, sessionId: sid, assistantMsgId: assistantMsgId, status: 1, stderrText: "无法启动 SSH 进程：\(error.localizedDescription)")
            chatRevision += 1
        }
    }
    private func applyAgentEventLine(vmName: String, sessionId: String, agent: String, assistantMsgId: String, line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            // Non-JSON line fallback (e.g. plain text output)
            if agent == "claude" && !line.isEmpty {
                chatStore.updateSession(vmName: vmName, sessionId: sessionId) { s in
                    guard let idx = s.messages.firstIndex(where: { $0.id == assistantMsgId }) else { return }
                    s.messages[idx].text += (s.messages[idx].text.isEmpty ? "" : "\n") + line
                }
                chatRevision += 1
            }
            return
        }

        if agent == "claude" {
            applyClaudeEvent(vmName: vmName, sessionId: sessionId, assistantMsgId: assistantMsgId, type: type, obj: obj)
            return
        }

        if type == "thread.started", let tid = obj["thread_id"] as? String, !tid.isEmpty {
            chatStore.updateSession(vmName: vmName, sessionId: sessionId, immediateSave: true) { s in
                s.threadId = tid
            }
            chatRevision += 1
            return
        }

        chatStore.updateSession(vmName: vmName, sessionId: sessionId) { s in
            guard let idx = s.messages.firstIndex(where: { $0.id == assistantMsgId }) else { return }
            if (type == "item.started" || type == "item.updated" || type == "item.completed"),
               let item = obj["item"] as? [String: Any] {
                let itemType = item["type"] as? String ?? ""
                if itemType == "agent_message" {
                    let text = item["text"] as? String ?? ""
                    if !text.isEmpty {
                        s.messages[idx].text = text
                    }
                } else {
                    var items = s.messages[idx].items ?? []
                    let itemId = item["id"] as? String ?? UUID().uuidString
                    var changes: [ChatFileChange]? = nil
                    if let rawChanges = item["changes"] as? [[String: Any]] {
                        changes = rawChanges.compactMap { c in
                            guard let p = c["path"] as? String else { return nil }
                            return ChatFileChange(path: p, kind: (c["kind"] as? String) ?? "modify")
                        }
                    }
                    let rawOut = item["aggregated_output"] as? String
                    let clippedOut = rawOut.map { $0.count > 24000 ? String($0.suffix(24000)) : $0 }
                    let entry = ChatStepItem(
                        id: itemId,
                        type: itemType,
                        status: item["status"] as? String,
                        text: item["text"] as? String,
                        command: item["command"] as? String,
                        output: clippedOut,
                        exitCode: item["exit_code"] as? Int,
                        changes: changes
                    )
                    if let existing = items.firstIndex(where: { $0.id == itemId }) {
                        items[existing] = entry
                    } else {
                        items.append(entry)
                    }
                    s.messages[idx].items = items
                }
            } else if type == "turn.completed", let usage = obj["usage"] as? [String: Any] {
                s.messages[idx].usage = ChatTokenUsage(
                    inputTokens: usage["input_tokens"] as? Int,
                    cachedInputTokens: usage["cached_input_tokens"] as? Int,
                    outputTokens: usage["output_tokens"] as? Int
                )
            } else if type == "turn.failed" || type == "error" {
                let errObj = obj["error"] as? [String: Any]
                let errMsg = (errObj?["message"] as? String) ?? (obj["message"] as? String) ?? "执行失败"
                s.messages[idx].error = errMsg
                s.messages[idx].status = "error"
            }
        }
        chatRevision += 1
    }
    private func applyClaudeEvent(vmName: String, sessionId: String, assistantMsgId: String, type: String, obj: [String: Any]) {
        if let sid = obj["session_id"] as? String, !sid.isEmpty {
            chatStore.updateSession(vmName: vmName, sessionId: sessionId, immediateSave: true) { s in
                s.threadId = sid
            }
        }
        chatStore.updateSession(vmName: vmName, sessionId: sessionId) { s in
            guard let idx = s.messages.firstIndex(where: { $0.id == assistantMsgId }) else { return }
            if type == "assistant", let message = obj["message"] as? [String: Any],
               let contents = message["content"] as? [[String: Any]] {
                var items = s.messages[idx].items ?? []
                var textParts: [String] = []
                for block in contents {
                    let btype = block["type"] as? String ?? ""
                    if btype == "text", let t = block["text"] as? String, !t.isEmpty {
                        textParts.append(t)
                    } else if btype == "thinking", let t = block["thinking"] as? String, !t.isEmpty {
                        let id = "thinking-\(items.count)"
                        items.append(ChatStepItem(id: id, type: "reasoning", status: "completed", text: t))
                    } else if btype == "tool_use" {
                        let id = block["id"] as? String ?? UUID().uuidString
                        let name = block["name"] as? String ?? "tool"
                        let inputStr = (try? JSONSerialization.data(withJSONObject: block["input"] ?? [:]))
                            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        let cmdLabel = "\(name) \(inputStr)"
                        let entry = ChatStepItem(id: id, type: "command_execution", status: "in_progress", text: nil, command: cmdLabel)
                        if let existing = items.firstIndex(where: { $0.id == id }) { items[existing] = entry } else { items.append(entry) }
                    }
                }
                if !textParts.isEmpty { s.messages[idx].text = textParts.joined(separator: "\n") }
                s.messages[idx].items = items
            } else if type == "user", let message = obj["message"] as? [String: Any],
                      let contents = message["content"] as? [[String: Any]] {
                var items = s.messages[idx].items ?? []
                for block in contents where (block["type"] as? String) == "tool_result" {
                    let toolId = block["tool_use_id"] as? String ?? ""
                    if let existing = items.firstIndex(where: { $0.id == toolId }) {
                        items[existing].status = "completed"
                        if let out = block["content"] as? String {
                            items[existing].output = out.count > 24000 ? String(out.suffix(24000)) : out
                        }
                        items[existing].exitCode = (block["is_error"] as? Bool) == true ? 1 : 0
                    }
                }
                s.messages[idx].items = items
            } else if type == "result" {
                if let res = obj["result"] as? String, !res.isEmpty {
                    s.messages[idx].text = res
                }
                if let usage = obj["usage"] as? [String: Any] {
                    s.messages[idx].usage = ChatTokenUsage(
                        inputTokens: usage["input_tokens"] as? Int,
                        cachedInputTokens: usage["cache_read_input_tokens"] as? Int,
                        outputTokens: usage["output_tokens"] as? Int
                    )
                }
                if (obj["is_error"] as? Bool) == true {
                    s.messages[idx].status = "error"
                    s.messages[idx].error = (obj["result"] as? String) ?? "Claude Code 执行失败"
                }
            }
        }
        chatRevision += 1
    }
    private func finishAgentMessage(vm: VM, sessionId: String, assistantMsgId: String, status: Int32, stderrText: String) {
        let wasStopped = stoppedSessions.remove(sessionId) != nil
        let now = Date().timeIntervalSince1970
        var finalStatus = "done"
        var finalTitle = ""
        chatStore.updateSession(vmName: vm.name, sessionId: sessionId, immediateSave: true) { s in
            finalTitle = s.title
            guard let idx = s.messages.firstIndex(where: { $0.id == assistantMsgId }) else { return }
            s.messages[idx].finishedAt = now
            // Close any lingering in-progress steps
            if var items = s.messages[idx].items {
                for i in items.indices where items[i].status == "in_progress" {
                    items[i].status = wasStopped ? "stopped" : (status == 0 ? "completed" : "failed")
                }
                s.messages[idx].items = items
            }
            if wasStopped {
                s.messages[idx].status = "stopped"
                finalStatus = "stopped"
            } else if status != 0 {
                if (s.messages[idx].error ?? "").isEmpty {
                    s.messages[idx].error = stderrText.isEmpty ? "Agent 退出码：\(status)" : stderrText
                }
                if s.messages[idx].status == "running" {
                    s.messages[idx].status = "error"
                }
                finalStatus = "error"
            } else if s.messages[idx].status == "running" {
                s.messages[idx].status = "done"
                finalStatus = "done"
            } else {
                finalStatus = s.messages[idx].status
            }
        }
        let label = displayName(for: vm)
        if finalStatus == "done" {
            pushToast(title: "\(label) 任务完成", message: finalTitle, level: "ok", vmName: vm.name)
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        } else if finalStatus == "error" {
            pushToast(title: "\(label) 任务失败", message: finalTitle, level: "error", vmName: vm.name)
            if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
        }
    }
    func terminal(_ vm: VM, resumeAgent: String? = nil) {
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
            let safeName = vm.name
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let scriptName = safeName.isEmpty ? "Connect" : safeName
            let title = String(vm.name.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f })
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-vm-terminal-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let script = directory.appendingPathComponent("\(scriptName).command")
            var command = "exec /usr/bin/ssh -F \(quote(config)) -o ForwardAgent=no -o ForwardX11=no -tt \(quote("lima-" + vm.name))"
            let mount = vmMounts[vm.name]?.first
            let isStandalone = mount?.location.hasPrefix(NSHomeDirectory() + "/AgentVM-Workspaces/") == true
            let guestDir = isStandalone ? "/mnt/agent-vm-shared" : (mount?.guestPath ?? "/mnt/agent-vm-shared")
            if let agent = resumeAgent, ["codex", "claude", "agy", "opencode", "vibe", "pi"].contains(agent) {
                // The CLI presents its own history selector. No live process is attached.
                let resumeCommand: String
                switch agent {
                case "codex": resumeCommand = "codex resume"
                case "claude": resumeCommand = "claude --resume"
                default: resumeCommand = agent
                }
                let remote = "cd -- " + quote(guestDir) + " && exec bash -lic " + quote(resumeCommand)
                command += " " + quote(remote)
            } else if mount != nil {
                command += " " + quote("cd -- " + quote(guestDir) + " && exec \"$SHELL\" -l")
            }
            let setTitle = title.isEmpty ? "" : "printf '\\033]0;%s\\007' \(quote(title))\n"
            let contents = "#!/bin/sh\nrm -f -- \"$0\"\nrmdir -- \"$(dirname -- \"$0\")\" 2>/dev/null || true\n" + setTitle + command + "\n"
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
        stopCodex(vmName: vm.name)
        operationFailed = false
        busy = true
        run(["rm", vm.name]) { code, text in
            self.output = text
            self.operationFailed = code != 0
            if code == 0 {
                self.vmMounts.removeValue(forKey: vm.name)
                self.managedFolders.removeValue(forKey: vm.name)
                self.vmQuotas.removeValue(forKey: vm.name)
                self.vmAgentQuotas.removeValue(forKey: vm.name)
                self.vmSelectedAgents.removeValue(forKey: vm.name)
                UserDefaults.standard.set(self.vmSelectedAgents, forKey: "vmSelectedAgents")
                self.vmUsage.removeValue(forKey: vm.name)
                self.usageErrors.remove(vm.name)
                self.vmProxyRoutes.removeValue(forKey: vm.name)
                self.chatStore.removeAllSessions(for: vm.name)
                self.chatRevision += 1
                UserDefaults.standard.set(self.vmProxyRoutes, forKey: "vmProxyRoutes")
            }
            self.stopVMMihomo(vm.name)
            self.busy = false
            self.refresh()
        }
    }
    func stop(_ vm: VM) {
        busy = true
        run(["stop", vm.name]) { code, text in
            self.stopVMMihomo(vm.name)
            self.output = text; self.operationFailed = code != 0; self.busy = false; self.refresh()
        }
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
            self.run(["run", "true"], cwd: project, vmName: vm.name) { code, text in
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
    func hostDiskAvailGB() -> Int {
        let state = ProcessInfo.processInfo.environment["AGENT_VM_STATE_DIR"] ?? NSHomeDirectory() + "/.agent-vm"
        let vals = try? URL(fileURLWithPath: state).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let bytes = vals?.volumeAvailableCapacityForImportantUsage ?? Int64(vals?.volumeAvailableCapacity ?? 0)
        return max(0, Int(bytes >> 30))
    }
    static func parseDiskGiB(_ raw: String) -> Int {
        let digits = raw.prefix(while: { $0.isNumber })
        return Int(digits) ?? 0
    }
    func resizeDisk(_ vm: VM, diskGiB: Int) {
        guard !busy, vm.name != "base", vm.name != "base-building" else { return }
        let curGiB = Self.parseDiskGiB(vm.disk)
        guard diskGiB > curGiB, (10...1024).contains(diskGiB) else {
            output = "目标磁盘容量必须大于当前容量（\(vm.disk)）且不超过 1024 GiB。"
            operationFailed = true
            pushToast(title: "无法调整磁盘容量", message: output, level: "error", vmName: vm.name)
            return
        }
        guard let project = vmMounts[vm.name]?.first?.location else {
            output = "无法确定该虚拟机的项目文件夹。"; operationFailed = true; return
        }
        busy = true
        output = "正在为 \(displayName(for: vm)) 调整存储容量至 \(diskGiB) GiB…\n"
        pushToast(title: "正在调整磁盘容量", message: "\(displayName(for: vm)) → \(diskGiB) GiB（完成后将自动重启）", level: "info", vmName: vm.name)

        let applyResize = {
            self.run(["name", project]) { code, name in
                guard code == 0, name.trimmingCharacters(in: .whitespacesAndNewlines) == vm.name else {
                    self.output = "项目文件夹与虚拟机身份不匹配，无法调整磁盘。\n" + name
                    self.operationFailed = true; self.busy = false; self.refresh()
                    return
                }
                self.run(["run", "--disk", String(diskGiB), "true"], cwd: project, vmName: vm.name) { code, text in
                    self.output = text
                    self.operationFailed = code != 0
                    self.busy = false
                    self.refresh()
                    if code == 0 {
                        self.checkCodexDesktop(vm)
                        self.pushToast(title: "磁盘扩容完成", message: "\(self.displayName(for: vm)) 已扩展到 \(diskGiB) GiB", level: "ok", vmName: vm.name)
                    } else {
                        self.pushToast(title: "磁盘扩容失败", message: text, level: "error", vmName: vm.name)
                    }
                }
            }
        }

        if vm.status == "Running" {
            run(["stop", vm.name]) { code, text in
                self.stopVMMihomo(vm.name)
                guard code == 0 else {
                    self.output = text; self.operationFailed = true; self.busy = false; self.refresh()
                    self.pushToast(title: "停止虚拟机失败", message: text, level: "error", vmName: vm.name)
                    return
                }
                applyResize()
            }
        } else {
            applyResize()
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

    func setVMProxyRoute(_ vm: VM, nodeId: String) {
        if nodeId.isEmpty {
            vmProxyRoutes.removeValue(forKey: vm.name)
            UserDefaults.standard.set(vmProxyRoutes, forKey: "vmProxyRoutes")
            stopVMMihomo(vm.name)
            proxyMessage = vm.status == "Running"
                ? "已将「\(displayName(for: vm))」恢复为跟随全局出口；重启该虚拟机后生效。"
                : "已将「\(displayName(for: vm))」恢复为跟随全局出口。"
            return
        }
        vmProxyRoutes[vm.name] = nodeId
        UserDefaults.standard.set(vmProxyRoutes, forKey: "vmProxyRoutes")
        let sock = vmMihomoSocketPath(vm.name)
        if vm.status == "Running", vmMihomoProcesses[vm.name]?.isRunning == true,
           FileManager.default.fileExists(atPath: sock),
           let body = try? JSONSerialization.data(withJSONObject: ["name": nodeId]),
           let json = String(data: body, encoding: .utf8) {
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                p.arguments = ["--silent", "--show-error", "--fail", "--unix-socket", sock,
                               "-X", "PUT", "http://localhost/proxies/agentvm-exit",
                               "-H", "Content-Type: application/json", "-d", json]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
                p.waitUntilExit()
                DispatchQueue.main.async {
                    if p.terminationStatus == 0 {
                        self.proxyMessage = "已切换「\(self.displayName(for: vm))」的独立代理出口。"
                    } else {
                        self.proxyMessage = "已保存「\(self.displayName(for: vm))」的独立出口；重启该虚拟机后生效。"
                    }
                }
            }
        } else {
            proxyMessage = vm.status == "Running"
                ? "已保存「\(displayName(for: vm))」的独立出口；重启该虚拟机后生效。"
                : "已保存「\(displayName(for: vm))」的独立出口，下次启动时生效。"
        }
    }

    private func vmMihomoDir(_ vmName: String) -> String {
        let state = ProcessInfo.processInfo.environment["AGENT_VM_STATE_DIR"] ?? NSHomeDirectory() + "/.agent-vm"
        return state + "/proxy/vms/" + vmName
    }

    private func vmMihomoSocketPath(_ vmName: String) -> String {
        let hash = abs(vmName.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1) }) % 100000
        return "/tmp/agentvm-vm-\(getuid())-\(hash).sock"
    }

    private func vmMihomoPort(_ vmName: String) -> Int {
        let hash = abs(vmName.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1) }) % 900
        return 17900 + hash
    }

    func stopVMMihomo(_ vmName: String) {
        if let proc = vmMihomoProcesses.removeValue(forKey: vmName), proc.isRunning {
            proc.terminate()
        }
        try? FileManager.default.removeItem(atPath: vmMihomoSocketPath(vmName))
    }

    func stopAllVMMihomo() {
        for name in Array(vmMihomoProcesses.keys) { stopVMMihomo(name) }
    }

    private func prepareVMManagedNetworkConfig(for vmName: String, nodeId: String) -> String? {
        guard let st = proxyStatus, !st.managedConfigPath.isEmpty else { return nil }
        let state = ProcessInfo.processInfo.environment["AGENT_VM_STATE_DIR"] ?? NSHomeDirectory() + "/.agent-vm"
        let baseConfigPath = state + "/proxy/config.yaml"
        let mihomoPath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/mihomo").path
        guard FileManager.default.isExecutableFile(atPath: mihomoPath),
              let rawYaml = try? String(contentsOfFile: baseConfigPath, encoding: .utf8),
              let baseManagedData = try? Data(contentsOf: URL(fileURLWithPath: st.managedConfigPath)),
              var managedObj = try? JSONSerialization.jsonObject(with: baseManagedData) as? [String: Any],
              let baseProxyURL = managedObj["proxy_url"] as? String,
              var comps = URLComponents(string: baseProxyURL) else { return nil }

        let vmPort = vmMihomoPort(vmName)
        let vmSock = vmMihomoSocketPath(vmName)
        let vmDir = vmMihomoDir(vmName)
        let vmConfigPath = vmDir + "/config.yaml"
        let vmManagedPath = vmDir + "/managed-network.json"

        var allNodes = st.safeSources.flatMap { $0.safeNodes.map(\.id) }.filter { $0 != nodeId }
        allNodes.insert(nodeId, at: 0)

        var outLines: [String] = []
        var skippingProxyGroups = false
        for line in rawYaml.components(separatedBy: .newlines) {
            if skippingProxyGroups {
                if !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("-") {
                    skippingProxyGroups = false
                } else {
                    continue
                }
            }
            if line.hasPrefix("mixed-port:") {
                outLines.append("mixed-port: \(vmPort)")
            } else if line.hasPrefix("external-controller-unix:") {
                outLines.append("external-controller-unix: \(vmSock)")
            } else if line.hasPrefix("proxy-groups:") {
                skippingProxyGroups = true
                outLines.append("proxy-groups:")
                outLines.append("  - name: agentvm-exit")
                outLines.append("    type: select")
                outLines.append("    proxies:")
                for n in allNodes {
                    let escaped = n.replacingOccurrences(of: "\"", with: "\\\"")
                    outLines.append("      - \"\(escaped)\"")
                }
            } else {
                outLines.append(line)
            }
        }

        do {
            try FileManager.default.createDirectory(atPath: vmDir, withIntermediateDirectories: true)
            let yamlText = outLines.joined(separator: "\n") + "\n"
            try yamlText.write(toFile: vmConfigPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vmConfigPath)

            comps.port = vmPort
            managedObj["proxy_url"] = comps.string ?? baseProxyURL
            let managedData = try JSONSerialization.data(withJSONObject: managedObj)
            try managedData.write(to: URL(fileURLWithPath: vmManagedPath), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vmManagedPath)

            stopVMMihomo(vmName)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: mihomoPath)
            proc.arguments = ["-d", state + "/proxy", "-f", vmConfigPath]
            proc.standardInput = FileHandle.nullDevice
            let logURL = URL(fileURLWithPath: vmDir + "/mihomo.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            if let fh = try? FileHandle(forWritingTo: logURL) {
                proc.standardOutput = fh
                proc.standardError = fh
            }
            try proc.run()
            vmMihomoProcesses[vmName] = proc

            let deadline = Date().addingTimeInterval(3.0)
            while Date() < deadline && !FileManager.default.fileExists(atPath: vmSock) {
                Thread.sleep(forTimeInterval: 0.05)
            }
            return vmManagedPath
        } catch {
            return nil
        }
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
        let configuredAgents = vmSelectedAgents[vmName] ?? vmAgents[vmName] ?? []
        let targetsJSONData = (try? JSONSerialization.data(withJSONObject: configuredAgents)) ?? Data("[]".utf8)
        let targetsJSON = String(data: targetsJSONData, encoding: .utf8) ?? "[]"
        let script = """
import datetime, json, os, shutil, subprocess, urllib.error, urllib.request

SUPPORTED = ('codex', 'agy', 'claude')
targets = [a for a in \(targetsJSON) if a in SUPPORTED]
env_path = os.path.expanduser('~/.local/bin') + ':' + os.path.expanduser('~/.claude/local/bin') + ':' + os.environ.get('PATH', '')

if not targets:
    sel_file = os.path.expanduser('~/.config/agent-vm-selected-agents')
    if os.path.isfile(sel_file):
        try:
            raw = open(sel_file).read().strip()
            targets = [x.strip() for x in raw.split(',') if x.strip() in SUPPORTED]
        except Exception:
            pass
    if not targets:
        has_codex = bool(shutil.which('codex', path=env_path))
        has_agy = bool(shutil.which('agy', path=env_path))
        has_claude = bool(shutil.which('claude', path=env_path))
        if has_codex and (os.path.exists(os.path.expanduser('~/.codex/auth.json')) or (not has_agy and not has_claude)):
            targets.append('codex')
        if has_agy:
            targets.append('agy')
        if has_claude:
            targets.append('claude')

def iso_to_epoch_and_left(iso_str):
    if not iso_str or not isinstance(iso_str, str):
        return None, None
    try:
        dt = datetime.datetime.fromisoformat(iso_str.replace('Z', '+00:00'))
        epoch = int(dt.timestamp())
        left = max(0, int(epoch - datetime.datetime.now(datetime.timezone.utc).timestamp()))
        return epoch, left
    except Exception:
        return None, None

def query_codex():
    p = os.path.expanduser('~/.codex/auth.json')
    if not os.path.exists(p):
        return {'status': 'not_logged_in'}
    try:
        d = json.load(open(p))
        tok = d.get('tokens', {}).get('access_token', '')
        acc = d.get('tokens', {}).get('account_id', '')
        if not tok:
            return {'status': 'not_logged_in'}
        req = urllib.request.Request('https://chatgpt.com/backend-api/wham/usage', headers={
            'Authorization': 'Bearer ' + tok,
            'ChatGPT-Account-Id': acc,
            'Accept': 'application/json',
            'User-Agent': 'codex-cli/0.169.0',
        })
        with urllib.request.urlopen(req, timeout=10) as r:
            u = json.loads(r.read().decode())
        rl = u.get('rate_limit', {}) or {}
        windows = []
        for key, label in (('primary_window', '5 小时'), ('secondary_window', '每周')):
            w = rl.get(key)
            if isinstance(w, dict) and w.get('used_percent') is not None:
                windows.append({
                    'label': label,
                    'used_percent': int(round(w['used_percent'])),
                    'reset_after_seconds': w.get('reset_after_seconds'),
                    'reset_at': w.get('reset_at'),
                })
        return {'status': 'ok', 'plan_type': u.get('plan_type'), 'windows': windows}
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            return {'status': 'unauthorized', 'error': f'Codex 登录已过期 (HTTP {e.code})'}
        return {'status': 'error', 'error': f'HTTP {e.code}'}
    except Exception as e:
        return {'status': 'error', 'error': str(e)[:120]}

def query_agy():
    p = os.path.expanduser('~/.gemini/antigravity-cli/antigravity-oauth-token')
    if not os.path.exists(p):
        return {'status': 'not_logged_in'}
    def call_api(tok):
        req = urllib.request.Request(
            'https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels',
            data=b'{}',
            headers={
                'Authorization': 'Bearer ' + tok,
                'Content-Type': 'application/json',
                'User-Agent': 'antigravity/1.5.11 linux/arm64',
            },
            method='POST',
        )
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read().decode())
    try:
        d = json.load(open(p))
        tok = (d.get('token') or {}).get('access_token', '')
        if not tok:
            return {'status': 'not_logged_in'}
        try:
            body = call_api(tok)
        except urllib.error.HTTPError as e:
            if e.code == 401 and shutil.which('agy', path=env_path):
                subprocess.run(['agy', 'models'], env=dict(os.environ, PATH=env_path), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=12)
                d = json.load(open(p))
                tok = (d.get('token') or {}).get('access_token', '')
                body = call_api(tok)
            else:
                raise
        models = body.get('models') or {}
        windows = []
        for label, prefix_tuple in (('Gemini', ('gemini-',)), ('Claude', ('claude-', 'gpt-'))):
            candidates = []
            for mid, info in models.items():
                if not mid.startswith(prefix_tuple):
                    continue
                qi = info.get('quotaInfo') if isinstance(info, dict) else None
                if isinstance(qi, dict) and qi.get('remainingFraction') is not None:
                    candidates.append(qi)
            if candidates:
                chosen = min(candidates, key=lambda q: float(q.get('remainingFraction', 1.0)))
                rem = max(0.0, min(1.0, float(chosen.get('remainingFraction', 1.0))))
                used_pct = max(0, min(100, int(round((1.0 - rem) * 100))))
                epoch, left = iso_to_epoch_and_left(chosen.get('resetTime'))
                windows.append({
                    'label': label,
                    'used_percent': used_pct,
                    'reset_after_seconds': left,
                    'reset_at': epoch,
                })
        plan = d.get('id_token_email') or d.get('auth_method')
        return {'status': 'ok', 'plan_type': plan, 'windows': windows}
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            return {'status': 'unauthorized', 'error': f'Antigravity 登录已过期 (HTTP {e.code})'}
        return {'status': 'error', 'error': f'HTTP {e.code}'}
    except Exception as e:
        return {'status': 'error', 'error': str(e)[:120]}

def query_claude():
    cred = os.path.expanduser('~/.claude/.credentials.json')
    tok = ''
    plan = None
    if os.path.exists(cred):
        try:
            cd = json.load(open(cred))
            oauth = cd.get('claudeAiOauth') or {}
            tok = oauth.get('accessToken', '')
            plan = oauth.get('subscriptionType')
        except Exception:
            pass
    if not tok:
        cli = shutil.which('claude', path=env_path)
        if cli:
            try:
                out = subprocess.run([cli, 'auth', 'status'], env=dict(os.environ, PATH=env_path), capture_output=True, text=True, timeout=6)
                if out.returncode == 0 and out.stdout.strip().startswith('{'):
                    st = json.loads(out.stdout)
                    if st.get('loggedIn') and st.get('authMethod') not in (None, '', 'none'):
                        return {'status': 'api_key', 'plan_type': st.get('authMethod'), 'error': 'API Key 鉴权无窗口额度'}
            except Exception:
                pass
        return {'status': 'not_logged_in'}
    try:
        req = urllib.request.Request('https://api.anthropic.com/api/oauth/usage', headers={
            'Authorization': 'Bearer ' + tok,
            'anthropic-beta': 'oauth-2025-04-20',
            'Accept': 'application/json',
            'User-Agent': 'claude-code/2.1.0',
        })
        with urllib.request.urlopen(req, timeout=10) as r:
            u = json.loads(r.read().decode())
        windows = []
        for key, label in (('five_hour', '5 小时'), ('seven_day', '每周')):
            w = u.get(key)
            if isinstance(w, dict) and w.get('utilization') is not None:
                epoch, left = iso_to_epoch_and_left(w.get('resets_at'))
                windows.append({
                    'label': label,
                    'used_percent': max(0, min(100, int(round(float(w['utilization']))))),
                    'reset_after_seconds': left,
                    'reset_at': epoch,
                })
        return {'status': 'ok', 'plan_type': plan or 'Claude OAuth', 'windows': windows}
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            return {'status': 'unauthorized', 'error': f'Claude 登录已过期 (HTTP {e.code})'}
        return {'status': 'error', 'error': f'HTTP {e.code}'}
    except Exception as e:
        return {'status': 'error', 'error': str(e)[:120]}

handlers = {'codex': query_codex, 'agy': query_agy, 'claude': query_claude}
out = {t: handlers[t]() for t in targets if t in handlers}
print(json.dumps({'agents': out}))
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
            var agentMap: [String: AgentQuotaResult] = [:]
            do {
                try process.run()
                try inPipe.fileHandleForWriting.write(contentsOf: Data(script.utf8))
                try inPipe.fileHandleForWriting.close()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0,
                   let line = (String(data: data, encoding: .utf8) ?? "").components(separatedBy: .newlines).last(where: { $0.contains("{") }),
                   let jsonData = line.data(using: .utf8),
                   let env = try? JSONDecoder().decode(VMQuotasEnvelope.self, from: jsonData),
                   let agents = env.agents {
                    agentMap = agents
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = (String(data: errData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let msg = errMsg.isEmpty ? "无法查询额度" : String(errMsg.prefix(120))
                    for a in (configuredAgents.isEmpty ? ["codex"] : configuredAgents) {
                        agentMap[a] = AgentQuotaResult(status: "error", error: msg)
                    }
                }
            } catch {
                let msg = error.localizedDescription
                for a in (configuredAgents.isEmpty ? ["codex"] : configuredAgents) {
                    agentMap[a] = AgentQuotaResult(status: "error", error: msg)
                }
            }
            DispatchQueue.main.async {
                self.quotaPolling.remove(vmName)
                self.vmAgentQuotas[vmName] = agentMap
                if let c = agentMap["codex"] {
                    let wins = c.windows ?? []
                    let w0 = wins.first.map { CodexWindowQuota(usedPercent: $0.usedPercent, resetAfterSeconds: $0.resetAfterSeconds, resetAt: $0.resetAt) }
                    let w1 = wins.dropFirst().first.map { CodexWindowQuota(usedPercent: $0.usedPercent, resetAfterSeconds: $0.resetAfterSeconds, resetAt: $0.resetAt) }
                    self.vmQuotas[vmName] = CodexQuotaStatus(status: c.status, planType: c.planType, fiveHour: w0, weekly: w1, error: c.error, fetchedAt: c.fetchedAt)
                } else {
                    self.vmQuotas.removeValue(forKey: vmName)
                }
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
    private var projectPath: String {
        guard let path = model.vmMounts[vm.name]?.first?.location else { return "尚未获取挂载信息" }
        return path.hasPrefix(NSHomeDirectory() + "/AgentVM-Workspaces/") ? "共享工作区 · AgentVM-Shared" : path
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isBase ? "internaldrive" : "desktopcomputer")
                    .font(.title3)
                    .foregroundStyle(AgentTheme.accent)
                    .frame(width: 36, height: 36)
                    .background(AgentTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(model.displayName(for: vm))
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(model.displayName(for: vm))
                        if !isBase {
                            Button {
                                renameDraft = model.vmAliases[vm.name] ?? ""
                                renaming = true
                            } label: { Image(systemName: "pencil").font(.caption) }
                                .buttonStyle(.borderless)
                                .help("修改显示名称")
                                .popover(isPresented: $renaming) {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("修改虚拟机名称").font(.headline)
                                        Text("实例 ID：\(vm.name)").font(.caption).foregroundStyle(.secondary)
                                        TextField("输入自定义名称", text: $renameDraft)
                                            .textFieldStyle(.roundedBorder).frame(width: 240)
                                        HStack {
                                            Button("恢复默认") { model.renameVM(vm, to: ""); renaming = false }
                                            Spacer()
                                            Button("取消") { renaming = false }
                                            Button("保存") { model.renameVM(vm, to: renameDraft); renaming = false }
                                                .buttonStyle(.borderedProminent)
                                        }
                                    }.padding(14)
                                }
                        }
                    }
                    Text(isBase ? "基础模板" : projectPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(isBase ? "用于创建项目虚拟机" : projectPath)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(vm.status == "Running" ? Color.green : Color.secondary.opacity(0.6))
                            .frame(width: 6, height: 6)
                        Text(vm.status == "Running" ? "运行中" : vm.status == "Stopped" ? "已停止" : vm.status)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 7) {
                        if vm.status == "Running" {
                            Button { model.terminal(vm) } label: {
                                Image(systemName: "terminal")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.borderedProminent)
                            .help("打开终端")
                            .accessibilityLabel("打开终端")
                        } else {
                            Button { model.start(vm) } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.busy || vm.status != "Stopped" || model.vmMounts[vm.name]?.isEmpty != false)
                            .help("启动虚拟机")
                            .accessibilityLabel("启动虚拟机")
                        }
                        Menu {
                            if vm.status == "Running" {
                                Button("打开终端", systemImage: "terminal") { model.terminal(vm) }
                                if !isBase {
                                    Menu("恢复历史 AI 会话", systemImage: "clock.arrow.circlepath") {
                                        Button("Codex…") { model.resumeSession(vm, agent: "codex") }
                                        Button("Claude Code…") { model.resumeSession(vm, agent: "claude") }
                                    }
                                }
                                Button("停止虚拟机", systemImage: "stop.fill") { model.stop(vm) }
                                    .disabled(model.busy)
                                Divider()
                            }
                            Button(showDetails || showVMDetails ? "收起详情" : "查看详情",
                                   systemImage: "info.circle") { showDetails.toggle() }
                                .disabled(showVMDetails)
                            Button("挂载文件夹…", systemImage: "folder") { managingFolders = true }
                                .disabled(model.busy || model.vmMounts[vm.name]?.isEmpty != false)
                            if !isBase {
                                Button("刷新 Codex 额度", systemImage: "arrow.clockwise") { model.pollQuota(for: vm) }
                                    .disabled(vm.status != "Running" || model.quotaPolling.contains(vm.name))
                            }
                            Divider()
                            Button("删除虚拟机", systemImage: "trash", role: .destructive) { deleting = true }
                                .disabled(model.busy || vm.name == "base")
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 22, height: 28)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("更多操作")
                        .accessibilityLabel("更多操作")
                    }
                    .controlSize(.small)
                }
            }
            usageSummary
            if !isBase {
                Divider()
                codexQuotaSummary
            }
            if showDetails || showVMDetails {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("虚拟机详情").font(.subheadline.weight(.semibold))
                    detail("实例", value: vm.name)
                    detail("状态", value: vm.status)
                    detail("架构", value: vm.arch)
                    detail("类型", value: vm.vmType)
                    detail("SSH", value: vm.status == "Running" ? vm.ssh : "未运行")
                    detail("CPU 配额", value: "\(vm.cpus) 核")
                    detail("内存配置", value: vm.memory)
                    detail("磁盘配置", value: vm.disk)
                    if let mounts = model.vmMounts[vm.name] {
                        Text("挂载文件夹（\(mounts.count)）")
                            .font(.caption.weight(.semibold))
                        ForEach(mounts) { mount in
                            Text("\(mount.location) → \(mount.guestPath) · \(mount.writable ? "读写" : "只读")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
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
    @ViewBuilder
    private var usageSummary: some View {
        if vm.status != "Running" {
            Label("停止时不采集资源", systemImage: "pause.circle")
                .font(.caption).foregroundStyle(.secondary)
        } else if let usage = model.vmUsage[vm.name] {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 14) {
                    usageMeter(title: "CPU", value: String(format: "%.1f%%", usage.cpuPercent),
                               percent: usage.cpuPercent, tint: usage.cpuPercent >= 90 ? .orange : .green)
                    usageMeter(title: "内存",
                               value: String(format: "%.0f / %.0f MB", usage.usedMemoryMB, usage.totalMemoryMB),
                               percent: usage.memoryPercent, tint: usage.memoryPercent >= 85 ? .orange : .blue)
                }
                if usage.memoryPercent >= 85 {
                    Label("来宾内存使用较高。建议先检查运行进程；调整 VM 配额需要停止虚拟机。",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                } else if usage.cpuPercent >= 90 {
                    Label("来宾 CPU 使用较高；此处显示的是虚拟机内部负载，不是 Mac 整机占用。",
                          systemImage: "info.circle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(spacing: 6) {
                if model.usageErrors.contains(vm.name) {
                    Label("暂无法读取实时使用量", systemImage: "exclamationmark.circle")
                } else {
                    ProgressView().controlSize(.mini)
                    Text("正在读取实时使用量…")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func usageMeter(title: String, value: String, percent: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).lineLimit(1)
                .minimumScaleFactor(0.75)
            ProgressView(value: min(100, max(0, percent)), total: 100)
                .tint(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Label("Codex 额度", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let plan = quota?.planType, !plan.isEmpty {
                    Text(plan.uppercased())
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(AgentTheme.accent.opacity(0.14), in: Capsule())
                        .foregroundStyle(AgentTheme.accent)
                }
                if vm.status != "Running" {
                    Text("上次记录").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if polling {
                    ProgressView().controlSize(.mini)
                }
            }
            if let quota {
                if quota.status == "ok" {
                    HStack(alignment: .top, spacing: 12) {
                        if let five = quota.fiveHour {
                            quotaPill(label: "5 小时", window: five)
                        }
                        if let wk = quota.weekly {
                            quotaPill(label: "每周", window: wk)
                        }
                    }
                    if quota.fiveHour?.isLow == true || quota.weekly?.isLow == true {
                        Label("额度偏低，请留意重置时间", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    if quota.fiveHour == nil && quota.weekly == nil {
                        Text("服务未返回额度窗口").font(.caption2).foregroundStyle(.secondary)
                    }
                } else if quota.status == "not_logged_in" {
                    Text("VM 内 Codex 未登录").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(quota.error ?? "额度查询失败").font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
            } else {
                Text(vm.status == "Running" ? "正在获取额度…" : "启动后获取额度")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let fetched = quota?.fetchedAt {
                Text("查询于 " + fetched.formatted(date: .omitted, time: .shortened) +
                     (Date().timeIntervalSince(fetched) > 25 * 60 ? " · 数据可能已过期" : ""))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
    private func quotaPill(label: String, window: CodexWindowQuota) -> some View {
        let rem = window.remainingPercent
        let tint: Color = rem > 30 ? .green : rem > 10 ? .orange : .red
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(rem)%").fontWeight(.semibold).foregroundStyle(tint)
            }
            .font(.caption)
            ProgressView(value: Double(rem), total: 100)
                .tint(tint)
            if let sec = window.resetAfterSeconds, sec > 0 {
                Text(formatReset(sec))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    @State private var showingCreate = false
    @State private var navigateToProxyAfterDismiss = false
    var onProxy: () -> Void = {}
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
                Button {
                    beginCreation()
                } label: {
                    Label("新建", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy)
                Button { model.pollAllRunningQuotas() } label: { Label("刷新额度", systemImage: "gauge.with.dots.needle.33percent") }
                    .disabled(model.busy)
                Button { model.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(model.busy)
            }
            HStack(spacing: 16) {
                Text("总计 \(projects.count)")
                Text("运行中 \(projects.filter { $0.status == "Running" }.count)")
                Text("已停止 \(projects.filter { $0.status == "Stopped" }.count)")

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
                    Text("点击右上角「新建」创建项目虚拟机。").foregroundStyle(.secondary)
                    Button("新建虚拟机", systemImage: "plus") { beginCreation() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                    alignment: .leading,
                    spacing: 14
                ) {
                    ForEach(projects) { vm in
                        MachineRow(vm: vm, model: model)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showingCreate, onDismiss: {
            if navigateToProxyAfterDismiss {
                navigateToProxyAfterDismiss = false
                onProxy()
            } else {
                model.refresh()
            }
        }) {
            WizardView(model: model, onMachines: {
                showingCreate = false
                model.refresh()
            }, onProxy: {
                navigateToProxyAfterDismiss = true
                showingCreate = false
            })
        }
    }
    private func beginCreation() {
        guard !model.busy else { return }
        model.step = 0
        model.buildStarted = false
        model.buildComplete = false
        model.operationFailed = false
        model.confirmation = false
        model.project = ""
        model.newVMName = ""
        showingCreate = true
    }
}

struct WizardView: View {
    @ObservedObject var model: Model
    var onMachines: () -> Void = {}
    var onProxy: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var showAdvanced = false

    private let titles = ["环境配置", "确认创建"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: model.buildComplete ? "checkmark.circle.fill" : "desktopcomputer.and.arrow.down")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(model.buildComplete ? Color.green : AgentTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(AgentTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.buildStarted ? (model.buildComplete ? "创建完成" : "正在准备虚拟机") : "新建虚拟机")
                        .font(.title2.bold())
                    Text(model.buildStarted ? "可以查看各阶段的执行情况" : "为项目创建独立的开发环境")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !model.busy {
                    Button("关闭") { dismiss() }.buttonStyle(.borderless)
                        .accessibilityLabel("关闭创建窗口")
                }
            }
            .padding(.horizontal, 26).padding(.top, 22).padding(.bottom, 18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.buildStarted {
                        buildProgress
                    } else {
                        HStack(spacing: 8) {
                            ForEach(0..<titles.count, id: \.self) { index in
                                HStack(spacing: 6) {
                                    Image(systemName: index < model.step ? "checkmark.circle.fill" :
                                          index == model.step ? "circle.inset.filled" : "circle")
                                        .foregroundStyle(index <= model.step ? AgentTheme.accent : Color.secondary)
                                    Text(titles[index])
                                        .font(.caption.weight(index == model.step ? .semibold : .regular))
                                        .foregroundStyle(index == model.step ? Color.primary : Color.secondary)
                                }
                                if index < titles.count - 1 {
                                    Rectangle().fill(Color.secondary.opacity(0.2))
                                        .frame(height: 1).padding(.horizontal, 5)
                                }
                            }
                        }
                        .padding(.bottom, 4)
                        switch model.step {
                        case 0: environmentOptions
                        default: confirmationSummary
                        }
                    }
                }
                .padding(26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                if model.buildStarted {
                    if model.busy {
                        ProgressView().controlSize(.small)
                        Text("正在创建，请不要退出应用")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        Button(model.buildComplete ? "创建另一个" : "返回配置") {
                            model.step = model.buildComplete ? 0 : 1
                            if model.buildComplete {
                                model.project = ""
                                model.newVMName = ""
                            }
                            model.buildStarted = false
                            model.buildComplete = false
                        }
                        Spacer()
                        Button(model.buildComplete ? "完成" : "关闭") {
                            dismiss()
                            onMachines()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    Button("取消") { dismiss() }
                    Spacer()
                    if model.step > 0 {
                        Button("上一步") { model.step -= 1 }
                            .disabled(model.busy)
                    }
                    if model.step < titles.count - 1 {
                        Button("继续") { model.step += 1 }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.busy)
                    } else {
                        Button("创建虚拟机") { model.confirmation = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.busy)
                    }
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 26).padding(.vertical, 16)
        }
        .frame(width: 690, height: 620)
        .confirmationDialog("创建或启动项目虚拟机？", isPresented: $model.confirmation) {
            Button("确认创建") { model.setup() }
        } message: {
            Text("创建独立虚拟机，并自动挂载 AgentVM-Shared 公共目录。")
        }
        .interactiveDismissDisabled(model.busy)
    }

    private var environmentOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("配置开发环境").font(.title3.weight(.semibold))
            Text("默认使用 AgentVM-Shared，无需再次选择或挂载项目文件夹。")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(AgentTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("共享工作区").font(.subheadline.weight(.semibold))
                        Text("~/AgentVM-Shared → /mnt/agent-vm-shared")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("自动挂载", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                TextField("虚拟机名称（可选，例如：开发环境 1）", text: $model.newVMName)
                    .textFieldStyle(.roundedBorder)
                Text("不填名称将自动生成实例名。所有虚拟机独立运行，但共享同一个工作目录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("系统与工具", systemImage: "terminal")
                    Spacer()
                    Text("Debian · Codex CLI").foregroundStyle(.secondary)
                }
                Divider()
                Toggle(isOn: $model.includeCodeServer) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("安装浏览器编辑器")
                        Text("code-server · 需要至少 4 GiB 内存").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onChange(of: model.includeCodeServer) { enabled in
                    if enabled && model.memory < 4 { model.memory = 4 }
                }
                Divider()
                Toggle(isOn: $model.syncRegion) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("根据出口 IP 同步地区与时区")
                        Text("虚拟机启动后更新，可能访问外部 IP 查询服务。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onChange(of: model.syncRegion) { UserDefaults.standard.set($0, forKey: "syncRegion") }
            }
            .padding(18)
            .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 14))

            DisclosureGroup("高级设置", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 14) {
                    Stepper("CPU · \(model.cpus) 核", value: $model.cpus, in: 1...64)
                    Stepper("内存 · \(model.memory) GiB", value: $model.memory,
                            in: (model.includeCodeServer ? 4 : 1)...128)
                    Stepper("磁盘 · \(model.disk) GiB", value: $model.disk, in: 10...1000, step: 10)
                    Toggle("重新构建基础模板", isOn: $model.rebuildBase)
                    Text("默认复用基础模板。上述资源用于新虚拟机，已有实例不会重新分配。重建模板不会替换已有虚拟机。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 12)
            }
            .padding(16)
            .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 8) {
                Image(systemName: "network")
                VStack(alignment: .leading, spacing: 2) {
                    Text("网络代理")
                    Text(model.proxyStatus?.useProxy == true ? "使用当前保存的代理配置" : "未启用代理")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("代理设置…") { onProxy() }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var confirmationSummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("确认虚拟机配置").font(.title3.weight(.semibold))
            Text("检查信息无误后创建。系统会自动准备基础模板并启动项目环境。")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                summaryRow("名称", value: model.newVMName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "自动生成" : model.newVMName)
                Divider()
                summaryRow("共享目录", value: "~/AgentVM-Shared")
                Divider()
                summaryRow("VM 内路径", value: "/mnt/agent-vm-shared")
                Divider()
                summaryRow("系统", value: "Debian · Codex CLI")
                Divider()
                summaryRow("资源", value: "\(model.cpus) 核 CPU · \(model.memory) GiB 内存 · \(model.disk) GiB 磁盘")
                Divider()
                summaryRow("编辑器", value: model.includeCodeServer ? "安装 code-server" : "不安装")
                Divider()
                summaryRow("基础模板", value: model.rebuildBase ? "重新构建" : "优先复用")
                Divider()
                summaryRow("网络", value: model.proxyStatus?.useProxy == true ? "使用已保存的代理设置" : "不使用代理")
            }
            .padding(.horizontal, 18)
            .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 14))
            Label("新建实例使用独立 ID；公共目录可以被多个虚拟机同时修改，请避免并发编辑同一个文件。",
                  systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func summaryRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(title).foregroundStyle(.secondary).frame(width: 88, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .font(.callout)
        .padding(.vertical, 12)
    }

    private var buildProgress: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.buildComplete ? "虚拟机已就绪" : model.operationFailed ? "创建未完成" : "正在创建")
                .font(.title3.weight(.semibold))
            Text(model.newVMName.isEmpty ? "共享工作区 · AgentVM-Shared" : model.newVMName)
                .font(.caption).foregroundStyle(.secondary)
            if model.busy { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(["准备基础环境", "启动基础虚拟机", "安装系统与开发工具", "启动项目虚拟机"].enumerated()), id: \.offset) { index, title in
                    HStack(spacing: 12) {
                        let done = model.buildComplete || index < model.buildStage
                        let active = index == model.buildStage && !model.buildComplete
                        Image(systemName: done ? "checkmark.circle.fill" :
                              (active && model.operationFailed ? "xmark.circle.fill" : "circle"))
                            .foregroundStyle(done ? Color.green : (active && model.operationFailed ? Color.red : Color.secondary))
                        Text(title).fontWeight(active ? .semibold : .regular)
                        Spacer()
                        Text(model.reusedBase && index < 3 ? "已复用" : done ? "已完成" :
                             active && model.operationFailed ? "失败" : active ? "进行中" : "等待中")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(18)
            .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 14))
            if !model.regionMessage.isEmpty && model.buildComplete {
                Text(model.regionMessage).font(.caption).foregroundStyle(.secondary)
            }
            if model.operationFailed {
                Text(model.errorSummary).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                Text("详细日志：~/.agent-vm/setup.log").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

enum WorkbenchSection: String, CaseIterable, Identifiable, Hashable {
    case machines, proxy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .machines: return "虚拟机"
        case .proxy: return "代理与门禁"
        }
    }
    var symbol: String {
        switch self {
        case .machines: return "desktopcomputer"
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
    @ObservedObject var model: Model
    @State private var section: WorkbenchSection = .machines
    var body: some View {
        HStack(spacing: 0) {
            WorkbenchSidebar(selection: $section, busy: model.busy)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    Group {
                        switch section {
                        case .machines: MachinesView(model: model, onProxy: { section = .proxy })
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

private struct MenuBarControls: View {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    private var projects: [VM] {
        model.machines.filter { $0.name != "base" && $0.name != "base-building" }
    }
    private var active: [VM] { projects.filter { $0.status == "Running" } }
    var body: some View {
        Text("运行中 \(active.count) / \(projects.count) 台虚拟机")
        Button("打开 Agent VM", systemImage: "macwindow") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("刷新虚拟机状态", systemImage: "arrow.clockwise") { model.refresh() }
            .disabled(model.busy)
        Button("刷新 AI 额度", systemImage: "sparkles") { model.pollAllRunningQuotas() }
            .disabled(active.isEmpty)
        if let proxy = model.proxyStatus {
            Text("代理：" + (proxy.useProxy ? (proxy.proxyMode == "mihomo" ? "Mihomo" : "自定义代理") : "未启用"))
        }
        Divider()
        if projects.isEmpty {
            Text("暂无项目虚拟机")
        } else {
            ForEach(projects) { vm in
                Menu {
                    if vm.status == "Running" {
                        if let aq = model.vmAgentQuotas[vm.name] {
                            ForEach(["codex", "agy", "claude"], id: \.self) { agent in
                                if let q = aq[agent], q.status == "ok" {
                                    let title = agent == "codex" ? "Codex" : agent == "agy" ? "Antigravity" : "Claude"
                                    ForEach(Array((q.windows ?? []).enumerated()), id: \.offset) { _, w in
                                        Text("\(title) \(w.label)剩余 \(w.remainingPercent)%")
                                    }
                                }
                            }
                        }
                        Button("打开终端", systemImage: "terminal") { model.terminal(vm) }
                        Menu("恢复历史 AI 会话", systemImage: "clock.arrow.circlepath") {
                            Button("Codex…") { model.resumeSession(vm, agent: "codex") }
                            Button("Claude Code…") { model.resumeSession(vm, agent: "claude") }
                        }
                        Button("刷新 AI 额度", systemImage: "arrow.clockwise") { model.pollQuota(for: vm) }
                            .disabled(model.quotaPolling.contains(vm.name))
                        Button("停止", systemImage: "stop.fill") { model.stop(vm) }
                            .disabled(model.busy)
                    } else {
                        Button("启动", systemImage: "play.fill") { model.start(vm) }
                            .disabled(model.busy || vm.status != "Stopped" || model.vmMounts[vm.name]?.isEmpty != false)
                    }
                } label: {
                    Label(model.displayName(for: vm), systemImage: vm.status == "Running" ? "circle.fill" : "circle")
                }
            }
        }
        Divider()
        Button("退出 Agent VM", systemImage: "power") { NSApp.terminate(nil) }
    }
}

@main struct AgentVMApp: App {
    @StateObject private var model = Model()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup("Agent VM", id: "main") {
            ZStack(alignment: .topLeading) {
                ReactWorkbenchView(model: model)
                if model.browserSlotVisible,
                   let state = model.linuxBrowsers[model.activeBrowserVM],
                   state.status == "ready",
                   let url = URL(string: state.url),
                   model.browserSlot.width > 20, model.browserSlot.height > 20 {
                    LinuxBrowserWebView(
                        url: url,
                        reloadToken: model.browserReloadToken,
                        onBrowserShortcut: { action in
                            if action == "focusAddress" {
                                model.browserFocusAddressNonce += 1
                            } else {
                                model.browserShortcutSignal = ["action": action, "vm": model.activeBrowserVM, "nonce": UUID().uuidString]
                            }
                        },
                        onPasteText: { text in
                            if let bVM = model.machines.first(where: { $0.name == model.activeBrowserVM }) {
                                model.browserInsertText(bVM, text: text)
                            }
                        }
                    )
                        .frame(width: model.browserSlot.width, height: model.browserSlot.height)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .offset(x: model.browserSlot.minX, y: model.browserSlot.minY)
                    if let bVM = model.machines.first(where: { $0.name == model.activeBrowserVM }) {
                        BrowserFloatingOverlay(model: model, vm: bVM, slot: model.browserSlot)
                    }
                }
                if model.codexDesktopSlotVisible,
                   let state = model.codexDesktops[model.activeCodexDesktopVM],
                   state.status == "ready",
                   let url = URL(string: state.url),
                   model.codexDesktopSlot.width > 20, model.codexDesktopSlot.height > 20 {
                    LinuxBrowserWebView(
                        url: url,
                        reloadToken: model.codexDesktopReloadToken,
                        onPasteText: { text in
                            if let desktopVM = model.machines.first(where: { $0.name == model.activeCodexDesktopVM }) {
                                model.codexDesktopSendText(desktopVM, text: text)
                            }
                        }
                    )
                        .frame(width: model.codexDesktopSlot.width, height: model.codexDesktopSlot.height)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .offset(x: model.codexDesktopSlot.minX, y: model.codexDesktopSlot.minY)
                    if let desktopVM = model.machines.first(where: { $0.name == model.activeCodexDesktopVM }) {
                        CodexDesktopFloatingOverlay(model: model, vm: desktopVM, slot: model.codexDesktopSlot)
                    }
                }
            }
            .frame(minWidth: 920, minHeight: 640)
            .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        model.refresh()
                        model.refreshProxyStatus()
                    }
                }
        }
        MenuBarExtra("Agent VM", systemImage: "desktopcomputer") {
            MenuBarControls(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}
