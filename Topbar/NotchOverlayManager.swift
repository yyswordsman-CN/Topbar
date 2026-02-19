// NotchOverlayManager.swift
// Topbar — 刘海隐藏器
//
// 核心覆盖层管理器。
// 在每个带有 Notch 的屏幕顶部创建一个纯黑无边框 NSWindow，
// 从视觉上将刘海区域融入黑色背景。

import AppKit
import Observation

@Observable
@MainActor
final class NotchOverlayManager {

    // MARK: - Public State

    /// 是否启用刘海隐藏。状态会持久化到 UserDefaults。
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Constants.enabledKey)
            isEnabled ? showOverlays() : hideOverlays()
        }
    }

    // MARK: - Private State

    /// 当前活跃的覆盖窗口（每个 Notch 屏幕一个）
    private var overlayWindows: [NSWindow] = []

    /// 屏幕配置变化的观察者
    private var screenObserver: NSObjectProtocol?

    // MARK: - Constants

    private enum Constants {
        static let enabledKey = "TopbarNotchHideEnabled"

        /// 窗口层级策略：
        /// - mainMenu (24): 菜单栏背景层级，我们的窗口覆盖系统菜单栏背景
        /// - statusBar (25): 菜单栏图标（WiFi/电量/时钟）渲染在这个层级
        /// - 因此设置为 24，黑色窗口在背景之上、图标之下
        static let overlayLevel = NSWindow.Level(
            rawValue: NSWindow.Level.mainMenu.rawValue  // = 24
        )
    }

    // MARK: - Lifecycle

    init() {
        // 从 UserDefaults 恢复上次状态（首次默认开启）
        let persisted = UserDefaults.standard.object(forKey: Constants.enabledKey) as? Bool
        self.isEnabled = persisted ?? true

        setupScreenChangeObserver()

        if isEnabled {
            showOverlays()
        }
    }

    // MARK: - Screen Change Monitoring

    /// 监听显示器热插拔 / 分辨率变化 / 排列调整
    private func setupScreenChangeObserver() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshOverlays()
            }
        }
    }

    // MARK: - Overlay Window Management

    private func showOverlays() {
        // 先清除旧窗口，避免重复叠加
        hideOverlays()

        for screen in NSScreen.screens where hasNotch(screen) {
            let window = makeOverlayWindow(for: screen)
            window.orderFrontRegardless()
            overlayWindows.append(window)
        }

        if overlayWindows.isEmpty {
            print("[Topbar] 未检测到带刘海的屏幕")
        }
    }

    private func hideOverlays() {
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
    }

    private func refreshOverlays() {
        guard isEnabled else { return }
        showOverlays()
    }

    // MARK: - Window Factory

    /// 为指定屏幕创建一个纯黑覆盖窗口
    private func makeOverlayWindow(for screen: NSScreen) -> NSWindow {
        let frame = overlayFrame(for: screen)

        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,        // 无边框 — 纯矩形
            backing: .buffered,
            defer: false,
            screen: screen                 // 绑定到目标屏幕
        )

        // ┌─────────────────────────────────────────────┐
        // │              视觉属性                        │
        // └─────────────────────────────────────────────┘
        window.backgroundColor = .black    // 纯黑，与 Notch 硬件融合
        window.isOpaque = true             // 完全不透明
        window.hasShadow = false           // 去除阴影，避免暴露窗口边界

        // ┌─────────────────────────────────────────────┐
        // │         交互属性（核心重点）                   │
        // └─────────────────────────────────────────────┘
        window.ignoresMouseEvents = true   // 🔑 鼠标事件穿透
                                           //    用户可正常点击 WiFi/电量/时钟等

        // ┌─────────────────────────────────────────────┐
        // │              层级设置                        │
        // └─────────────────────────────────────────────┘
        window.level = Constants.overlayLevel  // 24: mainMenu 层级，低于菜单栏图标(25)

        // ┌─────────────────────────────────────────────┐
        // │              窗口行为                        │
        // └─────────────────────────────────────────────┘
        window.collectionBehavior = [
            .canJoinAllSpaces,             // 所有虚拟桌面(Space)可见
            .stationary,                   // 切换 Space 时不移动
            .ignoresCycle                  // 不出现在 Cmd+Tab / Mission Control
        ]

        // ┌─────────────────────────────────────────────┐
        // │             生命周期管理                      │
        // └─────────────────────────────────────────────┘
        window.isReleasedWhenClosed = false  // 手动管理内存
        window.hidesOnDeactivate = false     // 应用切到后台时不隐藏
        window.canHide = false               // 禁止 Cmd+H 隐藏

        return window
    }

    // MARK: - Geometry Calculation

    /// 计算覆盖窗口的位置和尺寸
    /// - 宽度 = 屏幕全宽
    /// - 高度 = Notch 区域高度（safeAreaInsets.top，通常 ~38pt）
    /// - 位置 = 屏幕最顶部
    private func overlayFrame(for screen: NSScreen) -> NSRect {
        let screenFrame = screen.frame
        let notchHeight = screen.safeAreaInsets.top

        // macOS 坐标系: 原点在左下角，Y 轴向上
        // maxY = 屏幕顶部边缘
        return NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.maxY - notchHeight,
            width: screenFrame.width,
            height: notchHeight
        )
    }

    // MARK: - Notch Detection

    /// 判断屏幕是否有刘海
    /// - 有 Notch 的内置屏幕: safeAreaInsets.top > 0
    /// - 外接显示器 / 无 Notch 的旧款 Mac: safeAreaInsets.top == 0
    private func hasNotch(_ screen: NSScreen) -> Bool {
        return screen.safeAreaInsets.top > 0
    }
}
