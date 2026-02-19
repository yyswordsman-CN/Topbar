# Topbar

> macOS 刘海管理器 + 灵动岛通知

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-black?logo=apple" />
  <img src="https://img.shields.io/badge/Swift-6-orange?logo=swift" />
  <img src="https://img.shields.io/badge/license-MIT-blue" />
</p>

## 功能

### 1. 隐藏刘海
黑色覆盖层融合 MacBook Notch 区域，让菜单栏看起来更整洁。

### 2. 显示被遮挡的图标
自动检测被刘海遮挡的菜单栏图标，在弹出面板中显示真实应用名和图标，点击即可触发原始功能。

- **AX API 引擎** — 通过辅助功能 API 精准获取真实应用名
- **CGWindowList 引擎** — 降级方案，无需额外权限

### 3. Notch 通知系统 (灵动岛风格)
从刘海下方弹出的通知卡片，弹簧动画展开/收缩。

- **下载监听** — 自动监控 `~/Downloads`，浏览器下载完成即弹通知
- **Agent 通知** — 任何进程写入 `/tmp/topbar-notify` 即可触发

```bash
# Agent 通知 (紫色)
echo '任务完成|报告已生成' > /tmp/topbar-notify

# 成功通知 (绿色)
echo 'success|已保存|文件同步完成' > /tmp/topbar-notify

# 下载 / 信息 / 警告
echo 'download|design_v3.fig' > /tmp/topbar-notify
echo 'info|提醒|5分钟后开会' > /tmp/topbar-notify
echo 'warning|磁盘空间不足|剩余 5GB' > /tmp/topbar-notify
```

## 安装

### DMG 安装
1. 从 [Releases](../../releases) 下载最新 `.dmg`
2. 拖入 Applications 文件夹
3. 首次打开：**右键 → 打开**（自签名证书需要手动信任）
4. 授权辅助功能权限（系统设置 → 隐私与安全 → 辅助功能）

### 源码编译
```bash
# 依赖: Xcode 16+, XcodeGen
brew install xcodegen
git clone https://github.com/YOUR_USERNAME/Topbar.git
cd Topbar
xcodegen generate
open Topbar.xcodeproj
# Cmd+R 运行
```

## 技术栈

| 组件 | 技术 |
|:---|:---|
| UI 框架 | SwiftUI + AppKit (NSPanel) |
| 菜单栏扫描 | AX API + CGWindowList 双引擎 |
| 通知动画 | SwiftUI Spring Animation |
| 下载监听 | DispatchSource (FSEvents) |
| Agent 通信 | 文件轮询 IPC (`/tmp/topbar-notify`) |
| 项目管理 | XcodeGen (project.yml) |

## 系统要求

- macOS 15+ (Sequoia)
- MacBook Pro / Air with Notch

## License

MIT
