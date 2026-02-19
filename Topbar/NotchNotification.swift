// NotchNotification.swift
// Topbar — 刘海下方通知面板
//
// 灵动岛设计: 从刘海处"生长"出来的通知卡片
// 全部使用 SwiftUI 原生动画，丝滑流畅

import AppKit
import SwiftUI

// MARK: - Notification Model

enum NotchNotificationType {
    case success, info, warning, download, agent
}

struct NotchNotificationItem: Identifiable {
    let id = UUID()
    let type: NotchNotificationType
    let title: String
    let subtitle: String
    let icon: String
    let duration: TimeInterval

    var accentColor: Color {
        switch type {
        case .success:  return .green
        case .info:     return .blue
        case .warning:  return .orange
        case .download: return .cyan
        case .agent:    return .purple
        }
    }
}

// MARK: - Notification State (驱动 SwiftUI 动画)

@Observable
@MainActor
final class NotchNotificationState {
    var item: NotchNotificationItem?
    var phase: AnimationPhase = .hidden

    enum AnimationPhase {
        case hidden     // 完全隐藏
        case entering   // 展开中
        case visible    // 完全可见
        case exiting    // 收缩中
    }
}

// MARK: - Notification Manager

@MainActor
final class NotchNotificationManager {

    static let shared = NotchNotificationManager()

    let state = NotchNotificationState()
    private var window: NSWindow?
    private var dismissTask: Task<Void, Never>?

    // MARK: - Public API

    func show(_ item: NotchNotificationItem) {
        dismissTask?.cancel()

        if window == nil {
            createWindow()
        }

        state.item = item
        state.phase = .hidden
        window?.orderFrontRegardless()

        // 微小延迟让 SwiftUI 识别状态变化
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            withAnimation(.spring(response: 0.55, dampingFraction: 0.72, blendDuration: 0)) {
                self.state.phase = .entering
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.state.phase = .visible

            // 自动关闭
            self.dismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(item.duration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()

        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            state.phase = .exiting
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.state.phase = .hidden
            self?.state.item = nil
            self?.window?.orderOut(nil)
        }
    }

    func showDownloadComplete(fileName: String) {
        show(NotchNotificationItem(
            type: .download, title: "下载完成", subtitle: fileName,
            icon: "arrow.down.circle.fill", duration: 2.5
        ))
    }

    func showAgentComplete(taskName: String) {
        show(NotchNotificationItem(
            type: .agent, title: "任务完成", subtitle: taskName,
            icon: "sparkles", duration: 3
        ))
    }

    func showSuccess(title: String, subtitle: String = "") {
        show(NotchNotificationItem(
            type: .success, title: title, subtitle: subtitle,
            icon: "checkmark.circle.fill", duration: 2
        ))
    }

    // MARK: - Window (固定位置，动画全交给 SwiftUI)

    private func createWindow() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else { return }

        let notchRect = calculateNotchRect(for: screen)
        // 紧凑设计: 比刘海稍宽，紧贴刘海底部
        let panelWidth: CGFloat = notchRect.width + 60
        let panelHeight: CGFloat = 60

        let x = notchRect.midX - panelWidth / 2
        let screenTop = screen.frame.maxY
        let menuBarBottom = screenTop - screen.safeAreaInsets.top
        let y = menuBarBottom - panelHeight  // 紧贴刘海底部

        let w = NSWindow(
            contentRect: NSRect(x: x, y: y, width: panelWidth, height: panelHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .statusBar + 1
        w.collectionBehavior = [.canJoinAllSpaces, .stationary]
        w.ignoresMouseEvents = true
        w.appearance = NSAppearance(named: .darkAqua)

        let rootView = NotchNotificationRootView(state: state)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        w.contentView = hostingView

        window = w
    }

    private func calculateNotchRect(for screen: NSScreen) -> CGRect {
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea,
           leftArea != .zero, rightArea != .zero {
            let notchLeft = leftArea.maxX
            let notchRight = rightArea.origin.x
            let menuBarHeight = screen.safeAreaInsets.top
            return CGRect(x: notchLeft, y: 0, width: notchRight - notchLeft, height: menuBarHeight)
        }
        let center = screen.frame.origin.x + screen.frame.width / 2
        return CGRect(x: center - 100, y: 0, width: 200, height: 32)
    }
}

// MARK: - SwiftUI Root View (动画全在这里)

struct NotchNotificationRootView: View {
    @Bindable var state: NotchNotificationState

    var body: some View {
        VStack(spacing: 0) {
            if let item = state.item {
                NotchNotificationCard(item: item, phase: state.phase)
                    .transition(.identity)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Notification Card (核心视觉组件)

struct NotchNotificationCard: View {
    let item: NotchNotificationItem
    let phase: NotchNotificationState.AnimationPhase

    private var isShowing: Bool {
        phase == .entering || phase == .visible
    }

    var body: some View {
        HStack(spacing: 10) {
            // ── 图标: 紧凑发光 ──
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [item.accentColor.opacity(0.35), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 18
                        )
                    )
                    .frame(width: 36, height: 36)
                    .blur(radius: 3)

                Circle()
                    .fill(item.accentColor.opacity(0.2))
                    .frame(width: 30, height: 30)

                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(item.accentColor)
            }

            // ── 文字: 紧凑排列 ──
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)

                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(white: 0.08))

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                item.accentColor.opacity(0.2),
                                item.accentColor.opacity(0.03),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [item.accentColor.opacity(0.4), .clear, .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
            }
        )
        .shadow(color: item.accentColor.opacity(0.25), radius: 16, x: 0, y: 6)
        .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 3)
        // ── 动画 ──
        .scaleEffect(x: isShowing ? 1 : 0.3, y: isShowing ? 1 : 0.1, anchor: .top)
        .opacity(isShowing ? 1 : 0)
        .offset(y: isShowing ? 0 : -20)
        .padding(.horizontal, 2)
    }
}
