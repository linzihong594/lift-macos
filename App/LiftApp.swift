import SwiftUI
import AppKit
import Darwin
import Combine

func processMemory(_ pid: Int32) -> UInt64? {
    var usage = rusage_info_v2()
    let result = withUnsafeMutablePointer(to: &usage) {
        proc_pid_rusage(pid, RUSAGE_INFO_V2, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
    }
    return result == 0 ? usage.ri_phys_footprint : nil
}

@MainActor final class LiftModel: ObservableObject {
    @Published var state: LiftState?
    @Published var running = false
    @Published var busy = false
    @Published var memory: UInt64?
    @Published var error: String?
    @Published var showingHelp = false
    private var icons: [String: NSImage] = [:]

    func refresh() {
        state = LiftState.load(from: LiftPaths.support)
        running = ServiceControl.running(state)
        memory = running ? state.flatMap { processMemory($0.pid) } : nil
        let visible = Set((state?.completed ?? []).compactMap { ($0.cachedIconURL() ?? $0.installedURL())?.path })
        icons = icons.filter { visible.contains($0.key) }
    }

    func icon(for item: LiftCompletion) -> NSImage? {
        guard let url = item.cachedIconURL() ?? item.installedURL() else { return nil }
        if let cached = icons[url.path] { return cached }
        let icon: NSImage
        if url.pathExtension.lowercased() != "app", let stored = NSImage(contentsOf: url) { icon = stored }
        else { icon = NSWorkspace.shared.icon(forFile: url.path) }
        icons[url.path] = icon
        return icon
    }

    func setEnabled(_ value: Bool) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                try await Task.detached(priority: .utility) { try ServiceControl.setEnabled(value) }.value
                try? await Task.sleep(for: .milliseconds(700))
                refresh()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    var memoryText: String {
        guard let memory else { return "—" }
        return String(format: "%.1f MB", Double(memory) / 1_048_576)
    }
}

struct LiftCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 1))
            .shadow(color: .black.opacity(0.035), radius: 12, x: 0, y: 5)
    }
}

struct LiftView: View {
    @StateObject private var model = LiftModel()
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    private let teal = Color(red: 0.12, green: 0.55, blue: 0.50)

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [teal.opacity(0.095), .clear, Color.blue.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 15) {
                    Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 66, height: 66)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("轻退").font(.system(size: 29, weight: .semibold))
                            Text("LIFT").font(.system(size: 11, weight: .medium)).tracking(3).foregroundStyle(.secondary)
                        }
                        Text("安装完成，自动弹出。").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.showingHelp = true } label: {
                        Image(systemName: "questionmark.circle").font(.system(size: 19)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain).help("使用说明").accessibilityLabel("使用说明")
                }

                LiftCard {
                    HStack(spacing: 14) {
                        Image(systemName: model.running ? "checkmark" : "pause.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(model.running ? teal : .secondary)
                            .frame(width: 43, height: 43)
                            .background((model.running ? teal : .gray).opacity(0.10), in: Circle())
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.running ? "自动弹出已开启" : "自动弹出已暂停").font(.system(size: 15, weight: .semibold))
                            Text(model.running ? "确认复制完整后，轻轻收起安装盘。" : "安装盘会保留挂载，直到你手动弹出。")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 10)
                        if model.busy { ProgressView().controlSize(.small) }
                        Toggle("自动弹出", isOn: Binding(get: { model.running }, set: { model.setEnabled($0) }))
                            .labelsHidden().toggleStyle(.switch).tint(teal).disabled(model.busy)
                            .accessibilityLabel("自动弹出")
                    }
                }

                HStack(spacing: 0) {
                    metric("后台内存", value: model.memoryText, icon: "memorychip")
                    Divider().frame(height: 35).padding(.horizontal, 10)
                    metric("正在留意", value: "\(model.running ? (model.state?.monitoring.count ?? 0) : 0) 个安装盘", icon: "externaldrive")
                    Divider().frame(height: 35).padding(.horizontal, 10)
                    metric("累计弹出", value: "\(model.state?.total ?? 0) 次", icon: "eject")
                }.padding(.horizontal, 8).padding(.vertical, 5)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if model.running, let volumes = model.state?.monitoring, !volumes.isEmpty {
                            sectionLabel("正在留意")
                            ForEach(volumes.prefix(3)) { volume in
                                HStack(spacing: 12) {
                                    Image(systemName: "externaldrive").font(.system(size: 20)).foregroundStyle(teal)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(volume.app).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(volume.preparing ? "已核对完整，准备弹出" : "等待复制完成").font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            Divider().padding(.vertical, 3)
                        }
                        sectionLabel("最近完成")
                        if let completed = model.state?.completed, !completed.isEmpty {
                            ForEach(completed) { item in
                                HStack(spacing: 12) {
                                    if let icon = model.icon(for: item) {
                                        Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
                                            .frame(width: 36, height: 36).accessibilityLabel(item.app + " 应用图标")
                                    } else {
                                        Image(systemName: "app.fill").font(.system(size: 21)).foregroundStyle(teal.opacity(0.65))
                                            .frame(width: 36, height: 36).background(teal.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.app).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(item.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                            .font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(teal)
                                }
                            }
                        } else {
                            VStack(spacing: 10) {
                                Image(systemName: "externaldrive.badge.checkmark").font(.system(size: 30, weight: .light)).foregroundStyle(teal.opacity(0.65))
                                Text("下一次安装完成后，记录会出现在这里。")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity).padding(.vertical, 30)
                        }
                    }.padding(20)
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.22), lineWidth: 1))

                VStack(alignment: .leading, spacing: 7) {
                    Label("保留安装包 · 磁盘忙时等待", systemImage: "checkmark.shield")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(model.running ? "关闭此窗口后，自动弹出仍会继续。" : "暂停状态会保留，重新开启后才会自动弹出。")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }.padding(.horizontal, 4)
            }.padding(28).padding(.top, 18)
        }
        .frame(width: 600, height: 700)
        .onAppear { model.refresh() }
        .onReceive(timer) { _ in model.refresh() }
        .sheet(isPresented: $model.showingHelp) { help }
        .alert("未能更改自动弹出状态", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            if ServiceControl.requiresApproval {
                Button("打开登录项设置") { ServiceControl.openSettings() }
            }
            Button("好", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    func metric(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .medium, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }

    var help: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("让安装，轻轻收尾。").font(.system(size: 23, weight: .semibold))
            Text("照常打开 DMG，把应用拖到“应用程序”。轻退会核对文件是否完整，通常在复制结束后约 2–5 秒弹出安装盘。大型应用还需要额外的核对时间。")
            Label("仅自动处理普通的单应用、只读 DMG。", systemImage: "app.badge.checkmark")
            Label("安装器、多应用或无法确认完成的情况，请手动弹出。", systemImage: "hand.raised")
            Label("不删除安装包，不强制弹出，也不结束其他进程。", systemImage: "checkmark.shield")
            Divider()
            Text("主开关同时控制后台运行和登录启动。关闭管理窗口不会停止后台服务；暂停后，重启电脑也保持暂停。界面的“后台内存”只统计自动弹出服务。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack { Spacer(); Button("知道了") { model.showingHelp = false }.keyboardShortcut(.defaultAction) }
        }.font(.system(size: 12)).padding(30).frame(width: 440)
    }
}

final class LiftAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct LiftApp: App {
    init() {
        let arguments = CommandLine.arguments
        if arguments.count == 3 && arguments[1] == "--background" {
            do {
                switch arguments[2] {
                case "status": break
                case "enable": try ServiceControl.setEnabled(true)
                case "disable": try ServiceControl.setEnabled(false)
                default: exit(2)
                }
                print(ServiceControl.statusName)
                exit(0)
            } catch {
                fputs(error.localizedDescription + "\n", stderr)
                exit(1)
            }
        }
    }
    @NSApplicationDelegateAdaptor(LiftAppDelegate.self) private var delegate
    var body: some Scene {
        Window("轻退", id: "main") { LiftView() }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
            .defaultPosition(.center)
    }
}
