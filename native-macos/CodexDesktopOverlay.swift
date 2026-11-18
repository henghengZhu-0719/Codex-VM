import SwiftUI

struct CodexDesktopFloatingOverlay: View {
    @ObservedObject var model: Model
    let vm: VM
    let slot: CGRect

    @State private var showControls = false
    @State private var showIME = false
    @State private var showLogs = false
    @State private var imeText = ""
    @FocusState private var imeFocused: Bool

    private var state: CodexDesktopState {
        model.codexDesktops[vm.name] ?? CodexDesktopState()
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
                .allowsHitTesting(false)

            VStack(alignment: .trailing, spacing: 8) {
                if showLogs {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("运行日志")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Button {
                                model.codexDesktopFetchLogs(vm)
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
                                    if !state.appVersion.isEmpty {
                                        Text("v\(state.appVersion)")
                                    }
                                    if !state.resolution.isEmpty {
                                        Text("· \(state.resolution)")
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("切换") {
                                showControls = false
                                model.requestCodexDesktopPicker()
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 5) {
                            Text("画面清晰度")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("", selection: Binding(
                                get: { state.qualityMode },
                                set: { model.setCodexDesktopQuality(vm, qualityMode: $0) }
                            )) {
                                Text("高清").tag("sharp")
                                Text("均衡").tag("balanced")
                                Text("流畅").tag("smooth")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        Toggle("自适应窗口分辨率", isOn: Binding(
                            get: { state.autoResize },
                            set: { model.setCodexDesktopAutoResize(vm, enabled: $0) }
                        ))
                        .font(.caption)
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        Divider()

                        HStack(spacing: 6) {
                            Button {
                                showControls = false
                                model.restartCodexDesktop(vm)
                            } label: {
                                Label("重启", systemImage: "power")
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)

                            Button {
                                showControls = false
                                model.stopCodexDesktop(vm)
                            } label: {
                                Label("休眠", systemImage: "moon.zzz")
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)

                            Button {
                                showControls = false
                                model.codexDesktopReloadToken += 1
                            } label: {
                                Label("重连", systemImage: "arrow.clockwise")
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)

                            Button {
                                showLogs.toggle()
                                if showLogs { model.codexDesktopFetchLogs(vm) }
                            } label: {
                                Label("日志", systemImage: "doc.text")
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(12)
                    .frame(width: 296)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.12)))
                    .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
                }

                if showIME {
                    HStack(spacing: 8) {
                        Image(systemName: "keyboard")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("输入中文，按 Enter 直接粘贴到 Codex…", text: $imeText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .focused($imeFocused)
                            .onSubmit {
                                let text = imeText
                                guard !text.isEmpty else { return }
                                imeText = ""
                                model.codexDesktopSendText(vm, text: text)
                            }
                        Button {
                            let text = imeText
                            guard !text.isEmpty else { return }
                            imeText = ""
                            model.codexDesktopSendText(vm, text: text)
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

                // Compact floating capsule
                HStack(spacing: 4) {
                    Button {
                        showIME.toggle()
                        if showIME {
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
                        if !showControls { showLogs = false }
                    } label: {
                        HStack(spacing: 4) {
                            Text(model.displayName(for: vm))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 92)
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
        .frame(width: slot.width, height: slot.height, alignment: .bottomTrailing)
        .offset(x: slot.minX, y: slot.minY)
    }
}
