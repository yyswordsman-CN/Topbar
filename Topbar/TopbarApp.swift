// TopbarApp.swift
// Topbar — 刘海管理器 + 菜单栏图标聚合
//
// 功能:
//   1. 黑色覆盖层隐藏刘海
//   2. 扫描被刘海遮挡的菜单栏图标并在弹出面板中显示
//   3. 点击面板中的图标 → 转发到原始位置

import SwiftUI
import AppKit
import ServiceManagement

@main
struct TopbarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - Dark Panel (替代 NSPopover，从第一帧就是深色)

/// 自定义深色面板 — 模拟飞书/iStatMenus 等专业 App 的状态栏弹窗
@MainActor
final class DarkPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        // 点击面板外部时自动关闭
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = false
        appearance = NSAppearance(named: .darkAqua)

        setupVisualEffect()
    }

    private func setupVisualEffect() {
        let visualEffect = NSVisualEffectView(frame: contentRect(forFrameRect: frame))
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.material = .menu          // 最接近系统菜单的深色材质
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 12
        visualEffect.layer?.masksToBounds = true
        visualEffect.appearance = NSAppearance(named: .darkAqua)

        // 添加深色底层 — 降低透光率，让文字更清晰
        let darkLayer = CALayer()
        darkLayer.backgroundColor = NSColor(white: 0.12, alpha: 0.6).cgColor
        darkLayer.frame = visualEffect.bounds
        darkLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        visualEffect.layer?.insertSublayer(darkLayer, at: 0)

        contentView = visualEffect
    }

    // 点击面板外部自动关闭
    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        close()
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var panel: DarkPanel?
    let notchManager = NotchOverlayManager()
    let scanner = MenuBarScanner()
    let downloadMonitor = DownloadMonitor()
    let agentMonitor = AgentMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        downloadMonitor.start()
        agentMonitor.start()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "TopbarConsole"

        if let button = statusItem.button {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            let img = NSImage(
                systemSymbolName: "rectangle.inset.topleading.filled",
                accessibilityDescription: "Topbar"
            )?.withSymbolConfiguration(config)
            img?.isTemplate = true
            button.image = img
            button.target = self
            button.action = #selector(togglePanel(_:))
        }
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        if let existingPanel = panel, existingPanel.isVisible {
            existingPanel.close()
            panel = nil
            return
        }

        // 创建内容视图
        scanner.statusMessage = "扫描中..."
        let swiftUIView = ControlPanel(
            notchManager: notchManager,
            scanner: scanner,
            dismissAction: { [weak self] in
                self?.panel?.close()
                self?.panel = nil
            }
        )

        let hostingView = NSHostingView(rootView: swiftUIView)
        hostingView.appearance = NSAppearance(named: .darkAqua)

        // 计算面板尺寸和位置
        let panelWidth: CGFloat = 280
        let panelHeight: CGFloat = 450
        let panelRect = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let darkPanel = DarkPanel(contentRect: panelRect)

        // 把 SwiftUI 视图嵌入 VisualEffect contentView
        if let visualEffect = darkPanel.contentView {
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            visualEffect.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
                hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            ])
        }

        // 定位: 在 StatusItem 按钮正下方
        if let buttonWindow = sender.window {
            let buttonFrame = sender.convert(sender.bounds, to: nil)
            let screenFrame = buttonWindow.convertToScreen(buttonFrame)
            let x = screenFrame.midX - panelWidth / 2
            let y = screenFrame.minY - panelHeight - 4
            darkPanel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        darkPanel.makeKeyAndOrderFront(nil)
        panel = darkPanel

        // 异步扫描
        Task.detached { @MainActor [scanner] in
            scanner.scan()
        }
    }
}

// MARK: - Control Panel

struct ControlPanel: View {
    @Bindable var notchManager: NotchOverlayManager
    var scanner: MenuBarScanner
    var dismissAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider().opacity(0.3)
            VStack(spacing: 12) {
                hiddenItemsSection
                Divider().opacity(0.3)
                notchToggle
                Divider().opacity(0.3)
                notificationDemoSection
                Divider().opacity(0.3)
                bottomRow
            }
            .padding(14)
        }
        .frame(width: 280)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.inset.topleading.filled")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("Topbar").font(.system(size: 14, weight: .bold))
                Text("刘海管理器").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { scanner.scan() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("重新扫描")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Hidden Items

    @ViewBuilder
    private var hiddenItemsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("被遮挡的图标")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !scanner.hiddenItems.isEmpty {
                    Text("\(scanner.hiddenItems.count) 个")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            // 辅助功能权限提示
            if !scanner.hasAccessibilityPermission {
                accessibilityPrompt
            }

            if scanner.hiddenItems.isEmpty {
                statusBadge
            } else {
                itemGrid
            }
        }
    }

    private var accessibilityPrompt: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 11))
            Text("需要辅助功能权限获取真实应用名")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button("授权") {
                MenuBarScanner.requestAccessibility()
            }
            .controlSize(.mini)
            .buttonStyle(.bordered)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.orange.opacity(0.12)))
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            if let msg = scanner.statusMessage {
                if msg.hasPrefix("所有图标可见") {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12))
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 12))
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var itemGrid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(scanner.hiddenItems) { item in
                    itemButton(item)
                }
            }
        }
    }

    private func itemButton(_ item: MenuBarItem) -> some View {
        Button(action: {
            dismissAction()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                scanner.clickItem(item)
            }
        }) {
            VStack(spacing: 4) {
                Group {
                    if let icon = item.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                    } else {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 24, height: 24)

                Text(item.displayName)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 52)
            }
            .frame(width: 56, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(0.08))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(item.displayName) — 点击打开")
    }

    // MARK: - Notch Toggle

    private var notchToggle: some View {
        Toggle(isOn: Binding(
            get: { notchManager.isEnabled },
            set: { notchManager.isEnabled = $0 }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("隐藏刘海").font(.system(size: 13, weight: .medium))
                Text("黑色覆盖层融合 Notch 区域")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.regular)
    }

    // MARK: - Notification Demo

    private var notificationDemoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("通知演示")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                demoButton(icon: "arrow.down.circle.fill", label: "下载", color: .cyan) {
                    dismissAction()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        NotchNotificationManager.shared.showDownloadComplete(fileName: "设计稿_v3.fig")
                    }
                }

                demoButton(icon: "sparkles", label: "Agent", color: .purple) {
                    dismissAction()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        NotchNotificationManager.shared.showAgentComplete(taskName: "数据分析报告已生成")
                    }
                }

                demoButton(icon: "checkmark.circle.fill", label: "成功", color: .green) {
                    dismissAction()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        NotchNotificationManager.shared.showSuccess(title: "已保存", subtitle: "文件已同步至云端")
                    }
                }
            }
        }
    }

    private func demoButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom

    private var bottomRow: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { e in try? e ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
            )) {
                Text("开机自启").font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Spacer()

            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.system(size: 9, weight: .semibold))
                    Text("退出")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .contentShape(Capsule())
        }
    }
}
