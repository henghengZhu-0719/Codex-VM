import SwiftUI

struct BrowserFloatingOverlay: View {
    @ObservedObject var model: Model
    let vm: VM
    let slot: CGRect

    @State private var showAddressBar = false
    @State private var showControls = false
    @State private var showIME = false
    @State private var showLogs = false
    @State private var imeText = ""
    @State private var urlText = ""
    @FocusState private var addressFocused: Bool
    @FocusState private var imeFocused: Bool

    private var state: LinuxBrowserState {
        model.linuxBrowsers[vm.name] ?? LinuxBrowserState()
    }

    private func openAddressBar() {
        urlText = state.activeURL
        showAddressBar = true
        showControls = false
        showIME = false
        model.browserInspect(vm)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            addressFocused = true
        }
    }

    private func submitAddress() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        showAddressBar = false
        model.browserNavigate(vm, url: trimmed, tabId: state.activeTabId)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .allowsHitTesting(false)

            // Top-center Spotlight/Safari quick navigation bar (Cmd+L or capsule button)
            if showAddressBar {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Button {
                            model.browserBack(vm, tabId: state.activeTabId)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)

                        Button {
                            model.browserForward(vm, tabId: state.activeTabId)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)

                        Button {
                            model.browserPageReload(vm, tabId: state.activeTabId)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)

                        TextField("输入网址、搜索内容或 :端口…", text: $urlText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .focused($addressFocused)
                            .onSubmit {
                                submitAddress()
                            }

                        Button {
                            model.browserNewTab(vm, url: "about:blank")
                            urlText = ""
                            addressFocused = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help("新建标签页")
                        .controlSize(.small)
                        .buttonStyle(.bordered)

                        Button {
                            showAddressBar = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    if !state.devPorts.isEmpty || state.tabs.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(state.devPorts, id: \.self) { port in
                                    Button(":\(port)") {
                                        showAddressBar = false
                                        model.browserNavigate(vm, url: "http://localhost:\(port)", tabId: state.activeTabId)
                                    }
                                    .controlSize(.mini)
                                    .buttonStyle(.bordered)
                                }
                                if state.tabs.count > 1 {
                                    ForEach(Array(state.tabs.enumerated()), id: \.offset) { _, tab in
                                        let tid = tab["id"] as? String ?? ""
                                        let title = (tab["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "标签页"
                                        let isActive = tid == state.activeTabId
                                        Button {
                                            model.browserActivateTab(vm, tabId: tid)
                                        } label: {
                                            Text(title)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                                .frame(maxWidth: 120)
                                        }
                                        .controlSize(.mini)
                                        .buttonStyle(.bordered)
                                        .tint(isActive ? .accentColor : nil)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(10)
                .frame(width: min(600, max(320, slot.width - 36)))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.14)))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
                .padding(.top, 12)
            }

            // Bottom-trailing compact capsule + popovers
            VStack {
                Spacer(minLength: 0)
                HStack {
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 8) {
                        if showLogs {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("运行日志")
                                        .font(.caption.weight(.semibold))
                                    Spacer()
                                    Button {
                                        model.browserFetchLogs(vm)
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                    Button {
                                        showLogs = false
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                }
                                ScrollView {
                                    Text(state.logs.isEmpty ? "正在读取日志…" : state.logs)
                                        .font(.system(size: 11, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                .frame(height: 180)
                            }
                            .padding(12)
                            .frame(width: 420)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.12)))
                            .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
                        }

                        if showControls {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.displayName(for: vm))
                                            .font(.subheadline.weight(.semibold))
                                        HStack(spacing: 6) {
                                            if !state.resolution.isEmpty {
                                                Text(state.resolution)
                                            }
                                            if !state.activeTitle.isEmpty {
                                                Text("· \(state.activeTitle)")
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)
                                            }
                                        }
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("切换") {
                                        showControls = false
                                        model.requestBrowserPicker()
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)
                                }

                                if !state.tabs.isEmpty {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 6) {
                                            ForEach(Array(state.tabs.enumerated()), id: \.offset) { _, tab in
                                                let tid = tab["id"] as? String ?? ""
                                                let title = (tab["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "新标签页"
                                                let isActive = tid == state.activeTabId
                                                HStack(spacing: 4) {
                                                    Button {
                                                        model.browserActivateTab(vm, tabId: tid)
                                                    } label: {
                                                        Text(title)
                                                            .lineLimit(1)
                                                            .truncationMode(.tail)
                                                            .frame(maxWidth: 100)
                                                    }
                                                    .buttonStyle(.plain)
                                                    if state.tabs.count > 1 {
                                                        Button {
                                                            model.browserCloseTab(vm, tabId: tid)
                                                        } label: {
                                                            Image(systemName: "xmark")
                                                                .font(.system(size: 9))
                                                                .foregroundStyle(.secondary)
                                                        }
                                                        .buttonStyle(.plain)
                                                    }
                                                }
                                                .font(.caption2)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(isActive ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
                                            }
                                            Button {
                                                model.browserNewTab(vm, url: "about:blank")
                                            } label: {
                                                Image(systemName: "plus")
                                                    .font(.caption2)
                                                    .padding(5)
                                                    .background(.primary.opacity(0.06), in: Circle())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }

                                Divider()

                                VStack(alignment: .leading, spacing: 5) {
                                    Text("画面模式")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Picker("", selection: Binding(
                                        get: { state.qualityMode },
                                        set: { model.setBrowserQuality(vm, qualityMode: $0) }
                                    )) {
                                        Text("流畅").tag("smooth")
                                        Text("均衡").tag("balanced")
                                        Text("高清").tag("sharp")
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                }

                                Toggle("自适应窗口分辨率", isOn: Binding(
                                    get: { state.autoResize },
                                    set: { model.setBrowserAutoResize(vm, enabled: $0) }
                                ))
                                .font(.caption)
                                .toggleStyle(.switch)
                                .controlSize(.small)

                                Divider()

                                HStack(spacing: 6) {
                                    Button {
                                        showControls = false
                                        model.browserOpenDownloads()
                                    } label: {
                                        Label("下载", systemImage: "folder")
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)

                                    Button {
                                        showControls = false
                                        model.browserReloadToken += 1
                                    } label: {
                                        Label("重连", systemImage: "arrow.clockwise")
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)

                                    Button {
                                        showControls = false
                                        model.restartLinuxBrowser(vm)
                                    } label: {
                                        Label("重启", systemImage: "power")
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)

                                    Button {
                                        showControls = false
                                        model.stopLinuxBrowser(vm)
                                    } label: {
                                        Label("休眠", systemImage: "moon.zzz")
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)

                                    Button {
                                        showLogs.toggle()
                                        if showLogs { model.browserFetchLogs(vm) }
                                    } label: {
                                        Label("日志", systemImage: "doc.text")
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(12)
                            .frame(width: 326)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.12)))
                            .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
                        }

                        if showIME {
                            HStack(spacing: 8) {
                                Image(systemName: "keyboard")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("输入中文，Enter 填入网页…", text: $imeText)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13))
                                    .focused($imeFocused)
                                    .onSubmit {
                                        let text = imeText
                                        guard !text.isEmpty else { return }
                                        imeText = ""
                                        model.browserInsertText(vm, text: text, tabId: state.activeTabId)
                                    }
                                Button {
                                    let text = imeText
                                    guard !text.isEmpty else { return }
                                    imeText = ""
                                    model.browserInsertText(vm, text: text, tabId: state.activeTabId)
                                } label: {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.system(size: 17))
                                }
                                .buttonStyle(.plain)
                                .disabled(imeText.isEmpty)

                                Button {
                                    showIME = false
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(width: min(360, max(240, slot.width - 32)))
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.45)))
                            .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
                        }

                        HStack(spacing: 4) {
                            Button {
                                if showAddressBar {
                                    showAddressBar = false
                                } else {
                                    openAddressBar()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "safari")
                                    Text("⌘L 地址")
                                }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(showAddressBar ? Color.accentColor.opacity(0.18) : Color.clear, in: Capsule())
                            }
                            .buttonStyle(.plain)

                            Divider()
                                .frame(height: 12)

                            Button {
                                showIME.toggle()
                                if showIME {
                                    showAddressBar = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        imeFocused = true
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "keyboard")
                                    Text("中文")
                                }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(showIME ? Color.accentColor.opacity(0.18) : Color.clear, in: Capsule())
                            }
                            .buttonStyle(.plain)

                            Divider()
                                .frame(height: 12)

                            Button {
                                showControls.toggle()
                                if showControls {
                                    showAddressBar = false
                                    urlText = state.activeURL
                                    model.browserInspect(vm)
                                } else {
                                    showLogs = false
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(model.displayName(for: vm))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .frame(maxWidth: 84)
                                    Image(systemName: "slider.horizontal.3")
                                }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(showControls ? Color.accentColor.opacity(0.18) : Color.clear, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.primary.opacity(0.12)))
                        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: slot.width, height: slot.height, alignment: .top)
        .offset(x: slot.minX, y: slot.minY)
        .onChange(of: model.browserFocusAddressNonce) { _ in
            openAddressBar()
        }
        .onChange(of: state.activeURL) { newURL in
            if !addressFocused {
                urlText = newURL
            }
        }
    }
}
