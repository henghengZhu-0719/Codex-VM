import Foundation
import SwiftUI

enum DesktopAppKind: String, CaseIterable {
    case codex
    case claude

    static func from(_ raw: String?) -> DesktopAppKind {
        raw == "claude" ? .claude : .codex
    }

    var displayName: String {
        switch self {
        case .codex: return "Codex 官方桌面"
        case .claude: return "Claude Code 官方桌面"
        }
    }

    var shortName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        }
    }

    var displayNumber: String {
        switch self {
        case .codex: return ":98"
        case .claude: return ":97"
        }
    }

    var vncPort: Int {
        switch self {
        case .codex: return 5998
        case .claude: return 5997
        }
    }

    var websockifyPortBase: Int {
        switch self {
        case .codex: return 22000
        case .claude: return 23000
        }
    }

    var configDirName: String {
        switch self {
        case .codex: return "agent-vm-codex-desktop"
        case .claude: return "agent-vm-claude-desktop"
        }
    }

    var packageId: String {
        switch self {
        case .codex: return "chatgpt"
        case .claude: return "claude-desktop"
        }
    }

    var logFileName: String {
        switch self {
        case .codex: return "chatgpt.log"
        case .claude: return "claude-desktop.log"
        }
    }

    var scriptSettings: [String: Any] {
        [
            "app": rawValue,
            "display": displayNumber,
            "vncPort": vncPort,
            "portBase": websockifyPortBase,
            "configDir": configDirName,
            "pkg": packageId,
            "logFile": logFileName
        ]
    }
}

struct CodexDesktopState {
    var app = "codex"
    var status = "idle" // idle, missing, starting, ready, error
    var stage = "idle"  // checking, display, app, vnc, ready, error
    var stageMessage = ""
    var url = ""
    var port = 0
    var error = ""
    var checked = false
    var installed = false
    var appRunning = false
    var appVersion = ""
    var diskAvailMB = 0
    var missingComponents: [String] = []
    var resolution = "1280x800"
    var qualityMode = "sharp"
    var autoResize = true
    var logs = ""
    var installing = false
    var installOutput = ""
}

// Installs and runs official Linux desktop apps inside the VM:
// - Codex (`chatgpt` .deb): virtual display :98, VNC 5998, websockify 22000+
// - Claude Code (`claude-desktop` .deb): virtual display :97, VNC 5997, websockify 23000+
// Streams over loopback noVNC to the native macOS shell.
@MainActor final class CodexDesktopManager {
    var onChange: (([String: CodexDesktopState]) -> Void)?
    var onOpen: ((String, DesktopAppKind, URL) -> Void)?
    private(set) var states: [String: CodexDesktopState] = [:]
    private var preparing: Set<String> = []
    private var checking: Set<String> = []
    private var generations: [String: UUID] = [:]
    private var resizeWorkItems: [String: DispatchWorkItem] = [:]
    private final class IMEChannel {
        let process: Process
        let stdin: FileHandle
        init(process: Process, stdin: FileHandle) {
            self.process = process
            self.stdin = stdin
        }
        var isAlive: Bool { process.isRunning }
        func close() {
            try? stdin.close()
            if process.isRunning { process.terminate() }
        }
    }

    private let imeQueue = DispatchQueue(label: "org.agentvm.codex-desktop.ime")
    nonisolated(unsafe) private var imeChannels: [String: IMEChannel] = [:]

    static func stateKey(name: String, app: DesktopAppKind) -> String {
        "\(name)::\(app.rawValue)"
    }

    nonisolated private static func sshControlArgs(config: String, timeout: Int = 6) -> [String] {
        [
            "-F", config,
            "-o", "ConnectTimeout=\(timeout)",
            "-o", "BatchMode=yes",
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=120",
            "-o", "ControlPath=/tmp/avm-ssh-%C"
        ]
    }

    private static func buildNoVNCURL(port: Int, qualityMode: String) -> String {
        let q: Int
        let c: Int
        switch qualityMode {
        case "sharp":
            q = 9; c = 0
        case "smooth":
            q = 5; c = 4
        default:
            q = 8; c = 2
        }
        return "http://127.0.0.1:\(port)/vnc.html?autoconnect=1&resize=scale&quality=\(q)&compression=\(c)"
    }

    private static func displayScaleFactor() -> Double {
        let raw = NSScreen.main?.backingScaleFactor ?? 2.0
        return min(2.0, max(1.0, Double(raw)))
    }

    private static func clampedSize(_ width: Int, _ height: Int, scale: Double? = nil) -> (Int, Int) {
        let s = scale ?? displayScaleFactor()
        let w = max(800, min(4096, (Int(round(Double(width) * s)) / 2) * 2))
        let h = max(500, min(2560, (Int(round(Double(height) * s)) / 2) * 2))
        return (w, h)
    }

    private static func wrapScript(_ body: String, settings: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: settings) else { return nil }
        return "import json, base64\nsettings = json.loads(base64.b64decode('" + data.base64EncodedString() + "'))\n" + body
    }

    func retain(_ names: Set<String>) {
        for key in Array(states.keys) {
            let vmName = key.components(separatedBy: "::").first ?? key
            if !names.contains(vmName) {
                generations.removeValue(forKey: key)
                preparing.remove(key)
                checking.remove(key)
                resizeWorkItems[key]?.cancel()
                resizeWorkItems.removeValue(forKey: key)
                states.removeValue(forKey: key)
                closeIME(vmName: vmName)
            }
        }
        onChange?(states)
    }

    func checkStatus(name: String, config: String, app: DesktopAppKind = .codex) {
        let key = Self.stateKey(name: name, app: app)
        guard !checking.contains(key), !preparing.contains(key), states[key]?.installing != true else { return }
        guard let script = Self.wrapScript(Self.statusScript, settings: app.scriptSettings) else { return }
        checking.insert(key)
        DispatchQueue.global(qos: .utility).async {
            let proc = Process(), out = Pipe(), stdin = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = Self.sshControlArgs(config: config) + ["lima-" + name, "python3 -"]
            proc.standardOutput = out
            proc.standardError = out
            proc.standardInput = stdin
            do {
                try proc.run()
                try stdin.fileHandleForWriting.write(contentsOf: Data(script.utf8))
                try stdin.fileHandleForWriting.close()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                let line = text.components(separatedBy: .newlines).last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") })
                let obj = line.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                DispatchQueue.main.async {
                    self.checking.remove(key)
                    guard let obj else { return }
                    var st = self.states[key] ?? CodexDesktopState(app: app.rawValue)
                    let installed = obj["installed"] as? Bool ?? false
                    let appRunning = obj["appRunning"] as? Bool ?? false
                    let missing = obj["missing"] as? [String] ?? []
                    st.app = app.rawValue
                    st.checked = true
                    st.installed = installed
                    st.appRunning = appRunning
                    st.appVersion = obj["version"] as? String ?? ""
                    st.diskAvailMB = obj["diskAvailMB"] as? Int ?? 0
                    st.missingComponents = missing
                    if st.status == "idle" || st.status == "missing" {
                        st.status = missing.isEmpty ? "idle" : "missing"
                    }
                    self.states[key] = st
                    self.onChange?(self.states)
                }
            } catch {
                DispatchQueue.main.async { self.checking.remove(key) }
            }
        }
    }

    func open(name: String, config: String, app: DesktopAppKind = .codex, width: Int = 1280, height: Int = 800, qualityMode: String? = nil) {
        let key = Self.stateKey(name: name, app: app)
        guard states[key]?.installing != true else { return }
        let qMode = qualityMode ?? states[key]?.qualityMode ?? "sharp"
        if let existing = states[key], existing.status == "ready", existing.port > 0 {
            let url = Self.buildNoVNCURL(port: existing.port, qualityMode: qMode)
            states[key]?.qualityMode = qMode
            states[key]?.url = url
            onChange?(states)
            verifyAndOpen(name: name, app: app, port: existing.port, url: url, config: config, width: width, height: height, qualityMode: qMode, fallbackPrepare: true)
            return
        }
        guard !preparing.contains(key) else { return }
        warmIME(name: name, config: config)
        start(name: name, config: config, app: app, width: width, height: height, qualityMode: qMode)
    }

    func setQuality(name: String, app: DesktopAppKind = .codex, qualityMode: String) {
        guard ["balanced", "sharp", "smooth"].contains(qualityMode) else { return }
        let key = Self.stateKey(name: name, app: app)
        var st = states[key] ?? CodexDesktopState(app: app.rawValue)
        st.qualityMode = qualityMode
        if st.status == "ready", st.port > 0 {
            let newURL = Self.buildNoVNCURL(port: st.port, qualityMode: qualityMode)
            st.url = newURL
            states[key] = st
            onChange?(states)
            if let target = URL(string: newURL) { onOpen?(name, app, target) }
        } else {
            states[key] = st
            onChange?(states)
        }
    }

    func setAutoResize(name: String, app: DesktopAppKind = .codex, enabled: Bool, config: String, width: Int, height: Int) {
        let key = Self.stateKey(name: name, app: app)
        var st = states[key] ?? CodexDesktopState(app: app.rawValue)
        st.autoResize = enabled
        states[key] = st
        onChange?(states)
        if enabled && width > 100 && height > 100 {
            resize(name: name, config: config, app: app, width: width, height: height)
        }
    }

    func resize(name: String, config: String, app: DesktopAppKind = .codex, width: Int, height: Int) {
        let key = Self.stateKey(name: name, app: app)
        let (w, h) = Self.clampedSize(width, height)
        let targetRes = "\(w)x\(h)"
        guard states[key]?.status == "ready", states[key]?.resolution != targetRes else { return }
        resizeWorkItems[key]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.performResize(name: name, config: config, app: app, width: w, height: h)
        }
        resizeWorkItems[key] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: item)
    }

    private func performResize(name: String, config: String, app: DesktopAppKind, width: Int, height: Int) {
        let key = Self.stateKey(name: name, app: app)
        guard states[key]?.status == "ready" else { return }
        var input = app.scriptSettings
        input["width"] = width
        input["height"] = height
        guard let script = Self.wrapScript(Self.resizeScript, settings: input) else { return }
        DispatchQueue.global(qos: .utility).async {
            let proc = Process(), output = Pipe(), stdin = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = Self.sshControlArgs(config: config) + ["lima-" + name, "python3 -"]
            proc.standardOutput = output
            proc.standardError = output
            proc.standardInput = stdin
            do {
                try proc.run()
                try stdin.fileHandleForWriting.write(contentsOf: Data(script.utf8))
                try stdin.fileHandleForWriting.close()
                let raw = output.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if proc.terminationStatus == 0,
                   let decoded = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                   let actual = decoded["resolution"] as? String {
                    DispatchQueue.main.async {
                        self.states[key]?.resolution = actual
                        self.onChange?(self.states)
                    }
                }
            } catch {}
        }
    }

    private func verifyAndOpen(name: String, app: DesktopAppKind, port: Int, url: String, config: String, width: Int, height: Int, qualityMode: String, fallbackPrepare: Bool) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/vnc.html")!)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { _, response, _ in
            DispatchQueue.main.async {
                if (response as? HTTPURLResponse)?.statusCode == 200, let target = URL(string: url) {
                    self.warmIME(name: name, config: config)
                    self.onOpen?(name, app, target)
                    self.resize(name: name, config: config, app: app, width: width, height: height)
                } else if fallbackPrepare {
                    self.start(name: name, config: config, app: app, width: width, height: height, qualityMode: qualityMode)
                } else {
                    self.failed(name, app: app, "\(app.displayName)未响应，请重试。", missing: [])
                }
            }
        }.resume()
    }

    private func start(name: String, config: String, app: DesktopAppKind, width: Int, height: Int, qualityMode: String, restartApp: Bool = false) {
        let key = Self.stateKey(name: name, app: app)
        let generation = UUID()
        generations[key] = generation
        preparing.insert(key)
        let scale = Self.displayScaleFactor()
        let (w, h) = Self.clampedSize(width, height, scale: scale)
        var st = states[key] ?? CodexDesktopState(app: app.rawValue)
        st.app = app.rawValue
        st.status = "starting"
        st.stage = "checking"
        st.stageMessage = "正在检查\(app.displayName)与显示环境…"
        st.error = ""
        st.qualityMode = qualityMode
        states[key] = st
        onChange?(states)

        var input = app.scriptSettings
        input["name"] = name
        input["width"] = w
        input["height"] = h
        input["scale"] = scale
        input["restartApp"] = restartApp
        guard let script = Self.wrapScript(Self.prepareScript, settings: input) else { return }

        DispatchQueue.global(qos: .utility).async {
            let process = Process(), output = Pipe(), stdin = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = Self.sshControlArgs(config: config, timeout: 8) + ["lima-" + name, "python3 -u -"]
            process.standardOutput = output
            process.standardError = output
            process.standardInput = stdin
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }

            var buffer = Data()
            var finalDecoded: [String: Any]?
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0a) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                        finalDecoded = obj
                        if let stage = obj["stage"] as? String {
                            let msg = obj["message"] as? String ?? ""
                            DispatchQueue.main.async {
                                guard let self, self.generations[key] == generation else { return }
                                self.states[key]?.stage = stage
                                if !msg.isEmpty { self.states[key]?.stageMessage = msg }
                                self.onChange?(self.states)
                            }
                        }
                    }
                }
            }

            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: timeout)
                try stdin.fileHandleForWriting.write(contentsOf: Data(script.utf8))
                try stdin.fileHandleForWriting.close()
                process.waitUntilExit()
                timeout.cancel()
                output.fileHandleForReading.readabilityHandler = nil
                if !buffer.isEmpty, let obj = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any] {
                    finalDecoded = obj
                }
                let port = finalDecoded?["port"] as? Int
                let resolution = finalDecoded?["resolution"] as? String ?? "\(w)x\(h)"
                let version = finalDecoded?["version"] as? String ?? ""
                let diskAvailMB = finalDecoded?["diskAvailMB"] as? Int ?? 0
                let missing = finalDecoded?["missing"] as? [String] ?? []
                let error = finalDecoded?["error"] as? String ?? "无法启动\(app.displayName)，请检查虚拟机连接。"
                DispatchQueue.main.async {
                    guard self.generations[key] == generation else { return }
                    if !missing.isEmpty {
                        self.preparing.remove(key)
                        var st = self.states[key] ?? CodexDesktopState(app: app.rawValue)
                        st.app = app.rawValue
                        st.status = "missing"
                        st.stage = "checking"
                        st.checked = true
                        st.installed = !missing.contains(app.packageId)
                        st.missingComponents = missing
                        st.diskAvailMB = diskAvailMB
                        st.error = ""
                        self.states[key] = st
                        self.onChange?(self.states)
                        return
                    }
                    guard process.terminationStatus == 0, let port, (1024...65535).contains(port) else {
                        self.failed(name, app: app, error, missing: missing)
                        return
                    }
                    self.states[key]?.installed = true
                    if !version.isEmpty { self.states[key]?.appVersion = version }
                    self.states[key]?.stage = "vnc"
                    self.states[key]?.stageMessage = "正在建立 noVNC 画面连接…"
                    self.states[key]?.resolution = resolution
                    self.onChange?(self.states)
                    self.check(name: name, app: app, port: port, qualityMode: qualityMode, generation: generation, attempts: 25)
                }
            } catch {
                timeout.cancel()
                output.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { process.terminate() }
                DispatchQueue.main.async {
                    if self.generations[key] == generation {
                        self.failed(name, app: app, "无法连接\(app.displayName)。", missing: [])
                    }
                }
            }
        }
    }

    private func check(name: String, app: DesktopAppKind, port: Int, qualityMode: String, generation: UUID, attempts: Int) {
        let key = Self.stateKey(name: name, app: app)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/vnc.html")!)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { _, response, _ in
            DispatchQueue.main.async {
                guard self.generations[key] == generation else { return }
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    self.preparing.remove(key)
                    let url = Self.buildNoVNCURL(port: port, qualityMode: qualityMode)
                    var st = self.states[key] ?? CodexDesktopState(app: app.rawValue)
                    st.app = app.rawValue
                    st.status = "ready"
                    st.stage = "ready"
                    st.stageMessage = "\(app.displayName)已就绪"
                    st.url = url
                    st.port = port
                    st.qualityMode = qualityMode
                    st.checked = true
                    st.installed = true
                    st.appRunning = true
                    st.error = ""
                    st.missingComponents = []
                    self.states[key] = st
                    self.onChange?(self.states)
                    if let target = URL(string: url) { self.onOpen?(name, app, target) }
                } else if attempts > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.check(name: name, app: app, port: port, qualityMode: qualityMode, generation: generation, attempts: attempts - 1)
                    }
                } else {
                    self.failed(name, app: app, "\(app.displayName)界面未能响应，请重试。", missing: [])
                }
            }
        }.resume()
    }

    private func failed(_ name: String, app: DesktopAppKind, _ error: String, missing: [String]) {
        let key = Self.stateKey(name: name, app: app)
        preparing.remove(key)
        var st = states[key] ?? CodexDesktopState(app: app.rawValue)
        st.app = app.rawValue
        st.status = "error"
        st.stage = "error"
        st.error = error
        st.missingComponents = missing
        states[key] = st
        onChange?(states)
    }

    func restartApp(name: String, config: String, app: DesktopAppKind = .codex, width: Int, height: Int) {
        let key = Self.stateKey(name: name, app: app)
        guard !preparing.contains(key), states[key]?.installing != true else { return }
        let qMode = states[key]?.qualityMode ?? "sharp"
        start(name: name, config: config, app: app, width: width, height: height, qualityMode: qMode, restartApp: true)
    }

    func stopSession(name: String, config: String, app: DesktopAppKind = .codex, completion: (() -> Void)? = nil) {
        let key = Self.stateKey(name: name, app: app)
        guard !preparing.contains(key), states[key]?.installing != true else { return }
        generations[key] = UUID()
        resizeWorkItems[key]?.cancel()
        resizeWorkItems.removeValue(forKey: key)
        var st = states[key] ?? CodexDesktopState(app: app.rawValue)
        st.app = app.rawValue
        st.status = "idle"
        st.stage = "idle"
        st.url = ""
        st.port = 0
        st.appRunning = false
        st.checked = true
        states[key] = st
        onChange?(states)

        guard let script = Self.wrapScript(Self.stopScript, settings: app.scriptSettings) else {
            completion?()
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let proc = Process(), stdin = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = Self.sshControlArgs(config: config) + ["lima-" + name, "python3 -"]
            proc.standardInput = stdin
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                try stdin.fileHandleForWriting.write(contentsOf: Data(script.utf8))
                try stdin.fileHandleForWriting.close()
                proc.waitUntilExit()
            } catch {}
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    nonisolated private func ensureIMEChannel(name: String, config: String) -> IMEChannel? {
        if let existing = imeChannels[name], existing.isAlive {
            return existing
        }
        imeChannels[name]?.close()
        imeChannels.removeValue(forKey: name)

        let b64 = Data(Self.imeDaemonScript.utf8).base64EncodedString()
        let remoteCmd = "python3 -u -c \"import base64;exec(base64.b64decode('\(b64)'))\""
        let proc = Process()
        let stdinPipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = Self.sshControlArgs(config: config, timeout: 6) + ["lima-" + name, remoteCmd]
        proc.standardInput = stdinPipe
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let ch = IMEChannel(process: proc, stdin: stdinPipe.fileHandleForWriting)
            imeChannels[name] = ch
            return ch
        } catch {
            return nil
        }
    }

    private func warmIME(name: String, config: String) {
        imeQueue.async { [weak self] in
            _ = self?.ensureIMEChannel(name: name, config: config)
        }
    }

    private func closeIME(vmName: String) {
        imeQueue.async { [weak self] in
            self?.imeChannels[vmName]?.close()
            self?.imeChannels.removeValue(forKey: vmName)
        }
    }

    func sendText(name: String, config: String, app: DesktopAppKind = .codex, text: String) {
        guard !text.isEmpty else { return }
        let payload: [String: Any] = ["display": app.displayNumber, "text": text]
        guard var lineData = try? JSONSerialization.data(withJSONObject: payload) else { return }
        lineData.append(0x0a)
        imeQueue.async { [weak self] in
            guard let self else { return }
            for _ in 0..<2 {
                guard let ch = self.ensureIMEChannel(name: name, config: config) else { return }
                do {
                    try ch.stdin.write(contentsOf: lineData)
                    return
                } catch {
                    ch.close()
                    self.imeChannels.removeValue(forKey: name)
                }
            }
        }
    }

    func fetchLogs(name: String, config: String, app: DesktopAppKind = .codex) {
        let key = Self.stateKey(name: name, app: app)
        guard let script = Self.wrapScript(Self.logsScript, settings: app.scriptSettings) else { return }
        DispatchQueue.global(qos: .utility).async {
            let proc = Process(), out = Pipe(), stdin = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = Self.sshControlArgs(config: config) + ["lima-" + name, "python3 -"]
            proc.standardOutput = out
            proc.standardError = out
            proc.standardInput = stdin
            do {
                try proc.run()
                try stdin.fileHandleForWriting.write(contentsOf: Data(script.utf8))
                try stdin.fileHandleForWriting.close()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                if let line = text.components(separatedBy: .newlines).last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }),
                   let lineData = line.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   let logs = obj["logs"] as? String {
                    DispatchQueue.main.async {
                        self.states[key]?.logs = logs
                        self.onChange?(self.states)
                    }
                }
            } catch {}
        }
    }

    func install(name: String, config: String, app: DesktopAppKind = .codex, width: Int, height: Int, completion: @escaping (Bool, String) -> Void) {
        let key = Self.stateKey(name: name, app: app)
        guard states[key]?.installing != true else { return }
        var st = states[key] ?? CodexDesktopState(app: app.rawValue)
        st.app = app.rawValue
        st.installing = true
        st.error = ""
        st.stageMessage = "正在准备安装\(app.displayName)与显示环境…"
        st.installOutput = ""
        states[key] = st
        onChange?(states)

        let script = Self.installScript(for: app)
        DispatchQueue.global(qos: .utility).async {
            let proc = Process(), out = Pipe(), stdin = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = Self.sshControlArgs(config: config, timeout: 10) + ["lima-" + name, "bash -s"]
            proc.standardOutput = out
            proc.standardError = out
            proc.standardInput = stdin

            let lock = NSLock()
            var acc = ""
            out.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                if let str = String(data: chunk, encoding: .utf8), !str.isEmpty {
                    lock.lock()
                    acc += str
                    if acc.count > 16000 { acc = String(acc.suffix(16000)) }
                    let snapshot = acc
                    lock.unlock()
                    DispatchQueue.main.async {
                        self?.states[key]?.installOutput = snapshot
                        self?.onChange?(self?.states ?? [:])
                    }
                }
            }

            do {
                try proc.run()
                try stdin.fileHandleForWriting.write(contentsOf: Data(script.utf8))
                try stdin.fileHandleForWriting.close()
                proc.waitUntilExit()
                out.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    self.states[key]?.installing = false
                    if proc.terminationStatus == 0 {
                        self.states[key]?.missingComponents = []
                        self.states[key]?.installed = true
                        self.onChange?(self.states)
                        self.open(name: name, config: config, app: app, width: width, height: height)
                        completion(true, "\(app.displayName)安装完成")
                    } else {
                        self.states[key]?.status = "error"
                        self.states[key]?.error = "安装未完成，请展开安装日志查看详情。"
                        self.onChange?(self.states)
                        completion(false, "安装失败（退出码 \(proc.terminationStatus)）")
                    }
                }
            } catch {
                out.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    self.states[key]?.installing = false
                    self.states[key]?.status = "error"
                    self.states[key]?.error = error.localizedDescription
                    self.onChange?(self.states)
                    completion(false, error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Guest Python & Shell Scripts

    static let statusScript = #"""
import json, os, shutil, subprocess

app_kind = settings.get('app', 'codex')
pkg_id = settings.get('pkg', 'chatgpt')

def find_app():
    if app_kind == 'claude':
        candidates = ('claude-desktop', '/usr/bin/claude-desktop', '/usr/lib/claude-desktop/claude-desktop', '/opt/Claude/claude-desktop')
    else:
        candidates = ('chatgpt', '/opt/ChatGPT/chatgpt', '/usr/bin/chatgpt')
    for c in candidates:
        p = shutil.which(c) if '/' not in c else (c if os.path.isfile(c) else None)
        if p: return p
    return None

def get_version():
    try:
        r = subprocess.run(['dpkg-query', '-W', '-f=${Status}|${Version}', pkg_id], capture_output=True, text=True)
        if r.returncode == 0 and 'install ok installed' in r.stdout:
            return r.stdout.split('|', 1)[1].strip()
    except Exception:
        pass
    return ''

def disk_avail_mb():
    try:
        st = os.statvfs('/')
        return int((st.f_bavail * st.f_frsize) / (1024 * 1024))
    except Exception:
        return 0

def matches_app(args):
    if app_kind == 'claude':
        return any('claude-desktop' in os.path.basename(x).lower() or '/claude-desktop/' in x.lower() for x in args[:2])
    return any('chatgpt' in os.path.basename(x).lower() for x in args[:2])

missing = []
app_bin = find_app()
if not app_bin: missing.append(pkg_id)
if not shutil.which('Xtigervnc'):
    if not shutil.which('Xvfb'): missing.append('xvfb')
    if not shutil.which('x11vnc'): missing.append('x11vnc')
if not shutil.which('openbox'): missing.append('openbox')
if not shutil.which('websockify') or not os.path.isfile('/usr/share/novnc/vnc.html'): missing.append('novnc')
if not shutil.which('xclip'): missing.append('xclip')
if not shutil.which('xdotool'): missing.append('xdotool')

def is_app_running():
    for d in os.listdir('/proc'):
        if not d.isdigit(): continue
        try:
            if os.stat('/proc/' + d).st_uid != os.getuid(): continue
            raw = open(f'/proc/{d}/cmdline', 'rb').read().decode(errors='ignore')
            args = [x for x in raw.split('\0') if x]
            if matches_app(args):
                return True
        except Exception:
            pass
    return False

print(json.dumps({
    'installed': app_bin is not None,
    'appRunning': is_app_running(),
    'version': get_version(),
    'diskAvailMB': disk_avail_mb(),
    'missing': missing
}))
"""#

    static let prepareScript = #"""
import os, pathlib, socket, subprocess, time, json, shutil, hashlib, signal

app_kind = settings.get('app', 'codex')
display_num = settings.get('display', ':98')
vnc_port = int(settings.get('vncPort', 5998))
port_base = int(settings.get('portBase', 22000))
config_dir = settings.get('configDir', 'agent-vm-codex-desktop')
pkg_id = settings.get('pkg', 'chatgpt')
log_file = settings.get('logFile', 'chatgpt.log')
app_label = 'Claude Code 官方桌面' if app_kind == 'claude' else 'Codex 官方桌面'

def emit(obj):
    print(json.dumps(obj), flush=True)

def proc_running(match):
    pids = []
    for proc in pathlib.Path('/proc').iterdir():
        if not proc.name.isdigit(): continue
        try:
            if proc.stat().st_uid != os.getuid(): continue
            args = (proc/'cmdline').read_bytes().decode(errors='ignore').split('\0')
            if match(args): pids.append((int(proc.name), args))
        except OSError:
            pass
    return pids

def find_app():
    if app_kind == 'claude':
        candidates = ('claude-desktop', '/usr/bin/claude-desktop', '/usr/lib/claude-desktop/claude-desktop', '/opt/Claude/claude-desktop')
    else:
        candidates = ('chatgpt', '/opt/ChatGPT/chatgpt', '/usr/bin/chatgpt')
    for c in candidates:
        p = shutil.which(c) if '/' not in c else (c if os.path.isfile(c) else None)
        if p: return p
    return None

def matches_app(args):
    if app_kind == 'claude':
        return any('claude-desktop' in os.path.basename(x).lower() or '/claude-desktop/' in x.lower() for x in args[:2])
    return any('chatgpt' in os.path.basename(x).lower() for x in args[:2])

def get_version():
    try:
        r = subprocess.run(['dpkg-query', '-W', '-f=${Status}|${Version}', pkg_id], capture_output=True, text=True)
        if r.returncode == 0 and 'install ok installed' in r.stdout:
            return r.stdout.split('|', 1)[1].strip()
    except Exception:
        pass
    return ''

def disk_avail_mb():
    try:
        st = os.statvfs('/')
        return int((st.f_bavail * st.f_frsize) / (1024 * 1024))
    except Exception:
        return 0

def cleanup_stale_chromium_shm():
    try:
        in_use = set()
        for p in pathlib.Path('/proc').iterdir():
            if not p.name.isdigit(): continue
            try:
                for fd in (p / 'fd').iterdir():
                    try:
                        t = os.readlink(fd)
                        if t.startswith('/tmp/.org.chromium.Chromium.'):
                            in_use.add(t)
                    except OSError:
                        pass
            except OSError:
                pass
        for item in pathlib.Path('/tmp').glob('.org.chromium.Chromium.*'):
            if str(item) not in in_use:
                try: item.unlink()
                except OSError: pass
    except Exception:
        pass

def ensure_cjk_fontconfig():
    try:
        fc_dir = pathlib.Path.home() / '.config/fontconfig'
        fc_file = fc_dir / 'fonts.conf'
        existing = fc_file.read_text(errors='ignore') if fc_file.exists() else ''
        if 'Noto Sans CJK SC' not in existing or 'hintslight' not in existing or 'rgba' not in existing:
            fc_dir.mkdir(parents=True, exist_ok=True)
            fc_file.write_text('''<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
    <edit name="rgba" mode="assign"><const>none</const></edit>
    <edit name="lcdfilter" mode="assign"><const>lcdnone</const></edit>
  </match>
  <alias><family>sans-serif</family><prefer><family>Noto Sans CJK SC</family><family>DejaVu Sans</family></prefer></alias>
  <alias><family>system-ui</family><prefer><family>Noto Sans CJK SC</family><family>DejaVu Sans</family></prefer></alias>
  <alias><family>serif</family><prefer><family>Noto Serif CJK SC</family><family>DejaVu Serif</family></prefer></alias>
  <alias><family>monospace</family><prefer><family>Noto Sans Mono CJK SC</family><family>DejaVu Sans Mono</family></prefer></alias>
</fontconfig>
''')
            subprocess.run(['fc-cache', '-f'], capture_output=True)
    except Exception:
        pass

try:
    emit({'stage': 'checking', 'message': f'正在检查{app_label}与显示组件…'})
    app_bin = find_app()
    websockify = shutil.which('websockify')
    xtigervnc = shutil.which('Xtigervnc')
    xvfb = shutil.which('Xvfb')
    x11vnc = shutil.which('x11vnc')
    openbox = shutil.which('openbox')
    missing = []
    if not app_bin: missing.append(pkg_id)
    if not xtigervnc and (not xvfb or not x11vnc):
        if not xvfb: missing.append('xvfb')
        if not x11vnc: missing.append('x11vnc')
    if not openbox: missing.append('openbox')
    if not websockify or not os.path.isfile('/usr/share/novnc/vnc.html'): missing.append('novnc')
    if not shutil.which('xclip'): missing.append('xclip')
    if not shutil.which('xdotool'): missing.append('xdotool')
    if missing:
        emit({'missing': missing, 'diskAvailMB': disk_avail_mb()})
        raise SystemExit(0)

    ensure_cjk_fontconfig()
    cleanup_stale_chromium_shm()
    shared_cwd = None
    try:
        shared_dir = pathlib.Path('/mnt/agent-vm-shared')
        if shared_dir.is_dir():
            shared_cwd = str(shared_dir)
            for link_name in ('共享文件夹', 'Shared'):
                link = pathlib.Path.home() / link_name
                if not link.exists() and not link.is_symlink():
                    link.symlink_to(shared_dir)
            bm_entries = [f'file://{shared_dir} 共享文件夹']
            mnt_root = pathlib.Path('/mnt')
            if mnt_root.is_dir():
                for child in sorted(mnt_root.iterdir()):
                    if child.name in ('agent-vm-shared', 'lima-cidata') or not child.is_dir():
                        continue
                    bm_entries.append(f'file://{child} {child.name}')
            for gtk_ver in ('gtk-3.0', 'gtk-4.0'):
                bm_dir = pathlib.Path.home() / '.config' / gtk_ver
                bm_dir.mkdir(parents=True, exist_ok=True)
                bm_file = bm_dir / 'bookmarks'
                existing_bm = bm_file.read_text(errors='ignore').splitlines() if bm_file.exists() else []
                existing_bm = [line for line in existing_bm if line.strip() and not line.startswith('file:///mnt/')]
                bm_file.write_text('\n'.join(bm_entries + existing_bm) + '\n')
    except Exception:
        pass
    scale = max(1.0, min(2.0, float(settings.get('scale', 2.0))))
    w = max(800, min(4096, int(settings.get('width', 2560)) // 2 * 2))
    h = max(500, min(2560, int(settings.get('height', 1600)) // 2 * 2))
    restart_app = bool(settings.get('restartApp', False))

    log_dir = pathlib.Path.home() / '.config' / config_dir
    log_dir.mkdir(parents=True, exist_ok=True)
    scale_file = log_dir / 'display-scale'
    dpi_val = int(round(scale * 96))
    scale_tag = f'{scale:.2f}-dpi{dpi_val}-v2'
    prev_scale = scale_file.read_text(errors='ignore').strip() if scale_file.exists() else ''
    scale_changed = prev_scale != scale_tag
    if scale_changed:
        restart_app = True
        scale_file.write_text(scale_tag)
    env = dict(os.environ, DISPLAY=display_num, LANG='en_US.UTF-8', LC_CTYPE='en_US.UTF-8')
    vnc_port_str = str(vnc_port)

    def stop_procs(match, wait_sec=3.5):
        targets = proc_running(match)
        if not targets:
            return
        for pid, _ in targets:
            try: os.kill(pid, signal.SIGTERM)
            except OSError: pass
        deadline = time.time() + wait_sec
        while time.time() < deadline:
            if not proc_running(match):
                return
            time.sleep(0.15)
        for pid, _ in proc_running(match):
            try: os.kill(pid, signal.SIGKILL)
            except OSError: pass
        time.sleep(0.2)

    def stop_electron_app():
        # Terminate main browser process(es) first so Electron shuts down its own
        # zygote/GPU children cleanly instead of triggering a GPU respawn loop.
        main_match = lambda a: matches_app(a) and '--type=' not in ' '.join(a)
        mains = proc_running(main_match)
        if mains:
            for pid, _ in mains:
                try: os.kill(pid, signal.SIGTERM)
                except OSError: pass
            deadline = time.time() + 2.5
            while time.time() < deadline:
                if not proc_running(matches_app):
                    return
                time.sleep(0.15)
            for pid, _ in proc_running(main_match):
                try: os.kill(pid, signal.SIGKILL)
                except OSError: pass
            time.sleep(0.15)
        stop_procs(matches_app, wait_sec=1.0)

    if scale_changed:
        stop_electron_app()
        stop_procs(lambda a: any('openbox' in x for x in a[:2]) and config_dir in ' '.join(a))
        stop_procs(lambda a: any('x11vnc' in x for x in a[:2]) and vnc_port_str in a)
        stop_procs(lambda a: any(('Xtigervnc' in x or 'Xvfb' in x) for x in a[:2]) and display_num in a)
        cleanup_stale_chromium_shm()

    use_tiger = bool(xtigervnc)
    if use_tiger:
        old_xvfb = proc_running(lambda a: any('Xvfb' in x for x in a[:2]) and display_num in a)
        if old_xvfb:
            stop_electron_app()
            stop_procs(lambda a: any('x11vnc' in x for x in a[:2]) and vnc_port_str in a)
            stop_procs(lambda a: any('openbox' in x for x in a[:2]) and config_dir in ' '.join(a))
            stop_procs(lambda a: any('Xvfb' in x for x in a[:2]) and display_num in a)

        emit({'stage': 'display', 'message': f'正在启动自适应虚拟显示 {display_num} ({w}×{h})…'})
        if not proc_running(lambda a: any('Xtigervnc' in x for x in a[:2]) and display_num in a):
            with open(log_dir / 'xvfb.log', 'ab') as f:
                subprocess.Popen([
                    xtigervnc, display_num, '-localhost', '-rfbport', vnc_port_str,
                    '-SecurityTypes', 'None', '-geometry', f'{w}x{h}',
                    '-depth', '24', '-dpi', str(dpi_val), '-FrameRate=60', '-CompareFB=1',
                    '-AcceptSetDesktopSize=1', '-AlwaysShared=1'
                ], stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)
            time.sleep(0.5)
    else:
        emit({'stage': 'display', 'message': f'正在启动虚拟显示 {display_num} ({w}×{h})…'})
        if not proc_running(lambda a: any('Xvfb' in x for x in a[:2]) and display_num in a):
            with open(log_dir / 'xvfb.log', 'ab') as f:
                subprocess.Popen(['Xvfb', display_num, '-screen', '0', f'{w}x{h}x24', '-nolisten', 'tcp', '+extension', 'RANDR'],
                                 stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)
            time.sleep(0.5)

    if not proc_running(lambda a: any('openbox' in x for x in a[:2]) and config_dir in ' '.join(a)):
        ob_rc = log_dir / 'openbox-rc.xml'
        ob_rc.write_text('''<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <applications>
    <application class="*">
      <decor>no</decor>
      <maximized>yes</maximized>
    </application>
  </applications>
</openbox_config>
''')
        with open(log_dir / 'openbox.log', 'ab') as f:
            subprocess.Popen(['openbox', '--config-file', str(ob_rc)], env=env, stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)
        time.sleep(0.3)

    if shutil.which('xrdb'):
        dpi_val = int(round(scale * 96))
        subprocess.run(['xrdb', '-merge'], input=f'Xft.dpi: {dpi_val}\n', text=True, env=env, capture_output=True)

    if restart_app:
        stop_electron_app()

    emit({'stage': 'app', 'message': f'正在启动{app_label}…'})
    running_app = proc_running(lambda a: matches_app(a) and '--type=' not in ' '.join(a))
    if not running_app:
        cmd = [
            app_bin,
            '--no-sandbox',
            '--disable-gpu',
            '--disable-dev-shm-usage',
            '--password-store=basic',
            '--ozone-platform=x11',
            f'--force-device-scale-factor={scale:g}'
        ]
        launch_cmd = ['dbus-run-session', '--'] + cmd if shutil.which('dbus-run-session') else cmd
        with open(log_dir / log_file, 'wb') as f:
            subprocess.Popen(launch_cmd, env=env, cwd=shared_cwd, stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)
        time.sleep(1.5)

    emit({'stage': 'vnc', 'message': '正在启动 noVNC 画面服务…'})
    if not use_tiger and not proc_running(lambda a: any('x11vnc' in x for x in a[:2]) and vnc_port_str in a):
        with open(log_dir / 'x11vnc.log', 'ab') as f:
            subprocess.Popen([
                'x11vnc', '-display', display_num, '-localhost', '-rfbport', vnc_port_str,
                '-forever', '-shared', '-nopw', '-quiet',
                '-xrandr', 'resize', '-noxdamage', '-wait', '10', '-defer', '10'
            ], env=env, stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)
        time.sleep(0.3)

    vnc_target = f'127.0.0.1:{vnc_port}'
    port = None
    existing = proc_running(lambda a: any('websockify' in x for x in a[:3]) and vnc_target in a)
    if existing:
        for arg in existing[0][1]:
            if arg.startswith('127.0.0.1:') and arg != vnc_target:
                try:
                    port = int(arg.split(':', 1)[1])
                    break
                except ValueError:
                    pass

    if port is None:
        number = int(hashlib.sha256(f"{settings['name']}:{app_kind}".encode()).hexdigest()[:4], 16)
        for candidate in range(port_base + number % 991, port_base + 10 + number % 991):
            with socket.socket() as probe:
                try: probe.bind(('127.0.0.1', candidate))
                except OSError: continue
            port = candidate
            break
        if port is None:
            raise RuntimeError('没有可用的桌面串流端口。')
        with open(log_dir / 'novnc.log', 'ab') as f:
            subprocess.Popen([
                websockify, '--web=/usr/share/novnc',
                '127.0.0.1:' + str(port), vnc_target
            ], stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)

    for _ in range(40):
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=0.3):
                break
        except OSError:
            time.sleep(0.25)
    else:
        raise RuntimeError('noVNC 启动超时。')

    emit({'port': port, 'resolution': f'{w}x{h}', 'version': get_version()})
except SystemExit:
    raise
except Exception as error:
    emit({'error': str(error)})
    raise SystemExit(1)
"""#

    static let resizeScript = #"""
import os, re, subprocess, json, shutil

w = max(800, min(4096, int(settings.get('width', 2560)) // 2 * 2))
h = max(500, min(2560, int(settings.get('height', 1600)) // 2 * 2))
env = dict(os.environ, DISPLAY=settings.get('display', ':98'))
xrandr = shutil.which('xrandr')
cvt = shutil.which('cvt')
actual = f'{w}x{h}'

if xrandr:
    q = subprocess.run([xrandr, '--query'], env=env, capture_output=True, text=True)
    m_out = re.search(r'^(\S+)\s+connected', q.stdout, re.M)
    out_name = m_out.group(1) if m_out else 'VNC-0'
    mode_name = f'{w}x{h}'
    if re.search(rf'^\s+{re.escape(mode_name)}\s+', q.stdout, re.M):
        subprocess.run([xrandr, '--output', out_name, '--mode', mode_name], env=env, capture_output=True)
    else:
        if cvt:
            c = subprocess.run([cvt, str(w), str(h), '60'], capture_output=True, text=True)
            ml = re.search(r'Modeline\s+"[^"]+"\s+(.*)', c.stdout)
            params = ml.group(1).split() if ml else None
        else:
            htotal = w + 160
            vtotal = h + 30
            pclk = round((htotal * vtotal * 60.0) / 1e6, 2)
            params = [str(pclk), str(w), str(w + 48), str(w + 80), str(htotal), str(h), str(h + 3), str(h + 8), str(vtotal), '-hsync', '+vsync']
        if params:
            subprocess.run([xrandr, '--newmode', mode_name] + params, env=env, capture_output=True)
            subprocess.run([xrandr, '--addmode', out_name, mode_name], env=env, capture_output=True)
            subprocess.run([xrandr, '--output', out_name, '--mode', mode_name], env=env, capture_output=True)
    q2 = subprocess.run([xrandr, '--query'], env=env, capture_output=True, text=True)
    cur = re.search(r'current\s+(\d+)\s+x\s+(\d+)', q2.stdout)
    if cur:
        actual = f'{cur.group(1)}x{cur.group(2)}'

print(json.dumps({'resolution': actual}))
"""#

    nonisolated static let imeDaemonScript = #"""
import json, os, subprocess, sys, time

for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        item = json.loads(raw)
        text = item.get('text', '')
        disp = item.get('display', ':98')
    except Exception:
        continue
    if not text:
        continue
    env = dict(os.environ, DISPLAY=disp)
    p = subprocess.Popen(
        ['xclip', '-selection', 'clipboard', '-in'],
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    p.communicate(text.encode('utf-8'))
    time.sleep(0.015)
    subprocess.run(
        ['xdotool', 'key', '--clearmodifiers', '--delay', '0', 'ctrl+v'],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
"""#

    static let stopScript = #"""
import os, pathlib, signal, time

app_kind = settings.get('app', 'codex')
display_num = settings.get('display', ':98')
vnc_port_str = str(settings.get('vncPort', 5998))
config_dir = settings.get('configDir', 'agent-vm-codex-desktop')

def proc_running(match):
    pids = []
    for proc in pathlib.Path('/proc').iterdir():
        if not proc.name.isdigit(): continue
        try:
            if proc.stat().st_uid != os.getuid(): continue
            args = [x for x in (proc / 'cmdline').read_bytes().decode(errors='ignore').split('\0') if x]
            if match(args): pids.append(int(proc.name))
        except OSError:
            pass
    return pids

def matches_app(args):
    if app_kind == 'claude':
        return any('claude-desktop' in os.path.basename(x).lower() or '/claude-desktop/' in x.lower() for x in args[:2])
    return any('chatgpt' in os.path.basename(x).lower() for x in args[:2])

def stop_procs(match, wait_sec=3.0):
    pids = proc_running(match)
    if not pids: return
    for pid in pids:
        try: os.kill(pid, signal.SIGTERM)
        except OSError: pass
    deadline = time.time() + wait_sec
    while time.time() < deadline:
        if not proc_running(match): return
        time.sleep(0.15)
    for pid in proc_running(match):
        try: os.kill(pid, signal.SIGKILL)
        except OSError: pass

def stop_electron_app():
    main_match = lambda a: matches_app(a) and '--type=' not in ' '.join(a)
    mains = proc_running(main_match)
    if mains:
        for pid in mains:
            try: os.kill(pid, signal.SIGTERM)
            except OSError: pass
        deadline = time.time() + 2.5
        while time.time() < deadline:
            if not proc_running(matches_app):
                return
            time.sleep(0.15)
        for pid in proc_running(main_match):
            try: os.kill(pid, signal.SIGKILL)
            except OSError: pass
        time.sleep(0.15)
    stop_procs(matches_app, wait_sec=1.0)

stop_electron_app()
stop_procs(lambda a: any('websockify' in x for x in a[:3]) and f'127.0.0.1:{vnc_port_str}' in a)
stop_procs(lambda a: any('openbox' in x for x in a[:2]) and config_dir in ' '.join(a))
stop_procs(lambda a: any('x11vnc' in x for x in a[:2]) and vnc_port_str in a)
stop_procs(lambda a: any(('Xtigervnc' in x or 'Xvfb' in x) for x in a[:2]) and display_num in a)
try:
    in_use = set()
    for p in pathlib.Path('/proc').iterdir():
        if not p.name.isdigit(): continue
        try:
            for fd in (p / 'fd').iterdir():
                try:
                    t = os.readlink(fd)
                    if t.startswith('/tmp/.org.chromium.Chromium.'):
                        in_use.add(t)
                except OSError:
                    pass
        except OSError:
            pass
    for item in pathlib.Path('/tmp').glob('.org.chromium.Chromium.*'):
        if str(item) not in in_use:
            try: item.unlink()
            except OSError: pass
except Exception:
    pass
"""#

    static let logsScript = #"""
import json, pathlib

config_dir = settings.get('configDir', 'agent-vm-codex-desktop')
log_file = settings.get('logFile', 'chatgpt.log')
log_dir = pathlib.Path.home() / '.config' / config_dir
chunks = []
for fname in ('install.log', 'xvfb.log', 'openbox.log', log_file, 'x11vnc.log', 'novnc.log'):
    p = log_dir / fname
    if p.exists():
        lines = p.read_text(errors='replace').splitlines()[-60:]
        if lines: chunks.append(f'=== {fname} ===\n' + '\n'.join(lines))
print(json.dumps({'logs': '\n\n'.join(chunks) or '暂无日志。'}))
"""#

    static func installScript(for app: DesktopAppKind) -> String {
        switch app {
        case .codex:
            return #"""
#!/bin/bash
set -euo pipefail
mkdir -p "$HOME/.config/agent-vm-codex-desktop"
exec > >(tee "$HOME/.config/agent-vm-codex-desktop/install.log") 2>&1

apt_busy() {
  for p in apt-get apt dpkg; do
    if pgrep -x "$p" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

wait_apt_lock() {
  local waited=0
  while apt_busy; do
    if [ "$waited" -eq 0 ]; then
      echo "检测到虚拟机内已有其他 apt/dpkg 任务正在运行，正在等待完成..."
    fi
    sleep 2
    waited=$((waited + 2))
    if [ "$waited" -ge 300 ]; then
      echo "等待 apt 锁超时（300 秒），请稍后重试。"
      exit 1
    fi
  done
}

NEED_APT=0
for bin in Xtigervnc openbox websockify xclip xdotool dbus-run-session; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    NEED_APT=1
    break
  fi
done
if [ ! -f /usr/share/novnc/vnc.html ]; then
  NEED_APT=1
fi
if [ "$(fc-list :lang=zh 2>/dev/null | wc -l)" = "0" ]; then
  NEED_APT=1
fi

if [ "$NEED_APT" = "1" ]; then
  echo "[1/4] 更新软件源索引..."
  wait_apt_lock
  sudo apt-get -o DPkg::Lock::Timeout=180 update
  echo "[2/4] 安装虚拟显示、中文字体与输入桥接组件 (TigerVNC / openbox / noVNC / fonts-noto-cjk / xclip / xdotool)..."
  PKGS="tigervnc-standalone-server xauth openbox novnc websockify x11-xserver-utils xclip xdotool dbus-x11 xdg-utils fonts-liberation fonts-dejavu-core fonts-noto-cjk"
  if ! command -v chromium >/dev/null 2>&1 && ! command -v chromium-browser >/dev/null 2>&1; then
    PKGS="$PKGS chromium"
  fi
  wait_apt_lock
  sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y --no-install-recommends $PKGS </dev/null
else
  echo "[1-2/4] 虚拟显示与输入桥接组件已就绪，跳过 apt 安装。"
  wait_apt_lock
  sudo apt-get -o DPkg::Lock::Timeout=180 update
fi

if ! command -v chatgpt >/dev/null 2>&1 && [ ! -f /opt/ChatGPT/chatgpt ]; then
  ARCH=$(dpkg --print-architecture)
  echo "[3/4] 正在获取 OpenAI 官方 Linux 桌面端 ($ARCH) 最新下载地址..."
  PKG_URL="https://persistent.oaistatic.com/codex-app-prod/linux/deb/dists/stable/main/binary-$ARCH/Packages"
  DEB_REL=$(curl -fsSL "$PKG_URL" | awk '/^Filename:/ {f=$2} END {print f}')
  if [ -z "$DEB_REL" ]; then
    echo "错误：未在官方仓库中找到 $ARCH 安装包 ($PKG_URL)"
    exit 1
  fi
  DEB_URL="https://persistent.oaistatic.com/codex-app-prod/linux/deb/$DEB_REL"
  echo "正在下载: $DEB_URL"
  curl -fL --retry 2 --connect-timeout 15 "$DEB_URL" -o /tmp/chatgpt-codex.deb 2>&1 | tr '\r' '\n' | awk 'NR==1 || NR%5==0 {print; fflush()}'

  echo "[4/4] 正在安装 chatgpt 桌面端 (.deb)..."
  wait_apt_lock
  sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y /tmp/chatgpt-codex.deb </dev/null
  rm -f /tmp/chatgpt-codex.deb
else
  echo "[3-4/4] 检测到官方 chatgpt 桌面端已安装，跳过下载。"
fi

echo "安装完成。"
"""#
        case .claude:
            return #"""
#!/bin/bash
set -euo pipefail
mkdir -p "$HOME/.config/agent-vm-claude-desktop"
exec > >(tee "$HOME/.config/agent-vm-claude-desktop/install.log") 2>&1

apt_busy() {
  for p in apt-get apt dpkg; do
    if pgrep -x "$p" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

wait_apt_lock() {
  local waited=0
  while apt_busy; do
    if [ "$waited" -eq 0 ]; then
      echo "检测到虚拟机内已有其他 apt/dpkg 任务正在运行，正在等待完成..."
    fi
    sleep 2
    waited=$((waited + 2))
    if [ "$waited" -ge 300 ]; then
      echo "等待 apt 锁超时（300 秒），请稍后重试。"
      exit 1
    fi
  done
}

NEED_APT=0
for bin in Xtigervnc openbox websockify xclip xdotool dbus-run-session curl; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    NEED_APT=1
    break
  fi
done
if [ ! -f /usr/share/novnc/vnc.html ]; then
  NEED_APT=1
fi
if [ "$(fc-list :lang=zh 2>/dev/null | wc -l)" = "0" ]; then
  NEED_APT=1
fi

if [ "$NEED_APT" = "1" ]; then
  echo "[1/4] 更新软件源索引..."
  wait_apt_lock
  sudo apt-get -o DPkg::Lock::Timeout=180 update
  echo "[2/4] 安装虚拟显示、中文字体与输入桥接组件 (TigerVNC / openbox / noVNC / fonts-noto-cjk / xclip / xdotool)..."
  PKGS="ca-certificates curl tigervnc-standalone-server xauth openbox novnc websockify x11-xserver-utils xclip xdotool dbus-x11 xdg-utils fonts-liberation fonts-dejavu-core fonts-noto-cjk"
  if ! command -v chromium >/dev/null 2>&1 && ! command -v chromium-browser >/dev/null 2>&1; then
    PKGS="$PKGS chromium"
  fi
  wait_apt_lock
  sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y --no-install-recommends $PKGS </dev/null
else
  echo "[1-2/4] 虚拟显示与输入桥接组件已就绪，跳过 apt 安装。"
fi

if ! command -v claude-desktop >/dev/null 2>&1 && [ ! -f /usr/lib/claude-desktop/claude-desktop ] && [ ! -f /opt/Claude/claude-desktop ]; then
  ARCH=$(dpkg --print-architecture)
  echo "[3/4] 正在配置 Anthropic 官方 Claude Desktop ($ARCH) APT 软件源..."
  sudo mkdir -p /usr/share/keyrings
  sudo curl -fsSLo /usr/share/keyrings/claude-desktop-archive-keyring.asc https://downloads.claude.ai/claude-desktop/key.asc
  echo "deb [signed-by=/usr/share/keyrings/claude-desktop-archive-keyring.asc] https://downloads.claude.ai/claude-desktop/apt/stable stable main" | sudo tee /etc/apt/sources.list.d/claude-desktop.list >/dev/null
  wait_apt_lock
  sudo apt-get -o DPkg::Lock::Timeout=180 update
  echo "[4/4] 正在安装 Claude Code / Claude 官方桌面端 (claude-desktop)..."
  wait_apt_lock
  sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y claude-desktop </dev/null
else
  echo "[3-4/4] 检测到官方 claude-desktop 桌面端已安装，跳过下载。"
fi

echo "安装完成。"
"""#
        }
    }
}
