# v0.1.0 发布审计 / Release audit

审计日期：2026-10-16。范围为本次公开仓库的首个提交、macOS 应用、源码压缩包、校验文件及 Release 说明，不包括开发工作区和个人应用数据。

Audit date: October 16, 2026. Scope: the initial public repository commit, macOS app, source archive, checksums, and Release notes. The development workspace and personal app data are outside the published content.

## 个人信息与敏感信息 / Personal and sensitive information

- 扫描源码、资源、文档和 macOS 二进制，未发现真实登录邮箱、账号密码、API 密钥、访问令牌、私钥、个人 Team ID、设备 UDID、私有服务器地址或本机用户目录。Gitleaks 8.30.1 默认规则扫描未检出密钥。<br>Source, resources, documentation, and the macOS binary were scanned. No real login email, password, API key, access token, private key, personal Team ID, device UDID, private server address, or local user-directory path was found. Gitleaks 8.30.1 found no secrets using its default rules.
- 公开内容不包含个人数据库、坚果云同步快照或配置、Keychain 导出、日志、备份、个人截图、iPhone 安装包、设备描述文件或签名证书。测试邮箱使用保留的 `.invalid` 域名。<br>Published content excludes personal databases, Nutstore snapshots and settings, Keychain exports, logs, backups, personal screenshots, iPhone packages, provisioning profiles, and signing certificates. Test email addresses use the reserved `.invalid` domain.
- macOS 应用使用本地 ad-hoc 签名，无个人签名身份或 TeamIdentifier，严格签名完整性校验通过。既有 Bundle ID、Keychain 服务名和可选 CloudKit 命名空间保留，用于版本兼容；这些是应用标识，不是登录凭据。<br>The macOS app uses a local ad-hoc signature without a personal signing identity or TeamIdentifier, and strict signature integrity verification passed. Existing bundle, Keychain-service, and optional CloudKit namespaces remain for version compatibility; they identify the app and are not login credentials.
- 检查 13 张图标图片，未发现 GPS、设备型号、序列号、拥有者或个人作者标签。两个设计母版保留公开的图像生成来源信息，其余 EXIF 仅为色彩空间和尺寸。<br>All 13 icon images were checked for GPS, device models, serial numbers, owners, and personal author tags, with none found. The two design masters retain public image-generation provenance; other EXIF data contains only color-space and image-dimension information.
- 采用隔离的源码目录创建首次 Git 历史，提交身份使用 GitHub noreply 邮箱；历史内容和提交元数据均经过检查。<br>The initial Git history was created from an isolated source directory using a GitHub noreply email. Both historical content and commit metadata were reviewed.
- 发布附件采用明确白名单。压缩包不包含 AppleDouble、`__MACOSX`、用户扩展属性副本、开发缓存或个人签名文件；附件内容与审核后的文件一致。<br>Release assets use an explicit allowlist. Archives exclude AppleDouble, `__MACOSX`, copies of user extended attributes, development caches, and personal signing files, and match the reviewed files.

## 依赖与验证 / Dependencies and validation

- 70 个固定第三方资源与许可证的 SHA-256 与清单一致。固定版本依赖的 npm audit 报告为 0 项已知漏洞；原版第三方许可证原文保留。<br>SHA-256 values for 70 pinned third-party resources and license files match their manifest. The pinned dependency npm audit reported zero known vulnerabilities. Upstream license texts remain unchanged.
- macOS Release 通用构建通过，包含 Apple Silicon 与 Intel。离线同步、回收站、Markdown、WebKit 预加载，以及持久化、清单、年份标记、引用、保存失败恢复测试全部通过。<br>The universal macOS Release build passed for Apple Silicon and Intel. Offline sync, Trash, Markdown, WebKit preload, persistence, checklist, year-label, reference, and save-failure recovery tests all passed.
- 文档和 Release 说明保持中英文对照。iPhone 因个人开发、仅有短期开发签名而不发布安装包；iOS 源码仍包含在仓库和源码附件中。<br>Documentation and Release notes are bilingual in Chinese and English. No iPhone installation package is published because the independently developed app has only a short-lived development signature; iOS source remains in the repository and source asset.

## 范围边界 / Scope and limits

上述结论表示在本次审核快照内未检出所列信息，不是对所有未知秘密或未来修改的绝对保证。应用真实同步、设备交互及功能限制见 [VALIDATION.md](VALIDATION.md)。仓库尚未选择通用开源许可证，第三方组件遵循各自许可证。

These results mean the listed information was not detected in this reviewed snapshot; they are not an absolute guarantee about every unknown secret or future change. See [VALIDATION.md](VALIDATION.md) for live-sync, device-interaction, and functional limits. The repository has not selected a general open-source license; third-party components retain their own licenses.
