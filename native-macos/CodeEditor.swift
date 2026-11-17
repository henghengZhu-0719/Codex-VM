import Foundation
import Darwin

struct CodeEditorState {
    var status = "starting"
    var localURL = ""
    var lanURL = ""
    var error = ""
    var url: String { lanURL.isEmpty ? localURL : lanURL }
}

// Only the native host owns credentials, SSH configuration and generated URLs.
@MainActor final class CodeEditorManager {
    var onChange: (([String: CodeEditorState]) -> Void)?
    private(set) var states: [String: CodeEditorState] = [:]
    private var tunnels: [String: Process] = [:]
    private var preparing: Set<String> = []
    private var generations: [String: UUID] = [:]
    private var retryAfter: [String: Date] = [:]
    private var addresses: [String: String] = [:]

    static func lanAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var candidates: [(String, String)] = []
        var entry = head
        while let pointer = entry {
            defer { entry = pointer.pointee.ifa_next }
            let item = pointer.pointee
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  item.ifa_flags & UInt32(IFF_UP) != 0,
                  item.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: item.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("eth") || name.hasPrefix("wlan") else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer,
                              socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: buffer)
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4,
                  parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) ||
                    (parts[0] == 192 && parts[1] == 168) else { continue }
            candidates.append((name, ip))
        }
        return candidates.sorted { $0.0 < $1.0 }.first?.1
    }

    func retain(_ names: Set<String>) {
        for name in Array(states.keys) where !names.contains(name) { stop(name) }
    }

    func stop(_ name: String) {
        generations.removeValue(forKey: name)
        preparing.remove(name)
        if let process = tunnels.removeValue(forKey: name), process.isRunning { process.terminate() }
        states.removeValue(forKey: name)
        addresses.removeValue(forKey: name)
        retryAfter.removeValue(forKey: name)
        onChange?(states)
    }

    func stopAll() { for name in Array(states.keys) { stop(name) } }

    func ensure(name: String, config: String, directory: String, retry: Bool = false) {
        let address = Self.lanAddress() ?? ""
        if !preparing.contains(name), addresses[name] != nil, addresses[name] != address { stop(name) }
        guard !preparing.contains(name) else { return }
        if !retry, let state = states[name], state.status == "ready",
           let generation = generations[name], let port = URL(string: state.url)?.port {
            check(name: name, port: port, address: address, url: state.url, generation: generation, attempts: 2)
            return
        }
        if !retry, let next = retryAfter[name], next > Date() { return }
        let generation = UUID()
        generations[name] = generation
        addresses[name] = address
        preparing.insert(name)
        states[name] = CodeEditorState()
        onChange?(states)
        let input: [String: Any] = ["directory": directory, "name": name, "password": "Zhuyq020110"]
        guard let data = try? JSONSerialization.data(withJSONObject: input) else { return }
        let script = "import json, base64\nsettings = json.loads(base64.b64decode('" + data.base64EncodedString() + "'))\n" + Self.prepareScript
        DispatchQueue.global(qos: .utility).async {
            let process = Process(), output = Pipe(), stdin = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-F", config, "-o", "ConnectTimeout=8", "-o", "ForwardAgent=no",
                                 "-o", "ForwardX11=no", "lima-" + name, "python3 -"]
            process.standardOutput = output
            process.standardError = output
            process.standardInput = stdin
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 40, execute: timeout)
                try stdin.fileHandleForWriting.write(contentsOf: Data(script.utf8))
                try stdin.fileHandleForWriting.close()
                let result = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeout.cancel()
                let decoded = try? JSONSerialization.jsonObject(with: result) as? [String: Any]
                let port = decoded?["port"] as? Int
                let error = decoded?["error"] as? String ?? "无法启动 Web Code，请检查虚拟机连接。"
                DispatchQueue.main.async {
                    guard self.generations[name] == generation else { return }
                    guard process.terminationStatus == 0, let port, (1024...65535).contains(port) else {
                        self.failed(name, error)
                        return
                    }
                    self.forward(name: name, config: config, port: port, address: address, generation: generation)
                }
            } catch {
                timeout.cancel()
                if process.isRunning { process.terminate() }
                DispatchQueue.main.async {
                    if self.generations[name] == generation { self.failed(name, "无法连接 Web Code。") }
                }
            }
        }
    }

    private func failed(_ name: String, _ error: String) {
        preparing.remove(name)
        if let process = tunnels.removeValue(forKey: name), process.isRunning { process.terminate() }
        states[name] = CodeEditorState(status: "error", error: error)
        retryAfter[name] = Date().addingTimeInterval(60)
        onChange?(states)
    }

    private func forward(name: String, config: String, port: Int, address: String, generation: UUID) {
        if address.isEmpty {
            // Lima already forwards the guest loopback port to this Mac.
            check(name: name, port: port, address: address, url: "http://127.0.0.1:\(port)/", generation: generation, attempts: 20)
            return
        }
        // A private LAN address, rather than a wildcard, leaves other interfaces closed.
        let bindAddress = address.isEmpty ? "127.0.0.1" : address
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-F", config, "-N", "-T", "-o", "ControlMaster=no", "-o", "ControlPath=none",
                             "-o", "ConnectTimeout=8", "-o", "ExitOnForwardFailure=yes",
                             "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                             "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-L",
                             "\(bindAddress):\(port):127.0.0.1:\(port)", "lima-" + name]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                guard self.generations[name] == generation else { return }
                self.failed(name, "Web Code 连接已断开。")
            }
        }
        do {
            try process.run()
            tunnels[name] = process
            let url = "http://\(bindAddress):\(port)/"
            check(name: name, port: port, address: address, url: url, generation: generation, attempts: 20)
        } catch { failed(name, "无法建立 Web Code 连接。") }
    }

    private func check(name: String, port: Int, address: String, url: String, generation: UUID, attempts: Int) {
        var request = URLRequest(url: URL(string: url + "healthz")!)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, response, _ in
            DispatchQueue.main.async {
                guard self.generations[name] == generation,
                      address.isEmpty || self.tunnels[name]?.isRunning == true else { return }
                if (response as? HTTPURLResponse)?.statusCode == 200,
                   let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   ["alive", "expired"].contains(object["status"] as? String ?? "") {
                    self.preparing.remove(name)
                    self.states[name] = CodeEditorState(status: "ready", localURL: "http://\(name.lowercased()).localhost:\(port)/",
                                                         lanURL: address.isEmpty ? "" : url)
                    self.retryAfter.removeValue(forKey: name)
                    self.onChange?(self.states)
                } else if attempts > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.check(name: name, port: port, address: address, url: url, generation: generation, attempts: attempts - 1)
                    }
                } else { self.failed(name, "Web Code 未能响应，请重试。") }
            }
        }.resume()
    }

    // Sent over SSH stdin. Credentials never appear in process arguments or React data.
    static let prepareScript = #"""
import os, pathlib, socket, subprocess, time, json, signal, shutil, hashlib
try:
    binary = shutil.which('code-server')
    if not binary:
        raise RuntimeError('此虚拟机尚未安装 code-server。')
    directory = settings['directory']
    if not os.path.isdir(directory):
        raise RuntimeError('Web Code 工作目录不存在。')
    config = pathlib.Path.home()/'.config/code-server'/('agent-vm-'+socket.gethostname()+'.yaml')
    config.parent.mkdir(parents=True, exist_ok=True)
    desired = 'auth: password\npassword: '+settings['password']+'\ncert: false\n'
    previous = config.read_text() if config.exists() else ''
    changed = previous != desired
    if changed:
        backup = config.with_suffix('.yaml.before-desktop')
        if previous and not backup.exists():
            backup.write_text(previous)
            backup.chmod(0o600)
        temp = config.with_suffix('.yaml.tmp')
        fd = os.open(temp, os.O_WRONLY|os.O_CREAT|os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as file:
            file.write(desired)
        temp.replace(config)
    running = []
    for proc in pathlib.Path('/proc').iterdir():
        if not proc.name.isdigit(): continue
        try:
            if proc.stat().st_uid != os.getuid(): continue
            args = (proc/'cmdline').read_bytes().decode().split('\0')
            if '--config' not in args or args[args.index('--config')+1] != str(config): continue
            if not any('code-server' in arg for arg in args[:3]): continue
            bind = args[args.index('--bind-addr')+1]
            running.append((int(proc.name), int(bind.rsplit(':',1)[1])))
        except (OSError, ValueError, IndexError, UnicodeError): pass
    if changed:
        for pid, _ in running:
            try: os.kill(pid, signal.SIGTERM)
            except ProcessLookupError: pass
        time.sleep(0.5)
        running = []
    port = running[0][1] if running else None
    if port is None:
        suffix = settings['name'][-4:]
        try: number = int(suffix,16)
        except ValueError: number = int(hashlib.sha256(settings['name'].encode()).hexdigest()[:4],16)
        for candidate in range(20000+number%9991,20010+number%9991):
            with socket.socket() as probe:
                try: probe.bind(('127.0.0.1',candidate))
                except OSError: continue
            port = candidate
            break
        if port is None: raise RuntimeError('没有可用的 Web Code 端口。')
        args = [binary,'--config',str(config),'--bind-addr','127.0.0.1:'+str(port),
                '--cookie-suffix',settings['name'],'--app-name',settings['name'],
                '--disable-telemetry','--disable-update-check','--disable-workspace-trust',
                '--disable-proxy','--disable-getting-started-override',
                '--vscode-option','disable-experiments','--vscode-option','disable-extension=GitHub.copilot-chat',directory]
        environment = dict(os.environ, VSCODE_PROXY_URI='')
        log = config.with_suffix('.log')
        fd = os.open(log,os.O_WRONLY|os.O_CREAT|os.O_APPEND,0o600)
        with os.fdopen(fd,'ab') as output:
            process = subprocess.Popen(args,stdin=subprocess.DEVNULL,stdout=output,stderr=output,
                                       env=environment,start_new_session=True)
    for attempt in range(60):
        try:
            with socket.create_connection(('127.0.0.1',port),timeout=0.3): break
        except OSError: time.sleep(0.25)
    else: raise RuntimeError('Web Code 启动超时。')
    print(json.dumps({'port':port}))
except Exception as error:
    print(json.dumps({'error':str(error)}))
    raise SystemExit(1)
"""#
}
