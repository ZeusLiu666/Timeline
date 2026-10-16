# Timeline v0.1.1 — 编辑区修复 / Editor layout fix

修复长记录只能在小输入框内滚动的问题，编辑区现在跟随内容自动增高或缩短，并始终保留末尾书写空白。

Fixes long entries being constrained to a small scrolling input. Editors now grow or shrink with their content and always retain blank writing space at the end.

## 更新内容 / Changes

- 正文输入区按实际换行计算高度；原位编辑随主页面统一滚动，窗口宽度变化时重新排版。<br>Source fields size to actual wrapped text. Inline editing scrolls with the main page and reflows when the window width changes.
- 末尾始终保留约四行空白，长文、短文和删除回缩后均适用。<br>Roughly four blank lines remain at the end of long or short text and after deleting content.
- 修正原生输入焦点衔接，验证粘贴、撤销、保存及 Markdown / 公式实时预览。<br>Corrected native focus handling and verified paste, undo, save, and live Markdown / formula previews.
- 全新且未绑定同步账号的空数据库只生成 3 个通用示例项目、6 条示例记录；升级保留已有内容。<br>A fresh empty database with no linked sync account generates only three generic sample projects and six sample entries. Upgrades preserve existing content.

## 隐私核查 / Privacy review

重新从 GitHub 下载并检查了 v0.1.0 的公开附件及完整 Git 历史，未发现真实项目、记录、个人数据库、同步配置或凭据，因此无需下架。v0.1.1 的源码、提交、二进制和归档同样经过审计；发布目录不包含开发工作区、个人截图或备份。

The public v0.1.0 assets and full Git history were downloaded from GitHub and reviewed again. No real projects, entries, personal databases, sync settings, or credentials were found, so no takedown was needed. The v0.1.1 source, commits, binary, and archives were also audited; development workspaces, personal screenshots, and backups are excluded.

应用在你的设备上显示已有真实项目，是读取本机数据或你自己绑定的同步账号；这些内容不在发行包中。不会为显示示例而清除你的记录。

Existing real projects shown on your device come from your local data or your own linked sync account. They are not in the release package. Your entries are never cleared to display samples.

## 下载 / Downloads

| 文件 / File | 内容 / Contents |
| --- | --- |
| `Timeline-macOS.zip` | macOS 14+ 通用应用，支持 Apple Silicon 与 Intel。<br>Universal macOS 14+ app for Apple Silicon and Intel. |
| `Timeline-source.zip` | macOS / iOS 工程、双语文档及测试。<br>macOS / iOS project, bilingual documentation, and tests. |
| `SHA256SUMS.txt` | 两个压缩包的 SHA-256 校验值。<br>SHA-256 checksums for both archives. |

将解压后的 `Timeline.app` 拖入「应用程序」。macOS 包为本地 ad-hoc 签名，尚未经过 Apple Developer ID 公证，首次打开可能出现系统安全提示。详见 [README](https://github.com/ZeusLiu666/Timeline/blob/main/README.md)。

Drag the extracted `Timeline.app` into Applications. The macOS package is locally ad-hoc signed and has not been notarized through Apple Developer ID, so macOS may show a security prompt on first launch. See the [README](https://github.com/ZeusLiu666/Timeline/blob/main/README.md).

## iPhone 暂不发布安装包 / No iPhone installation package

这是个人开发项目，目前 iPhone 仅使用普通 Apple 账号的短期 Personal Team 开发签名，需要定期重新签名，不适合长期向他人分发。因此本次继续不提供 IPA、App Store 或 TestFlight 安装包。iOS / iPadOS 17+ 源码保留，可使用自己的 Apple 账号和 Xcode 签名安装。

This is an independently developed project. The iPhone app currently uses a short-lived Personal Team development signature from a regular Apple Account and requires periodic re-signing, making it unsuitable for ongoing distribution to others. This release therefore provides no IPA, App Store, or TestFlight package. iOS / iPadOS 17+ source remains available for signing and installation with your own Apple Account and Xcode.

[验证范围 / Validation](https://github.com/ZeusLiu666/Timeline/blob/main/VALIDATION.md) · [发布审计 / Release audit](https://github.com/ZeusLiu666/Timeline/blob/main/RELEASE-AUDIT.md)
