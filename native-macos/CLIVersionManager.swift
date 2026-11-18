import Foundation

struct CLIVersionEntry {
    let agent: String        // "codex" | "agy" | "claude"
    var installed = false
    var current = ""
    var latest = ""
    var hasUpdate = false
    var updating = false
    var error = ""
}

struct VMCLIState {
    var checking = false
    var updating = false
    var entries: [String: CLIVersionEntry] = [:]
    var checkedAt: Date?
    var error = ""
}

// Monitors codex, agy (Antigravity), and claude CLI versions across running VMs
// and updates any outdated CLIs when discovered (auto or manual).
@MainActor final class CLIVersionManager {
    static let trackedAgents = ["codex", "agy", "claude"]

    var onChange: (() -> Void)?
    var onAutoUpdateComplete: ((_ updatedCount: Int, _ failedCount: Int) -> Void)?

    private(set) var vmStates: [String: VMCLIState] = [:]
    private(set) var latestVersions: [String: String] = [:]
    private(set) var latestCheckedAt: Date?
    private(set) var checkingAll = false
    private(set) var updatingAll = false
    var autoUpdate: Bool = UserDefaults.standard.object(forKey: "cliAutoUpdate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoUpdate, forKey: "cliAutoUpdate") }
    }

    private var checkingVMs: Set<String> = []
    private var updatingVMs: Set<String> = []

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

    static func parseVersionParts(_ raw: String) -> [Int] {
        let core = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        let parts = core.split(separator: ".").compactMap { Int($0) }
        return parts
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = parseVersionParts(candidate)
        let b = parseVersionParts(current)
        guard !a.isEmpty, !b.isEmpty else { return false }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }

    func retain(_ names: Set<String>) {
        var changed = false
        for k in Array(vmStates.keys) where !names.contains(k) {
            vmStates.removeValue(forKey: k)
            checkingVMs.remove(k)
            updatingVMs.remove(k)
            changed = true
        }
        if changed { onChange?() }
    }

    func hasChecked(vmName: String) -> Bool {
        vmStates[vmName]?.checkedAt != nil
    }

    func pruneUnallowed(vmName: String, allowed: [String]) {
        guard var st = vmStates[vmName] else { return }
        let allowSet = Set(allowed)
        var changed = false
        for key in Array(st.entries.keys) where !allowSet.contains(key) {
            st.entries.removeValue(forKey: key)
            changed = true
        }
        if changed {
            vmStates[vmName] = st
            onChange?()
        }
    }

    private func recomputeUpdateFlags() {
        for vmName in vmStates.keys {
            guard var st = vmStates[vmName] else { continue }
            for agent in Self.trackedAgents {
                if var entry = st.entries[agent] {
                    let latest = latestVersions[agent] ?? entry.latest
                    entry.latest = latest
                    entry.hasUpdate = entry.installed && !entry.current.isEmpty && !latest.isEmpty && Self.isVersion(latest, newerThan: entry.current)
                    st.entries[agent] = entry
                }
            }
            vmStates[vmName] = st
        }
    }

    func checkAll(vms: [VM],
                  sshConfigForVM: @escaping (String) -> String,
                  allowedAgentsForVM: @escaping (String) -> [String],
                  triggerAutoUpdate: Bool = true) {
        let running = vms.filter { $0.status == "Running" && $0.name != "base" && $0.name != "base-building" }
        guard !running.isEmpty, !checkingAll, !updatingAll else { return }
        checkingAll = true
        onChange?()

        let group = DispatchGroup()
        // Query local CLI versions on all running VMs; fetch upstream latest from the first VM (or fallback)
        var gotLatest = false
        let latestLock = NSLock()
        var sshTargets: [(VM, [String], String)] = []

        for vm in running {
            let vmName = vm.name
            let allowed = allowedAgentsForVM(vmName).filter { Self.trackedAgents.contains($0) }
            let cfg = sshConfigForVM(vmName)
            guard FileManager.default.fileExists(atPath: cfg) else { continue }
            pruneUnallowed(vmName: vmName, allowed: allowed)
            if allowed.isEmpty {
                var st = vmStates[vmName] ?? VMCLIState()
                st.checking = false
                st.checkedAt = Date()
                st.entries = [:]
                st.error = ""
                vmStates[vmName] = st
                continue
            }
            sshTargets.append((vm, allowed, cfg))
        }

        // Fallback if all running VMs have no configured apps yet: still fetch upstream latest on the first VM.
        if sshTargets.isEmpty, let first = running.first {
            let cfg = sshConfigForVM(first.name)
            if FileManager.default.fileExists(atPath: cfg) {
                sshTargets.append((first, [], cfg))
            }
        }

        for (index, item) in sshTargets.enumerated() {
            let (vm, allowed, cfg) = item
            let vmName = vm.name
            var st = vmStates[vmName] ?? VMCLIState()
            st.checking = true
            st.error = ""
            vmStates[vmName] = st
            checkingVMs.insert(vmName)

            let shouldFetchRemote = (index == 0)
            group.enter()
            runCheckScript(vmName: vmName, config: cfg, agents: allowed, fetchRemote: shouldFetchRemote) { [weak self] localMap, remoteMap, err in
                guard let self else { group.leave(); return }
                self.checkingVMs.remove(vmName)
                var curState = self.vmStates[vmName] ?? VMCLIState()
                curState.checking = false
                curState.checkedAt = Date()
                if let err { curState.error = err }
                let allowSet = Set(allowed)
                for key in Array(curState.entries.keys) where !allowSet.contains(key) {
                    curState.entries.removeValue(forKey: key)
                }
                for agent in allowed {
                    if let info = localMap[agent] {
                        var existing = curState.entries[agent] ?? CLIVersionEntry(agent: agent)
                        existing.installed = info.installed
                        existing.current = info.current
                        existing.error = info.error
                        curState.entries[agent] = existing
                    }
                }
                self.vmStates[vmName] = curState

                if !remoteMap.isEmpty {
                    latestLock.lock()
                    for (k, v) in remoteMap where !v.isEmpty {
                        self.latestVersions[k] = v
                    }
                    gotLatest = true
                    self.latestCheckedAt = Date()
                    latestLock.unlock()
                }
                self.recomputeUpdateFlags()
                self.onChange?()
                group.leave()
            }
        }
        onChange?()

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let finalize = {
                self.checkingAll = false
                self.recomputeUpdateFlags()
                self.onChange?()
                if triggerAutoUpdate && self.autoUpdate && self.hasAnyUpdate() {
                    self.updateAllOutdated(vms: running, sshConfigForVM: sshConfigForVM, allowedAgentsForVM: allowedAgentsForVM, fromAutoMonitor: true)
                }
            }
            latestLock.lock()
            let needFallback = !gotLatest && sshTargets.count > 1
            latestLock.unlock()
            if needFallback {
                let second = sshTargets[1]
                self.runCheckScript(vmName: second.0.name, config: second.2, agents: second.1, fetchRemote: true) { _, remoteMap, _ in
                    for (k, v) in remoteMap where !v.isEmpty {
                        self.latestVersions[k] = v
                    }
                    if !remoteMap.isEmpty { self.latestCheckedAt = Date() }
                    finalize()
                }
            } else {
                finalize()
            }
        }
    }

    func hasAnyUpdate() -> Bool {
        vmStates.values.contains { st in st.entries.values.contains { $0.hasUpdate } }
    }

    func updateAllOutdated(vms: [VM],
                           sshConfigForVM: (String) -> String,
                           allowedAgentsForVM: (String) -> [String],
                           fromAutoMonitor: Bool = false) {
        guard !updatingAll else { return }
        let targets: [(VM, [String])] = vms.compactMap { vm in
            guard vm.status == "Running",
                  let st = vmStates[vm.name] else { return nil }
            let allowed = Set(allowedAgentsForVM(vm.name))
            let agents = Self.trackedAgents.filter { allowed.contains($0) && st.entries[$0]?.hasUpdate == true }
            return agents.isEmpty ? nil : (vm, agents)
        }
        guard !targets.isEmpty else { return }

        updatingAll = true
        onChange?()

        var updatedCount = 0
        var failedCount = 0
        let group = DispatchGroup()

        for (vm, agents) in targets {
            let vmName = vm.name
            let cfg = sshConfigForVM(vmName)
            guard FileManager.default.fileExists(atPath: cfg) else { continue }
            group.enter()
            updateVM(vmName: vmName, agents: agents, config: cfg) { ok, count in
                updatedCount += count
                if !ok { failedCount += 1 }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.updatingAll = false
            self.recomputeUpdateFlags()
            self.onChange?()
            if fromAutoMonitor || updatedCount > 0 || failedCount > 0 {
                self.onAutoUpdateComplete?(updatedCount, failedCount)
            }
        }
    }

    func updateSingle(vmName: String, agent: String, config: String, completion: @escaping (Bool, Int) -> Void) {
        guard Self.trackedAgents.contains(agent), !updatingVMs.contains(vmName) else {
            completion(false, 0)
            return
        }
        updateVM(vmName: vmName, agents: [agent], config: config, completion: completion)
    }

    private func updateVM(vmName: String, agents: [String], config: String, completion: @escaping (Bool, Int) -> Void) {
        guard !agents.isEmpty else { completion(true, 0); return }
        updatingVMs.insert(vmName)
        var st = vmStates[vmName] ?? VMCLIState()
        st.updating = true
        st.error = ""
        for a in agents {
            var e = st.entries[a] ?? CLIVersionEntry(agent: a)
            e.updating = true
            e.error = ""
            st.entries[a] = e
        }
        vmStates[vmName] = st
        onChange?()

        let input: [String: Any] = ["agents": agents]
        guard let data = try? JSONSerialization.data(withJSONObject: input) else {
            completion(false, 0)
            return
        }
        let script = "import json, base64\npayload = json.loads(base64.b64decode('" + data.base64EncodedString() + "'))\n" + Self.updateScript

        DispatchQueue.global(qos: .utility).async {
            let proc = Process(), out = Pipe(), stdin = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = Self.sshControlArgs(config: config, timeout: 10) + ["lima-" + vmName, "python3 -"]
            proc.standardOutput = out
            proc.standardError = out
            proc.standardInput = stdin
            var results: [String: [String: Any]] = [:]
            do {
                try proc.run()
                try stdin.fileHandleForWriting.write(contentsOf: Data(script.utf8))
                try stdin.fileHandleForWriting.close()
                let raw = out.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                let text = String(data: raw, encoding: .utf8) ?? ""
                if let line = text.components(separatedBy: .newlines).last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }),
                   let lineData = line.data(using: .utf8),
                   let decoded = try? JSONSerialization.jsonObject(with: lineData) as? [String: [String: Any]] {
                    results = decoded
                }
            } catch {}

            DispatchQueue.main.async {
                self.updatingVMs.remove(vmName)
                var cur = self.vmStates[vmName] ?? VMCLIState()
                cur.updating = false
                cur.checkedAt = Date()
                var allOK = !results.isEmpty
                var okCount = 0
                for a in agents {
                    var e = cur.entries[a] ?? CLIVersionEntry(agent: a)
                    e.updating = false
                    if let res = results[a] {
                        let ok = res["ok"] as? Bool ?? false
                        if ok {
                            okCount += 1
                            if let newVer = res["version"] as? String, !newVer.isEmpty {
                                e.current = newVer
                            }
                            e.error = ""
                        } else {
                            allOK = false
                            e.error = (res["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "更新失败"
                        }
                    } else {
                        allOK = false
                        e.error = "SSH 执行失败"
                    }
                    cur.entries[a] = e
                }
                self.vmStates[vmName] = cur
                self.recomputeUpdateFlags()
                self.onChange?()
                completion(allOK, okCount)
            }
        }
    }

    private func runCheckScript(vmName: String, config: String, agents: [String], fetchRemote: Bool,
                                completion: @escaping ([String: (installed: Bool, current: String, error: String)], [String: String], String?) -> Void) {
        let input: [String: Any] = ["agents": agents, "fetchRemote": fetchRemote]
        guard let data = try? JSONSerialization.data(withJSONObject: input) else {
            completion([:], [:], "参数编码失败")
            return
        }
        let script = "import json, base64\npayload = json.loads(base64.b64decode('" + data.base64EncodedString() + "'))\n" + Self.checkScript

        DispatchQueue.global(qos: .utility).async {
            let proc = Process(), out = Pipe(), stdin = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = Self.sshControlArgs(config: config, timeout: 6) + ["lima-" + vmName, "python3 -"]
            proc.standardOutput = out
            proc.standardError = out
            proc.standardInput = stdin
            do {
                try proc.run()
                try stdin.fileHandleForWriting.write(contentsOf: Data(script.utf8))
                try stdin.fileHandleForWriting.close()
                let raw = out.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                let text = String(data: raw, encoding: .utf8) ?? ""
                if proc.terminationStatus == 0,
                   let line = text.components(separatedBy: .newlines).last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }),
                   let lineData = line.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                    var localMap: [String: (Bool, String, String)] = [:]
                    if let local = obj["local"] as? [String: [String: Any]] {
                        for (k, v) in local {
                            localMap[k] = (
                                v["installed"] as? Bool ?? false,
                                v["version"] as? String ?? "",
                                v["error"] as? String ?? ""
                            )
                        }
                    }
                    let remoteMap = obj["remote"] as? [String: String] ?? [:]
                    DispatchQueue.main.async { completion(localMap, remoteMap, nil) }
                } else {
                    DispatchQueue.main.async { completion([:], [:], "连接失败") }
                }
            } catch {
                DispatchQueue.main.async { completion([:], [:], error.localizedDescription) }
            }
        }
    }

    // MARK: - Guest Python Scripts

    static let checkScript = #"""
import json, os, platform, re, shutil, subprocess, urllib.request

env_path = os.path.expanduser('~/.local/bin') + ':' + os.path.expanduser('~/.claude/local/bin') + ':' + os.environ.get('PATH', '')
env = dict(os.environ, PATH=env_path)

def extract_ver(txt):
    m = re.search(r'(\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?)', txt or '')
    return m.group(1) if m else ''

def check_local(cmd):
    p = shutil.which(cmd, path=env_path)
    if not p:
        return {'installed': False, 'version': '', 'error': ''}
    try:
        r = subprocess.run([p, '--version'], env=env, capture_output=True, text=True, timeout=8)
        ver = extract_ver(r.stdout + '\n' + r.stderr)
        return {'installed': True, 'version': ver, 'error': '' if ver else '无法解析版本号'}
    except Exception as e:
        return {'installed': True, 'version': '', 'error': str(e)[:100]}

req_agents = [a for a in (payload.get('agents') or []) if a in ('codex', 'agy', 'claude')]
local = {a: check_local(a) for a in req_agents}
remote = {}

if payload.get('fetchRemote'):
    def fetch_text(url, timeout=8):
        req = urllib.request.Request(url, headers={'User-Agent': 'agent-vm/1.0'})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read().decode('utf-8', errors='replace').strip()

    try:
        d = json.loads(fetch_text('https://registry.npmjs.org/@openai/codex/latest'))
        if d.get('version'): remote['codex'] = str(d['version']).strip()
    except Exception:
        pass

    try:
        m = platform.machine().lower()
        arch = 'arm64' if m in ('aarch64', 'arm64') else 'amd64'
        manifest_url = f'https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_{arch}.json'
        d = json.loads(fetch_text(manifest_url))
        if d.get('version'): remote['agy'] = str(d['version']).strip()
    except Exception:
        pass

    try:
        v = fetch_text('https://downloads.claude.ai/claude-code-releases/latest')
        ver = extract_ver(v)
        if ver: remote['claude'] = ver
    except Exception:
        pass

print(json.dumps({'local': local, 'remote': remote}))
"""#

    static let updateScript = #"""
import json, os, re, shutil, subprocess

env_path = os.path.expanduser('~/.local/bin') + ':' + os.path.expanduser('~/.claude/local/bin') + ':' + os.environ.get('PATH', '')
env = dict(os.environ, PATH=env_path)

def extract_ver(txt):
    m = re.search(r'(\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?)', txt or '')
    return m.group(1) if m else ''

def get_ver(cmd):
    p = shutil.which(cmd, path=env_path)
    if not p: return ''
    try:
        r = subprocess.run([p, '--version'], env=env, capture_output=True, text=True, timeout=8)
        return extract_ver(r.stdout + '\n' + r.stderr)
    except Exception:
        return ''

out = {}
for agent in payload.get('agents', []):
    if agent == 'codex':
        cmd = ['sudo', '-E', 'npm', 'i', '-g', '@openai/codex']
    elif agent == 'agy':
        agy = shutil.which('agy', path=env_path)
        cmd = [agy, 'update'] if agy else None
    elif agent == 'claude':
        cl = shutil.which('claude', path=env_path)
        cmd = [cl, 'update'] if cl else None
    else:
        cmd = None

    if not cmd:
        out[agent] = {'ok': False, 'error': '未找到可执行文件'}
        continue
    try:
        r = subprocess.run(cmd, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=480)
        if r.returncode == 0:
            out[agent] = {'ok': True, 'version': get_ver(agent)}
        else:
            msg = (r.stderr or r.stdout or '').strip().splitlines()
            out[agent] = {'ok': False, 'error': (msg[-1] if msg else f'退出码 {r.returncode}')[:140]}
    except Exception as e:
        out[agent] = {'ok': False, 'error': str(e)[:140]}

print(json.dumps(out))
"""#
}
