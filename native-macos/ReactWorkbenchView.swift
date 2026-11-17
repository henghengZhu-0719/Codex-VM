import SwiftUI
import AppKit
import WebKit
import Combine

// Native host bridge. All privileged operations remain on the Swift/Go side.
// This is deliberately not a generic shell or file system bridge.
struct ReactWorkbenchView: NSViewRepresentable {
    @ObservedObject var model: Model

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "agentVM")
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        context.coordinator.attach(web)
        if let root = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") {
            web.loadFileURL(root, allowingReadAccessTo: root.deletingLastPathComponent())
        } else {
            web.loadHTMLString("<html><body style='font:14px -apple-system;padding:32px'>React 资源未打包，请先运行 native-macos/build.sh。</body></html>", baseURL: nil)
        }
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.publish()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let model: Model
        private weak var web: WKWebView?
        private var observation: AnyCancellable?
        private var ready = false
        private let allowedRoot = Bundle.main.resourceURL?.appendingPathComponent("web", isDirectory: true).standardizedFileURL.path ?? ""

        init(model: Model) {
            self.model = model
            super.init()
            observation = model.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
                // Published properties emit before the new value is assigned.
                DispatchQueue.main.async { self?.publish() }
            }
        }

        func attach(_ web: WKWebView) { self.web = web }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Never permit a remote page to load into this privileged bridge.
            let url = navigationAction.request.url
            let local = url?.isFileURL == true &&
                !allowedRoot.isEmpty &&
                (url?.standardizedFileURL.path.hasPrefix(allowedRoot + "/") == true)
            decisionHandler(local || url?.absoluteString == "about:blank" ? .allow : .cancel)
        }

        private func windowData(_ q: CodexWindowQuota?) -> [String: Any]? {
            guard let q else { return nil }
            var d: [String: Any] = ["used_percent": q.usedPercent]
            if let reset = q.resetAfterSeconds { d["reset_after_seconds"] = reset }
            if let at = q.resetAt { d["reset_at"] = at }
            return d
        }

        private func quotaData(_ q: CodexQuotaStatus) -> [String: Any] {
            var d: [String: Any] = ["status": q.status]
            if let plan = q.planType { d["plan_type"] = plan }
            if let err = q.error { d["error"] = err }
            if let w = windowData(q.fiveHour) { d["five_hour"] = w }
            if let w = windowData(q.weekly) { d["weekly"] = w }
            if let at = q.fetchedAt { d["fetchedAt"] = DateFormatter.localizedString(from: at, dateStyle: .none, timeStyle: .short) }
            return d
        }

        private func proxyData(_ p: ProxyStatusResponse) -> [String: Any] {
            var d: [String: Any] = [
                "proxy_mode":p.proxyMode, "managed_enabled":p.managedEnabled,
                "use_proxy":p.useProxy, "custom_proxy_url":p.customProxyUrl,
                "dns_url":p.dnsUrl, "port":p.port,
                "running":p.running, "selected":p.selected, "route":p.safeRoute,
                "core_available":p.coreAvailable,
                "sources":p.safeSources.map { s -> [String: Any] in
                    ["id":s.id,"name":s.name,"updated_at":s.updatedAt,
                     "nodes":s.safeNodes.map { n in ["id":n.id,"name":n.name,"type":n.type] },
                     "error":s.error ?? "", "usage":s.usage ?? "", "remote":s.remote]
                },
                "gates":p.safeGates.map { ["state":$0.state,"dir":$0.dir] }
            ]
            if let probe = p.lastProbe {
                var last: [String: Any] = ["gate_triggered":probe.gateTriggered]
                if let ip = probe.exitIp { last["exit_ip"] = ip }
                if let err = probe.error { last["error"] = err }
                if let err = probe.gateCheckError { last["gate_check_error"] = err }
                if let report = probe.report {
                    last["report"] = ["checks": report.safeChecks.map {
                        ["id":$0.id,"state":$0.state,"evidence":$0.evidence]
                    }]
                }
                d["last_probe"] = last
            }
            return d
        }

        func publish() {
            guard ready, let web else { return }
            let vms = model.machines.map { vm -> [String: Any] in
                let project = model.vmMounts[vm.name]?.first?.location ?? ""
                return [
                    "name":vm.name, "displayName":model.displayName(for: vm),
                    "status":vm.status, "cpus":vm.cpus, "memory":vm.memory, "disk":vm.disk,
                    "projectPath":project, "standalone":project.hasPrefix(NSHomeDirectory() + "/AgentVM-Workspaces/")
                ]
            }
            var usage: [String:[String:Double]] = [:]
            for (name,u) in model.vmUsage {
                usage[name] = ["cpu":u.cpuPercent,"used":u.usedMemoryMB,"total":u.totalMemoryMB]
            }
            var quota: [String:[String:Any]] = [:]
            for (name,q) in model.vmQuotas { quota[name] = quotaData(q) }
            var data: [String:Any] = [
                "vms":vms, "usage":usage, "quotas":quota,
                "busy":model.busy, "proxyBusy":model.proxyBusy,
                "error":model.operationFailed ? model.errorSummary : "",
                "proxyError":model.proxyError, "proxyMessage":model.proxyMessage,
                "buildStarted":model.buildStarted, "buildComplete":model.buildComplete,
                "buildStage":model.buildStage,
                "proxyConnections":model.proxyConnections.map {
                    ["id":$0.id, "host":$0.host, "port":$0.port,
                     "network":$0.network, "upload":$0.upload, "download":$0.download] as [String:Any]
                },
                "proxyUploadTotal":model.proxyUploadTotal, "proxyDownloadTotal":model.proxyDownloadTotal
            ]
            if let p = model.proxyStatus { data["proxy"] = proxyData(p) }
            guard JSONSerialization.isValidJSONObject(data),
                  let bytes = try? JSONSerialization.data(withJSONObject:data),
                  let json = String(data:bytes,encoding:.utf8) else { return }
            web.evaluateJavaScript("window.agentVMReceive && window.agentVMReceive(\(json));", completionHandler: nil)
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.isFileURL == true,
                  message.frameInfo.request.url?.standardizedFileURL.path.hasPrefix(allowedRoot + "/") == true,
                  message.name == "agentVM", let dict = message.body as? [String:Any],
                  let action = dict["action"] as? String else { return }
            let payload = dict["payload"] as? [String:Any] ?? [:]
            DispatchQueue.main.async { [weak self] in self?.handle(action, payload) }
        }

        private func existingVM(_ payload: [String:Any]) -> VM? {
            guard let name = payload["name"] as? String else { return nil }
            return model.machines.first { $0.name == name && $0.name != "base" && $0.name != "base-building" }
        }

        private func handle(_ action: String, _ payload: [String:Any]) {
            switch action {
            case "ready":
                ready = true
                model.refresh()
                model.refreshProxyStatus()
                publish()
            case "refresh":
                model.refresh()
                model.refreshProxyStatus()
            case "refreshQuotas":
                model.pollAllRunningQuotas()
            case "quota":
                if let vm = existingVM(payload) { model.pollQuota(for: vm) }
            case "terminal":
                if let vm = existingVM(payload), vm.status == "Running" { model.terminal(vm) }
            case "resume":
                if let vm = existingVM(payload), let agent = payload["agent"] as? String {
                    model.resumeSession(vm, agent: agent)
                }
            case "start":
                if let vm = existingVM(payload), vm.status == "Stopped", !model.busy { model.start(vm) }
            case "stop":
                if let vm = existingVM(payload), vm.status == "Running", !model.busy { model.stop(vm) }
            case "delete":
                if let vm = existingVM(payload), vm.status != "Running", !model.busy { model.remove(vm) }
            case "create":
                guard !model.busy else { break }
                let cpus = payload["cpus"] as? Int ?? 2
                let memory = payload["memory"] as? Int ?? 4
                let disk = payload["disk"] as? Int ?? 20
                guard (1...16).contains(cpus), (2...64).contains(memory), (10...1024).contains(disk) else { break }
                model.project = ""
                model.newVMName = String((payload["name"] as? String ?? "").prefix(80))
                model.cpus = cpus
                model.memory = memory
                model.disk = disk
                model.includeCodeServer = payload["codeServer"] as? Bool ?? false
                model.rebuildBase = false
                model.setup()
            case "proxyRefresh":
                model.refreshProxyStatus()
            case "proxyConfig":
                guard let mode = payload["proxy_mode"] as? String, ["custom","mihomo"].contains(mode),
                      let enabled = payload["use_proxy"] as? Bool,
                      let managed = payload["managed_enabled"] as? Bool,
                      let custom = payload["custom_proxy_url"] as? String,
                      let dns = payload["dns_url"] as? String,
                      let port = payload["port"] as? Int, (1...65535).contains(port) else { break }
                model.saveProxyConfig(proxyMode:mode,managedEnabled:managed,useProxy:enabled,
                                      customProxyURL:custom,dnsURL:dns,port:port)
            case "proxyImport":
                guard let link = payload["url"] as? String,
                      let url = URL(string:link), url.scheme == "https" else { break }
                model.importProxySource(name:"订阅",url:link,content:"",interval:12,hostDownload:true)
            case "proxyManual":
                guard let name = payload["name"] as? String, !name.isEmpty, name.count <= 100,
                      let type = payload["type"] as? String, ["http","socks5"].contains(type),
                      let server = payload["server"] as? String, !server.isEmpty, server.count <= 253,
                      let port = payload["port"] as? Int, (1...65535).contains(port) else { break }
                model.addManualNode(name:name,type:type,server:server,port:port,
                                    username:payload["username"] as? String ?? "",
                                    password:payload["password"] as? String ?? "",
                                    uuid:"",cipher:"",sni:"",tls:false,skipCertVerify:false)
            case "proxyRoute":
                guard let node = payload["id"] as? String,
                      let proxy = model.proxyStatus,
                      proxy.safeSources.contains(where: { $0.safeNodes.contains(where: { $0.id == node }) }) else { break }
                model.applyProxyRoute(route:[node],port:proxy.port)
            case "proxySourceRefresh":
                if let id = payload["id"] as? String,
                   model.proxyStatus?.safeSources.contains(where: { $0.id == id }) == true {
                    model.refreshSubscription(id:id,hostDownload:true)
                }
            case "proxySourceDelete":
                if let id = payload["id"] as? String,
                   model.proxyStatus?.safeSources.contains(where: { $0.id == id }) == true {
                    model.deleteSource(id:id)
                }
            case "proxyDelay":
                let id = payload["id"] as? String
                model.measureDelay(nodeID:id)
            case "proxyGateClose":
                model.closeGate()
            case "proxyConnections":
                model.refreshConnections()
            case "proxyStop":
                model.stopProxyCore()
            case "proxyProbe":
                model.runGateProbe()
            case "mount":
                if let vm = existingVM(payload), !model.busy {
                    model.addFolder(vm, writable:payload["writable"] as? Bool ?? true)
                }
            case "doctor":
                model.doctor()
            case "openShared":
                let path = NSHomeDirectory() + "/AgentVM-Shared"
                if model.prepareSharedFolder() { NSWorkspace.shared.open(URL(fileURLWithPath:path)) }
            default:
                break
            }
        }
    }
}
