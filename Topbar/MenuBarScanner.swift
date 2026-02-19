// MenuBarScanner.swift
// Topbar — 双引擎菜单栏扫描器
//
// 引擎 1 (CGWindowList): 检测被刘海遮挡的窗口位置
// 引擎 2 (AX API):       通过辅助功能 API 获取真实应用名称和 Bundle 图标
//
// macOS 26 关键限制:
//   CGWindowList 下所有 StatusItem 由控制中心进程渲染 (共享 PID)
//   → 只能通过 AX API 穿透获取真实的第三方应用名称
//   → AX API 需要代码签名 + 辅助功能权限

import AppKit
import CoreGraphics
import Observation

// MARK: - Data Model

/// 菜单栏图标
struct MenuBarItem: Identifiable {
    let id: String              // 唯一标识 (PID-X坐标)
    let ownerName: String       // 真实应用名 (AX API 获取)
    let ownerPID: pid_t
    let frame: CGRect           // Quartz 坐标系
    let appIcon: NSImage?       // Bundle 路径提取的高清图标
    let axElement: AXUIElement? // AX 元素引用 (用于 AXPress 交互)

    var displayName: String { ownerName }
}

// MARK: - Scanner

@Observable
@MainActor
final class MenuBarScanner {

    // MARK: Public State

    var hiddenItems: [MenuBarItem] = []
    var statusMessage: String?
    var hasAccessibilityPermission: Bool = false

    // MARK: - Private

    private let selfPID = ProcessInfo.processInfo.processIdentifier

    // MARK: - Scan

    func scan() {
        statusMessage = "扫描中..."

        // 检查辅助功能权限
        hasAccessibilityPermission = AXIsProcessTrusted()

        print("\n" + String(repeating: "=", count: 70))
        print("[Topbar] 开始扫描 — selfPID=\(selfPID)")
        print("[Topbar] 辅助功能权限: \(hasAccessibilityPermission ? "✅ 已授权" : "❌ 未授权")")

        // ── 1. 找到带刘海的屏幕 ──
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else {
            statusMessage = "未检测到刘海屏幕"
            hiddenItems = []
            return
        }

        // ── 2. 计算刘海区域 ──
        let notch = calculateNotchRect(for: screen)
        print("[Topbar] 刘海区域: X[\(notch.minX) ~ \(notch.maxX)]")

        if hasAccessibilityPermission {
            // ── AX API 引擎: 精准获取真实应用名 ──
            scanWithAccessibility(notchRect: notch)
        } else {
            // ── CGWindowList 引擎: 降级方案 ──
            scanWithCGWindowList(notchRect: notch)
            print("[Topbar] ⚠️ 无辅助功能权限，使用 CGWindowList 降级方案")
            print("[Topbar] 请在 系统设置 → 隐私与安全 → 辅助功能 中授权 Topbar")
        }

        print("[Topbar] ✅ 最终: \(hiddenItems.count) 个被遮挡图标")
        for item in hiddenItems {
            let hasIcon = item.appIcon != nil ? "有图标" : "无图标"
            print("  🔴 [\(item.ownerName)] PID=\(item.ownerPID) \(hasIcon)")
        }
        print(String(repeating: "=", count: 70) + "\n")
    }

    // MARK: - AX API Engine (精准)

    /// 通过辅助功能 API 扫描菜单栏，获取真实应用名和图标
    private func scanWithAccessibility(notchRect: CGRect) {
        print("[Topbar] 使用 AX API 引擎扫描...")

        // 获取系统范围的辅助功能元素
        let systemWide = AXUIElementCreateSystemWide()

        // 获取所有运行中的应用
        let apps = NSWorkspace.shared.runningApplications

        var results: [MenuBarItem] = []

        for app in apps {
            let pid = app.processIdentifier
            if pid == selfPID { continue }

            let axApp = AXUIElementCreateApplication(pid)

            // 获取该应用的菜单栏 extras
            var extrasValue: AnyObject?
            let extrasResult = AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &extrasValue)

            // 尝试获取菜单栏区域中的子元素
            if extrasResult == .success, let menuBar = extrasValue {
                var childrenValue: AnyObject?
                let childrenResult = AXUIElementCopyAttributeValue(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &childrenValue)

                if childrenResult == .success, let children = childrenValue as? [AXUIElement] {
                    for child in children {
                        // 获取位置和尺寸
                        var posValue: AnyObject?
                        var sizeValue: AnyObject?
                        AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posValue)
                        AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeValue)

                        guard let posValue = posValue, let sizeValue = sizeValue else { continue }

                        var position = CGPoint.zero
                        var size = CGSize.zero
                        AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
                        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

                        let frame = CGRect(origin: position, size: size)

                        // 碰撞检测: 中心点在刘海 X 范围内
                        let centerX = frame.midX
                        if centerX >= notchRect.minX && centerX <= notchRect.maxX {
                            let appName = app.localizedName ?? "未知应用"
                            let icon = extractHighResIcon(for: app)

                            print("  🔴 AX发现: [\(appName)] PID=\(pid) pos=(\(position.x),\(position.y)) size=(\(size.width)×\(size.height))")

                            results.append(MenuBarItem(
                                id: "\(pid)-\(Int(position.x))",
                                ownerName: appName,
                                ownerPID: pid,
                                frame: frame,
                                appIcon: icon,
                                axElement: child
                            ))
                        }
                    }
                }
            }
        }

        // 也检查 ControlCenter 托管的状态栏项 (macOS 26 特殊处理)
        scanControlCenterExtras(notchRect: notchRect, results: &results)

        hiddenItems = results.sorted { $0.frame.origin.x > $1.frame.origin.x }

        if hiddenItems.isEmpty {
            statusMessage = "所有图标可见"
        } else {
            statusMessage = nil
        }
    }

    /// 扫描 ControlCenter 的 AXExtrasMenuBar 子元素
    /// macOS 26 中第三方 StatusItem 的窗口都归属 ControlCenter
    /// 但 AX API 可以穿透看到每个 StatusItem 的真实 title
    private func scanControlCenterExtras(notchRect: CGRect, results: inout [MenuBarItem]) {
        // 找到控制中心进程
        guard let ccApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first else {
            return
        }

        let ccPID = ccApp.processIdentifier
        let axCC = AXUIElementCreateApplication(ccPID)

        var extrasValue: AnyObject?
        let extrasResult = AXUIElementCopyAttributeValue(axCC, "AXExtrasMenuBar" as CFString, &extrasValue)

        guard extrasResult == .success, let menuBar = extrasValue else { return }

        var childrenValue: AnyObject?
        let childrenResult = AXUIElementCopyAttributeValue(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &childrenValue)

        guard childrenResult == .success, let children = childrenValue as? [AXUIElement] else { return }

        print("[Topbar] ControlCenter AXExtrasMenuBar 有 \(children.count) 个子元素")

        for child in children {
            // 获取位置和尺寸
            var posValue: AnyObject?
            var sizeValue: AnyObject?
            AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posValue)
            AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeValue)

            guard let posValue = posValue, let sizeValue = sizeValue else { continue }

            var position = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

            let frame = CGRect(origin: position, size: size)
            let centerX = frame.midX

            // 获取 title / description
            var titleValue: AnyObject?
            AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleValue)
            var descValue: AnyObject?
            AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &descValue)

            let title = titleValue as? String ?? ""
            let desc = descValue as? String ?? ""
            let displayStr = !title.isEmpty ? title : desc

            print("    CC子元素: title=\"\(title)\" desc=\"\(desc)\" pos=(\(position.x),\(position.y)) size=(\(size.width)×\(size.height)) centerX=\(centerX) inNotch=\(centerX >= notchRect.minX && centerX <= notchRect.maxX)")

            // 碰撞检测
            if centerX >= notchRect.minX && centerX <= notchRect.maxX {
                // 跳过已知系统项和自身
                if ["WiFi", "Battery", "Clock", "FocusModes", "BentoBox", "Siri",
                    "Bluetooth", "Sound", "NowPlaying", "TopbarConsole"].contains(where: { title.contains($0) || desc.contains($0) }) {
                    continue
                }

                // 尝试通过 title 找到真实应用（用 bundleIdentifier 或者进程名匹配）
                let (resolvedName, resolvedIcon) = resolveAppFromTitle(title: title, desc: desc)

                // 避免重复添加 (检查位置)
                let itemId = "cc-\(Int(position.x))"
                if !results.contains(where: { $0.id == itemId }) {
                    results.append(MenuBarItem(
                        id: itemId,
                        ownerName: resolvedName,
                        ownerPID: ccPID,
                        frame: frame,
                        appIcon: resolvedIcon,
                        axElement: child
                    ))
                }
            }
        }
    }

    /// 通过 StatusItem 的 title/desc 反查真实应用名和图标
    private func resolveAppFromTitle(title: String, desc: String) -> (String, NSImage?) {
        let searchText = !title.isEmpty ? title : desc

        // 在运行中的应用中搜索匹配
        for app in NSWorkspace.shared.runningApplications {
            guard let appName = app.localizedName else { continue }
            // 名称包含匹配
            if searchText.localizedCaseInsensitiveContains(appName)
                || appName.localizedCaseInsensitiveContains(searchText) {
                return (appName, extractHighResIcon(for: app))
            }
        }

        // 没找到匹配，返回原始文本
        let name = !searchText.isEmpty ? searchText : "未知应用"
        return (name, nil)
    }

    // MARK: - CGWindowList Engine (降级)

    /// CGWindowList 降级方案 (无辅助功能权限时使用)
    private func scanWithCGWindowList(notchRect: CGRect) {
        print("[Topbar] 使用 CGWindowList 降级引擎...")

        guard let windowList = CGWindowListCopyWindowInfo(
            .optionAll, kCGNullWindowID
        ) as? [[String: Any]] else { return }

        var candidates: [MenuBarItem] = []

        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 25
            else { continue }

            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let rawOwnerName = info[kCGWindowOwnerName as String] as? String ?? "Unknown"

            if rawOwnerName == "Window Server" { continue }
            if ownerPID == selfPID { continue }

            guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let frame = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            // 严格尺寸过滤: 宽度 <= 50, 高度 >= 10
            guard frame.width > 5,
                  frame.width <= 50,
                  frame.height >= 10,
                  frame.height < 50,
                  frame.origin.y <= 40
            else { continue }

            // 排除已知系统图标
            let windowName = info[kCGWindowName as String] as? String ?? ""
            if ["WiFi", "Battery", "Clock", "FocusModes", "BentoBox-0",
                "Siri", "Sound", "Bluetooth", "TopbarConsole"].contains(windowName) { continue }

            let windowID = info[kCGWindowNumber as String] as? CGWindowID ?? 0

            // PID 反查应用名 + Bundle 图标
            let resolvedName: String
            let icon: NSImage?
            if let app = NSRunningApplication(processIdentifier: ownerPID) {
                resolvedName = app.localizedName ?? rawOwnerName
                icon = extractHighResIcon(for: app)
            } else {
                resolvedName = rawOwnerName
                icon = nil
            }

            candidates.append(MenuBarItem(
                id: "\(windowID)",
                ownerName: resolvedName,
                ownerPID: ownerPID,
                frame: frame,
                appIcon: icon,
                axElement: nil
            ))
        }

        // 碰撞检测
        let blocked = candidates.filter { item in
            let centerX = item.frame.midX
            return centerX >= notchRect.minX && centerX <= notchRect.maxX
        }

        hiddenItems = blocked.sorted { $0.frame.origin.x > $1.frame.origin.x }

        if hiddenItems.isEmpty {
            statusMessage = "所有图标可见 (\(candidates.count) 项)"
        } else {
            statusMessage = nil
        }
    }

    // MARK: - High-Res Icon Extraction

    /// 从 App Bundle 提取高清图标
    private func extractHighResIcon(for app: NSRunningApplication) -> NSImage? {
        // 策略 1: NSWorkspace.icon(forFile:) — 最可靠，自动返回高清版
        if let bundleURL = app.bundleURL {
            let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
            // NSWorkspace 返回的图标永远非 nil（至少返回通用图标），检查是否有效
            if icon.size.width > 0 {
                return icon
            }
        }

        // 策略 2: Bundle 路径手动提取 .icns
        if let bundleURL = app.bundleURL,
           let bundle = Bundle(url: bundleURL) {
            let iconName = bundle.infoDictionary?["CFBundleIconFile"] as? String
                        ?? bundle.infoDictionary?["CFBundleIconName"] as? String
            if let iconName = iconName {
                var iconFile = iconName
                if !iconFile.hasSuffix(".icns") { iconFile += ".icns" }
                let iconPath = bundleURL.appendingPathComponent("Contents/Resources/\(iconFile)")
                if let img = NSImage(contentsOf: iconPath) {
                    return img
                }
            }
        }

        // 策略 3: NSRunningApplication.icon (最后兜底)
        return app.icon
    }

    // MARK: - Click

    /// 点击被遮挡的图标，触发其原始功能（弹出菜单等）
    ///
    /// 策略优先级:
    ///   1. AXUIElementPerformAction(kAXPressAction) — 直接在 AX 层面触发
    ///      最可靠，无需坐标，不受 Notch 遮挡影响
    ///   2. CGEvent 模拟鼠标点击 — 降级方案
    func clickItem(_ item: MenuBarItem) {
        // ── 策略 1: AX Press (推荐) ──
        if let element = item.axElement {
            let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if result == .success {
                print("[Topbar] ✅ AXPress 成功: [\(item.ownerName)]")
                return
            }
            print("[Topbar] ⚠️ AXPress 失败 (\(result.rawValue)), 尝试 CGEvent...")
        }

        // ── 策略 2: 尝试通过 PID 重新查找 AX 元素并 Press ──
        if hasAccessibilityPermission {
            if let element = findAXElement(pid: item.ownerPID, nearX: item.frame.origin.x) {
                let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
                if result == .success {
                    print("[Topbar] ✅ AXPress (重新查找) 成功: [\(item.ownerName)]")
                    return
                }
            }
        }

        // ── 策略 3: CGEvent 模拟点击 (降级) ──
        let point = CGPoint(x: item.frame.midX, y: item.frame.midY)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                  mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                mouseCursorPosition: point, mouseButton: .left)
        else { return }

        down.post(tap: .cghidEventTap)
        usleep(80_000)
        up.post(tap: .cghidEventTap)
        print("[Topbar] ✅ CGEvent 点击: [\(item.ownerName)] at (\(point.x), \(point.y))")
    }

    /// 通过 PID 和 X 坐标重新查找 AX 元素
    private func findAXElement(pid: pid_t, nearX: CGFloat) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)

        var extrasValue: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &extrasValue) == .success
        else { return nil }
        let menuBar = extrasValue as! AXUIElement

        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement]
        else { return nil }

        for child in children {
            var posValue: AnyObject?
            AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posValue)
            guard let posValue = posValue else { continue }

            var position = CGPoint.zero
            AXValueGetValue(posValue as! AXValue, .cgPoint, &position)

            // 位置匹配 (允许 5pt 偏差)
            if abs(position.x - nearX) < 5 {
                return child
            }
        }
        return nil
    }

    // MARK: - Permission

    /// 请求辅助功能权限 (会弹系统对话框)
    @MainActor
    static func requestAccessibility() {
        // 直接使用字符串常量避免 Swift 6 concurrency 报错
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// 打开辅助功能设置页面
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Private

    private func calculateNotchRect(for screen: NSScreen) -> CGRect {
        let menuBarHeight = screen.safeAreaInsets.top

        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea,
           leftArea != .zero, rightArea != .zero {
            let notchLeft = leftArea.maxX
            let notchRight = rightArea.origin.x
            return CGRect(x: notchLeft, y: 0, width: notchRight - notchLeft, height: menuBarHeight)
        }

        let screenWidth = screen.frame.width
        let center = screen.frame.origin.x + screenWidth / 2
        let notchWidth: CGFloat = 200
        return CGRect(x: center - notchWidth / 2, y: 0, width: notchWidth, height: menuBarHeight)
    }
}
