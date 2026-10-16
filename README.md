# Timeline

记录项目的进展、待解决问题与 Idea，让每一次思考都有时间坐标。

Track project progress, open questions, and ideas—one entry at a time.

Timeline 是面向 Mac、iPhone 和 iPad 的原生应用，采用简洁的时间线界面，支持离线 Markdown / LaTeX 公式、历史内容引用和坚果云同步。

Timeline is a native app for Mac, iPhone, and iPad. Its simple timeline supports offline Markdown and LaTeX formulas, references to past entries, and Nutstore sync.

当前版本为 **v0.1.0**。下载 macOS 安装包与源码，请前往 [GitHub Release](https://github.com/ZeusLiu666/Timeline/releases/tag/v0.1.0)。

The current version is **v0.1.0**. Download the macOS app and source from the [GitHub Release](https://github.com/ZeusLiu666/Timeline/releases/tag/v0.1.0).

[更新记录 / Changelog](CHANGELOG.md) · [验证范围 / Validation](VALIDATION.md) · [发布审计 / Release audit](RELEASE-AUDIT.md)

## 功能 / Features

- **项目与时间线**：按项目管理记录，按时间倒序浏览；点击日期或标题展开，双击进入原位编辑。当天没有记录时，顶部显示可直接编辑的「今日记录」。<br>**Projects and timeline:** Organize entries by project in reverse chronological order. Click a date or title to expand it, and double-click to edit in place. An editable “Today” placeholder appears when no entry exists for the current day.
- **快速记录**：标题可根据内容自动生成，进展、待解决问题和 Idea 按需添加或隐藏；问题支持复选框。<br>**Quick entries:** Generate titles from content, add or hide progress, open questions, and ideas as needed, and use checkboxes for questions.
- **Markdown 与公式**：支持标题、列表、表格、代码块及 KaTeX 公式。渲染组件与字体随应用打包，无需联网。<br>**Markdown and formulas:** Use headings, lists, tables, code blocks, and KaTeX formulas. Rendering components and fonts are bundled for offline use.
- **引用历史内容**：选择正文后，将摘录加入引用区，再拖入另一条记录；点击引用可查看来源、摘录和前后文。<br>**References to past entries:** Select text, add the excerpt to the reference shelf, and drag it into another entry. Click a reference to view its source, excerpt, and surrounding context.
- **本地保存与同步**：SwiftData 保存本地数据，可选坚果云 WebDAV 同步已保存的项目、记录与引用；离线也能编辑。<br>**Local storage and sync:** SwiftData stores data locally. Optional Nutstore WebDAV sync shares saved projects, entries, and references across devices. Editing also works offline.
- **回收站**：删除项目或记录时先移入回收站，30 天内可以恢复，之后自动清除；回收站入口位于主界面项目侧栏底部。<br>**Trash:** Deleted projects and entries move to Trash first. Restore them within 30 days before automatic cleanup. Open Trash at the bottom of the main project sidebar.
- **轻量界面**：可收起项目侧栏，无边框记录区，保留展开与收起动画，并预加载邻近内容。<br>**Minimal interface:** A collapsible project sidebar, borderless entries, animated expansion and collapse, and preloading of nearby content.

Mac 快捷键：`⌘N` 新建记录、`⇧⌘N` 新建项目、`⌘Return` 保存记录、`⇧⌘T` 打开菜单栏速览（应用处于前台时）。

Mac shortcuts: `⌘N` creates an entry, `⇧⌘N` creates a project, `⌘Return` saves an entry, and `⇧⌘T` opens the menu bar preview while the app is active.

## 回收站与恢复 / Trash and recovery

在 Mac 或 iPhone 的主界面项目侧栏底部打开「回收站」。其中列出被删除的项目和单独删除的记录，显示删除时间与剩余天数；点击「恢复」即可放回项目时间线。保留期从执行删除时开始计算，与记录原本的日期无关。

Open Trash at the bottom of the main project sidebar on Mac or iPhone. It lists deleted projects and individually deleted entries with their deletion time and remaining days. Select Restore to return an item to the timeline. The retention period starts when the item is deleted, regardless of the entry’s original date.

删除项目会一并隐藏其记录，完整保留项目和子记录供恢复，回收站中不重复列出这些子记录。恢复项目时，在删除该项目之前就已单独删除的记录仍留在回收站，需分别恢复。回收站内容不出现在普通项目列表、搜索结果或菜单栏速览中。

Deleting a project hides its entries together and retains the project and its children for recovery. Those children are not listed twice in Trash. Restoring the project leaves any entries deleted individually before the project deletion in Trash; restore those entries separately. Trashed content is excluded from normal project lists, search results, and the menu bar preview.

满 30 天后自动清理，不提供手动永久删除按钮。应用关闭或设备未允许运行时，到期内容会在下次启动或回到前台时补清理；不承诺 iOS 在后台到点执行。清理后无法再从回收站恢复。同步层为处理离线合并可能继续保留删除标记与历史版本，回收站清理不代表抹除所有同步历史。

Items are cleaned up automatically after 30 days; there is no manual permanent-delete button. If the app is closed or cannot run, overdue items are cleaned up on the next launch or foreground session. Exact-time iOS background cleanup is not promised. Cleaned-up items can no longer be restored from Trash. The sync layer may retain deletion markers and historical versions for offline merging, so Trash cleanup does not erase all sync history.

## macOS 菜单栏速览 / macOS menu bar preview

- 点击系统菜单栏中的 Timeline 图标，或在应用处于前台时按 `⇧⌘T`，打开紧凑的时间线弹窗。<br>Click the Timeline icon in the macOS menu bar, or press `⇧⌘T` while the app is active, to open a compact timeline popover.
- 顶部横向排列项目。可点击项目标签，或在标题和留白处用鼠标左右拖动；触控板也可在普通正文上横滑。整个项目页跟随手势移动，邻页逐渐露出，松手后吸附；页内展开状态和纵向位置保留，不叠加正文淡入或重新展开。开启系统「减少动态效果」时省略松手吸附动画。<br>Projects appear as horizontal tabs. Click a tab, drag a heading or blank area with the mouse, or swipe horizontally over ordinary text with the trackpad. The entire project page follows the gesture, reveals its neighbor, and snaps into place on release. Each page retains its expanded entry and vertical position, without fading or reopening body content. Reduce Motion skips the settling animation.
- 弹窗中只读查看已保存的记录、Markdown、公式、问题勾选状态及引用上下文。正文仍可用鼠标选文；包含代码或表格的 Markdown 栏目保留内部横向滚动，该区域不触发项目翻页。<br>The popover displays saved entries, Markdown, formulas, question checkbox states, and reference context without editing them. Mouse text selection remains available. Markdown sections containing code or tables retain their own horizontal scrolling and do not trigger project paging.
- 菜单栏图标只展开或收起弹窗，不激活或前置主窗口。单击日期或标题展开记录；只有双击记录标题、正文或引用内容，才会从弹窗打开主窗口并进入对应记录的编辑模式。<br>The menu bar icon only opens or closes the popover, without activating or bringing the main window forward. Click a date or title to expand an entry. Only double-clicking an entry title, body, or reference opens the main window from the popover and edits that entry.
- 底部同步状态可点击立即同步，并显示上次成功同步时间。打开弹窗时检查自动同步条件：本机已保存内容有变化，且满足至少 24 小时的自动同步间隔。通过齿轮菜单可隐藏或恢复 Dock 图标，并退出 Timeline。关闭主窗口后，应用仍驻留菜单栏。<br>Click the footer’s sync status to sync immediately and see the last successful sync time. Opening the popover checks whether automatic sync is due: saved local content must have changed, and the minimum 24-hour automatic sync interval must have elapsed. Use the gear menu to hide or restore the Dock icon, or quit Timeline. The app remains in the menu bar after its main window is closed.

## 安装 / Installation

### macOS 安装 / macOS installation

需要 **macOS 14 或更新版本**，支持 Apple Silicon 和 Intel Mac。

Requires **macOS 14 or later**. Supports Apple Silicon and Intel Macs.

1. 从 [v0.1.0 Release](https://github.com/ZeusLiu666/Timeline/releases/tag/v0.1.0) 下载 `Timeline-macOS.zip` 并解压。<br>Download `Timeline-macOS.zip` from the [v0.1.0 Release](https://github.com/ZeusLiu666/Timeline/releases/tag/v0.1.0) and extract it.
2. 将 `Timeline.app` 拖入「应用程序」文件夹。<br>Drag `Timeline.app` into the Applications folder.
3. 打开 Timeline，创建项目并开始记录。<br>Open Timeline, create a project, and start writing.

当前版本采用本地签名，尚未经过 Apple Developer ID 公证，首次打开可能出现系统安全提示。确认文件来自本仓库的 Release 后，可按 macOS「系统设置 → 隐私与安全性」中的提示允许打开；不要全局关闭系统安全保护。

This version is locally signed and has not been notarized through Apple Developer ID. macOS may show a security prompt on first launch. After confirming that the file came from this repository’s Release, follow the prompts in System Settings → Privacy & Security to allow it to open. Do not disable system security globally.

更新时退出 Timeline，再用新版替换「应用程序」中的旧版本。保留原有应用数据目录，避免删除记录。

To update, quit Timeline and replace the older app in Applications. Keep the existing app data directory to preserve your entries.

### iPhone / iPad 安装 / iPhone / iPad installation

需要 **iOS / iPadOS 17 或更新版本**。本项目目前由个人开发，现有 iPhone 安装方式只有短期开发签名，不适合面向其他用户长期分发，因此本次暂不发布 iPhone 安装包（IPA），也尚未上架 App Store / TestFlight。iOS 源码随工程提供，可使用自己的 Apple 账号与 Xcode 签名安装。

Requires **iOS / iPadOS 17 or later**. This is an independently developed project, and the current iPhone installation uses only a short-lived development signature. It is unsuitable for ongoing distribution to other users, so this release does not include an iPhone package (IPA) or an App Store / TestFlight version. The iOS source is included; you can sign and install it with your own Apple Account and Xcode.

1. 在 Mac 上安装 Xcode，下载本仓库源码并打开 `Timeline.xcodeproj`。<br>Install Xcode on a Mac, download this repository’s source, and open `Timeline.xcodeproj`.
2. 在 Xcode「Settings → Apple Accounts」登录自己的 Apple 账号。<br>Sign in with your own Apple Account in Xcode → Settings → Apple Accounts.
3. 连接设备并信任电脑；选择 `Timeline` scheme 与目标设备。<br>Connect the device and trust the computer. Select the `Timeline` scheme and your device.
4. 在 Target 的「Signing & Capabilities」选择自己的 Team，开启自动签名。若 Bundle ID 被占用，改为自己唯一的标识。<br>In the target’s Signing & Capabilities, select your own Team and enable automatic signing. If the Bundle ID is unavailable, choose a unique one.
5. 按 Xcode 提示开启设备开发者模式并运行安装；如设备要求信任开发者，按系统提示完成。<br>Follow Xcode’s prompts to enable Developer Mode and run the app. If the device asks you to trust the developer, follow its instructions.

普通 Apple 账号可以通过 Personal Team 安装到自己的设备，免费描述文件通常有效 7 天，到期需重新签名安装。更新时沿用相同 Team 和 Bundle ID，直接覆盖，不要先删除应用。详见 [Apple 账号说明](https://developer.apple.com/help/account/basics/about-your-developer-account)与[开发者模式说明](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device/)。隔空投送仅传输文件，不能代替 iOS 签名安装。

A regular Apple Account can use a Personal Team to install apps on your own devices. Free provisioning profiles generally expire after seven days, after which you must sign and install the app again. Keep the same Team and Bundle ID for updates and overwrite the app without deleting it first. See [Apple’s account guide](https://developer.apple.com/help/account/basics/about-your-developer-account) and [Developer Mode instructions](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device/). AirDrop transfers files; it does not replace iOS signing and installation.

## 坚果云同步 / Nutstore sync

默认使用本地数据库与可选的坚果云 WebDAV，无需为同步开通 Apple Developer Program。

The default configuration uses a local database with optional Nutstore WebDAV sync. Sync itself does not require Apple Developer Program membership.

1. 在坚果云账户安全设置的「第三方应用管理」中，为 Timeline 创建应用密码，参见[官方帮助](https://help.jianguoyun.com/?p=2064)。<br>Create an application password for Timeline under third-party application management in your Nutstore account’s security settings. See [Nutstore’s official guide](https://help.jianguoyun.com/?p=2064).
2. 在 Timeline 的「设置同步」中填写坚果云邮箱与应用密码，点击「保存并同步」。<br>In Timeline’s sync settings, enter your Nutstore email and application password, then select “Save and Sync.”
3. 在其他设备配置同一账号。每台设备需要分别输入应用密码。<br>Configure the same account on your other devices. Enter the application password separately on each device.

服务器固定为 `https://dav.jianguoyun.com/dav/`，同步数据保存在专用 `TimelineSync-v1` 文件夹。不要手动修改该文件夹中的同步文件。

The server is fixed at `https://dav.jianguoyun.com/dav/`. Sync data is stored in the dedicated `TimelineSync-v1` folder. Do not manually edit the sync files in that folder.

- 回收站版本将同步文档格式升级为 **v2**，仍使用现有 `TimelineSync-v1` 目录。请将 Mac 和 iPhone 一起更新后再继续同步。新版可读取 v1 文档；旧版不能读取 v2 文档，会停止同步，不能与新版混用。<br>The Trash update upgrades the sync document format to **v2** while retaining the existing `TimelineSync-v1` directory. Update both Mac and iPhone before continuing to sync. The new version reads v1 documents; older versions cannot read v2 and stop syncing, so do not mix old and new clients.
- 自动同步仅在本机已保存内容较上次成功同步有变化时执行，自动同步请求间隔至少 24 小时。回到应用前台或打开 Mac 菜单栏弹窗时只检查是否满足条件；反复打开不会绕过间隔。本机内容未变化时，请手动同步以接收其他设备的更新。<br>Automatic sync runs only when saved local content has changed since the last successful sync, with at least 24 hours between automatic sync requests. Returning to the foreground or opening the Mac menu bar popover only checks whether these conditions are met; reopening does not bypass the interval. If local content has not changed, sync manually to receive updates from other devices.
- 自动同步仅在应用前台执行。24 小时间隔到期时如果应用未打开，会在下次进入前台且满足本地变化条件时同步；不承诺到期时在后台执行。编辑草稿期间暂停，保存或取消后重新检查条件。<br>Automatic sync runs only while the app is in the foreground. If the app is not open when the 24-hour interval expires, it syncs on the next foreground session when local changes are present; background execution at the deadline is not promised. Sync pauses while a draft is being edited and rechecks the conditions after saving or canceling.
- Mac / iPhone 主界面和菜单栏弹窗的同步状态可点击立即同步，不受 24 小时自动同步间隔限制；账号设置通过独立齿轮进入。上次成功同步时间在重启后保留，失败或编辑暂停不会更新该时间。<br>Click the sync status in the Mac / iPhone main interface or menu bar popover to sync immediately, without the 24-hour automatic sync limit. The separate gear opens account settings. The last successful sync time survives relaunches and is not advanced by a failure or editing pause.
- 应用密码仅保存在当前设备的 Keychain，不写入记录、同步快照或源码。密码框支持显示与隐藏。<br>The application password is stored only in the current device’s Keychain, not in entries, sync snapshots, or source code. The password field supports showing and hiding its contents.
- 从旧版升级后，首次成功同步会建立用于比较内容的基线。若旧版没有留下该基线，会保守保留待同步状态，并继续遵守 24 小时自动间隔。<br>After upgrading, the first successful sync establishes a content-comparison baseline. If an older version did not store one, the app conservatively keeps a pending state while still respecting the 24-hour automatic interval.
- 首次同步前会自动保存本机快照。并发修改保留冲突副本，移入回收站、恢复及到期清理会通过同步传播；这些变化继续遵守自动同步的 24 小时间隔，也可手动立即同步。冲突副本需要自行检查整理。<br>A local snapshot is saved before the first sync. Concurrent edits preserve conflict copies. Moving items to Trash, restoring them, and expiry cleanup propagate through sync under the same 24-hour automatic interval, or immediately through manual sync. Review and reconcile conflict copies yourself.
- 同步使用 HTTPS，云端文件为 JSON，**未额外实现端到端加密**。删除标记和部分旧数据会保留，以处理离线设备重新连接。<br>Sync uses HTTPS, and cloud files are JSON. **Additional end-to-end encryption is not implemented.** Deletion markers and some older data are retained to handle devices reconnecting after being offline.
- 未保存草稿、栏目显示偏好及当前选中项目不跨设备同步。停用同步保留数据；当前设置页暂不支持直接更换已绑定账号。<br>Unsaved drafts, section visibility preferences, and the selected project do not sync across devices. Disabling sync preserves data. The settings screen does not yet support directly changing a linked account.
- 每台设备上传完整快照，单文件上限 20 MB；超限或远端目录不完整时暂停并提示。<br>Each device uploads a full snapshot, with a 20 MB limit per file. Sync pauses and shows an error if a file exceeds the limit or the remote directory listing is incomplete.

## 当前限制 / Current limitations

这是首个公开版本，建议保留重要记录的独立备份。

This is the first public release. Keep an independent backup of important entries.

- 编辑方式为「Markdown 源码 + 实时预览」，尚未实现完整 Typora 式直接编辑渲染文本。<br>The editor uses Markdown source with a live preview. Full Typora-style direct editing of rendered text is not implemented.
- 不支持图片附件、远程图片加载、原始 HTML 执行、多人协作或交互式版本历史。删除可在回收站保留期内恢复，满 30 天自动清理后无法恢复。<br>Image attachments, remote image loading, raw HTML execution, collaboration, and interactive version history are not supported. Deletions can be restored during the Trash retention period, but cannot be restored after automatic cleanup at 30 days.
- 未保存草稿可在当前会话中切换项目后继续编辑；退出后的草稿恢复尚未验收，正式记录请点击保存。<br>Unsaved drafts can be resumed after switching projects within the same session. Recovery after quitting has not been validated; save entries you want to keep.
- 真实 Mac 的坚果云读取与上传已验证，Mac → iPhone 的项目与记录同步已由使用者确认。手机反向编辑、并发修改和远程删除尚未完成独立的双设备实测，详见 [VALIDATION.md](VALIDATION.md)。<br>Real Nutstore reads and uploads have been verified on a Mac, and a user confirmed receiving the Mac’s projects and entries on an iPhone. Edits from iPhone back to Mac, concurrent changes, and remote deletions have not been independently tested across two devices. See [VALIDATION.md](VALIDATION.md).
- 工程保留可选 `Timeline-iCloud` 配置，但未完成 CloudKit 真实同步验收；默认 `Timeline` scheme 使用本地数据库与坚果云。<br>The project retains an optional `Timeline-iCloud` configuration, but real CloudKit sync has not been validated. The default `Timeline` scheme uses the local database and Nutstore.

## 从源码构建 / Build from source

已使用 Xcode 26.3 构建。请先安装 Xcode，并确保命令行开发工具指向完整 Xcode。

The project has been built with Xcode 26.3. Install Xcode and ensure the command-line developer tools point to the full Xcode installation.

```sh
# macOS Release 构建，不配置分发签名 / Build macOS Release without distribution signing
xcodebuild -project Timeline.xcodeproj -scheme Timeline \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build/mac CODE_SIGNING_ALLOWED=NO build

# iOS 模拟器构建 / Build for the iOS simulator
xcodebuild -project Timeline.xcodeproj -scheme Timeline \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/ios-simulator CODE_SIGNING_ALLOWED=NO build
```

真机安装请在 Xcode 配置自己的签名。`--timeline-ui-testing` 仅用于不落盘的临时演示数据，不应在正常使用时添加。

For physical devices, configure your own signing in Xcode. The `--timeline-ui-testing` argument uses temporary, nonpersistent demo data; do not add it for normal use.

在 Mac 上运行离线同步与 WebKit 预加载检查：

Run the offline sync and WebKit preload checks on a Mac:

```sh
zsh Tests/run-nutstore-tests.sh
zsh Tests/run-markdown-preload.sh
```

同步测试使用替身凭据、模拟远端与临时数据库，不访问真实坚果云或个人钥匙串。预加载检查另需 `python3`，结果不代表整界面帧率。

Sync tests use dummy credentials, a simulated remote, and temporary databases. They do not access the real Nutstore service or a personal Keychain. The preload check also requires `python3`; its results do not measure the full interface’s frame rate.

工程主要使用 SwiftUI、SwiftData 与 WebKit。离线 Markdown 依赖、固定版本、校验值及许可证见 [第三方组件说明](Timeline/Resources/Markdown/VENDOR.md)。本仓库尚未选择通用开源许可证；第三方组件继续遵循各自许可证。

The app primarily uses SwiftUI, SwiftData, and WebKit. See [third-party components](Timeline/Resources/Markdown/VENDOR.md) for offline Markdown dependencies, pinned versions, checksums, and licenses. This repository has not selected a general open-source license; third-party components remain subject to their respective licenses.
