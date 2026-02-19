// DownloadMonitor.swift
// Topbar — 下载完成监听器
//
// 监听 ~/Downloads 目录变化
// 新文件完成下载时触发 Notch 通知
//
// 工作原理:
//   1. 启动时扫描 ~/Downloads 记录现有文件
//   2. 使用 DispatchSource.makeFileSystemObjectSource 监听目录变化
//   3. 目录变化时对比差异，识别新增完成文件
//   4. 过滤掉下载中的临时文件 (.crdownload / .download / .part / .tmp)

import Foundation

@MainActor
final class DownloadMonitor {

    private var source: DispatchSourceFileSystemObject?
    private var knownFiles: Set<String> = []
    private let downloadsURL: URL

    // 浏览器下载中的临时文件后缀
    private let tempExtensions: Set<String> = [
        "crdownload",  // Chrome
        "download",    // Safari
        "part",        // Firefox
        "tmp",         // 通用
        "partial",     // Edge
    ]

    init() {
        downloadsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
    }

    // MARK: - Start / Stop

    func start() {
        // 记录现有文件
        knownFiles = scanCurrentFiles()
        print("[Topbar] 📂 下载监听已启动 — ~/Downloads (\(knownFiles.count) 个现有文件)")

        // 打开目录文件描述符
        let fd = open(downloadsURL.path, O_EVTONLY)
        guard fd >= 0 else {
            print("[Topbar] ❌ 无法打开 ~/Downloads 目录")
            return
        }

        // 创建 DispatchSource 监听目录变化
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,  // 文件写入 (新增/修改/删除)
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.handleDirectoryChange()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        print("[Topbar] 📂 下载监听已停止")
    }

    // MARK: - Change Detection

    private func handleDirectoryChange() {
        let currentFiles = scanCurrentFiles()
        let newFiles = currentFiles.subtracting(knownFiles)

        for fileName in newFiles {
            // 检查是否是临时文件 (下载中)
            let ext = (fileName as NSString).pathExtension.lowercased()
            if tempExtensions.contains(ext) {
                continue  // 跳过下载中的文件
            }

            // 检查文件是否还在写入 (大小是否稳定)
            let fileURL = downloadsURL.appendingPathComponent(fileName)
            guard isFileComplete(at: fileURL) else { continue }

            print("[Topbar] ✅ 新下载完成: \(fileName)")

            // 触发 Notch 通知
            let displayName = formatFileName(fileName)
            NotchNotificationManager.shared.showDownloadComplete(fileName: displayName)
        }

        knownFiles = currentFiles
    }

    // MARK: - Helpers

    /// 扫描目录中的所有文件名
    private func scanCurrentFiles() -> Set<String> {
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: downloadsURL.path)
            // 过滤隐藏文件
            return Set(contents.filter { !$0.hasPrefix(".") })
        } catch {
            return []
        }
    }

    /// 检查文件是否已完成写入 (非零大小 + 可读)
    private func isFileComplete(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int
        else { return false }
        return size > 0
    }

    /// 格式化文件名用于显示 (截断过长文件名)
    private func formatFileName(_ name: String) -> String {
        if name.count <= 30 { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        let maxStem = 24 - ext.count
        if maxStem > 3 {
            return String(stem.prefix(maxStem)) + "…." + ext
        }
        return String(name.prefix(28)) + "…"
    }
}
