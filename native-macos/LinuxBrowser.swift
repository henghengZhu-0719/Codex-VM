import Foundation
import AppKit
import SwiftUI
import WebKit

struct LinuxBrowserState {
    var status = "idle"
    var stage = "idle"
    var stageMessage = ""
    var url = ""
    var port = 0
    var error = ""
    var checked = false
    var installed = false
    var appRunning = false
    var browserPID = 0
    var browserRSSMB = 0
    var browserTreeRSSMB = 0
    var browserProcessCount = 0
    var browserCPUSeconds = 0.0
    var cdpAvailable = false
    var mcpInstalled = false
    var missingComponents: [String] = []
    var resolution = "1280x800"
    var qualityMode = "balanced"
    var autoResize = true
    var tabs: [[String: Any]] = []
    var activeTabId = ""
    var activeURL = ""
    var activeTitle = ""
    var devPorts: [Int] = []
    var logs = ""
    var installing = false
}

// WKWebView dedicated to rendering the VM's local noVNC canvas.
// Only allows loopback URLs and bridges clipboard + browser shortcuts for those loopback pages.
final class LinuxBrowserWKWebView: WKWebView {
    var onCommandShortcut: ((String) -> Void)?
    var onBrowserShortcut: ((String) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command,
           let window = self.window,
           let responder = window.firstResponder as? NSView,
           responder === self || responder.isDescendant(of: self),
           let key = event.charactersIgnoringModifiers?.lowercased() {
            if ["c", "v", "x", "a"].contains(key) {
                onCommandShortcut?(key)
                return true
            }
            switch key {
            case "l": onBrowserShortcut?("focusAddress"); return true
            case "r": onBrowserShortcut?("reload"); return true
            case "t": onBrowserShortcut?("newTab"); return true
            case "[": onBrowserShortcut?("back"); return true
            case "]": onBrowserShortcut?("forward"); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct LinuxBrowserWebView: NSViewRepresentable {
    let url: URL
    let reloadToken: Int
    var onBrowserShortcut: ((String) -> Void)? = nil
    var onPasteText: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LinuxBrowserWKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.clipboardBridgeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.add(context.coordinator, name: "clipboard")
        controller.add(context.coordinator, name: "imeCommit")
        config.userContentController = controller

        let web = LinuxBrowserWKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        context.coordinator.webView = web
        context.coordinator.onBrowserShortcut = onBrowserShortcut
        context.coordinator.onPasteText = onPasteText
        web.onCommandShortcut = { [weak coordinator = context.coordinator] key in
            coordinator?.handleCommandShortcut(key)
        }
        web.onBrowserShortcut = { [weak coordinator = context.coordinator] action in
            coordinator?.onBrowserShortcut?(action)
        }
        context.coordinator.startClipboardSync()
        context.coordinator.lastLoadedURL = url
        context.coordinator.lastReloadToken = reloadToken
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ web: LinuxBrowserWKWebView, context: Context) {
        context.coordinator.onBrowserShortcut = onBrowserShortcut
        context.coordinator.onPasteText = onPasteText
        if context.coordinator.lastLoadedURL != url || context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastLoadedURL = url
            context.coordinator.lastReloadToken = reloadToken
            web.load(URLRequest(url: url))
        }
    }

    static func dismantleNSView(_ web: LinuxBrowserWKWebView, coordinator: Coordinator) {
        coordinator.stopClipboardSync()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "clipboard")
        web.configuration.userContentController.removeScriptMessageHandler(forName: "imeCommit")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: LinuxBrowserWKWebView?
        var onBrowserShortcut: ((String) -> Void)?
        var onPasteText: ((String) -> Void)?
        var lastLoadedURL: URL?
        var lastReloadToken = 0
        private var clipboardTimer: Timer?
        private var lastPasteboardChangeCount = NSPasteboard.general.changeCount
        private var lastSyncedToVM: String?

        private static func isLoopbackHost(_ host: String?) -> Bool {
            let h = host?.lowercased() ?? ""
            return h == "127.0.0.1" || h == "localhost" || h.hasSuffix(".localhost")
        }

        func startClipboardSync() {
            stopClipboardSync()
            lastPasteboardChangeCount = NSPasteboard.general.changeCount
            clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard NSApp.isActive, self?.webView?.window?.isVisible == true else { return }
                    self?.syncHostClipboardToVMIfChanged()
                }
            }
        }

        func stopClipboardSync() {
            clipboardTimer?.invalidate()
            clipboardTimer = nil
        }

        @MainActor
        @discardableResult
        private func syncHostClipboardToVMIfChanged(force: Bool = false) -> Bool {
            guard let webView, webView.window != nil else { return false }
            let pb = NSPasteboard.general
            let currentCount = pb.changeCount
            guard force || currentCount != lastPasteboardChangeCount else { return false }
            lastPasteboardChangeCount = currentCount
            guard let text = pb.string(forType: .string), !text.isEmpty else { return false }
            if !force && text == lastSyncedToVM { return false }
            lastSyncedToVM = text
            pushTextToVM(text)
            return true
        }

        @MainActor
        private func pushTextToVM(_ text: String) {
            guard let webView,
                  let data = try? JSONSerialization.data(withJSONObject: [text]),
                  let jsonArray = String(data: data, encoding: .utf8) else { return }
            let js = "window.__agentVMSetClipboard && window.__agentVMSetClipboard(\(jsonArray)[0]);"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        @MainActor
        func handleCommandShortcut(_ key: String) {
            guard let webView else { return }
            switch key {
            case "c":
                sendCtrlKey(key: "c", code: "KeyC", keyCode: 67)
            case "x":
                sendCtrlKey(key: "x", code: "KeyX", keyCode: 88)
            case "a":
                sendCtrlKey(key: "a", code: "KeyA", keyCode: 65)
            case "v":
                if let onPasteText,
                   let text = NSPasteboard.general.string(forType: .string),
                   !text.isEmpty,
                   text.unicodeScalars.contains(where: { $0.value > 0x7f }) {
                    onPasteText(text)
                    return
                }
                let pushed = syncHostClipboardToVMIfChanged()
                let delay: DispatchTimeInterval = pushed ? .milliseconds(60) : .milliseconds(0)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.webView === webView else { return }
                    self.sendCtrlKey(key: "v", code: "KeyV", keyCode: 86)
                }
            default:
                break
            }
        }

        @MainActor
        private func sendCtrlKey(key: String, code: String, keyCode: Int) {
            let js = "window.__agentVMSendCtrlKey && window.__agentVMSendCtrlKey('\(key)', '\(code)', \(keyCode));"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  Self.isLoopbackHost(message.frameInfo.request.url?.host),
                  let text = message.body as? String else { return }
            if message.name == "imeCommit" {
                if !text.isEmpty {
                    onPasteText?(text)
                }
                return
            }
            guard message.name == "clipboard" else { return }
            let pb = NSPasteboard.general
            if pb.string(forType: .string) == text {
                lastSyncedToVM = text
                return
            }
            pb.clearContents()
            pb.setString(text, forType: .string)
            lastPasteboardChangeCount = pb.changeCount
            lastSyncedToVM = text
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(Self.isLoopbackHost(navigationAction.request.url?.host) ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                Task { @MainActor in
                    self?.syncHostClipboardToVMIfChanged(force: true)
                }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            webView.loadHTMLString("<html><body style='font:14px -apple-system;padding:24px;color:#c34c4c'>加载失败：\(error.localizedDescription)</body></html>", baseURL: nil)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            webView.loadHTMLString("<html><body style='font:14px -apple-system;padding:24px;color:#c34c4c'>加载失败：\(error.localizedDescription)</body></html>", baseURL: nil)
        }
    }

    private static let clipboardBridgeScript = #"""
    (function() {
      if (window.__agentVMClipboardInstalled) return;
      window.__agentVMClipboardInstalled = true;
      var internalUpdating = false;

      function hookClipboardTextarea() {
        var el = document.getElementById('noVNC_clipboard_text');
        if (!el || el.__agentVMHooked) return !!el;
        var desc = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value');
        if (!desc || !desc.get || !desc.set) return false;
        el.__agentVMHooked = true;
        Object.defineProperty(el, 'value', {
          configurable: true,
          get: function() { return desc.get.call(this); },
          set: function(v) {
            desc.set.call(this, v);
            if (!internalUpdating && typeof v === 'string') {
              try {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.clipboard) {
                  window.webkit.messageHandlers.clipboard.postMessage(v);
                }
              } catch (e) {}
            }
          }
        });
        return true;
      }

      if (!hookClipboardTextarea()) {
        var observer = new MutationObserver(function() {
          if (hookClipboardTextarea()) observer.disconnect();
        });
        observer.observe(document.documentElement || document, { childList: true, subtree: true });
      }

      window.__agentVMSetClipboard = function(text) {
        var el = document.getElementById('noVNC_clipboard_text');
        if (!el) return false;
        internalUpdating = true;
        try {
          el.value = text;
          el.dispatchEvent(new Event('change', { bubbles: true }));
        } finally {
          internalUpdating = false;
        }
        return true;
      };

      window.__agentVMSendCtrlKey = function(key, code, keyCode) {
        var active = document.activeElement;
        if (active && active.id !== 'avm_ime_proxy' && (active.tagName === 'INPUT' || active.tagName === 'TEXTAREA')) {
          return false;
        }
        var target = document.querySelector('#noVNC_container canvas') || active || document;
        var base = { bubbles: true, cancelable: true, view: window };
        target.dispatchEvent(new KeyboardEvent('keydown', Object.assign({}, base, {
          key: 'Control', code: 'ControlLeft', keyCode: 17, which: 17, ctrlKey: true
        })));
        target.dispatchEvent(new KeyboardEvent('keydown', Object.assign({}, base, {
          key: key, code: code, keyCode: keyCode, which: keyCode, ctrlKey: true
        })));
        target.dispatchEvent(new KeyboardEvent('keyup', Object.assign({}, base, {
          key: key, code: code, keyCode: keyCode, which: keyCode, ctrlKey: true
        })));
        target.dispatchEvent(new KeyboardEvent('keyup', Object.assign({}, base, {
          key: 'Control', code: 'ControlLeft', keyCode: 17, which: 17, ctrlKey: false
        })));
        return true;
      };

      // Direct macOS IME proxy over noVNC canvas so Chinese Pinyin works directly in the guest window.
      (function installIMEProxy() {
        var proxy = null;
        var composing = false;
        var pendingKey = null;
        var swallowKeyupCode = null;
        var justEndedCompositionAt = 0;
        var lastX = 160, lastY = 160;

        function snapshotKey(e) {
          return {
            key: e.key,
            code: e.code,
            keyCode: e.keyCode,
            which: e.which || e.keyCode,
            location: e.location || 0,
            ctrlKey: !!e.ctrlKey,
            shiftKey: !!e.shiftKey,
            altKey: !!e.altKey,
            metaKey: !!e.metaKey,
            repeat: !!e.repeat,
            capsLock: e.getModifierState ? e.getModifierState('CapsLock') : false
          };
        }

        function ensureProxy() {
          if (proxy && document.body && document.body.contains(proxy)) return proxy;
          if (!document.body) return null;
          proxy = document.createElement('textarea');
          proxy.id = 'avm_ime_proxy';
          proxy.setAttribute('autocapitalize', 'off');
          proxy.setAttribute('autocomplete', 'off');
          proxy.setAttribute('autocorrect', 'off');
          proxy.setAttribute('spellcheck', 'false');
          proxy.style.cssText = 'position:fixed;left:160px;top:160px;width:48px;height:22px;font-size:16px;line-height:22px;opacity:0.001;pointer-events:none;resize:none;border:0;padding:0;margin:0;outline:none;overflow:hidden;background:transparent;color:transparent;caret-color:transparent;z-index:9999;';
          document.body.appendChild(proxy);

          function commitText(txt) {
            if (!txt) return;
            try {
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.imeCommit) {
                window.webkit.messageHandlers.imeCommit.postMessage(txt);
              }
            } catch (err) {}
          }

          function dispatchKey(type, k) {
            var canvas = document.querySelector('#noVNC_container canvas');
            if (!canvas || !k) return;
            var evt = new KeyboardEvent(type, {
              key: k.key,
              code: k.code,
              keyCode: k.keyCode,
              which: k.which || k.keyCode,
              location: k.location || 0,
              ctrlKey: !!k.ctrlKey,
              shiftKey: !!k.shiftKey,
              altKey: !!k.altKey,
              metaKey: !!k.metaKey,
              repeat: !!k.repeat,
              modifierCapsLock: !!k.capsLock,
              bubbles: true,
              cancelable: true,
              view: window
            });
            canvas.dispatchEvent(evt);
          }

          proxy.addEventListener('compositionstart', function() {
            composing = true;
            pendingKey = null;
          });
          proxy.addEventListener('compositionend', function(e) {
            composing = false;
            pendingKey = null;
            justEndedCompositionAt = Date.now();
            var txt = (e && e.data) || proxy.value || '';
            proxy.value = '';
            commitText(txt);
          });
          proxy.addEventListener('input', function(e) {
            if (composing || (e && (e.inputType === 'insertFromComposition' || e.isComposing))) return;
            var txt = proxy.value || (e && e.data) || '';
            proxy.value = '';
            if (!txt) {
              pendingKey = null;
              return;
            }
            if (pendingKey && !pendingKey.ctrlKey && !pendingKey.altKey && txt === pendingKey.key &&
                txt.length === 1 && txt.charCodeAt(0) >= 0x20 && txt.charCodeAt(0) <= 0x7e) {
              swallowKeyupCode = pendingKey.code || null;
              dispatchKey('keydown', pendingKey);
              dispatchKey('keyup', pendingKey);
            } else {
              commitText(txt);
            }
            pendingKey = null;
          });
          proxy.addEventListener('paste', function(e) {
            if (e && e.clipboardData) {
              var txt = e.clipboardData.getData('text/plain');
              if (txt) {
                e.preventDefault();
                proxy.value = '';
                pendingKey = null;
                commitText(txt);
              }
            }
          });
          proxy.addEventListener('keydown', function(e) {
            if (e.metaKey) return;
            if (composing || e.isComposing || e.key === 'Process' || e.keyCode === 229) {
              pendingKey = null;
              swallowKeyupCode = e.code || null;
              return;
            }
            if (!e.ctrlKey && !e.altKey && e.key && e.key.length === 1) {
              // Allow WKWebView NSTextInputContext to start Chinese IME composition instead of cancelling keydown.
              pendingKey = snapshotKey(e);
              return;
            }
            pendingKey = null;
            e.preventDefault();
            dispatchKey('keydown', snapshotKey(e));
          });
          proxy.addEventListener('keyup', function(e) {
            if (e.metaKey) return;
            if (composing || e.isComposing || e.key === 'Process' || e.keyCode === 229) return;
            if (Date.now() - justEndedCompositionAt < 100) return;
            if (swallowKeyupCode && e.code === swallowKeyupCode) {
              swallowKeyupCode = null;
              return;
            }
            if (!e.ctrlKey && !e.altKey && e.key && e.key.length === 1) return;
            e.preventDefault();
            dispatchKey('keyup', snapshotKey(e));
          });
          return proxy;
        }

        function focusProxyAt(clientX, clientY) {
          lastX = Math.max(12, Math.min(window.innerWidth - 60, clientX || lastX));
          lastY = Math.max(12, Math.min(window.innerHeight - 40, clientY || lastY));
          var p = ensureProxy();
          if (!p) return;
          p.style.left = lastX + 'px';
          p.style.top = lastY + 'px';
          setTimeout(function() {
            try { p.focus({ preventScroll: true }); } catch (err) { p.focus(); }
          }, 25);
        }

        function isCanvasEvent(e) {
          var canvas = document.querySelector('#noVNC_container canvas');
          if (!canvas) return false;
          return e.target === canvas || canvas.contains(e.target);
        }

        if (!document.getElementById('avm-novnc-clean-style')) {
          var st = document.createElement('style');
          st.id = 'avm-novnc-clean-style';
          st.textContent = '#noVNC_control_bar_handle{display:none!important}';
          (document.head || document.documentElement).appendChild(st);
        }

        document.addEventListener('mouseup', function(e) {
          if (isCanvasEvent(e)) focusProxyAt(e.clientX, e.clientY);
        }, true);
        document.addEventListener('click', function(e) {
          if (isCanvasEvent(e)) focusProxyAt(e.clientX, e.clientY);
        }, true);
      })();
    })();
    """#
}

// Runs Chromium + Xvfb + openbox + x11vnc + noVNC entirely inside the Linux VM.
// The host displays the VNC canvas over loopback and queries/controls Chromium via CDP on :9222 over SSH.
@MainActor final class LinuxBrowserManager {
    var onChange: (([String: LinuxBrowserState]) -> Void)?
    var onOpen: ((String, URL) -> Void)?
    private(set) var states: [String: LinuxBrowserState] = [:]
    private var preparing: Set<String> = []
    private var checking: Set<String> = []
    private var generations: [String: UUID] = [:]
    private var resizeWorkItems: [String: DispatchWorkItem] = [:]

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
            q = 6; c = 2
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
                    var st = self.states[name] ?? LinuxBrowserState()
                    let installed = obj["installed"] as? Bool ?? false
                    let appRunning = obj["appRunning"] as? Bool ?? false
                    let missing = obj["missing"] as? [String] ?? []
                    st.checked = true
                    st.installed = installed
                    st.appRunning = appRunning
                    st.browserPID = obj["browserPID"] as? Int ?? 0
                    st.browserRSSMB = obj["browserRSSMB"] as? Int ?? 0
                    st.browserTreeRSSMB = obj["browserTreeRSSMB"] as? Int ?? 0
                    st.browserProcessCount = obj["browserProcessCount"] as? Int ?? 0
                    st.browserCPUSeconds = obj["browserCPUSeconds"] as? Double ?? 0
                    st.cdpAvailable = obj["cdpAvailable"] as? Bool ?? false
                    st.mcpInstalled = obj["mcpInstalled"] as? Bool ?? false
                    st.missingComponents = missing
                    if st.status == "idle" && !missing.isEmpty {
                        st.status = "idle"
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
        var st = states[name] ?? LinuxBrowserState()
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
        var st = states[name] ?? LinuxBrowserState()
        st.autoResize = enabled
        states[name] = st
        onChange?(states)
        if enabled && width > 100 && height > 100 {
            resize(name: name, config: config, width: width, height: height)
        }
    }

    func restartApp(name: String, config: String, width: Int, height: Int) {
        guard !preparing.contains(name), states[name]?.installing != true else { return }
        let qMode = states[name]?.qualityMode ?? "balanced"
        start(name: name, config: config, width: width, height: height, qualityMode: qMode, restartApp: true)
    }

    func stopSession(name: String, config: String, completion: (() -> Void)? = nil) {
        guard !preparing.contains(name), states[name]?.installing != true else { return }
        generations[name] = UUID()
        resizeWorkItems[name]?.cancel()
        resizeWorkItems.removeValue(forKey: name)
        var st = states[name] ?? LinuxBrowserState()
        st.status = "idle"
        st.stage = "idle"
        st.url = ""
        st.port = 0
        st.appRunning = false
        st.checked = true
        st.tabs = []
        st.activeTabId = ""
        st.activeURL = ""
        st.activeTitle = ""
        states[name] = st
        onChange?(states)

        let script = Self.stopScript
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
            let process = Process(), output = Pipe(), stdin = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = Self.sshControlArgs(config: config) + ["lima-" + name, "python3 -"]
            process.standardOutput = output
            process.standardError = output
            process.standardInput = stdin
            do {
                try process.run()
                try stdin.fileHandleForWriting.write(contentsOf: Data(script.utf8))
                try stdin.fileHandleForWriting.close()
                let raw = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0,
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
                    self.inspect(name: name, config: config)
                    self.resize(name: name, config: config, width: width, height: height)
                } else if fallbackPrepare {
                    self.start(name: name, config: config, width: width, height: height, qualityMode: qualityMode)
                } else {
                    self.failed(name, "Linux 浏览器未响应，请重试。", missing: [])
                }
            }
        }.resume()
    }

    private func start(name: String, config: String, width: Int, height: Int, qualityMode: String, restartApp: Bool = false) {
        let generation = UUID()
        generations[name] = generation
        preparing.insert(name)
        let (w, h) = Self.clampedSize(width, height)
        var st = states[name] ?? LinuxBrowserState()
        st.status = "starting"
        st.stage = "checking"
        st.stageMessage = "正在连接虚拟机并检查浏览器组件…"
        st.error = ""
        st.missingComponents = []
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
                DispatchQueue.global().asyncAfter(deadline: .now() + 35, execute: timeout)
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
                let missing = finalDecoded?["missing"] as? [String] ?? []
                let error = finalDecoded?["error"] as? String ?? "无法启动 Linux 浏览器，请检查虚拟机连接。"
                DispatchQueue.main.async {
                    guard self.generations[name] == generation else { return }
                    guard process.terminationStatus == 0, let port, (1024...65535).contains(port) else {
                        self.failed(name, error, missing: missing)
                        return
                    }
                    self.states[name]?.stage = "vnc"
                    self.states[name]?.stageMessage = "正在建立 noVNC 画面连接…"
                    self.states[name]?.resolution = resolution
                    self.onChange?(self.states)
                    self.check(name: name, config: config, port: port, qualityMode: qualityMode, generation: generation, attempts: 20)
                }
            } catch {
                timeout.cancel()
                output.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { process.terminate() }
                DispatchQueue.main.async {
                    if self.generations[name] == generation {
                        self.failed(name, "无法连接 Linux 浏览器。", missing: [])
                    }
                }
            }
        }
    }

    private func check(name: String, config: String, port: Int, qualityMode: String, generation: UUID, attempts: Int) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/vnc.html")!)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { _, response, _ in
            DispatchQueue.main.async {
                guard self.generations[name] == generation else { return }
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    self.preparing.remove(name)
                    let url = Self.buildNoVNCURL(port: port, qualityMode: qualityMode)
                    var st = self.states[name] ?? LinuxBrowserState()
                    st.status = "ready"
                    st.stage = "ready"
                    st.stageMessage = "浏览器已就绪"
                    st.url = url
                    st.port = port
                    st.qualityMode = qualityMode
                    st.checked = true
                    st.installed = true
                    st.appRunning = true
                    st.error = ""
                    st.missingComponents = []
                    self.states[name] = st
                    self.onChange?(self.states)
                    if let target = URL(string: url) { self.onOpen?(name, target) }
                    self.inspect(name: name, config: config)
                } else if attempts > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.check(name: name, config: config, port: port, qualityMode: qualityMode, generation: generation, attempts: attempts - 1)
                    }
                } else {
                    self.failed(name, "Linux 浏览器界面未能响应，请重试。", missing: [])
                }
            }
        }.resume()
    }

    private func failed(_ name: String, _ error: String, missing: [String]) {
        preparing.remove(name)
        var st = states[name] ?? LinuxBrowserState()
        st.status = "error"
        st.stage = "error"
        st.error = error
        st.missingComponents = missing
        states[name] = st
        onChange?(states)
    }

    // MARK: - CDP Control & Inspection

    func inspect(name: String, config: String) {
        runCDP(name: name, config: config, op: "inspect", params: [:]) { [weak self] obj in
            self?.applyInspectResult(name: name, obj: obj)
        }
    }

    func navigate(name: String, config: String, url: String, tabId: String = "") {
        runCDP(name: name, config: config, op: "navigate", params: ["url": url, "tabId": tabId]) { [weak self] obj in
            self?.applyInspectResult(name: name, obj: obj)
        }
    }

    func back(name: String, config: String, tabId: String = "") {
        runCDP(name: name, config: config, op: "back", params: ["tabId": tabId]) { [weak self] obj in
            self?.applyInspectResult(name: name, obj: obj)
        }
    }

    func forward(name: String, config: String, tabId: String = "") {
        runCDP(name: name, config: config, op: "forward", params: ["tabId": tabId]) { [weak self] obj in
            self?.applyInspectResult(name: name, obj: obj)
        }
    }

    func reloadPage(name: String, config: String, tabId: String = "") {
        runCDP(name: name, config: config, op: "reload", params: ["tabId": tabId]) { [weak self] obj in
            self?.applyInspectResult(name: name, obj: obj)
        }
    }

    func newTab(name: String, config: String, url: String = "about:blank") {
        runCDP(name: name, config: config, op: "new_tab", params: ["url": url]) { [weak self] obj in
            self?.applyInspectResult(name: name, obj: obj)
        }
    }

    func activateTab(name: String, config: String, tabId: String) {
        runCDP(name: name, config: config, op: "activate_tab", params: ["tabId": tabId]) { [weak self] obj in
            self?.applyInspectResult(name: name, obj: obj)
        }
    }

    func closeTab(name: String, config: String, tabId: String) {
        runCDP(name: name, config: config, op: "close_tab", params: ["tabId": tabId]) { [weak self] obj in
            self?.applyInspectResult(name: name, obj: obj)
        }
    }

    func insertText(name: String, config: String, text: String, tabId: String = "") {
        runCDP(name: name, config: config, op: "insert_text", params: ["text": text, "tabId": tabId]) { _ in }
    }

    func captureScreenshot(name: String, config: String, tabId: String = "", completion: @escaping (Data?, String?) -> Void) {
        runCDP(name: name, config: config, op: "screenshot", params: ["tabId": tabId]) { obj in
            if let b64 = obj?["png_base64"] as? String,
               let data = Data(base64Encoded: b64) {
                completion(data, nil)
            } else {
                completion(nil, obj?["error"] as? String ?? "截图失败")
            }
        }
    }

    func fetchLogs(name: String, config: String) {
        runCDP(name: name, config: config, op: "logs", params: [:]) { [weak self] obj in
            guard let self, let logs = obj?["logs"] as? String else { return }
            self.states[name]?.logs = logs
            self.onChange?(self.states)
        }
    }

    func installComponents(name: String, config: String, completion: @escaping (Bool, String) -> Void) {
        guard states[name]?.installing != true else { return }
        var st = states[name] ?? LinuxBrowserState()
        st.installing = true
        st.stageMessage = "正在虚拟机内安装 Chromium 与 noVNC 组件…"
        st.error = ""
        states[name] = st
        onChange?(states)

        let installCmd = """
        sudo apt-get update && sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends chromium fonts-liberation fonts-dejavu-core fonts-noto-cjk tigervnc-standalone-server xvfb xauth openbox x11vnc novnc websockify x11-xserver-utils </dev/null && \
        sudo ln -sf /usr/bin/chromium /usr/bin/google-chrome && \
        sudo ln -sf /usr/bin/chromium /usr/bin/google-chrome-stable && \
        sudo mkdir -p /opt/google/chrome && \
        sudo ln -sf /usr/bin/chromium /opt/google/chrome/chrome
        """
        DispatchQueue.global(qos: .utility).async {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = Self.sshControlArgs(config: config, timeout: 10) + ["lima-" + name, "bash -lc '\(installCmd)'"]
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    self.states[name]?.installing = false
                    self.states[name]?.logs = String(text.suffix(4000))
                    if process.terminationStatus == 0 {
                        self.states[name]?.missingComponents = []
                        self.onChange?(self.states)
                        completion(true, "浏览器组件安装完成")
                    } else {
                        self.states[name]?.error = "安装失败，请查看日志。"
                        self.onChange?(self.states)
                        completion(false, "安装失败")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.states[name]?.installing = false
                    self.states[name]?.error = error.localizedDescription
                    self.onChange?(self.states)
                    completion(false, error.localizedDescription)
                }
            }
        }
    }

    private func applyInspectResult(name: String, obj: [String: Any]?) {
        guard let obj else { return }
        var st = states[name] ?? LinuxBrowserState()
        if let tabs = obj["tabs"] as? [[String: Any]] {
            st.tabs = tabs
            if let active = tabs.first(where: { ($0["active"] as? Bool) == true }) ?? tabs.first {
                st.activeTabId = active["id"] as? String ?? ""
                st.activeURL = active["url"] as? String ?? ""
                st.activeTitle = active["title"] as? String ?? ""
            }
        }
        if let ports = obj["devPorts"] as? [Int] {
            st.devPorts = ports
        }
        if let res = obj["resolution"] as? String, !res.isEmpty {
            st.resolution = res
        }
        states[name] = st
        onChange?(states)
    }

    private func runCDP(name: String, config: String, op: String, params: [String: Any], completion: @escaping ([String: Any]?) -> Void) {
        var payload = params
        payload["op"] = op
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(nil)
            return
        }
        let script = "import json, base64\ncmd = json.loads(base64.b64decode('" + data.base64EncodedString() + "'))\n" + Self.cdpScript
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process(), output = Pipe(), stdin = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = Self.sshControlArgs(config: config, timeout: 4) + ["lima-" + name, "python3 -"]
            process.standardOutput = output
            process.standardError = output
            process.standardInput = stdin
            do {
                try process.run()
                try stdin.fileHandleForWriting.write(contentsOf: Data(script.utf8))
                try stdin.fileHandleForWriting.close()
                let raw = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(data: raw, encoding: .utf8) ?? ""
                if let line = text.components(separatedBy: .newlines).last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }),
                   let lineData = line.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                    DispatchQueue.main.async { completion(obj) }
                } else {
                    DispatchQueue.main.async { completion(nil) }
                }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    func installMCP(name: String, config: String, completion: @escaping (Bool, String) -> Void) {
        // The installer writes only inside the guest user's private config directory.
        // No CDP port forwarding or public listener is created.
        let encoded = Data(Self.mcpServerScript.utf8).base64EncodedString()
        let script = """
        import base64, os, pathlib, json
        target = pathlib.Path.home() / '.config' / 'agent-vm-browser' / 'agent_vm_browser_mcp.py'
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(target.parent, 0o700)
        target.write_bytes(base64.b64decode('\(encoded)'))
        os.chmod(target, 0o700)
        print(json.dumps({'path': str(target)}))
        """
        DispatchQueue.global(qos: .utility).async {
            let process = Process(), output = Pipe(), input = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = Self.sshControlArgs(config: config, timeout: 8) + ["lima-" + name, "python3 -"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
                try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
                try input.fileHandleForWriting.close()
                let result = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let message = String(data: result, encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    completion(process.terminationStatus == 0, process.terminationStatus == 0
                               ? message.trimmingCharacters(in: .whitespacesAndNewlines)
                               : "MCP 安装失败：" + String(message.suffix(600)))
                }
            } catch {
                DispatchQueue.main.async { completion(false, error.localizedDescription) }
            }
        }
    }

    func registerMCP(name: String, config: String, completion: @escaping (Bool, String) -> Void) {
        // Opt-in registration: do not silently change agent settings.
        let script = #"""
import json, pathlib, shutil, subprocess
path = pathlib.Path.home() / '.config/agent-vm-browser/agent_vm_browser_mcp.py'
results = {}
if not path.is_file():
    print(json.dumps({'ok': False, 'message': '请先安装 MCP 服务端'}))
    raise SystemExit(0)
for agent, argv in (
    ('codex', ['codex', 'mcp', 'add', 'agent-vm-browser', '--', 'python3', str(path)]),
    ('claude', ['claude', 'mcp', 'add', '--scope', 'user', 'agent-vm-browser', '--', 'python3', str(path)]),
):
    if not shutil.which(agent):
        results[agent] = 'not_installed'
        continue
    try:
        run = subprocess.run(argv, capture_output=True, text=True, timeout=15)
        if run.returncode == 0:
            results[agent] = 'registered'
        elif 'already exists' in (run.stdout + run.stderr).lower():
            results[agent] = 'already_registered'
        else:
            results[agent] = 'failed: ' + (run.stderr or run.stdout)[-240:]
    except (OSError, subprocess.TimeoutExpired) as exc:
        results[agent] = 'failed: ' + str(exc)
print(json.dumps({'ok': any(v in ('registered', 'already_registered') for v in results.values()), 'agents': results}))
"""#
        DispatchQueue.global(qos: .utility).async {
            let process = Process(), output = Pipe(), input = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = Self.sshControlArgs(config: config, timeout: 8) + ["lima-" + name, "python3 -"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
                try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
                try input.fileHandleForWriting.close()
                let raw = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let message = String(data: raw, encoding: .utf8) ?? ""
                let line = message.components(separatedBy: .newlines).last(where: { $0.hasPrefix("{") })
                let parsed = line?.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let agents = parsed?["agents"] as? [String: String] ?? [:]
                let summary = agents.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "；")
                DispatchQueue.main.async {
                    completion(parsed?["ok"] as? Bool ?? false, summary.isEmpty ? "未找到可注册的 Agent CLI" : summary)
                }
            } catch {
                DispatchQueue.main.async { completion(false, error.localizedDescription) }
            }
        }
    }

    private static let mcpServerScript = #"""
#!/usr/bin/env python3
"""Minimal stdio MCP adapter for the existing guest-local Chromium CDP endpoint.

No TCP listener, third-party packages or direct host network access.
Run this inside the same Linux VM as Chromium.
"""
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

CDP = "http://127.0.0.1:9222"
MAX_MESSAGE = 1024 * 1024

TOOLS = [
    {"name": "browser_tabs", "description": "List open Chromium page tabs.",
     "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}},
    {"name": "browser_new_tab", "description": "Open a URL in a new Chromium tab.",
     "inputSchema": {"type": "object", "properties": {"url": {"type": "string"}},
                     "required": ["url"], "additionalProperties": False}},
    {"name": "browser_activate_tab", "description": "Activate an existing tab by ID.",
     "inputSchema": {"type": "object", "properties": {"tabId": {"type": "string"}},
                     "required": ["tabId"], "additionalProperties": False}},
    {"name": "browser_close_tab", "description": "Close a tab by ID.",
     "inputSchema": {"type": "object", "properties": {"tabId": {"type": "string"}},
                     "required": ["tabId"], "additionalProperties": False}},
]


def cdp(path, method="GET"):
    request = urllib.request.Request(CDP + path, method=method)
    with urllib.request.urlopen(request, timeout=5) as response:
        data = response.read(MAX_MESSAGE + 1)
        if len(data) > MAX_MESSAGE:
            raise ValueError("CDP response too large")
        return json.loads(data) if data else {}


def tabs():
    return [
        {"id": tab.get("id"), "title": tab.get("title"), "url": tab.get("url")}
        for tab in cdp("/json/list") if tab.get("type") == "page"
    ]


def call(name, args):
    if not isinstance(args, dict):
        raise ValueError("arguments must be an object")
    if name == "browser_tabs":
        return tabs()
    if name == "browser_new_tab":
        url = args.get("url")
        if not isinstance(url, str) or not url or len(url) > 4096:
            raise ValueError("url must be a nonempty string up to 4096 characters")
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme not in ("http", "https") or not parsed.netloc:
            raise ValueError("only absolute http/https URLs are accepted")
        return cdp("/json/new?" + urllib.parse.quote(url, safe=""), "PUT")
    if name in ("browser_activate_tab", "browser_close_tab"):
        tab_id = args.get("tabId")
        if not isinstance(tab_id, str) or not tab_id or len(tab_id) > 128:
            raise ValueError("invalid tab ID")
        if tab_id not in {tab["id"] for tab in tabs()}:
            raise ValueError("tab not found")
        operation = "activate" if name == "browser_activate_tab" else "close"
        return cdp("/json/" + operation + "/" + urllib.parse.quote(tab_id, safe=""))
    raise ValueError("unknown tool")


def respond(payload):
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    sys.stdout.buffer.write(raw + b"\n")
    sys.stdout.buffer.flush()


def serve():
    stream = sys.stdin.buffer
    while True:
        body = stream.readline(MAX_MESSAGE + 1)
        if not body:
            return
        if len(body) > MAX_MESSAGE:
            return
        try:
            request = json.loads(body)
            if not isinstance(request, dict) or request.get("jsonrpc") != "2.0":
                continue
            ident = request.get("id")
            method = request.get("method")
            if ident is None:
                continue  # Notifications do not receive a response.
            if method == "initialize":
                result = {"protocolVersion": "2024-11-05",
                          "capabilities": {"tools": {}},
                          "serverInfo": {"name": "agent-vm-browser", "version": "0.1.0"}}
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": TOOLS}
            elif method == "tools/call":
                params = request.get("params") or {}
                try:
                    value = call(params.get("name"), params.get("arguments") or {})
                    result = {"content": [{"type": "text", "text": json.dumps(value, ensure_ascii=False)}]}
                except (ValueError, urllib.error.URLError, OSError) as exc:
                    result = {"isError": True, "content": [{"type": "text", "text": str(exc)}]}
            else:
                respond({"jsonrpc": "2.0", "id": ident,
                         "error": {"code": -32601, "message": "Method not found"}})
                continue
            respond({"jsonrpc": "2.0", "id": ident, "result": result})
        except (ValueError, TypeError, KeyError):
            continue


if __name__ == "__main__":
    serve()
"""#

    // MARK: - Guest Python Scripts

    static let statusScript = #"""
import json, os, shutil, socket

chromium = shutil.which('chromium') or shutil.which('chromium-browser') or shutil.which('google-chrome')
websockify = shutil.which('websockify')
xtigervnc = shutil.which('Xtigervnc')
xvfb = shutil.which('Xvfb')
x11vnc = shutil.which('x11vnc')
openbox = shutil.which('openbox')
missing = []
if not chromium: missing.append('chromium')
if not xtigervnc and (not xvfb or not x11vnc):
    if not xvfb: missing.append('xvfb')
    if not x11vnc: missing.append('x11vnc')
if not openbox: missing.append('openbox')
if not websockify or not os.path.isfile('/usr/share/novnc/vnc.html'): missing.append('novnc')

app_running = False
browser_pid = 0
browser_rss_mb = 0
browser_cpu_seconds = 0.0
for d in os.listdir('/proc'):
    if not d.isdigit(): continue
    try:
        if os.stat('/proc/' + d).st_uid != os.getuid(): continue
        raw = open(f'/proc/{d}/cmdline', 'rb').read().decode(errors='ignore')
        args = [x for x in raw.split('\0') if x]
        if any('chromium' in x or 'chrome' in x for x in args[:2]) and '--remote-debugging-port=9222' in args:
            app_running = True
            browser_pid = int(d)
            try:
                for line in open(f'/proc/{d}/status'):
                    if line.startswith('VmRSS:'):
                        browser_rss_mb = int(line.split()[1]) // 1024
                        break
                ticks = os.sysconf('SC_CLK_TCK')
                raw_stat = open(f'/proc/{d}/stat').read().rsplit(')', 1)[1].split()
                browser_cpu_seconds = round((int(raw_stat[11]) + int(raw_stat[12])) / ticks, 2)
            except (OSError, ValueError, IndexError): pass
            break
    except Exception:
        pass

# Account for Chromium's renderer, GPU and utility processes. This is
# observational only; no automatic suspension or termination is performed.
tree_rss_kb = 0
tree_count = 0
if browser_pid:
    parent = {}
    rss = {}
    for d in os.listdir('/proc'):
        if not d.isdigit(): continue
        try:
            if os.stat('/proc/' + d).st_uid != os.getuid(): continue
            stat = open('/proc/' + d + '/stat').read().rsplit(')', 1)[1].split()
            parent[int(d)] = int(stat[1])
            for line in open('/proc/' + d + '/status'):
                if line.startswith('VmRSS:'):
                    rss[int(d)] = int(line.split()[1])
                    break
        except (OSError, ValueError, IndexError):
            continue
    descendants = {browser_pid}
    changed = True
    while changed:
        expanded = descendants | {pid for pid, ppid in parent.items() if ppid in descendants}
        changed = len(expanded) != len(descendants)
        descendants = expanded
    tree_count = len(descendants)
    tree_rss_kb = sum(rss.get(pid, 0) for pid in descendants)

cdp_available = False
if app_running:
    try:
        with socket.create_connection(('127.0.0.1', 9222), timeout=0.4):
            cdp_available = True
    except OSError:
        pass

print(json.dumps({
    'installed': chromium is not None,
    'appRunning': app_running,
    'browserPID': browser_pid,
    'browserRSSMB': browser_rss_mb,
    'browserTreeRSSMB': tree_rss_kb // 1024,
    'browserProcessCount': tree_count,
    'browserCPUSeconds': browser_cpu_seconds,
    'cdpAvailable': cdp_available,
    'mcpInstalled': (pathlib.Path.home() / '.config/agent-vm-browser/agent_vm_browser_mcp.py').is_file(),
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
            args = [x for x in (proc/'cmdline').read_bytes().decode(errors='ignore').split('\0') if x]
            if match(args): pids.append((int(proc.name), args))
        except OSError:
            pass
    return pids

def stop_procs(match, wait_sec=3.5):
    targets = proc_running(match)
    if not targets: return
    for pid, _ in targets:
        try: os.kill(pid, signal.SIGTERM)
        except OSError: pass
    deadline = time.time() + wait_sec
    while time.time() < deadline:
        if not proc_running(match): return
        time.sleep(0.15)
    for pid, _ in proc_running(match):
        try: os.kill(pid, signal.SIGKILL)
        except OSError: pass
    time.sleep(0.2)

def ensure_download_prefs(profile_dir):
    try:
        dl = pathlib.Path('/mnt/agent-vm-shared/Downloads')
        dl.mkdir(parents=True, exist_ok=True)
        default_dir = profile_dir / 'Default'
        default_dir.mkdir(parents=True, exist_ok=True)
        pref_path = default_dir / 'Preferences'
        prefs = {}
        if pref_path.exists():
            try: prefs = json.loads(pref_path.read_text())
            except Exception: prefs = {}
        prefs.setdefault('download', {})['default_directory'] = str(dl)
        prefs.setdefault('download', {})['prompt_for_download'] = False
        pref_path.write_text(json.dumps(prefs))
    except Exception:
        pass

try:
    emit({'stage': 'checking', 'message': '正在检查 Chromium 与 VNC 组件…'})
    chromium = shutil.which('chromium') or shutil.which('chromium-browser') or shutil.which('google-chrome')
    websockify = shutil.which('websockify')
    xtigervnc = shutil.which('Xtigervnc')
    xvfb = shutil.which('Xvfb')
    x11vnc = shutil.which('x11vnc')
    openbox = shutil.which('openbox')
    missing = []
    if not chromium: missing.append('chromium')
    if not xtigervnc and (not xvfb or not x11vnc):
        if not xvfb: missing.append('xvfb')
        if not x11vnc: missing.append('x11vnc')
    if not openbox: missing.append('openbox')
    if not websockify or not os.path.isfile('/usr/share/novnc/vnc.html'): missing.append('novnc')
    if missing:
        msg = '此虚拟机缺少浏览器组件：' + ', '.join(missing)
        emit({'error': msg, 'missing': missing})
        raise SystemExit(1)

    w = max(800, min(2560, int(settings.get('width', 1280)) // 2 * 2))
    h = max(500, min(1600, int(settings.get('height', 800)) // 2 * 2))
    restart_app = bool(settings.get('restartApp', False))

    log_dir = pathlib.Path.home() / '.config/agent-vm-browser'
    log_dir.mkdir(parents=True, exist_ok=True)
    profile_dir = log_dir / 'profile'
    profile_dir.mkdir(parents=True, exist_ok=True)
    # Chromium profiles contain authenticated sessions. Never expose them to other guest users.
    os.chmod(log_dir, 0o700)
    os.chmod(profile_dir, 0o700)
    ensure_download_prefs(profile_dir)
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
    env = dict(os.environ, DISPLAY=':99', LANG='en_US.UTF-8', LC_CTYPE='en_US.UTF-8')

    use_tiger = bool(xtigervnc)
    if use_tiger and proc_running(lambda a: any('Xvfb' in x for x in a[:2]) and ':99' in a):
        stop_procs(lambda a: any('chromium' in x or 'chrome' in x for x in a[:2]) and '--remote-debugging-port=9222' in a)
        stop_procs(lambda a: any('openbox' in x for x in a[:2]) and 'agent-vm-browser' in ' '.join(a))
        stop_procs(lambda a: any('x11vnc' in x for x in a[:2]) and '5999' in a)
        stop_procs(lambda a: any('Xvfb' in x for x in a[:2]) and ':99' in a)

    if restart_app:
        if shutil.which('systemctl'):
            subprocess.run(['systemctl', '--user', 'stop', 'agent-vm-chromium.service'],
                           capture_output=True, timeout=8)
        stop_procs(lambda a: any('chromium' in x or 'chrome' in x for x in a[:2]) and '--remote-debugging-port=9222' in a)

    emit({'stage': 'display', 'message': f'正在启动虚拟显示 ({w}×{h})…'})
    if use_tiger:
        if not proc_running(lambda a: any('Xtigervnc' in x for x in a[:2]) and ':99' in a):
            with open(log_dir / 'xvfb.log', 'ab') as f:
                subprocess.Popen([
                    xtigervnc, ':99', '-localhost', '-rfbport', '5999',
                    '-SecurityTypes', 'None', '-geometry', f'{w}x{h}', '-depth', '24',
                    '-dpi', '96', '-FrameRate=60', '-CompareFB=1',
                    '-AcceptSetDesktopSize=1', '-AlwaysShared=1'
                ], stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)
            time.sleep(0.45)
    elif not proc_running(lambda a: any('Xvfb' in x for x in a[:2]) and ':99' in a):
        with open(log_dir / 'xvfb.log', 'ab') as f:
            subprocess.Popen(['Xvfb', ':99', '-screen', '0', f'{w}x{h}x24', '-nolisten', 'tcp', '+extension', 'RANDR'],
                             stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)
        time.sleep(0.45)

    if not proc_running(lambda a: any('openbox' in x for x in a[:2]) and 'agent-vm-browser' in ' '.join(a)):
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
        time.sleep(0.25)

    emit({'stage': 'chromium', 'message': '正在启动 Chromium 浏览器…'})
    if not proc_running(lambda a: any('chromium' in x or 'chrome' in x for x in a[:2]) and '--remote-debugging-port=9222' in a):
        with open(log_dir / 'chromium.log', 'ab') as f:
            browser_args = [
                chromium, '--no-sandbox', '--test-type', '--disable-dev-shm-usage',
                '--disable-gpu', '--ozone-platform=x11',
                # Keep active agent pages alive, but allow Chromium to throttle idle tabs.
                '--force-webrtc-ip-handling-policy=disable_non_proxied_udp',
                '--no-first-run', '--no-default-browser-check',
                # CDP is a privileged browser-control interface: bind only inside the guest.
                '--remote-debugging-address=127.0.0.1',
                '--remote-debugging-port=9222',
                '--user-data-dir=' + str(profile_dir),
                f'--window-size={w},{h}',
                '--start-maximized'
            ]
            # A transient user service survives workbench disconnections and provides
            # restart-on-failure. When the user manager is unavailable (minimal guests),
            # retain the previous detached-process implementation.
            systemd_run = shutil.which('systemd-run')
            managed = False
            if systemd_run and pathlib.Path('/run/user/' + str(os.getuid()) + '/bus').exists():
                service_cmd = [
                    systemd_run, '--user', '--unit=agent-vm-chromium',
                    '--collect', '--property=Restart=on-failure',
                    '--property=RestartSec=3s',
                    '--property=TimeoutStopSec=8s',
                    '--setenv=DISPLAY=:99',
                    '--setenv=LANG=en_US.UTF-8',
                    '--'
                ] + browser_args
                attempt = subprocess.run(service_cmd, env=env, capture_output=True, text=True, timeout=8)
                managed = attempt.returncode == 0
                if not managed:
                    f.write(('systemd-run fallback: ' + attempt.stderr + '\\n').encode())
            if not managed:
                subprocess.Popen(browser_args, env=env, stdin=subprocess.DEVNULL,
                                 stdout=f, stderr=f, start_new_session=True)
        time.sleep(0.8)

    emit({'stage': 'vnc', 'message': '正在启动 noVNC 画面服务…'})
    if not use_tiger and not proc_running(lambda a: any('x11vnc' in x for x in a[:2]) and '5999' in a):
        with open(log_dir / 'x11vnc.log', 'ab') as f:
            subprocess.Popen([
                'x11vnc', '-display', ':99', '-localhost', '-rfbport', '5999',
                '-forever', '-shared', '-nopw', '-quiet',
                '-xrandr', 'resize', '-noxdamage', '-wait', '10', '-defer', '10'
            ], env=env, stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)
        time.sleep(0.25)

    port = None
    existing = proc_running(lambda a: any('websockify' in x for x in a[:3]) and '127.0.0.1:5999' in a)
    if existing:
        for arg in existing[0][1]:
            if arg.startswith('127.0.0.1:') and arg != '127.0.0.1:5999':
                try:
                    port = int(arg.split(':', 1)[1])
                    break
                except ValueError:
                    pass

    if port is None:
        number = int(hashlib.sha256(settings['name'].encode()).hexdigest()[:4], 16)
        for candidate in range(21000 + number % 9991, 21010 + number % 9991):
            with socket.socket() as probe:
                try: probe.bind(('127.0.0.1', candidate))
                except OSError: continue
            port = candidate
            break
        if port is None:
            raise RuntimeError('没有可用的浏览器端口。')
        with open(log_dir / 'novnc.log', 'ab') as f:
            subprocess.Popen([
                websockify, '--web=/usr/share/novnc',
                '127.0.0.1:' + str(port), '127.0.0.1:5999'
            ], stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)

    for _ in range(40):
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=0.3):
                break
        except OSError:
            time.sleep(0.25)
    else:
        raise RuntimeError('noVNC 启动超时。')

    emit({'port': port, 'resolution': f'{w}x{h}'})
except SystemExit:
    raise
except Exception as error:
    emit({'error': str(error)})
    raise SystemExit(1)
"""#

    static let stopScript = #"""
import os, pathlib, signal, time

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

# Stop the managed service first, then clean up any legacy detached browser.
import subprocess, shutil
if shutil.which('systemctl'):
    subprocess.run(['systemctl', '--user', 'stop', 'agent-vm-chromium.service'],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
stop_procs(lambda a: any('chromium' in x or 'chrome' in x for x in a[:2]) and '--remote-debugging-port=9222' in a)
stop_procs(lambda a: any('websockify' in x for x in a[:3]) and '127.0.0.1:5999' in a)
stop_procs(lambda a: any('openbox' in x for x in a[:2]) and 'agent-vm-browser' in ' '.join(a))
stop_procs(lambda a: any('x11vnc' in x for x in a[:2]) and '5999' in a)
stop_procs(lambda a: any(('Xtigervnc' in x or 'Xvfb' in x) for x in a[:2]) and ':99' in a)
"""#

    static let resizeScript = #"""
import os, re, subprocess, json, shutil

w = max(800, min(2560, int(settings.get('width', 1280)) // 2 * 2))
h = max(500, min(1600, int(settings.get('height', 800)) // 2 * 2))
env = dict(os.environ, DISPLAY=':99')
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

    static let cdpScript = #"""
import json, urllib.request, urllib.parse, socket, base64, hashlib, os, struct, pathlib, subprocess, re

def http_json(url, method='GET'):
    req = urllib.request.Request(url, method=method)
    with urllib.request.urlopen(req, timeout=2.5) as r:
        txt = r.read().decode('utf-8', errors='replace')
        try: return json.loads(txt)
        except Exception: return txt

def normalize_url(u):
    u = (u or '').strip()
    if not u: return 'about:blank'
    if '://' in u or u.startswith('about:') or u.startswith('data:') or u.startswith('chrome:'):
        return u
    if u.startswith('localhost') or re.match(r'^(\d{1,3}\.){3}\d{1,3}(:\d+)?', u) or u.startswith(':'):
        if u.startswith(':'): u = 'localhost' + u
        return 'http://' + u
    if '.' not in u and ':' not in u:
        return 'https://www.google.com/search?q=' + urllib.parse.quote(u)
    return 'https://' + u

def ws_cdp(ws_url, method, params=None):
    p = urllib.parse.urlparse(ws_url)
    host = p.hostname or '127.0.0.1'
    port = p.port or 9222
    path = p.path + (('?' + p.query) if p.query else '')
    key = base64.b64encode(os.urandom(16)).decode()
    sock = socket.create_connection((host, port), timeout=5)
    try:
        req = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            f"Upgrade: websocket\r\n"
            f"Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n\r\n"
        )
        sock.sendall(req.encode())
        buf = b''
        while b'\r\n\r\n' not in buf:
            chunk = sock.recv(4096)
            if not chunk: break
            buf += chunk
        rest = buf.split(b'\r\n\r\n', 1)[1]

        def send_frame(text):
            data = text.encode('utf-8')
            mask = os.urandom(4)
            header = bytearray([0x81])
            n = len(data)
            if n < 126: header.append(0x80 | n)
            elif n < 65536: header.extend([0x80 | 126]) ; header.extend(struct.pack('!H', n))
            else: header.extend([0x80 | 127]) ; header.extend(struct.pack('!Q', n))
            header.extend(mask)
            masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            sock.sendall(bytes(header) + masked)

        def recv_exact(n):
            nonlocal rest
            while len(rest) < n:
                c = sock.recv(max(4096, n - len(rest)))
                if not c: raise EOFError('ws closed')
                rest += c
            out = rest[:n]
            rest = rest[n:]
            return out

        def recv_frame():
            while True:
                b1, b2 = recv_exact(2)
                opcode = b1 & 0x0f
                length = b2 & 0x7f
                if length == 126: length = struct.unpack('!H', recv_exact(2))[0]
                elif length == 127: length = struct.unpack('!Q', recv_exact(8))[0]
                if b2 & 0x80: recv_exact(4)
                payload = recv_exact(length)
                if opcode == 0x8: raise EOFError('ws close')
                if opcode == 0x9: continue
                if opcode == 0x1: return payload.decode('utf-8', errors='replace')

        send_frame(json.dumps({'id': 1, 'method': method, 'params': params or {}}))
        for _ in range(50):
            msg = json.loads(recv_frame())
            if msg.get('id') == 1:
                return msg.get('result') or {}
    finally:
        sock.close()
    return {}

def scan_dev_ports():
    ports = set()
    excluded = {22, 53, 5999, 9222}
    for proc_file in ('/proc/net/tcp', '/proc/net/tcp6'):
        try:
            lines = pathlib.Path(proc_file).read_text().splitlines()[1:]
            for line in lines:
                cols = line.split()
                if len(cols) < 4 or cols[3] != '0A': continue
                port = int(cols[1].split(':')[1], 16)
                if port in excluded or 21000 <= port <= 21030: continue
                if 80 <= port <= 65000: ports.add(port)
        except Exception:
            pass
    return sorted(ports)[:12]

def list_tabs():
    try:
        items = http_json('http://127.0.0.1:9222/json/list')
        pages = [t for t in items if t.get('type') == 'page']
        return [{
            'id': t.get('id', ''),
            'title': t.get('title') or t.get('url') or '新标签页',
            'url': t.get('url', ''),
            'ws': t.get('webSocketDebuggerUrl', ''),
            'active': i == 0
        } for i, t in enumerate(pages)]
    except Exception:
        return []

def get_resolution():
    try:
        q = subprocess.run(['xrandr', '--query'], env=dict(os.environ, DISPLAY=':99'), capture_output=True, text=True)
        m = re.search(r'current\s+(\d+)\s+x\s+(\d+)', q.stdout)
        if m: return f'{m.group(1)}x{m.group(2)}'
    except Exception:
        pass
    return ''

op = cmd.get('op', 'inspect')
tab_id = cmd.get('tabId', '')

try:
    if op == 'logs':
        log_dir = pathlib.Path.home() / '.config/agent-vm-browser'
        chunks = []
        for fname in ('xvfb.log', 'openbox.log', 'chromium.log', 'x11vnc.log', 'novnc.log'):
            p = log_dir / fname
            if p.exists():
                lines = p.read_text(errors='replace').splitlines()[-35:]
                if lines: chunks.append(f'=== {fname} ===\n' + '\n'.join(lines))
        print(json.dumps({'logs': '\n\n'.join(chunks) or '暂无日志。'}))
        raise SystemExit(0)

    tabs = list_tabs()
    target = next((t for t in tabs if t['id'] == tab_id), None) if tab_id else (tabs[0] if tabs else None)

    if op == 'navigate' and target and target.get('ws'):
        ws_cdp(target['ws'], 'Page.navigate', {'url': normalize_url(cmd.get('url', ''))})
    elif op == 'reload' and target and target.get('ws'):
        ws_cdp(target['ws'], 'Page.reload', {})
    elif op == 'back' and target and target.get('ws'):
        hist = ws_cdp(target['ws'], 'Page.getNavigationHistory', {})
        idx = hist.get('currentIndex', 0)
        entries = hist.get('entries', [])
        if idx > 0 and idx - 1 < len(entries):
            ws_cdp(target['ws'], 'Page.navigateToHistoryEntry', {'entryId': entries[idx - 1]['id']})
    elif op == 'forward' and target and target.get('ws'):
        hist = ws_cdp(target['ws'], 'Page.getNavigationHistory', {})
        idx = hist.get('currentIndex', 0)
        entries = hist.get('entries', [])
        if idx + 1 < len(entries):
            ws_cdp(target['ws'], 'Page.navigateToHistoryEntry', {'entryId': entries[idx + 1]['id']})
    elif op == 'new_tab':
        u = urllib.parse.quote(normalize_url(cmd.get('url', 'about:blank')), safe=':/?&=#')
        try: http_json(f'http://127.0.0.1:9222/json/new?{u}', method='PUT')
        except Exception: http_json(f'http://127.0.0.1:9222/json/new?{u}', method='GET')
    elif op == 'activate_tab' and tab_id:
        http_json(f'http://127.0.0.1:9222/json/activate/{tab_id}')
    elif op == 'close_tab' and tab_id:
        http_json(f'http://127.0.0.1:9222/json/close/{tab_id}')
    elif op == 'insert_text' and target and target.get('ws'):
        ws_cdp(target['ws'], 'Input.insertText', {'text': cmd.get('text', '')})
    elif op == 'screenshot' and target and target.get('ws'):
        res = ws_cdp(target['ws'], 'Page.captureScreenshot', {'format': 'png'})
        print(json.dumps({'png_base64': res.get('data', '')}))
        raise SystemExit(0)

    tabs = list_tabs()
    clean_tabs = [{'id': t['id'], 'title': t['title'], 'url': t['url'], 'active': t['active']} for t in tabs]
    print(json.dumps({
        'tabs': clean_tabs,
        'devPorts': scan_dev_ports(),
        'resolution': get_resolution()
    }))
except SystemExit:
    raise
except Exception as e:
    print(json.dumps({'error': str(e), 'tabs': [], 'devPorts': scan_dev_ports()}))
"""#
}
