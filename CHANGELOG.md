# 更新记录 / Changelog

## v0.1.0 — 2026-10-16

首个公开版本，提供 macOS 通用应用与 macOS / iOS 工程源码。个人开发的 iPhone 版本仅有短期开发签名，因此不发布 iPhone 安装包。

The first public release includes the universal macOS app and the macOS / iOS project source. The independently developed iPhone version has only a short-lived development signature, so no iPhone installation package is published.

- 按项目管理时间线，倒序浏览记录，支持搜索、今日记录入口与原位编辑。<br>Project timelines with reverse chronological browsing, search, a Today entry placeholder, and editing in place.
- 记录进展、待解决问题和 Idea；支持复选框、自动标题与栏目显隐。<br>Progress, open questions, and ideas, with checkboxes, automatic titles, and section visibility controls.
- 离线 Markdown / KaTeX 公式预览，随应用打包渲染组件与字体。<br>Offline Markdown / KaTeX previews with bundled rendering components and fonts.
- 从历史内容选择摘录，暂存至引用区并拖入记录；可查看来源与上下文。<br>Select excerpts from past entries, keep them on the reference shelf, and drag them into an entry; view each source and its context.
- SwiftData 本地保存，可选坚果云 WebDAV 同步，并保留离线编辑、冲突副本和首次同步前快照。<br>Local SwiftData storage and optional Nutstore WebDAV sync, with offline editing, conflict copies, and a snapshot before the first sync.
- 新增 Mac / iPhone 共用回收站，入口位于主界面项目侧栏底部。删除项目或记录时先软删除，30 天内可恢复，之后自动清理；显示删除时间、剩余天数及记录原项目，不提供手动永久删除按钮。<br>Added shared Trash on Mac and iPhone, accessible at the bottom of the main project sidebar. Deletions are recoverable for 30 days before automatic cleanup. Trash shows deletion times, remaining days, and each entry’s original project, without a manual permanent-delete button.
- 删除项目保留全部子记录；恢复项目时，此前已单独删除的记录仍留在回收站。普通项目列表、搜索、数量统计和菜单栏速览排除回收站内容。<br>Deleting a project retains all of its entries. Restoring it leaves previously individually deleted entries in Trash. Normal project lists, searches, counts, and the menu bar preview exclude trashed content.
- 应用关闭或无法运行时，在下次启动或回到前台补清理到期项目；不承诺 iOS 后台准点清理。同步文档升级至 v2，新版兼容读取 v1；Mac 与 iPhone 需一起更新，避免旧版拒绝 v2 数据而停止同步。<br>If the app is closed or unable to run, overdue items are cleaned up on the next launch or foreground session. Exact-time iOS background cleanup is not promised. Sync documents use v2, and the new app can read v1. Update Mac and iPhone together so an older client does not reject v2 data and stop syncing.
- 简洁的原生界面、可收起侧栏、平滑展开动画与邻近内容预加载。<br>A minimal native interface, collapsible sidebar, smooth expansion animations, and preloading of nearby content.
- 新增 macOS 菜单栏速览：顶部项目横向排列，支持点击、拖动及触控板横滑切换，整页跟手移动、松手吸附，保持各页展开状态；遵循系统「减少动态效果」。<br>Added a macOS menu bar preview with horizontal project tabs and click / drag / trackpad navigation. Whole pages follow gestures and snap on release while retaining expanded entries and respecting Reduce Motion.
- 菜单栏弹窗只读展示记录、公式、问题状态与引用；双击标题、正文或引用可打开主窗口编辑对应记录。<br>The menu bar popover displays entries, formulas, question states, and references without modifying them. Double-click a title, body, or reference to open the main window and edit the matching entry.
- 修正收起菜单栏弹窗时主窗口被前置的问题；弹窗开关不再激活整应用，移除空状态呼出主窗口的入口，仅保留记录双击编辑路径。<br>Fixed the main window being brought forward when dismissing the menu bar popover. Toggling the popover no longer activates the whole app, and the empty-state window-opening action was removed; entry double-click editing remains.
- 移除菜单栏弹窗内的滑动提示、记录数量与「只读浏览」文字；编辑器的「实时预览」标题只保留首个可见预览处。<br>Removed swipe hints, entry counts, and the read-only label from the menu bar popover. The editor shows its live-preview heading only for the first visible preview.
- 菜单栏齿轮菜单支持隐藏 Dock 图标与退出；关闭主窗口后保持常驻。应用处于前台时可用 `⇧⌘T` 打开速览。<br>The menu bar’s gear menu supports hiding the Dock icon and quitting. Closing the main window keeps the app running in the menu bar. Press `⇧⌘T` while the app is active to open the preview.
- Mac / iPhone 主界面和菜单栏弹窗的同步状态支持点击立即同步，不受自动同步间隔限制，显示并保留上次成功同步时间。账号设置通过独立齿轮进入。<br>Sync status in the Mac / iPhone main interface and menu bar popover triggers immediate sync without the automatic sync interval limit, and the last successful sync time remains visible across relaunches. Account settings use a separate gear button.
- 自动同步改为仅在本机已保存内容较上次成功同步发生变化时执行，自动同步请求间隔至少 24 小时。仅在应用前台执行；到期时应用未打开则等待下次前台检查。本机没有变化时，接收其他设备更新需手动同步。<br>Automatic sync now requires saved local changes since the last successful sync, with at least 24 hours between automatic sync requests. It runs only in the foreground; if the app is not open when the interval expires, the next foreground session checks again. When local content has not changed, receiving updates from other devices requires manual sync.
- 为 Mac 与 iPhone 提供统一的深蓝时间节点图标。<br>A matching dark-blue timeline-node icon for Mac and iPhone.

需要 macOS 14 或 iOS / iPadOS 17 及更新版本。Mac 包尚未经过 Developer ID 公证；本项目目前为个人开发，现有 iPhone 安装只有短期开发签名，因此暂不发布 iPhone 安装包（IPA）。iOS 源码可使用自己的 Apple 账号与 Xcode 签名安装。

Requires macOS 14 or iOS / iPadOS 17 or later. The Mac package has not been notarized through Developer ID. This is an independently developed project, and the current iPhone installation has only a short-lived development signature, so no iPhone package (IPA) is published. You can sign and install the iOS source with your own Apple Account and Xcode.

已验证范围和未验收的双设备同步场景见 [VALIDATION.md](VALIDATION.md)，安装与使用方式见 [README.md](README.md)。

See [VALIDATION.md](VALIDATION.md) for the verified scope and untested two-device sync scenarios, and [README.md](README.md) for installation and usage.
