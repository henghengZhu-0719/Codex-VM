import SwiftUI
import AppKit

struct ProxyNodeItem: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
}

struct ProxySkippedItem: Decodable, Identifiable {
    let index: Int
    let name: String?
    let type: String?
    let reason: String
    var id: String { "\(index)-\(name ?? "")" }
}

struct ProxySourceItem: Decodable, Identifiable {
    let id: String
    let name: String
    let remote: Bool
    let host: String?
    let intervalHours: Int
    let updatedAt: String
    let error: String?
    let usage: String?
    let nodes: [ProxyNodeItem]?
    let skipped: [ProxySkippedItem]?

    enum CodingKeys: String, CodingKey {
        case id, name, remote, host, error, usage, nodes, skipped
        case intervalHours = "interval_hours"
        case updatedAt = "updated_at"
    }

    var safeNodes: [ProxyNodeItem] { nodes ?? [] }
    var safeSkipped: [ProxySkippedItem] { skipped ?? [] }
}

struct GateInstanceItem: Decodable, Identifiable {
    let dir: String
    let socket: String
    let state: String
    let epoch: UInt64
    let error: String?
    var id: String { dir }
}

struct SafetyCheckItem: Decodable, Identifiable {
    let id: String
    let state: String
    let evidence: String
    let checkedAt: String

    enum CodingKeys: String, CodingKey {
        case id, state, evidence
        case checkedAt = "checked_at"
    }
}

struct SafetyReportItem: Decodable {
    let policy: String
    let runId: String
    let configuration: String
    let checkEpoch: UInt64
    let createdAt: String
    let checks: [SafetyCheckItem]?

    enum CodingKeys: String, CodingKey {
        case policy, configuration, checks
        case runId = "run_id"
        case checkEpoch = "check_epoch"
        case createdAt = "created_at"
    }

    var safeChecks: [SafetyCheckItem] { checks ?? [] }
}

struct ProbeResultItem: Decodable {
    let checkedAt: String
    let proxyUrl: String
    let dnsUrl: String
    let exitIp: String?
    let exitIpError: String?
    let gateTriggered: Bool
    let report: SafetyReportItem?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case report, error
        case checkedAt = "checked_at"
        case proxyUrl = "proxy_url"
        case dnsUrl = "dns_url"
        case exitIp = "exit_ip"
        case exitIpError = "exit_ip_error"
        case gateTriggered = "gate_triggered"
    }
}

struct ProxyStatusResponse: Decodable {
    let proxyMode: String
    let managedEnabled: Bool
    let useProxy: Bool
    let customProxyUrl: String
    let displayProxyUrl: String
    let managedConfigPath: String
    let dnsUrl: String
    let bootstrapDns: [String]?
    let port: Int
    let selected: String
    let route: [String]?
    let routeError: String?
    let running: Bool
    let coreAvailable: Bool
    let corePath: String?
    let coreVersion: String?
    let sources: [ProxySourceItem]?
    let gates: [GateInstanceItem]?
    let lastProbe: ProbeResultItem?

    enum CodingKeys: String, CodingKey {
        case port, selected, route, running, sources, gates
        case proxyMode = "proxy_mode"
        case managedEnabled = "managed_enabled"
        case useProxy = "use_proxy"
        case customProxyUrl = "custom_proxy_url"
        case displayProxyUrl = "display_proxy_url"
        case managedConfigPath = "managed_config_path"
        case dnsUrl = "dns_url"
        case bootstrapDns = "bootstrap_dns"
        case routeError = "route_error"
        case coreAvailable = "core_available"
        case corePath = "core_path"
        case coreVersion = "core_version"
        case lastProbe = "last_probe"
    }

    var safeRoute: [String] { route ?? [] }
    var safeSources: [ProxySourceItem] { sources ?? [] }
    var safeGates: [GateInstanceItem] { gates ?? [] }
    var safeBootstrapDns: [String] { bootstrapDns ?? [] }
}

struct ProxyConnectionItem: Decodable, Identifiable {
    let id: String
    let host: String
    let port: String
    let network: String
    let upload: Int64
    let download: Int64
}

struct ConnectionsSnapshotItem: Decodable {
    let uploadTotal: Int64
    let downloadTotal: Int64
    let connections: [ProxyConnectionItem]?

    enum CodingKeys: String, CodingKey {
        case connections
        case uploadTotal = "upload_total"
        case downloadTotal = "download_total"
    }
}

struct ProxyDelayResponse: Decodable {
    let delays: [String: Int]?
    let errors: [String: String]?
}

struct FlatProxyNode: Identifiable {
    let node: ProxyNodeItem
    let sourceID: String
    let sourceName: String
    var id: String { node.id }
}

private enum ProxyTab: String, CaseIterable, Identifiable {
    case gateway, sources, route, security, gate, diagnostics
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gateway: return "1 代理方式"
        case .sources: return "2 节点来源"
        case .route: return "3 出口链路"
        case .security: return "4 DNS 与安全"
        case .gate: return "5 自检"
        case .diagnostics: return "连接监控"
        }
    }
}

struct ProxyGatewayView: View {
    @ObservedObject var model: Model
    @State private var tab: ProxyTab = .gateway

    // Gateway form state
    @State private var proxyMode = "custom"
    @State private var useProxy = true
    @State private var managedEnabled = false
    @State private var customProxyURL = "http://10.126.126.1:8787"
    @State private var dnsURL = "https://1.1.1.1/dns-query"
    @State private var mihomoPort = "17896"
    @State private var routeDraft: [String]? = nil
    @State private var nodeSearch = ""
    @State private var filterSourceID = ""

    // Import form state
    @State private var importMode = "url" // "url" | "yaml"
    @State private var importName = ""
    @State private var importURL = ""
    @State private var importYAML = ""
    @State private var importInterval = 24
    @State private var importHostDownload = true

    // Manual node form state
    @State private var manualType = "socks5"
    @State private var manualName = ""
    @State private var manualServer = ""
    @State private var manualPort = "1080"
    @State private var manualUser = ""
    @State private var manualPass = ""
    @State private var manualUUID = ""
    @State private var manualCipher = "aes-256-gcm"
    @State private var manualSNI = ""
    @State private var manualTLS = false
    @State private var manualSkipCert = false
    @State private var expandedSkipped: Set<String> = []

    private var status: ProxyStatusResponse? { model.proxyStatus }

    private var allNodes: [FlatProxyNode] {
        (status?.safeSources ?? []).flatMap { src in
            src.safeNodes.map { FlatProxyNode(node: $0, sourceID: src.id, sourceName: src.name) }
        }
    }

    private var filteredNodes: [FlatProxyNode] {
        let q = nodeSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allNodes.filter { item in
            if !filterSourceID.isEmpty && item.sourceID != filterSourceID { return false }
            if q.isEmpty { return true }
            return item.node.name.lowercased().contains(q)
                || item.node.type.lowercased().contains(q)
                || item.sourceName.lowercased().contains(q)
        }
    }

    private var savedRoute: [String] {
        if let r = status?.safeRoute, !r.isEmpty { return r }
        if let sel = status?.selected, !sel.isEmpty { return [sel] }
        return []
    }

    private var activeRoute: [String] {
        if let routeDraft, !routeDraft.isEmpty { return routeDraft }
        if !savedRoute.isEmpty { return savedRoute }
        return [""]
    }

    private var routeValid: Bool {
        let r = activeRoute
        guard !r.isEmpty else { return false }
        if Set(r).count != r.count { return false }
        let ids = Set(allNodes.map(\.id))
        return r.allSatisfy { !$0.isEmpty && ids.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerBar
            statusBanner
            Picker("", selection: $tab) {
                ForEach(ProxyTab.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            if !model.proxyError.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(model.proxyError).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else if !model.proxyMessage.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
                    Text(model.proxyMessage).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }

            switch tab {
            case .gateway:
                gatewayTab
            case .sources:
                sourcesTab
                if proxyMode != "mihomo" || !useProxy {
                    Text("当前不使用 Mihomo 节点。可返回代理方式，或直接继续 DNS 与安全配置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("上一步：代理方式") { tab = .gateway }
                    Spacer()
                    Button("下一步：选择出口") { tab = .route }
                        .disabled(allNodes.isEmpty || proxyMode != "mihomo" || !useProxy)
                }
            case .route:
                routeTab
            case .security:
                securityTab
            case .gate:
                gateTab
            case .diagnostics:
                diagnosticsTab
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            syncFieldsFromStatus()
            model.refreshProxyStatus { syncFieldsFromStatus() }
        }
        .onChange(of: tab) { next in
            if next == .diagnostics {
                model.refreshConnections()
            } else if next == .gate {
                model.refreshProxyStatus()
            }
        }
    }

    private var headerBar: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("代理与门禁").font(.largeTitle.bold())
                Text("管理 Egress 代理出口、代理内 DoH 解析、Mihomo 节点链路与 Fail-Closed 连接门禁。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.proxyBusy { ProgressView().controlSize(.small) }
            Button {
                model.refreshProxyStatus { syncFieldsFromStatus() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(model.proxyBusy)
        }
    }

    // This overview intentionally uses persisted status, not unsaved form fields.
    private var statusBanner: some View {
        let st = status
        let enabled = st?.useProxy ?? false
        let mode = st?.proxyMode ?? "custom"
        let route = st?.safeRoute ?? []
        let sourceNodes = (st?.safeSources ?? []).flatMap { $0.safeNodes }
        let routeNames = route.map { id in sourceNodes.first(where: { $0.id == id })?.name ?? id }
        let routeText = routeNames.isEmpty ? "尚未选择出口节点" : routeNames.joined(separator: " → ")
        let gateStates = st?.safeGates ?? []
        let gateText: String = {
            if st == nil { return "正在读取" }
            if !enabled { return "代理已关闭" }
            if st?.managedEnabled != true { return "未启用托管门禁" }
            if gateStates.isEmpty { return "已配置 · 尚无运行中的托管 VM" }
            return gateStates.map { $0.state.uppercased() }.joined(separator: " / ")
        }()
        let checks = st?.lastProbe?.report?.safeChecks ?? []
        let hasFailed = checks.contains { $0.state == "failed" }
        let hasUnknown = checks.contains { $0.state != "passed" }
        let checkText: String = {
            guard let probe = st?.lastProbe else { return "尚未执行自检" }
            if hasFailed { return "有失败项 · 请查看报告" }
            if !checks.isEmpty && !hasUnknown && probe.error == nil { return "上次报告：全部已列检查通过" }
            if probe.error != nil { return "上次检查发生错误" }
            return "结果未完全确认"
        }()
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("当前配置总览").font(.headline)
                    Text("展示已经保存的配置。修改下方表单后，需保存才会更新这里。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("刷新状态", systemImage: "arrow.clockwise") {
                    model.refreshProxyStatus { syncFieldsFromStatus() }
                }
                .controlSize(.small)
                .disabled(model.proxyBusy)
            }
            if st == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取代理配置…").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    overviewItem("代理方式", symbol: "network", section: .gateway,
                                 value: !enabled ? "代理已关闭" : mode == "mihomo" ? "内置 Mihomo" : "自定义 HTTP / SOCKS5",
                                 detail: !enabled ? "新启动的虚拟机不使用代理" : mode == "mihomo" ? (st!.running ? "核心运行中" : "核心未运行") : st!.customProxyUrl)
                    overviewItem("节点与出口", symbol: "arrow.triangle.branch", section: mode == "mihomo" ? .route : .gateway,
                                 value: !enabled ? "未启用" : mode == "mihomo" ? (route.isEmpty ? "未配置节点链路" : "已配置 \(route.count) 跳") : "使用外部代理",
                                 detail: !enabled ? "—" : mode == "mihomo" ? routeText : st!.displayProxyUrl)
                    overviewItem("DNS 解析", symbol: "globe", section: .security,
                                 value: st!.dnsUrl.isEmpty ? "未配置 DoH" : "DoH 端点",
                                 detail: st!.dnsUrl.isEmpty ? "请设置 DNS 地址" : st!.dnsUrl)
                    overviewItem("网络门禁", symbol: "lock.shield", section: .security,
                                 value: gateText,
                                 detail: st!.managedEnabled && enabled ? "实验性 · 默认 Closed；未完成实机安全验证" : "不代表来宾流量已被强制隔离")
                    overviewItem("最近自检", symbol: "checkmark.shield", section: .gate,
                                 value: checkText,
                                 detail: st!.lastProbe?.checkedAt ?? "尚无测试记录")
                    overviewItem("探测出口 IP", symbol: "globe.americas", section: .gate,
                                 value: st!.lastProbe?.exitIp ?? "尚未测得",
                                 detail: "仅为上次探测结果，不保证当前连接出口相同")
                }
                HStack {
                    Text("可点击每项右侧的“配置”跳转到相应步骤。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("运行安全自检", systemImage: "checkmark.shield") {
                        tab = .gate
                        model.runGateProbe()
                    }
                    .disabled(model.proxyBusy || !enabled)
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
    }

    private func overviewItem(_ title: String, symbol: String, section: ProxyTab,
                              value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("配置") { tab = section }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
            Text(value).font(.subheadline.weight(.semibold))
                .lineLimit(2).textSelection(.enabled)
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)
                .help(detail).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }

    private var gatewayTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeading(1, "选择代理方式", "先确认使用哪一种出口方式，保存后再进行后续配置。")
            VStack(alignment: .leading, spacing: 14) {
                Picker("代理模式", selection: $proxyMode) {
                    Text("使用已有 HTTP / SOCKS5 代理").tag("custom")
                    Text("使用内置 Mihomo 节点").tag("mihomo")
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                Toggle("对新建或启动的虚拟机使用代理", isOn: $useProxy)
                if !useProxy {
                    Label("代理已关闭。保存后不再对新启动的虚拟机应用该出口。", systemImage: "info.circle")
                        .foregroundStyle(.secondary).font(.caption)
                } else if proxyMode == "custom" {
                    Text("代理服务器地址").font(.subheadline.weight(.semibold))
                    TextField("http://10.126.126.1:8787", text: $customProxyURL)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("10.126.126.1:8787") { customProxyURL = "http://10.126.126.1:8787" }
                        Button("127.0.0.1:7890") { customProxyURL = "http://127.0.0.1:7890" }
                    }.controlSize(.small)
                    Text("填写数字 IPv4 和端口，避免宿主机 DNS 查询引起泄漏。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Mihomo 本机监听端口").font(.subheadline.weight(.semibold))
                    TextField("17896", text: $mihomoPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                    Text("Mihomo 监听 127.0.0.1。下一步导入节点，然后配置出口。")
                        .font(.caption).foregroundStyle(.secondary)
                    if status?.coreAvailable == false {
                        Label("当前未检测到 Mihomo 核心，请在启动节点链路前安装。", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).font(.caption)
                    }
                }
                Divider()
                HStack {
                    Spacer()
                    Button("保存并继续") {
                        saveGatewayConfig {
                            tab = useProxy && proxyMode == "mihomo" ? .sources : .security
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.proxyBusy || (useProxy && proxyMode == "custom" && customProxyURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || (useProxy && proxyMode == "mihomo" && (Int(mihomoPort) ?? 0) <= 0))
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var routeTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeading(3, "选择出口节点", "选择最终出口，必要时添加中转；应用节点后会启动或重启 Mihomo。")
            if proxyMode != "mihomo" || !useProxy {
                Label("当前代理模式不需要配置 Mihomo 出口链路。请返回代理方式或继续 DNS 设置。", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            // Mihomo core, route chain, and node selection
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("选择节点和出口链路").font(.headline)
                        if let ver = status?.coreVersion, !ver.isEmpty {
                            Text(ver).font(.caption).foregroundStyle(.secondary)
                        } else if status?.coreAvailable == false {
                            Text("未检测到 mihomo 可执行文件（可放到 ~/.agent-vm/bin/mihomo 或重新构建 App）")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    if status?.running == true {
                        Button("停止核心") { model.stopProxyCore { syncFieldsFromStatus() } }
                            .disabled(model.proxyBusy)
                    }
                }

                if !allNodes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("代理链路编排（支持多跳中转）").font(.subheadline.weight(.semibold))
                        ForEach(Array(activeRoute.enumerated()), id: \.offset) { idx, hopID in
                            let isFinal = idx == activeRoute.count - 1
                            HStack(spacing: 8) {
                                Text(isFinal ? "最终出口" : "中转节点 \(idx + 1)")
                                    .font(.caption.weight(.medium))
                                    .frame(width: 72, alignment: .leading)
                                Picker("", selection: Binding(
                                    get: { hopID },
                                    set: { next in updateHop(index: idx, nodeID: next) }
                                )) {
                                    Text("请选择节点").tag("")
                                    ForEach(status?.safeSources ?? []) { src in
                                        ForEach(src.safeNodes) { n in
                                            Text("\(n.name) [\(src.name) · \(n.type.uppercased())]").tag(n.id)
                                        }
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 380)
                                if !isFinal {
                                    Button {
                                        var copy = activeRoute
                                        copy.remove(at: idx)
                                        routeDraft = copy
                                    } label: {
                                        Image(systemName: "xmark.circle")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                        HStack(spacing: 10) {
                            if allNodes.count > activeRoute.count {
                                Button("添加中转") {
                                    var copy = activeRoute
                                    copy.insert("", at: max(0, copy.count - 1))
                                    routeDraft = copy
                                }
                                .controlSize(.small)
                            }
                            if routeDraft != nil {
                                Button("撤销链修改") { routeDraft = nil }.controlSize(.small)
                            }
                            Spacer()
                            Button(status?.running == true && routeDraft == nil ? "重新应用并重启核心" : "应用节点并启动 Mihomo") {
                                let port = Int(mihomoPort) ?? 17896
                                model.applyProxyRoute(route: activeRoute, port: port) {
                                    routeDraft = nil
                                    syncFieldsFromStatus()
                                    if model.proxyError.isEmpty { tab = .security }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.proxyBusy || !routeValid || status?.coreAvailable != true || proxyMode != "mihomo" || !useProxy)
                        }
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                }

                HStack {
                    TextField("搜索节点名称、协议或来源", text: $nodeSearch)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                    Picker("来源", selection: $filterSourceID) {
                        Text("全部来源").tag("")
                        ForEach(status?.safeSources ?? []) { src in
                            Text(src.name).tag(src.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    Spacer()
                    Button {
                        model.measureDelay(nodeID: nil)
                    } label: {
                        Label("全部测速", systemImage: "speedometer")
                    }
                    .disabled(model.proxyBusy || status?.running != true || allNodes.isEmpty)
                    Button("管理节点来源") { tab = .sources }
                }

                if allNodes.isEmpty {
                    VStack(spacing: 8) {
                        Text("暂无代理节点").font(.headline)
                        Text("先在上一步导入订阅或添加节点，才能选择出口。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("返回添加节点") { tab = .sources }
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    VStack(spacing: 6) {
                        ForEach(filteredNodes) { item in
                            nodeRow(item)
                        }
                        if filteredNodes.isEmpty {
                            Text("没有符合筛选条件的节点。").font(.caption).foregroundStyle(.secondary).padding(.vertical, 12)
                        }
                    }
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))

            HStack {
                Button("上一步：管理节点") { tab = .sources }
                Spacer()
                Button("下一步：DNS 与安全") { tab = .security }
                    .disabled(!routeValid || status?.running != true)
            }
        }
    }

    private var securityTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeading(4, "DNS 与网络隔离", "先配置代理内 DNS，再选择隔离门禁。配置保存后进行出口和安全自检。")
            VStack(alignment: .leading, spacing: 14) {
                Text("代理内 DoH 解析").font(.subheadline.weight(.semibold))
                TextField("https://1.1.1.1/dns-query", text: $dnsURL)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 10) {
                    Button("Cloudflare") { dnsURL = "https://1.1.1.1/dns-query" }
                    Button("AliDNS") { dnsURL = "https://223.5.5.5/dns-query" }
                    Button("Google") { dnsURL = "https://8.8.8.8/dns-query" }
                }.controlSize(.small)
                Text("使用数字 IPv4 的 HTTPS DoH 地址，并填写 /dns-query 等完整路径；实际 DNS 解析由代理隧道承载。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("启用托管网络和 Fail-Closed 门禁（实验性）", isOn: $managedEnabled)
                    .disabled(!useProxy)
                Text("托管模式会启用 gVisor/Lima 强制转发、DoH 钩子和私有 Netgate。当前门禁默认 Closed，仅用于隔离联调；并不表示已经通过全部实机安全测试。")
                    .font(.caption).foregroundStyle(.secondary)
                if let path = status?.managedConfigPath, !path.isEmpty {
                    Text("托管配置：\(path)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Divider()
                HStack {
                    Button(proxyMode == "mihomo" && useProxy ? "上一步：节点链路" : "上一步：代理方式") {
                        tab = proxyMode == "mihomo" && useProxy ? .route : .gateway
                    }
                    Spacer()
                    Button("保存并进入安全自检") {
                        saveGatewayConfig { tab = .gate }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.proxyBusy || !dnsURL.hasPrefix("https://"))
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func stepHeading(_ index: Int, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("步骤 \(index) · \(title)").font(.title3.bold())
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func nodeRow(_ item: FlatProxyNode) -> some View {
        let isExit = activeRoute.last == item.id
        let isTransit = activeRoute.dropLast().contains(item.id)
        let delayText = model.nodeDelays[item.id] ?? "未测速"
        return HStack(spacing: 10) {
            Button {
                updateHop(index: max(0, activeRoute.count - 1), nodeID: item.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExit ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isExit ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.node.name).fontWeight(isExit ? .semibold : .regular)
                        Text("\(item.sourceName) · \(item.node.type.uppercased())")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isTransit)

            Spacer()
            if savedRoute.contains(item.id) && status?.proxyMode == "mihomo" {
                Text(item.id == status?.selected ? "当前出口" : "当前中转")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.green.opacity(0.15), in: Capsule())
                    .foregroundStyle(.green)
            } else if isTransit {
                Text("已作中转").font(.caption2).foregroundStyle(.secondary)
            }
            Text(delayText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(delayColor(delayText))
                .frame(width: 68, alignment: .trailing)
            Button {
                model.measureDelay(nodeID: item.id)
            } label: {
                Image(systemName: "waveform.path.ecg")
            }
            .controlSize(.small)
            .help("测速")
            .disabled(model.proxyBusy || status?.running != true)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background((isExit ? Color.green.opacity(0.07) : Color.primary.opacity(0.025)), in: RoundedRectangle(cornerRadius: 8))
    }

    private func delayColor(_ text: String) -> Color {
        if text.hasSuffix(" ms"), let v = Int(text.replacingOccurrences(of: " ms", with: "")) {
            if v < 180 { return .green }
            if v < 500 { return .orange }
            return .red
        }
        if text == "失败" || text == "超时" { return .red }
        return .secondary
    }

    private var sourcesTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeading(2, "导入节点来源", "选择订阅、YAML 文件或手动节点。导入成功后前往下一步选择出口。")
            // Import subscription / YAML
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("导入 Clash / Mihomo 订阅或配置").font(.headline)
                    Spacer()
                    Picker("", selection: $importMode) {
                        Text("HTTPS 订阅链接").tag("url")
                        Text("YAML 文本 / 文件").tag("yaml")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }
                HStack {
                    Text("来源名称").frame(width: 90, alignment: .leading)
                    TextField("例如：主力订阅", text: $importName).textFieldStyle(.roundedBorder)
                }
                if importMode == "url" {
                    HStack {
                        Text("订阅地址").frame(width: 90, alignment: .leading)
                        TextField("https://example.com/sub.yaml", text: $importURL).textFieldStyle(.roundedBorder)
                    }
                    HStack(spacing: 16) {
                        Stepper("更新间隔：\(importInterval) 小时", value: $importInterval, in: 0...168)
                        Toggle("通过主机环境代理下载订阅（推荐初次配置时勾选）", isOn: $importHostDownload)
                    }
                } else {
                    HStack {
                        Text("YAML 内容").frame(width: 90, alignment: .leading)
                        Button("从本地 YAML 文件读取…") { pickYAMLFile() }
                        Spacer()
                    }
                    TextEditor(text: $importYAML)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 120)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                }
                HStack {
                    Spacer()
                    Button("导入来源") {
                        model.importProxySource(
                            name: importName,
                            url: importMode == "url" ? importURL : "",
                            content: importMode == "yaml" ? importYAML : "",
                            interval: importInterval,
                            hostDownload: importHostDownload
                        ) {
                            importName = ""; importURL = ""; importYAML = ""
                            syncFieldsFromStatus()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.proxyBusy || importName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (importMode == "url" ? importURL.isEmpty : importYAML.isEmpty))
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))

            // Manual single node form
            VStack(alignment: .leading, spacing: 12) {
                Text("手动添加单个节点").font(.headline)
                HStack(spacing: 12) {
                    Picker("协议", selection: $manualType) {
                        ForEach(["socks5", "http", "ss", "vmess", "vless", "trojan", "hysteria2", "ssh"], id: \.self) { t in
                            Text(t.uppercased()).tag(t)
                        }
                    }.frame(width: 150)
                    TextField("节点名称", text: $manualName).textFieldStyle(.roundedBorder)
                    TextField("服务器地址 / IP", text: $manualServer).textFieldStyle(.roundedBorder)
                    TextField("端口", text: $manualPort).textFieldStyle(.roundedBorder).frame(width: 80)
                }
                HStack(spacing: 12) {
                    if manualType == "vmess" || manualType == "vless" {
                        TextField("UUID", text: $manualUUID).textFieldStyle(.roundedBorder)
                    } else {
                        TextField("用户名（可选）", text: $manualUser).textFieldStyle(.roundedBorder)
                    }
                    if manualType != "vless" {
                        SecureField("密码 / 密钥（可选）", text: $manualPass).textFieldStyle(.roundedBorder)
                    }
                    if manualType == "ss" || manualType == "vmess" {
                        TextField("加密方式", text: $manualCipher).textFieldStyle(.roundedBorder).frame(width: 150)
                    }
                    if ["http", "socks5", "vmess", "vless", "trojan", "hysteria2"].contains(manualType) {
                        TextField("SNI（可选）", text: $manualSNI).textFieldStyle(.roundedBorder).frame(width: 150)
                    }
                }
                HStack {
                    if ["http", "socks5", "vmess", "vless"].contains(manualType) {
                        Toggle("启用 TLS", isOn: $manualTLS)
                    }
                    if ["http", "socks5", "vmess", "vless", "trojan", "hysteria2"].contains(manualType) {
                        Toggle("跳过证书校验", isOn: $manualSkipCert)
                    }
                    Spacer()
                    Button("添加节点") {
                        model.addManualNode(
                            name: manualName,
                            type: manualType,
                            server: manualServer,
                            port: Int(manualPort) ?? 1080,
                            username: manualUser,
                            password: manualPass,
                            uuid: manualUUID,
                            cipher: manualCipher,
                            sni: manualSNI,
                            tls: manualTLS,
                            skipCertVerify: manualSkipCert
                        ) {
                            manualName = ""; manualServer = ""; manualPass = ""
                            syncFieldsFromStatus()
                        }
                    }
                    .disabled(model.proxyBusy || manualName.isEmpty || manualServer.isEmpty)
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))

            // Existing sources
            VStack(alignment: .leading, spacing: 10) {
                Text("已导入来源（\(status?.safeSources.count ?? 0)）").font(.headline)
                if let srcs = status?.safeSources, !srcs.isEmpty {
                    ForEach(srcs) { src in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(src.name).font(.subheadline.weight(.semibold))
                                    Text("\(src.remote ? (src.host ?? "远程订阅") : "本地导入") · \(src.safeNodes.count) 个节点\(src.usage?.isEmpty == false ? " · " + src.usage! : "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if src.remote {
                                    Button("刷新") {
                                        model.refreshSubscription(id: src.id, hostDownload: importHostDownload) { syncFieldsFromStatus() }
                                    }.controlSize(.small).disabled(model.proxyBusy)
                                }
                                Button("删除", role: .destructive) {
                                    model.deleteSource(id: src.id) { syncFieldsFromStatus() }
                                }.controlSize(.small).disabled(model.proxyBusy)
                            }
                            if let err = src.error, !err.isEmpty {
                                Text(err).font(.caption).foregroundStyle(.red)
                            }
                            if !src.safeSkipped.isEmpty {
                                DisclosureGroup("已跳过 \(src.safeSkipped.count) 个不兼容或不安全节点", isExpanded: Binding(
                                    get: { expandedSkipped.contains(src.id) },
                                    set: { on in if on { expandedSkipped.insert(src.id) } else { expandedSkipped.remove(src.id) } }
                                )) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        ForEach(src.safeSkipped) { issue in
                                            Text("#\(issue.index) \(issue.name ?? "") (\(issue.type ?? "-")): \(issue.reason)")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.top, 4)
                                }
                                .font(.caption)
                            }
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06)))
                    }
                } else {
                    Text("尚未导入任何订阅或手动节点。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var gateTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeading(5, "验证代理出口与安全边界", "先运行自检，再检查出口 IP、DNS 隧道和 Fail-Closed 结果；失败或 Unknown 不视为通过。")
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fail-Closed 连接门禁与安全自检").font(.headline)
                        Text("绑定到运行标识（RunID）、配置指纹与 Epoch；未实测的来宾隔离项目保持 Unknown，不会错误放行。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("撤销全部门禁 (Revoke)") {
                        model.closeGate()
                    }
                    .disabled(model.proxyBusy)
                    Button("运行网关与门禁自检") {
                        model.runGateProbe()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.proxyBusy)
                }

                Divider()

                Text("运行中的 HostAgent Netgate 实例（\(status?.safeGates.count ?? 0)）").font(.subheadline.weight(.semibold))
                if let gates = status?.safeGates, !gates.isEmpty {
                    ForEach(gates) { g in
                        HStack {
                            Text(g.dir).font(.caption.monospaced())
                            Text(g.state.uppercased())
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.blue.opacity(0.15), in: Capsule())
                            Text("Epoch \(g.epoch)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Spacer()
                            Text(g.socket).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                    }
                } else {
                    Text("当前没有处于托管模式并开启私有 Netgate Socket 的虚拟机进程；点击上方自检按钮仍可在宿主机执行离线隧道、DoH 与门禁闭态验证。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))

            if let probe = status?.lastProbe {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("最近一次自检报告").font(.headline)
                        Spacer()
                        Text(probe.gateTriggered ? "来源：HostAgent Netgate /check" : "来源：宿主机独立探测")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("探测出口 IP").font(.caption).foregroundStyle(.secondary)
                            Text(probe.exitIp ?? (probe.exitIpError ?? "未测出"))
                                .font(.callout.monospaced())
                                .foregroundStyle(probe.exitIp != nil ? .green : .orange)
                                .textSelection(.enabled)
                        }
                        if let rep = probe.report {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("RunID / Epoch").font(.caption).foregroundStyle(.secondary)
                                Text("\(rep.runId) · Epoch \(rep.checkEpoch)")
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("配置指纹 (SHA-256)").font(.caption).foregroundStyle(.secondary)
                                Text(String(rep.configuration.prefix(24)) + "…")
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }

                    if let checks = probe.report?.safeChecks, !checks.isEmpty {
                        Divider()
                        ForEach(checks) { c in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: c.state == "passed" ? "checkmark.circle.fill" : c.state == "failed" ? "xmark.circle.fill" : "questionmark.circle")
                                    .foregroundStyle(c.state == "passed" ? Color.green : c.state == "failed" ? Color.red : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(checkTitle(c.id)).font(.callout.weight(.medium))
                                        Text("(\(c.id))").font(.caption.monospaced()).foregroundStyle(.secondary)
                                        Spacer()
                                        Text(c.state.uppercased()).font(.caption2.weight(.semibold))
                                            .foregroundStyle(c.state == "passed" ? .green : c.state == "failed" ? .red : .secondary)
                                    }
                                    Text(c.evidence).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
            }
        }
    }

    private var diagnosticsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("托管网络边界策略").font(.headline)
                Text("• 客机公网 UDP、IPv6 与 ICMP：在托管模式下阻断（禁止旁路泄漏）").font(.caption)
                Text("• 业务域名解析：通过代理隧道内 DoH 端点（\(status?.dnsUrl ?? dnsURL)）执行，禁止混合 AAAA 查询回退").font(.caption)
                Text("• 基础设施引导 DoH：\((status?.safeBootstrapDns ?? []).joined(separator: "、"))（仅直连公网数值 IPv4，不使用系统 DNS）").font(.caption)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Mihomo 实时连接（\(model.proxyConnections.count)）").font(.headline)
                    Spacer()
                    Text("累计上传 \(formatBytes(model.proxyUploadTotal)) · 下载 \(formatBytes(model.proxyDownloadTotal))")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("刷新连接") { model.refreshConnections() }.controlSize(.small)
                }
                if model.proxyConnections.isEmpty {
                    Text(status?.running == true ? "当前无活动连接。" : "Mihomo 核心未运行。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.proxyConnections) { conn in
                        HStack {
                            Text("\(conn.host):\(conn.port)").font(.caption.monospaced()).textSelection(.enabled)
                            Text(conn.network.uppercased()).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text("↑ \(formatBytes(conn.upload))  ↓ \(formatBytes(conn.download))")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
        }
    }

    private func syncFieldsFromStatus() {
        guard let st = model.proxyStatus else { return }
        proxyMode = st.proxyMode
        useProxy = st.useProxy
        managedEnabled = st.managedEnabled
        customProxyURL = st.customProxyUrl
        dnsURL = st.dnsUrl
        mihomoPort = String(st.port)
    }

    private func saveGatewayConfig(onSuccess: (() -> Void)? = nil) {
        let portVal = Int(mihomoPort) ?? 17896
        model.saveProxyConfig(
            proxyMode: proxyMode,
            managedEnabled: managedEnabled && useProxy,
            useProxy: useProxy,
            customProxyURL: customProxyURL,
            dnsURL: dnsURL,
            port: portVal
        ) {
            syncFieldsFromStatus()
            if model.proxyError.isEmpty {
                onSuccess?()
            }
        }
    }

    private func updateHop(index: Int, nodeID: String) {
        var copy = activeRoute
        guard index < copy.count else { return }
        copy[index] = nodeID
        routeDraft = copy
    }

    private func pickYAMLFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url, let content = try? String(contentsOf: url, encoding: .utf8) {
            importYAML = content
            if importName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                importName = url.deletingPathExtension().lastPathComponent
            }
        }
    }

    private func checkTitle(_ id: String) -> String {
        switch id {
        case "proxy_transport": return "代理 TCP 隧道"
        case "dns_transport": return "代理内 DoH 解析"
        case "fail_closed": return "门禁 Fail-Closed"
        case "egress_policy": return "来宾出站策略"
        case "udp_policy": return "UDP 阻断策略"
        case "ipv6_policy": return "IPv6 阻断策略"
        case "host_boundary": return "宿主机隔离边界"
        case "exit_consistency": return "出口 IP 一致性"
        default: return id
        }
    }

    private func formatBytes(_ v: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, v), countStyle: .binary)
    }
}
