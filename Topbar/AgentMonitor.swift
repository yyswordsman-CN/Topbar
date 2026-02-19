// AgentMonitor.swift
// Topbar — Agent 通知监听器
//
// 监听 /tmp/topbar-notify 文件
// 任何进程写入该文件即触发 Notch 通知
//
// 协议格式 (每行一条通知):
//   标题|副标题           → Agent 类型通知 (紫色)
//   download|文件名       → 下载类型通知 (青色)
//   success|标题|副标题   → 成功类型通知 (绿色)
//   info|标题|副标题      → 信息类型通知 (蓝色)
//   warning|标题|副标题   → 警告类型通知 (橙色)
//
// 使用方式:
//   echo '任务完成|报告已生成' > /tmp/topbar-notify
//   echo 'success|已保存|文件同步' > /tmp/topbar-notify

import Foundation

@MainActor
final class AgentMonitor {

    private var timer: Timer?
    private let notifyPath = "/tmp/topbar-notify"
    private var lastModDate: Date?

    func start() {
        // 确保文件存在
        if !FileManager.default.fileExists(atPath: notifyPath) {
            FileManager.default.createFile(atPath: notifyPath, contents: nil)
        }

        // 记录初始修改时间
        lastModDate = modificationDate()

        // 每 0.5 秒轮询文件修改时间 (极低 CPU 开销)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForChanges()
            }
        }

        print("[Topbar] 🤖 Agent 通知监听已启动 — \(notifyPath)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Polling

    private func checkForChanges() {
        guard let currentMod = modificationDate() else { return }

        // 文件是否被修改过
        if let last = lastModDate, currentMod <= last { return }
        lastModDate = currentMod

        // 读取内容
        guard let data = FileManager.default.contents(atPath: notifyPath),
              !data.isEmpty,
              let content = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty
        else { return }

        // 清空文件 (防止重复)
        try? "".write(toFile: notifyPath, atomically: true, encoding: .utf8)
        // 更新时间戳 (清空也算修改)
        lastModDate = modificationDate()

        // 解析通知
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            parseAndShow(trimmed)
        }
    }

    private func modificationDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: notifyPath)[.modificationDate] as? Date
    }

    // MARK: - Parse

    private func parseAndShow(_ line: String) {
        let parts = line.components(separatedBy: "|")

        switch parts.first?.lowercased() {
        case "download":
            let fileName = parts.count > 1 ? parts[1] : "未知文件"
            NotchNotificationManager.shared.showDownloadComplete(fileName: fileName)

        case "success":
            let title = parts.count > 1 ? parts[1] : "成功"
            let subtitle = parts.count > 2 ? parts[2] : ""
            NotchNotificationManager.shared.showSuccess(title: title, subtitle: subtitle)

        case "info":
            let title = parts.count > 1 ? parts[1] : "提示"
            let subtitle = parts.count > 2 ? parts[2] : ""
            NotchNotificationManager.shared.show(NotchNotificationItem(
                type: .info, title: title, subtitle: subtitle,
                icon: "info.circle.fill", duration: 2.5
            ))

        case "warning":
            let title = parts.count > 1 ? parts[1] : "警告"
            let subtitle = parts.count > 2 ? parts[2] : ""
            NotchNotificationManager.shared.show(NotchNotificationItem(
                type: .warning, title: title, subtitle: subtitle,
                icon: "exclamationmark.triangle.fill", duration: 3
            ))

        default:
            // 默认: Agent 通知 (紫色)
            let title = parts.first ?? "通知"
            let subtitle = parts.count > 1 ? parts[1] : ""
            NotchNotificationManager.shared.showAgentComplete(
                taskName: subtitle.isEmpty ? title : subtitle
            )
        }

        print("[Topbar] 🤖 Agent 通知: \(line)")
    }
}
