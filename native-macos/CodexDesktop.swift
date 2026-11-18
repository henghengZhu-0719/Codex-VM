import Foundation
import SwiftUI

struct CodexDesktopState {
    var status = "idle" // idle, missing, starting, ready, error
    var stage = "idle"  // checking, display, app, vnc, ready, error
    var stageMessage = ""
    var url = ""
    var port = 0
    var error = ""
    var installed = false
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

// Installs and runs OpenAI's official Linux desktop app (`chatgpt` .deb) inside the VM
// on an isolated virtual display (:98, VNC 5998, websockify 22000..22010),
// and streams it over loopback noVNC to the native macOS shell.
@MainActor final class CodexDesktopManager {
    var onChange: (([String: CodexDesktopState]) -> Void)?
    var onOpen: ((String, URL) -> Void)?
    private(set) var states: [String: CodexDesktopState] = [:]
    private var preparing: Set<String> = []
    private var checking: Set<String> = []
    private var generations: [String: UUID] = [:]
    private var resizeWorkItems: [String: DispatchWorkItem] = [:]
    private let imeQueue = DispatchQueue(label: "org.agentvm.codex-desktop.ime")

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
            q = 9; c = 1
        case "smooth":
            q = 4; c = 5
        default:
            q = 7; c = 2
        }
        return "http://127.0.0.1:\(port)/vnc.html?autoconnect=1&resize=remote&quality=\(q)&compression=\(c)"
    }

    private static func clampedSize(_ width: Int, _ height: Int) -> (Int, Int) {
        let w = max(800, min(2560, (width / 2) * 2))
        let h = max(500, min(1600, (height / 2) * 2))
        return (w, h)
    }

    func retain(_ names: Set<String>) {
        for name in Array(states.keys) where !names.contains(name) {
            generations.removeValue(forKey: name)
            preparing.remove(name)
            checking.remove(name)
            resizeWorkItems[name]?.cancel()
            resizeWorkItems.removeValue(forKey: name)
            states.removeValue(forKey: name)
        }
        onChange?(states)
    }

    func checkStatus(name: String, config: String) {
        guard !checking.contains(name), !preparing.contains(name), states[name]?.installing != true else { return }
        checking.insert(name)
        let script = Self.statusScript
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
                    self.checking.remove(name)
                    guard let obj else { return }
                    var st = self.states[name] ?? CodexDesktopState()
                    let installed = obj["installed"] as? Bool ?? false
                    let missing = obj["missing"] as? [String] ?? []
                    st.installed = installed
                    st.appVersion = obj["version"] as? String ?? ""
                    st.diskAvailMB = obj["diskAvailMB"] as? Int ?? 0
                    st.missingComponents = missing
                    if st.status == "idle" || st.status == "missing" {
                        st.status = missing.isEmpty ? "idle" : "missing"
                    }
                    self.states[name] = st
                    self.onChange?(self.states)
                }
            } catch {
                DispatchQueue.main.async { self.checking.remove(name) }
            }
        }
    }

    func open(name: String, config: String, width: Int = 1280, height: Int = 800, qualityMode: String? = nil) {
        guard states[name]?.installing != true else { return }
        let qMode = qualityMode ?? states[name]?.qualityMode ?? "balanced"
        if let existing = states[name], existing.status == "ready", existing.port > 0 {
            let url = Self.buildNoVNCURL(port: existing.port, qualityMode: qMode)
            states[name]?.qualityMode = qMode
            states[name]?.url = url
            onChange?(states)
            verifyAndOpen(name: name, port: existing.port, url: url, config: config, width: width, height: height, qualityMode: qMode, fallbackPrepare: true)
            return
        }
        guard !preparing.contains(name) else { return }
        start(name: name, config: config, width: width, height: height, qualityMode: qMode)
    }

    func setQuality(name: String, qualityMode: String) {
        guard ["balanced", "sharp", "smooth"].contains(qualityMode) else { return }
        var st = states[name] ?? CodexDesktopState()
        st.qualityMode = qualityMode
        if st.status == "ready", st.port > 0 {
            let newURL = Self.buildNoVNCURL(port: st.port, qualityMode: qualityMode)
            st.url = newURL
            states[name] = st
            onChange?(states)
            if let target = URL(string: newURL) { onOpen?(name, target) }
        } else {
            states[name] = st
            onChange?(states)
        }
    }

    func setAutoResize(name: String, enabled: Bool, config: String, width: Int, height: Int) {
        var st = states[name] ?? CodexDesktopState()
        st.autoResize = enabled
        states[name] = st
        onChange?(states)
        if enabled && width > 100 && height > 100 {
            resize(name: name, config: config, width: width, height: height)
        }
    }

    func resize(name: String, config: String, width: Int, height: Int) {
        let (w, h) = Self.clampedSize(width, height)
        let targetRes = "\(w)x\(h)"
        guard states[name]?.status == "ready", states[name]?.resolution != targetRes else { return }
        resizeWorkItems[name]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.performResize(name: name, config: config, width: w, height: h)
        }
        resizeWorkItems[name] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: item)
    }

    private func performResize(name: String, config: String, width: Int, height: Int) {
        guard states[name]?.status == "ready" else { return }
        let input: [String: Any] = ["width": width, "height": height]
        guard let data = try? JSONSerialization.data(withJSONObject: input) else { return }
        let script = "import json, base64\nsettings = json.loads(base64.b64decode('" + data.base64EncodedString() + "'))\n" + Self.resizeScript
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
                        self.states[name]?.resolution = actual
                        self.onChange?(self.states)
                    }
                }
            } catch {}
        }
    }

    private func verifyAndOpen(name: String, port: Int, url: String, config: String, width: Int, height: Int, qualityMode: String, fallbackPrepare: Bool) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/vnc.html")!)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { _, response, _ in
            DispatchQueue.main.async {
                if (response as? HTTPURLResponse)?.statusCode == 200, let target = URL(string: url) {
                    self.onOpen?(name, target)
                    self.resize(name: name, config: config, width: width, height: height)
                } else if fallbackPrepare {
                    self.start(name: name, config: config, width: width, height: height, qualityMode: qualityMode)
                } else {
                    self.failed(name, "官方 Codex 桌面端未响应，请重试。", missing: [])
                }
            }
        }.resume()
    }

    private func start(name: String, config: String, width: Int, height: Int, qualityMode: String, restartApp: Bool = false) {
        let generation = UUID()
        generations[name] = generation
        preparing.insert(name)
        let (w, h) = Self.clampedSize(width, height)
        var st = states[name] ?? CodexDesktopState()
        st.status = "starting"
        st.stage = "checking"
        st.stageMessage = "正在检查官方 Codex 桌面端与显示环境…"
        st.error = ""
        st.qualityMode = qualityMode
        states[name] = st
        onChange?(states)

        let input: [String: Any] = ["name": name, "width": w, "height": h, "restartApp": restartApp]
        guard let data = try? JSONSerialization.data(withJSONObject: input) else { return }
        let script = "import json, base64\nsettings = json.loads(base64.b64decode('" + data.base64EncodedString() + "'))\n" + Self.prepareScript

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
                                guard let self, self.generations[name] == generation else { return }
                                self.states[name]?.stage = stage
                                if !msg.isEmpty { self.states[name]?.stageMessage = msg }
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
                let error = finalDecoded?["error"] as? String ?? "无法启动官方 Codex 桌面端，请检查虚拟机连接。"
                DispatchQueue.main.async {
                    guard self.generations[name] == generation else { return }
                    if !missing.isEmpty {
                        self.preparing.remove(name)
                        var st = self.states[name] ?? CodexDesktopState()
                        st.status = "missing"
                        st.stage = "checking"
                        st.installed = !missing.contains("chatgpt")
                        st.missingComponents = missing
                        st.diskAvailMB = diskAvailMB
                        st.error = ""
                        self.states[name] = st
                        self.onChange?(self.states)
                        return
                    }
                    guard process.terminationStatus == 0, let port, (1024...65535).contains(port) else {
                        self.failed(name, error, missing: missing)
                        return
                    }
                    self.states[name]?.installed = true
                    if !version.isEmpty { self.states[name]?.appVersion = version }
                    self.states[name]?.stage = "vnc"
                    self.states[name]?.stageMessage = "正在建立 noVNC 画面连接…"
                    self.states[name]?.resolution = resolution
                    self.onChange?(self.states)
                    self.check(name: name, port: port, qualityMode: qualityMode, generation: generation, attempts: 25)
                }
            } catch {
                timeout.cancel()
                output.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { process.terminate() }
                DispatchQueue.main.async {
                    if self.generations[name] == generation {
                        self.failed(name, "无法连接官方 Codex 桌面端。", missing: [])
                    }
                }
            }
        }
    }

    private func check(name: String, port: Int, qualityMode: String, generation: UUID, attempts: Int) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/vnc.html")!)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { _, response, _ in
            DispatchQueue.main.async {
                guard self.generations[name] == generation else { return }
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    self.preparing.remove(name)
                    let url = Self.buildNoVNCURL(port: port, qualityMode: qualityMode)
                    var st = self.states[name] ?? CodexDesktopState()
                    st.status = "ready"
                    st.stage = "ready"
                    st.stageMessage = "官方 Codex 桌面端已就绪"
                    st.url = url
                    st.port = port
                    st.qualityMode = qualityMode
                    st.installed = true
                    st.error = ""
                    st.missingComponents = []
                    self.states[name] = st
                    self.onChange?(self.states)
                    if let target = URL(string: url) { self.onOpen?(name, target) }
                } else if attempts > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.check(name: name, port: port, qualityMode: qualityMode, generation: generation, attempts: attempts - 1)
                    }
                } else {
                    self.failed(name, "官方 Codex 桌面端界面未能响应，请重试。", missing: [])
                }
            }
        }.resume()
    }

    private func failed(_ name: String, _ error: String, missing: [String]) {
        preparing.remove(name)
        var st = states[name] ?? CodexDesktopState()
        st.status = "error"
        st.stage = "error"
        st.error = error
        st.missingComponents = missing
        states[name] = st
        onChange?(states)
    }

    func restartApp(name: String, config: String, width: Int, height: Int) {
        guard !preparing.contains(name), states[name]?.installing != true else { return }
        let qMode = states[name]?.qualityMode ?? "balanced"
        start(name: name, config: config, width: width, height: height, qualityMode: qMode, restartApp: true)
    }

    func sendText(name: String, config: String, text: String) {
        guard !text.isEmpty else { return }
        let input: [String: Any] = ["text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: input) else { return }
        let script = "import json, base64\npayload = json.loads(base64.b64decode('" + data.base64EncodedString() + "'))\n" + Self.pasteTextScript
        imeQueue.async {
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
        }
    }

    func fetchLogs(name: String, config: String) {
        let script = Self.logsScript
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
                        self.states[name]?.logs = logs
                        self.onChange?(self.states)
                    }
                }
            } catch {}
        }
    }

    func install(name: String, config: String, width: Int, height: Int, completion: @escaping (Bool, String) -> Void) {
        guard states[name]?.installing != true else { return }
        var st = states[name] ?? CodexDesktopState()
        st.installing = true
        st.error = ""
        st.stageMessage = "正在准备安装官方 Codex 桌面端与显示环境…"
        st.installOutput = ""
        states[name] = st
        onChange?(states)

        let script = Self.installScript
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
                        self?.states[name]?.installOutput = snapshot
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
                    self.states[name]?.installing = false
                    if proc.terminationStatus == 0 {
                        self.states[name]?.missingComponents = []
                        self.states[name]?.installed = true
                        self.onChange?(self.states)
                        self.open(name: name, config: config, width: width, height: height)
                        completion(true, "官方 Codex 桌面端安装完成")
                    } else {
                        self.states[name]?.status = "error"
                        self.states[name]?.error = "安装未完成，请展开安装日志查看详情。"
                        self.onChange?(self.states)
                        completion(false, "安装失败（退出码 \(proc.terminationStatus)）")
                    }
                }
            } catch {
                out.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    self.states[name]?.installing = false
                    self.states[name]?.status = "error"
                    self.states[name]?.error = error.localizedDescription
                    self.onChange?(self.states)
                    completion(false, error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Guest Python & Shell Scripts

    static let statusScript = #"""
import json, os, shutil, subprocess

def find_chatgpt():
    for c in ('chatgpt', '/opt/ChatGPT/chatgpt', '/usr/bin/chatgpt'):
        p = shutil.which(c) if '/' not in c else (c if os.path.isfile(c) else None)
        if p: return p
    return None

def get_version():
    try:
        r = subprocess.run(['dpkg-query', '-W', '-f=${Status}|${Version}', 'chatgpt'], capture_output=True, text=True)
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

missing = []
app_bin = find_chatgpt()
if not app_bin: missing.append('chatgpt')
if not shutil.which('Xtigervnc'):
    if not shutil.which('Xvfb'): missing.append('xvfb')
    if not shutil.which('x11vnc'): missing.append('x11vnc')
if not shutil.which('openbox'): missing.append('openbox')
if not shutil.which('websockify') or not os.path.isfile('/usr/share/novnc/vnc.html'): missing.append('novnc')
if not shutil.which('xclip'): missing.append('xclip')
if not shutil.which('xdotool'): missing.append('xdotool')

print(json.dumps({
    'installed': app_bin is not None,
    'version': get_version(),
    'diskAvailMB': disk_avail_mb(),
    'missing': missing
}))
"""#

    static let prepareScript = #"""
import os, pathlib, socket, subprocess, time, json, shutil, hashlib, signal

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

def find_chatgpt():
    for c in ('chatgpt', '/opt/ChatGPT/chatgpt', '/usr/bin/chatgpt'):
        p = shutil.which(c) if '/' not in c else (c if os.path.isfile(c) else None)
        if p: return p
    return None

def get_version():
    try:
        r = subprocess.run(['dpkg-query', '-W', '-f=${Status}|${Version}', 'chatgpt'], capture_output=True, text=True)
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

def ensure_cjk_fontconfig():
    try:
        fc_dir = pathlib.Path.home() / '.config/fontconfig'
        fc_file = fc_dir / 'fonts.conf'
        if not fc_file.exists() or 'Noto Sans CJK SC' not in fc_file.read_text(errors='ignore'):
            fc_dir.mkdir(parents=True, exist_ok=True)
            fc_file.write_text('''<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
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
    emit({'stage': 'checking', 'message': '正在检查官方 Codex 桌面端与显示组件…'})
    app_bin = find_chatgpt()
    websockify = shutil.which('websockify')
    xtigervnc = shutil.which('Xtigervnc')
    xvfb = shutil.which('Xvfb')
    x11vnc = shutil.which('x11vnc')
    openbox = shutil.which('openbox')
    missing = []
    if not app_bin: missing.append('chatgpt')
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
    w = max(800, min(2560, int(settings.get('width', 1280)) // 2 * 2))
    h = max(500, min(1600, int(settings.get('height', 800)) // 2 * 2))
    restart_app = bool(settings.get('restartApp', False))

    log_dir = pathlib.Path.home() / '.config/agent-vm-codex-desktop'
    log_dir.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, DISPLAY=':98', LANG='en_US.UTF-8', LC_CTYPE='en_US.UTF-8')

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

    use_tiger = bool(xtigervnc)
    if use_tiger:
        old_xvfb = proc_running(lambda a: any('Xvfb' in x for x in a[:2]) and ':98' in a)
        if old_xvfb:
            stop_procs(lambda a: any('chatgpt' in x.lower() for x in a[:2]))
            stop_procs(lambda a: any('x11vnc' in x for x in a[:2]) and '5998' in a)
            stop_procs(lambda a: any('openbox' in x for x in a[:2]) and 'agent-vm-codex-desktop' in ' '.join(a))
            stop_procs(lambda a: any('Xvfb' in x for x in a[:2]) and ':98' in a)

        emit({'stage': 'display', 'message': f'正在启动自适应虚拟显示 :98 ({w}×{h})…'})
        if not proc_running(lambda a: any('Xtigervnc' in x for x in a[:2]) and ':98' in a):
            with open(log_dir / 'xvfb.log', 'ab') as f:
                subprocess.Popen([
                    xtigervnc, ':98', '-localhost', '-rfbport', '5998',
                    '-SecurityTypes', 'None', '-geometry', f'{w}x{h}',
                    '-depth', '24', '-AcceptSetDesktopSize=1', '-AlwaysShared=1'
                ], stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)
            time.sleep(0.5)
    else:
        emit({'stage': 'display', 'message': f'正在启动虚拟显示 :98 ({w}×{h})…'})
        if not proc_running(lambda a: any('Xvfb' in x for x in a[:2]) and ':98' in a):
            with open(log_dir / 'xvfb.log', 'ab') as f:
                subprocess.Popen(['Xvfb', ':98', '-screen', '0', f'{w}x{h}x24', '-nolisten', 'tcp', '+extension', 'RANDR'],
                                 stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)
            time.sleep(0.5)

    if not proc_running(lambda a: any('openbox' in x for x in a[:2]) and 'agent-vm-codex-desktop' in ' '.join(a)):
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

    if restart_app:
        stop_procs(lambda a: any('chatgpt' in x.lower() for x in a[:2]))

    emit({'stage': 'app', 'message': '正在启动官方 Codex 桌面端…'})
    running_app = proc_running(lambda a: any('chatgpt' in x.lower() for x in a[:2]) and '--type=' not in ' '.join(a))
    if not running_app:
        cmd = [
            app_bin,
            '--no-sandbox',
            '--disable-gpu',
            '--disable-dev-shm-usage',
            '--password-store=basic',
            '--ozone-platform=x11'
        ]
        launch_cmd = ['dbus-run-session', '--'] + cmd if shutil.which('dbus-run-session') else cmd
        with open(log_dir / 'chatgpt.log', 'ab') as f:
            subprocess.Popen(launch_cmd, env=env, stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)
        time.sleep(1.5)

    emit({'stage': 'vnc', 'message': '正在启动 noVNC 画面服务…'})
    if not use_tiger and not proc_running(lambda a: any('x11vnc' in x for x in a[:2]) and '5998' in a):
        with open(log_dir / 'x11vnc.log', 'ab') as f:
            subprocess.Popen([
                'x11vnc', '-display', ':98', '-localhost', '-rfbport', '5998',
                '-forever', '-shared', '-nopw', '-quiet',
                '-xrandr', 'resize', '-noxdamage', '-wait', '10', '-defer', '10'
            ], env=env, stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)
        time.sleep(0.3)

    port = None
    existing = proc_running(lambda a: any('websockify' in x for x in a[:3]) and '127.0.0.1:5998' in a)
    if existing:
        for arg in existing[0][1]:
            if arg.startswith('127.0.0.1:') and arg != '127.0.0.1:5998':
                try:
                    port = int(arg.split(':', 1)[1])
                    break
                except ValueError:
                    pass

    if port is None:
        number = int(hashlib.sha256(settings['name'].encode()).hexdigest()[:4], 16)
        for candidate in range(22000 + number % 9991, 22010 + number % 9991):
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
                '127.0.0.1:' + str(port), '127.0.0.1:5998'
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

w = max(800, min(2560, int(settings.get('width', 1280)) // 2 * 2))
h = max(500, min(1600, int(settings.get('height', 800)) // 2 * 2))
env = dict(os.environ, DISPLAY=':98')
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

    static let pasteTextScript = #"""
import os, subprocess, time

env = dict(os.environ, DISPLAY=':98')
text = payload.get('text', '')
if text:
    p = subprocess.Popen(
        ['xclip', '-selection', 'clipboard', '-in'],
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    p.communicate(text.encode('utf-8'))
    time.sleep(0.08)
    subprocess.run(['xdotool', 'key', '--clearmodifiers', 'ctrl+v'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
"""#

    static let logsScript = #"""
import json, pathlib

log_dir = pathlib.Path.home() / '.config/agent-vm-codex-desktop'
chunks = []
for fname in ('install.log', 'xvfb.log', 'openbox.log', 'chatgpt.log', 'x11vnc.log', 'novnc.log'):
    p = log_dir / fname
    if p.exists():
        lines = p.read_text(errors='replace').splitlines()[-60:]
        if lines: chunks.append(f'=== {fname} ===\n' + '\n'.join(lines))
print(json.dumps({'logs': '\n\n'.join(chunks) or '暂无日志。'}))
"""#

    static let installScript = #"""
#!/bin/bash
set -euo pipefail
mkdir -p "$HOME/.config/agent-vm-codex-desktop"
exec > >(tee "$HOME/.config/agent-vm-codex-desktop/install.log") 2>&1

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
  sudo apt-get update
  echo "[2/4] 安装虚拟显示、中文字体与输入桥接组件 (TigerVNC / openbox / noVNC / fonts-noto-cjk / xclip / xdotool)..."
  PKGS="tigervnc-standalone-server xauth openbox novnc websockify x11-xserver-utils xclip xdotool dbus-x11 xdg-utils fonts-liberation fonts-dejavu-core fonts-noto-cjk"
  if ! command -v chromium >/dev/null 2>&1 && ! command -v chromium-browser >/dev/null 2>&1; then
    PKGS="$PKGS chromium"
  fi
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $PKGS </dev/null
else
  echo "[1-2/4] 虚拟显示与输入桥接组件已就绪，跳过 apt 安装。"
  sudo apt-get update
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
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/chatgpt-codex.deb </dev/null
  rm -f /tmp/chatgpt-codex.deb
else
  echo "[3-4/4] 检测到官方 chatgpt 桌面端已安装，跳过下载。"
fi

echo "安装完成。"
"""#
}
