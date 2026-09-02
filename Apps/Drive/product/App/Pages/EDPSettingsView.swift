import AppKit
import ServiceManagement
import SwiftUI

struct EDPSettingsView: View {
    @ObservedObject var model: EDPVaultViewModel
    @State private var showingDiagnostics = false
    @State private var loginItemEnabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EDPTheme.Spacing.lg) {
                EDPSectionHeader(
                    "常规",
                    subtitle: "EDP Drive 的全局行为",
                    systemImage: "switch.2"
                )
                EDPContentCard(padding: 0) {
                    VStack(spacing: 0) {
                        settingsToggleRow(
                            title: "全局自动挂载",
                            subtitle: "允许已配置设备按各分区策略自动挂载",
                            isOn: Binding(
                                get: { model.snapshot.globalAutoMountEnabled },
                                set: { model.setGlobalAutoMount($0) }
                            )
                        )
                        Divider().padding(.leading, 48)
                        settingsToggleRow(
                            title: "登录时启动 EDP Drive",
                            subtitle: "登录后启动菜单栏界面，不改变后台服务策略",
                            isOn: Binding(
                                get: { loginItemEnabled },
                                set: { updateLoginItem($0) }
                            )
                        )
                    }
                }

                EDPSectionHeader(
                    "新设备默认设置",
                    subtitle: "新识别的 EDP U 盘会继承这里的三类分区策略；已有设备不会被随后修改的默认值覆盖",
                    systemImage: "externaldrive.badge.plus"
                )
                VStack(spacing: EDPTheme.Spacing.sm) {
                    ForEach(model.snapshot.partitionDefaults.sorted { $0.partitionType < $1.partitionType }) { defaults in
                        EDPDefaultPartitionSettingsCard(defaults: defaults, model: model)
                    }
                }

                EDPSectionHeader(
                    "系统集成",
                    subtitle: "磁盘访问、Raw Access 与 macFUSE Local",
                    systemImage: "externaldrive.connected.to.line.below"
                )
                EDPContentCard(padding: 16) {
                    VStack(spacing: 12) {
                        settingsStatusRow(
                            title: "完全磁盘访问",
                            value: model.rawAccessStatusText,
                            ready: !model.needsFullDiskAccess
                        )
                        Divider()
                        settingsStatusRow(
                            title: "Raw Access",
                            value: model.snapshot.devices.contains { $0.connected && $0.privilegedAccessReady }
                                ? "已就绪" : (model.needsFullDiskAccess ? "需要授权" : "等待设备验证"),
                            ready: model.snapshot.devices.contains { $0.connected && $0.privilegedAccessReady }
                        )
                        Divider()
                        settingsStatusRow(
                            title: "macFUSE Local",
                            value: model.transportRuntimeReady == true ? "已就绪" : "需要重新安装",
                            ready: model.transportRuntimeReady == true
                        )
                        Divider()
                        Text(setupDescription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            Button("打开系统设置") { model.openFullDiskAccessSettings() }
                                .buttonStyle(.glass)
                            Button("重新检测权限") { model.refreshRawAccess() }
                                .buttonStyle(.glassProminent)
                                .disabled(model.isBusy)
                            Button("显示组件") { model.revealRawAccessHelper() }
                                .buttonStyle(.glass)
                            Spacer()
                        }
                    }
                }

                EDPSectionHeader(
                    "后台服务",
                    subtitle: "特权服务状态与生命周期",
                    systemImage: "gearshape.2"
                )
                EDPContentCard(padding: 16) {
                    VStack(spacing: 12) {
                        settingsStatusRow(
                            title: "状态",
                            value: model.serviceStatus,
                            ready: model.serviceStatus == "运行中"
                        )
                        Divider()
                        LabeledContent("版本", value: model.snapshot.serviceVersion)
                        HStack(spacing: 8) {
                            Button("启动") { model.startService() }
                                .buttonStyle(.glassProminent)
                                .disabled(model.isBusy || model.serviceStatus == "运行中")
                            Button("停止") { model.stopService() }
                                .buttonStyle(.glass)
                                .disabled(model.isBusy || model.serviceStatus == "已停止")
                            Button("重启") { model.restartService() }
                                .buttonStyle(.glass)
                                .disabled(model.isBusy || model.serviceStatus != "运行中")
                            Spacer()
                            if model.serviceStatus == "需要系统批准" {
                                Button("打开登录项与扩展设置") { model.openServiceSettings() }
                                    .buttonStyle(.glass)
                            }
                        }
                    }
                }

                EDPSectionHeader(
                    "高级",
                    subtitle: "诊断和低频维护工具",
                    systemImage: "wrench.and.screwdriver"
                )
                EDPContentCard(padding: 16) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("诊断信息")
                                .font(.headline)
                            Text("查看服务、设备、挂载和运行组件诊断输出")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("查看诊断") {
                            model.diagnostics = ""
                            model.loadDiagnostics()
                            showingDiagnostics = true
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .padding(EDPTheme.Spacing.lg)
        }
        .navigationTitle("设置")
        .sheet(isPresented: $showingDiagnostics) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("诊断信息")
                        .font(.headline)
                    Spacer()
                    Button("复制诊断") { copyDiagnostics() }
                        .buttonStyle(.glass)
                        .disabled(model.diagnostics.isEmpty)
                    Button("关闭") { showingDiagnostics = false }
                        .buttonStyle(.glassProminent)
                }
                Divider()
                ScrollView {
                    Text(model.diagnostics.isEmpty ? "正在读取…" : model.diagnostics)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .frame(width: 680, height: 460)
            .background { EDPWindowBackdrop() }
        }
    }

    private var setupDescription: String {
        if model.setupReady {
            return "系统集成已就绪。后台服务按需打开经校验的 EDP 整盘；App、Mac 重启或重新插盘不需要重复管理员授权。"
        }
        if model.needsFullDiskAccess {
            return "请为 EDP Drive 磁盘访问组件开启一次完全磁盘访问，然后重新检测权限。"
        }
        return "完全磁盘访问会在连接标准 EDP 加密盘后进行验证；macFUSE Local 必须保持可用。"
    }

    @ViewBuilder
    private func settingsToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private func settingsStatusRow(title: String, value: String, ready: Bool) -> some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer()
            Circle()
                .fill(ready ? Color.green : Color.secondary.opacity(0.65))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(value)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.diagnostics, forType: .string)
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginItemEnabled = enabled
        } catch {
            model.lastError = "登录项更新失败：\(error.localizedDescription)"
            loginItemEnabled = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct EDPDefaultPartitionSettingsCard: View {
    let defaults: EDPXPCPartitionDefault
    @ObservedObject var model: EDPVaultViewModel
    @State private var password = ""

    private var kind: EDPPartitionKind? {
        EDPPartitionKind(rawValue: defaults.partitionType)
    }

    private var icon: String {
        switch kind {
        case .boot: return "externaldrive"
        case .exchange: return "arrow.left.arrow.right.square"
        case .secure: return "lock.square"
        case nil: return "externaldrive.badge.questionmark"
        }
    }

    private var summary: String {
        guard kind?.isEncrypted == true else {
            return "无需密码；是否自动挂载完全由用户配置"
        }
        let probe = defaults.autoProbePassword ? "自动探测密码" : "不自动探测密码"
        let mount = defaults.autoMount ? "自动挂载" : "不自动挂载"
        return "\(probe) · \(mount)"
    }

    var body: some View {
        EDPContentCard(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(defaults.displayName)
                            .font(.headline)
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Divider()

                settingsToggle(
                    title: "新设备默认自动挂载",
                    subtitle: "只有打开后，新识别设备的这个分区才会自动挂载",
                    isOn: Binding(
                        get: { defaults.autoMount },
                        set: { model.setDefaultAutoMount(partitionType: defaults.partitionType, enabled: $0) }
                    )
                )

                if kind?.isEncrypted == true {
                    Divider()
                    settingsToggle(
                        title: "新设备自动探测密码",
                        subtitle: "仅验证并保存凭据，不会绕过上面的自动挂载开关",
                        isOn: Binding(
                            get: { defaults.autoProbePassword },
                            set: {
                                model.setDefaultAutoProbePassword(
                                    partitionType: defaults.partitionType,
                                    enabled: $0
                                )
                            }
                        )
                    )

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("默认探测密码")
                                Text(
                                    defaults.defaultProbePasswordCustomized
                                        ? "当前使用自定义密码，明文只保存在系统钥匙串"
                                        : "当前使用内置默认值 0000aaaa"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        HStack(spacing: 8) {
                            SecureField("输入新的默认探测密码", text: $password)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 320)
                            Button("保存") {
                                model.setDefaultProbePassword(
                                    partitionType: defaults.partitionType,
                                    password: password
                                )
                                password = ""
                            }
                            .buttonStyle(.glassProminent)
                            .disabled(password.isEmpty || model.isBusy)
                            Button("恢复 0000aaaa") {
                                password = ""
                                model.resetDefaultProbePassword(partitionType: defaults.partitionType)
                            }
                            .buttonStyle(.glass)
                            .disabled(!defaults.defaultProbePasswordCustomized || model.isBusy)
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    private func settingsToggle(
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(model.isBusy)
        }
    }
}
