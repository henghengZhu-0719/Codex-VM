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
        private var publishWorkItem: DispatchWorkItem?
        private let allowedRoot = Bundle.main.resourceURL?.appendingPathComponent("web", isDirectory: true).standardizedFileURL.path ?? ""

        init(model: Model) {
            self.model = model
            super.init()
            model.remoteWorkbenchServer.onAction = { [weak self] action, payload in
                self?.handle(action, payload)
            }
            observation = model.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
                // Coalesce rapid updates (e.g. streaming agent events) to keep WebView responsive.
                self?.schedulePublish()
            }
        }

        private func schedulePublish() {
            guard publishWorkItem == nil else { return }
            let item = DispatchWorkItem { [weak self] in
                self?.publishWorkItem = nil
                self?.publish()
            }
            publishWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: item)
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

        private func agentQuotaData(_ q: AgentQuotaResult) -> [String: Any] {
            var d: [String: Any] = ["status": q.status]
            if let plan = q.planType { d["plan_type"] = plan }
            if let err = q.error { d["error"] = err }
            if let wins = q.windows {
                d["windows"] = wins.map { w -> [String: Any] in
                    var wd: [String: Any] = ["label": w.label, "used_percent": w.usedPercent]
                    if let sec = w.resetAfterSeconds { wd["reset_after_seconds"] = sec }
                    if let at = w.resetAt { wd["reset_at"] = at }
                    return wd
                }
            }
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
            let vms = model.machines.map { vm -> [String: Any] in
                let project = model.vmMounts[vm.name]?.first?.location ?? ""
                let guestMounts = (model.vmMounts[vm.name] ?? []).map { m in
                    ["location": m.location, "guestPath": m.guestPath, "writable": m.writable] as [String: Any]
                }
                return [
                    "name":vm.name, "displayName":model.displayName(for: vm),
                    "status":vm.status, "cpus":vm.cpus, "memory":vm.memory, "disk":vm.disk,
                    "projectPath":project, "standalone":project.hasPrefix(NSHomeDirectory() + "/AgentVM-Workspaces/"),
                    "guestMounts":guestMounts
                ]
            }
            var codexPayload = model.chatStore.bridgePayload(
                runningSessions: model.runningSessions,
                runningVMs: Set(model.runningSessionVMs.values)
            )
            codexPayload["stagedAttachments"] = model.stagedAttachments
            codexPayload["gitDiff"] = model.gitDiffState

            if model.remoteWorkbenchEnabled {
                let remoteState: [String: Any] = [
                    "vms": vms,
                    "agents": model.vmAgents,
                    "busy": model.busy,
                    "error": model.operationFailed ? model.errorSummary : "",
                    "codex": codexPayload
                ]
                model.remoteWorkbenchServer.broadcastState(remoteState)
            }
            guard ready, let web else { return }
            var usage: [String:[String:Double]] = [:]
            for (name,u) in model.vmUsage {
                usage[name] = ["cpu":u.cpuPercent,"used":u.usedMemoryMB,"total":u.totalMemoryMB]
            }
            var quota: [String:[String:Any]] = [:]
            for (name,q) in model.vmQuotas { quota[name] = quotaData(q) }
            var agentQuotas: [String: [String: [String: Any]]] = [:]
            for (name, map) in model.vmAgentQuotas {
                agentQuotas[name] = map.mapValues { agentQuotaData($0) }
            }
            var mounts: [String:[[String:Any]]] = [:]
            for (name, entries) in model.managedFolders {
                mounts[name] = entries.map { ["path":$0.path, "mode":$0.mode] }
            }
            var data: [String:Any] = [
                "editors":model.codeEditors.mapValues { editor in
                    ["status":editor.status,"url":editor.url,"localURL":editor.localURL,"lanURL":editor.lanURL,"error":editor.error]
                },
                "browsers":model.linuxBrowsers.mapValues { browser in
                    [
                        "status": browser.status,
                        "stage": browser.stage,
                        "stageMessage": browser.stageMessage,
                        "url": browser.url,
                        "error": browser.error,
                        "checked": browser.checked,
                        "installed": browser.installed,
                        "appRunning": browser.appRunning,
                        "browserPID": browser.browserPID,
                        "browserRSSMB": browser.browserRSSMB,
                        "browserTreeRSSMB": browser.browserTreeRSSMB,
                        "browserProcessCount": browser.browserProcessCount,
                        "browserCPUSeconds": browser.browserCPUSeconds,
                        "cdpAvailable": browser.cdpAvailable,
                        "mcpInstalled": browser.mcpInstalled,
                        "missing": browser.missingComponents,
                        "resolution": browser.resolution,
                        "qualityMode": browser.qualityMode,
                        "autoResize": browser.autoResize,
                        "tabs": browser.tabs,
                        "activeTabId": browser.activeTabId,
                        "activeURL": browser.activeURL,
                        "activeTitle": browser.activeTitle,
                        "devPorts": browser.devPorts,
                        "logs": browser.logs,
                        "installing": browser.installing
                    ] as [String: Any]
                },
                "activeBrowserVM":model.activeBrowserVM,
                "codexDesktops":model.codexDesktops.mapValues { d in
                    [
                        "app": d.app,
                        "status": d.status,
                        "stage": d.stage,
                        "stageMessage": d.stageMessage,
                        "url": d.url,
                        "error": d.error,
                        "checked": d.checked,
                        "installed": d.installed,
                        "appRunning": d.appRunning,
                        "appVersion": d.appVersion,
                        "diskAvailMB": d.diskAvailMB,
                        "missing": d.missingComponents,
                        "resolution": d.resolution,
                        "qualityMode": d.qualityMode,
                        "autoResize": d.autoResize,
                        "logs": d.logs,
                        "installing": d.installing,
                        "installOutput": d.installOutput
                    ] as [String: Any]
                },
                "activeCodexDesktopVM":model.activeCodexDesktopVM,
                "activeCodexDesktopApp":model.activeCodexDesktopApp.rawValue,
                "browserShortcut":model.browserShortcutSignal,
                "requestedPage":model.requestedPage,
                "toasts":model.toasts,
                "vms":vms, "usage":usage, "quotas":quota, "agentQuotas":agentQuotas, "mounts":mounts, "agents":model.vmAgents,
                "vmProxyRoutes":model.vmProxyRoutes,
                "busy":model.busy, "proxyBusy":model.proxyBusy,
                "hostDiskAvailGB":model.hostDiskAvailGB(),
                "error":model.operationFailed ? model.errorSummary : "",
                "proxyError":model.proxyError, "proxyMessage":model.proxyMessage,
                "buildStarted":model.buildStarted, "buildComplete":model.buildComplete,
                "buildStage":model.buildStage,
                "proxyConnections":model.proxyConnections.map {
                    ["id":$0.id, "host":$0.host, "port":$0.port,
                     "network":$0.network, "upload":$0.upload, "download":$0.download] as [String:Any]
                },
                "proxyUploadTotal":model.proxyUploadTotal, "proxyDownloadTotal":model.proxyDownloadTotal,
                "codex":codexPayload,
                "cliMonitor": {
                    let cliMgr = model.cliVersionManager
                    var cliVMs: [String: [String: Any]] = [:]
                    var pendingCount = 0
                    for (vmName, st) in cliMgr.vmStates {
                        var entriesPayload: [String: [String: Any]] = [:]
                        for (agent, e) in st.entries {
                            if e.hasUpdate { pendingCount += 1 }
                            entriesPayload[agent] = [
                                "agent": e.agent,
                                "installed": e.installed,
                                "current": e.current,
                                "latest": e.latest,
                                "hasUpdate": e.hasUpdate,
                                "updating": e.updating,
                                "error": e.error
                            ]
                        }
                        cliVMs[vmName] = [
                            "checking": st.checking,
                            "updating": st.updating,
                            "checkedAt": st.checkedAt.map { Int($0.timeIntervalSince1970 * 1000) } ?? 0,
                            "error": st.error,
                            "entries": entriesPayload
                        ]
                    }
                    return [
                        "autoUpdate": cliMgr.autoUpdate,
                        "checking": cliMgr.checkingAll,
                        "updating": cliMgr.updatingAll,
                        "latest": cliMgr.latestVersions,
                        "latestCheckedAt": cliMgr.latestCheckedAt.map { Int($0.timeIntervalSince1970 * 1000) } ?? 0,
                        "pendingCount": pendingCount,
                        "vms": cliVMs
                    ] as [String: Any]
                }(),
                "remoteWorkbench":[
                    "enabled":model.remoteWorkbenchEnabled,
                    "port":model.remoteWorkbenchPort,
                    "token":model.remoteWorkbenchToken,
                    "urls":model.remoteWorkbenchEnabled ? model.remoteWorkbenchURLs() : [],
                    "error":model.remoteWorkbenchError
                ]
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
            case "codeOpen":
                if let vm = existingVM(payload) { model.openCodeEditor(vm) }
            case "codeRetry":
                if let vm = existingVM(payload) { model.prepareCodeEditor(vm, retry: true) }
            case "browserCheck":
                if let vm = existingVM(payload) {
                    model.checkLinuxBrowser(vm)
                }
            case "browserOpen":
                if let vm = existingVM(payload) {
                    model.activeBrowserVM = vm.name
                    let w = (payload["width"] as? NSNumber)?.intValue ?? 1280
                    let h = (payload["height"] as? NSNumber)?.intValue ?? 800
                    let qMode = payload["qualityMode"] as? String
                    model.openLinuxBrowser(vm, width: w, height: h, qualityMode: qMode)
                }
            case "browserStopService":
                if let vm = existingVM(payload) {
                    model.stopLinuxBrowser(vm)
                }
            case "browserRestart":
                if let vm = existingVM(payload) {
                    let w = (payload["width"] as? NSNumber)?.intValue ?? 1280
                    let h = (payload["height"] as? NSNumber)?.intValue ?? 800
                    model.restartLinuxBrowser(vm, width: w, height: h)
                }
            case "browserSetAutoResize":
                if let vm = existingVM(payload), let enabled = payload["enabled"] as? Bool {
                    model.setBrowserAutoResize(vm, enabled: enabled)
                }
            case "browserSelect":
                if let vm = existingVM(payload) {
                    model.activeBrowserVM = vm.name
                    model.browserInspect(vm)
                }
            case "browserReload":
                model.browserReloadToken += 1
            case "browserResize":
                if let vm = existingVM(payload) {
                    let w = (payload["width"] as? NSNumber)?.intValue ?? 1280
                    let h = (payload["height"] as? NSNumber)?.intValue ?? 800
                    model.resizeLinuxBrowser(vm, width: w, height: h)
                }
            case "browserSetQuality":
                if let vm = existingVM(payload), let mode = payload["qualityMode"] as? String {
                    model.setBrowserQuality(vm, qualityMode: mode)
                }
            case "browserRegisterMCP":
                if let vm = existingVM(payload) {
                    model.registerBrowserMCP(vm)
                }
            case "browserInstallMCP":
                if let vm = existingVM(payload) {
                    model.installBrowserMCP(vm)
                }
            case "browserInspect":
                if let vm = existingVM(payload) {
                    model.checkLinuxBrowser(vm)
                    model.browserInspect(vm)
                }
            case "browserNavigate":
                if let vm = existingVM(payload), let url = payload["url"] as? String {
                    model.browserNavigate(vm, url: url, tabId: payload["tabId"] as? String ?? "")
                }
            case "browserBack":
                if let vm = existingVM(payload) {
                    model.browserBack(vm, tabId: payload["tabId"] as? String ?? "")
                }
            case "browserForward":
                if let vm = existingVM(payload) {
                    model.browserForward(vm, tabId: payload["tabId"] as? String ?? "")
                }
            case "browserPageReload":
                if let vm = existingVM(payload) {
                    model.browserPageReload(vm, tabId: payload["tabId"] as? String ?? "")
                }
            case "browserNewTab":
                if let vm = existingVM(payload) {
                    model.browserNewTab(vm, url: payload["url"] as? String ?? "about:blank")
                }
            case "browserActivateTab":
                if let vm = existingVM(payload), let tabId = payload["tabId"] as? String {
                    model.browserActivateTab(vm, tabId: tabId)
                }
            case "browserCloseTab":
                if let vm = existingVM(payload), let tabId = payload["tabId"] as? String {
                    model.browserCloseTab(vm, tabId: tabId)
                }
            case "browserInsertText":
                if let vm = existingVM(payload), let text = payload["text"] as? String {
                    model.browserInsertText(vm, text: text, tabId: payload["tabId"] as? String ?? "")
                }
            case "browserScreenshotToChat":
                if let vm = existingVM(payload) {
                    let jump = payload["jump"] as? Bool ?? true
                    model.browserScreenshotToChat(vm, tabId: payload["tabId"] as? String ?? "", jumpToChat: jump)
                }
            case "browserInstallComponents":
                if let vm = existingVM(payload) {
                    model.browserInstallComponents(vm)
                }
            case "browserFetchLogs":
                if let vm = existingVM(payload) {
                    model.browserFetchLogs(vm)
                }
            case "browserOpenDownloads":
                model.browserOpenDownloads()
            case "browserSlot":
                let visible = payload["visible"] as? Bool ?? false
                let x = (payload["x"] as? NSNumber)?.doubleValue ?? 0
                let y = (payload["y"] as? NSNumber)?.doubleValue ?? 0
                let w = (payload["width"] as? NSNumber)?.doubleValue ?? 0
                let h = (payload["height"] as? NSNumber)?.doubleValue ?? 0
                model.browserSlotVisible = visible
                model.browserSlot = CGRect(x: x, y: y, width: w, height: h)
            case "codexDesktopCheck":
                if let vm = existingVM(payload) {
                    let app = DesktopAppKind.from(payload["app"] as? String)
                    model.checkCodexDesktop(vm, app: app)
                }
            case "codexDesktopOpen":
                if let vm = existingVM(payload) {
                    let app = DesktopAppKind.from(payload["app"] as? String)
                    model.activeCodexDesktopVM = vm.name
                    model.activeCodexDesktopApp = app
                    let w = (payload["width"] as? NSNumber)?.intValue ?? 1280
                    let h = (payload["height"] as? NSNumber)?.intValue ?? 800
                    let qMode = payload["qualityMode"] as? String
                    model.openCodexDesktop(vm, app: app, width: w, height: h, qualityMode: qMode)
                }
            case "codexDesktopSelect":
                if let vm = existingVM(payload) {
                    let app = DesktopAppKind.from(payload["app"] as? String)
                    model.activeCodexDesktopVM = vm.name
                    model.activeCodexDesktopApp = app
                }
            case "codexDesktopReload":
                model.codexDesktopReloadToken += 1
            case "codexDesktopResize":
                if let vm = existingVM(payload) {
                    let app = DesktopAppKind.from(payload["app"] as? String)
                    let w = (payload["width"] as? NSNumber)?.intValue ?? 1280
                    let h = (payload["height"] as? NSNumber)?.intValue ?? 800
                    model.resizeCodexDesktop(vm, app: app, width: w, height: h)
                }
            case "codexDesktopSetQuality":
                if let vm = existingVM(payload), let mode = payload["qualityMode"] as? String {
                    let app = DesktopAppKind.from(payload["app"] as? String)
                    model.setCodexDesktopQuality(vm, app: app, qualityMode: mode)
                }
            case "codexDesktopInstall":
                if let vm = existingVM(payload) {
                    let app = DesktopAppKind.from(payload["app"] as? String)
                    let w = (payload["width"] as? NSNumber)?.intValue ?? 1280
                    let h = (payload["height"] as? NSNumber)?.intValue ?? 800
                    model.installCodexDesktop(vm, app: app, width: w, height: h)
                }
            case "codexDesktopRestart":
                if let vm = existingVM(payload) {
                    let app = DesktopAppKind.from(payload["app"] as? String)
                    let w = (payload["width"] as? NSNumber)?.intValue ?? 1280
                    let h = (payload["height"] as? NSNumber)?.intValue ?? 800
                    model.restartCodexDesktop(vm, app: app, width: w, height: h)
                }
            case "codexDesktopSendText":
                if let vm = existingVM(payload), let text = payload["text"] as? String {
                    let app = DesktopAppKind.from(payload["app"] as? String)
                    model.codexDesktopSendText(vm, app: app, text: text)
                }
            case "codexDesktopFetchLogs":
                if let vm = existingVM(payload) {
                    let app = DesktopAppKind.from(payload["app"] as? String)
                    model.codexDesktopFetchLogs(vm, app: app)
                }
            case "codexDesktopSlot":
                let visible = payload["visible"] as? Bool ?? false
                let x = (payload["x"] as? NSNumber)?.doubleValue ?? 0
                let y = (payload["y"] as? NSNumber)?.doubleValue ?? 0
                let w = (payload["width"] as? NSNumber)?.doubleValue ?? 0
                let h = (payload["height"] as? NSNumber)?.doubleValue ?? 0
                model.codexDesktopSlotVisible = visible
                model.codexDesktopSlot = CGRect(x: x, y: y, width: w, height: h)
            case "resume":
                if let vm = existingVM(payload), let agent = payload["agent"] as? String {
                    model.resumeSession(vm, agent: agent)
                }
            case "start":
                if let vm = existingVM(payload), vm.status == "Stopped", !model.busy { model.start(vm) }
            case "resizeDisk":
                if let vm = existingVM(payload), let disk = payload["disk"] as? Int, !model.busy {
                    model.resizeDisk(vm, diskGiB: disk)
                }
            case "stop":
                if let vm = existingVM(payload), vm.status == "Running", !model.busy { model.stop(vm) }
            case "delete":
                if let vm = existingVM(payload), !model.busy { model.remove(vm) }
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
                model.includeCodex = payload["codex"] as? Bool ?? true
                model.includeClaude = payload["claude"] as? Bool ?? false
                model.includeBrowser = (payload["claude"] as? Bool ?? false) && (payload["browser"] as? Bool ?? false)
                model.includeAgy = payload["agy"] as? Bool ?? false
                model.includeCodeServer = payload["codeServer"] as? Bool ?? true
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
            case "removeMount":
                guard !model.busy, let vm = existingVM(payload),
                      let path = payload["path"] as? String,
                      let mode = payload["mode"] as? String, ["ro","rw"].contains(mode),
                      model.managedFolders[vm.name]?.contains(where: { $0.path == path && $0.mode == mode }) == true else { break }
                model.changeFolder(vm, action:"remove", path:path, mode:mode)
            case "rename":
                guard let vm = existingVM(payload),
                      let label = payload["label"] as? String, label.count <= 80,
                      !label.unicodeScalars.contains(where: { $0.value < 0x20 }) else { break }
                model.renameVM(vm, to:label)
            case "vmProxyRoute":
                guard let vm = existingVM(payload) else { break }
                let nodeId = payload["nodeId"] as? String ?? ""
                if nodeId.isEmpty {
                    model.setVMProxyRoute(vm, nodeId: "")
                } else if let proxy = model.proxyStatus,
                          proxy.safeSources.contains(where: { $0.safeNodes.contains(where: { $0.id == nodeId }) }) {
                    model.setVMProxyRoute(vm, nodeId: nodeId)
                }
            case "codexRun":
                guard let vmName = payload["vm"] as? String,
                      let vm = model.machines.first(where: { $0.name == vmName && $0.status == "Running" }),
                      let prompt = payload["prompt"] as? String,
                      !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
                let sessionId = payload["sessionId"] as? String
                let workdir = payload["workdir"] as? String ?? "/mnt/agent-vm-shared"
                let mode = payload["mode"] as? String ?? "full-auto"
                let agent = payload["agent"] as? String ?? "codex"
                let resume = payload["resume"] as? Bool ?? true
                model.runCodex(vm: vm, sessionId: sessionId, workdir: workdir, prompt: prompt, mode: mode, agent: agent, resume: resume)
            case "codexEditResend":
                guard let vmName = payload["vm"] as? String,
                      let vm = model.machines.first(where: { $0.name == vmName && $0.status == "Running" }),
                      let sessionId = payload["sessionId"] as? String,
                      let msgId = payload["messageId"] as? String,
                      let prompt = payload["prompt"] as? String,
                      !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
                let workdir = payload["workdir"] as? String ?? "/mnt/agent-vm-shared"
                let mode = payload["mode"] as? String ?? "full-auto"
                let agent = payload["agent"] as? String ?? "codex"
                model.runCodex(vm: vm, sessionId: sessionId, workdir: workdir, prompt: prompt, mode: mode, agent: agent, resume: true, truncateFromMsgId: msgId)
            case "codexStop":
                model.stopCodex(sessionId: payload["sessionId"] as? String, vmName: payload["vm"] as? String)
            case "codexClear":
                if let vmName = payload["vm"] as? String {
                    model.clearCodexSession(vmName: vmName, sessionId: payload["sessionId"] as? String)
                }
            case "codexSelectSession":
                if let vmName = payload["vm"] as? String, let sid = payload["sessionId"] as? String {
                    model.selectChatSession(vmName: vmName, sessionId: sid)
                }
            case "codexNewSession":
                if let vmName = payload["vm"] as? String {
                    let agent = payload["agent"] as? String ?? "codex"
                    let workdir = payload["workdir"] as? String ?? "/mnt/agent-vm-shared"
                    let mode = payload["mode"] as? String ?? "full-auto"
                    model.newChatSession(vmName: vmName, agent: agent, workdir: workdir, mode: mode)
                }
            case "codexRenameSession":
                if let vmName = payload["vm"] as? String,
                   let sid = payload["sessionId"] as? String,
                   let title = payload["title"] as? String {
                    model.renameChatSession(vmName: vmName, sessionId: sid, title: title)
                }
            case "codexDeleteSession":
                if let vmName = payload["vm"] as? String, let sid = payload["sessionId"] as? String {
                    model.deleteChatSession(vmName: vmName, sessionId: sid)
                }
            case "codexSetSessionConfig":
                if let vmName = payload["vm"] as? String, let sid = payload["sessionId"] as? String {
                    model.updateChatSessionConfig(
                        vmName: vmName,
                        sessionId: sid,
                        workdir: payload["workdir"] as? String,
                        mode: payload["mode"] as? String,
                        agent: payload["agent"] as? String
                    )
                }
            case "codexGitDiff":
                if let vmName = payload["vm"] as? String,
                   let vm = model.machines.first(where: { $0.name == vmName && $0.status == "Running" }) {
                    let workdir = payload["workdir"] as? String ?? "/mnt/agent-vm-shared"
                    let file = payload["file"] as? String
                    model.fetchGitDiff(vm: vm, workdir: workdir, filePath: file)
                }
            case "codexAttachFile":
                if let vmName = payload["vm"] as? String {
                    model.stageChatAttachment(vmName: vmName)
                }
            case "codexRemoveAttachment":
                if let vmName = payload["vm"] as? String, let id = payload["id"] as? String {
                    model.removeChatAttachment(vmName: vmName, id: id)
                }
            case "toastDismiss":
                if let id = payload["id"] as? String {
                    model.dismissToast(id: id)
                }
            case "codexTerminal":
                if let vmName = payload["vm"] as? String,
                   let vm = model.machines.first(where: { $0.name == vmName && $0.status == "Running" }) {
                    let agent = payload["agent"] as? String ?? "codex"
                    model.resumeSession(vm, agent: agent)
                }
            case "doctor":
                model.doctor()
            case "openShared":
                let path = NSHomeDirectory() + "/AgentVM-Shared"
                if model.prepareSharedFolder() { NSWorkspace.shared.open(URL(fileURLWithPath:path)) }
            case "remoteWorkbenchToggle":
                let enabled = payload["enabled"] as? Bool ?? false
                model.toggleRemoteWorkbench(enabled)
            case "remoteWorkbenchRegenToken":
                model.regenerateRemoteWorkbenchToken()
            case "remoteWorkbenchSetPort":
                if let port = (payload["port"] as? NSNumber)?.intValue {
                    model.setRemoteWorkbenchPort(port)
                }
            case "cliCheck":
                let trigger = payload["autoUpdate"] as? Bool ?? model.cliVersionManager.autoUpdate
                model.checkCLIVersions(triggerAutoUpdate: trigger)
            case "cliUpdateAll":
                model.updateAllCLIs()
            case "cliUpdateOne":
                if let vmName = payload["vm"] as? String,
                   let agent = payload["agent"] as? String,
                   let vm = model.machines.first(where: { $0.name == vmName && $0.status == "Running" }) {
                    model.updateSingleCLI(vm, agent: agent)
                }
            case "cliSetAutoUpdate":
                let enabled = payload["enabled"] as? Bool ?? true
                model.setCLIAutoUpdate(enabled)
            default:
                break
            }
        }
    }
}
