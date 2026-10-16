# Timeline v0.1.0 — 首个公开版本 / First public release

用简洁的时间线记录项目进展、待解决问题与 Idea，支持 Mac 与 iPhone 源码，以及可选的坚果云同步。

Track project progress, open questions, and ideas in a minimal timeline, with Mac and iPhone source and optional Nutstore sync.

## 功能 / Features

- 项目管理、倒序时间线、搜索、今日记录入口与双击原位编辑。<br>Projects, reverse chronological timelines, search, a Today entry placeholder, and double-click editing in place.
- 离线 Markdown 与 LaTeX 公式预览、问题复选框、可选栏目。<br>Offline Markdown and LaTeX previews, question checkboxes, and optional sections.
- 历史选文引用、拖动引用区、来源与上下文预览。<br>References to selected historical text, a draggable reference shelf, and source-context previews.
- macOS 菜单栏只读速览、项目横向滑动与 Dock 图标显隐。双击记录打开主窗口编辑。<br>A read-only macOS menu bar preview, horizontal project swiping, and optional Dock visibility. Double-click an entry to edit it in the main window.
- 可选坚果云 WebDAV 同步。自动同步要求本地内容变化，且间隔至少 24 小时；手动同步可随时触发。<br>Optional Nutstore WebDAV sync. Automatic sync requires local changes and a minimum 24-hour interval; manual sync is available at any time.
- 项目与记录删除后先进入回收站，30 天内可恢复，之后自动清理；App 关闭时在下次启动补清理。<br>Deleted projects and entries stay in Trash for 30 days and can be restored before automatic cleanup. When the app is closed, overdue cleanup runs on the next launch.

## 下载 / Downloads

| 文件 / File | 内容 / Contents |
| --- | --- |
| `Timeline-macOS.zip` | macOS 14+ 通用应用，支持 Apple Silicon 与 Intel。<br>Universal macOS 14+ app for Apple Silicon and Intel. |
| `Timeline-source.zip` | macOS / iOS 工程、双语文档和离线测试。<br>macOS / iOS project, bilingual documentation, and offline tests. |
| `SHA256SUMS.txt` | 上述两个附件的 SHA-256 校验值。<br>SHA-256 checksums for the two assets above. |

解压 macOS 包后，将 `Timeline.app` 拖入「应用程序」。此版本为本地签名，尚未经过 Apple Developer ID 公证；首次打开可能出现 macOS 安全提示。安装说明见 [README](https://github.com/ZeusLiu666/Timeline/blob/main/README.md)。

Extract the macOS archive and drag `Timeline.app` into Applications. This build is locally signed and has not been notarized through Apple Developer ID; macOS may show a security prompt on first launch. See the [README](https://github.com/ZeusLiu666/Timeline/blob/main/README.md) for installation instructions.

## iPhone 暂不提供安装包 / No iPhone installation package

这是个人开发项目，目前 iPhone 安装仅使用普通 Apple 账号的 Personal Team 短期开发签名，通常约 7 天后需要重新签名，不适合向其他用户持续分发。因此本次不发布 IPA，也不提供 App Store / TestFlight 下载。iOS / iPadOS 17+ 源码完整提供，可使用自己的 Apple 账号在 Xcode 中签名安装。

This is an independently developed project. Its current iPhone installation uses a short-lived Personal Team development signature from a regular Apple Account, typically requiring re-signing after about seven days. It is unsuitable for ongoing distribution to other users, so this release provides no IPA or App Store / TestFlight download. The full iOS / iPadOS 17+ source is included for signing and installation with your own Apple Account in Xcode.

## 升级与限制 / Upgrades and limitations

回收站同步文档使用 v2，可读取 v1；使用此前测试版的用户需要同步更新 Mac 与 iPhone。当前同步不额外提供端到端加密，也不承诺 iOS 后台实时同步。重要内容请保留独立备份。

Trash sync documents use v2 and can read v1. Users of earlier development builds should update both Mac and iPhone together. Additional end-to-end encryption and real-time iOS background sync are not provided. Keep independent backups of important content.

完整验证范围与已知限制见 [VALIDATION](https://github.com/ZeusLiu666/Timeline/blob/main/VALIDATION.md)，发布隐私检查见 [RELEASE-AUDIT](https://github.com/ZeusLiu666/Timeline/blob/main/RELEASE-AUDIT.md)。

See [VALIDATION](https://github.com/ZeusLiu666/Timeline/blob/main/VALIDATION.md) for the verification scope and known limitations, and [RELEASE-AUDIT](https://github.com/ZeusLiu666/Timeline/blob/main/RELEASE-AUDIT.md) for the release privacy review.
