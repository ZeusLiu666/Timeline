# 离线 Markdown 渲染器依赖 / Offline Markdown renderer dependencies

Timeline 内置以下固定版本的发行包。运行时不使用 CDN、远程字体、遥测或远程渲染。

Timeline bundles these pinned distributions. No CDN, remote fonts, telemetry, or remote rendering is used at runtime.

| 依赖 / Dependency | 固定版本 / Pinned version | 官方上游 / Official upstream | 发行包 / Distribution |
| --- | --- | --- | --- |
| markdown-it | 15.0.2 | https://github.com/markdown-it/markdown-it | https://registry.npmjs.org/markdown-it/-/markdown-it-15.0.2.tgz |
| DOMPurify | 3.4.16 | https://github.com/cure53/DOMPurify | https://registry.npmjs.org/dompurify/-/dompurify-3.4.16.tgz |
| KaTeX、auto-render、CSS 和字体 / KaTeX, auto-render, CSS and fonts | 0.19.0 | https://github.com/KaTeX/KaTeX | https://registry.npmjs.org/katex/-/katex-0.19.0.tgz |
| markdown-it-task-lists | 2.1.1 | https://github.com/revin/markdown-it-task-lists | https://registry.npmjs.org/markdown-it-task-lists/-/markdown-it-task-lists-2.1.1.tgz |

任务列表包的浏览器构建带有上游 2.1.0 版本注释；实际固定的 npm 包版本为 2.1.1。许可证原文保留在 `licenses/`。`vendor-checksums.json` 记录打包依赖资源及许可证的 SHA-256。KaTeX auto-render 作为上游发行资源保留；Timeline 实际使用自定义 Markdown 数学语法标记，避免 Markdown 在公式渲染前消耗 LaTeX 的反斜杠。

The task-list package's browser bundle carries an upstream 2.1.0 comment; the pinned npm package is 2.1.1. Licenses are retained verbatim in `licenses/`. `vendor-checksums.json` records SHA-256 for bundled vendor assets and licenses. KaTeX auto-render is retained as an upstream distribution asset; Timeline uses custom Markdown math tokens instead so Markdown does not consume LaTeX backslashes before equations are rendered.

发行包归档的 SHA-256 / Package archive SHA-256 values:

- markdown-it: `3237f5ecac432f99453e6d8d345b6e4764a22f1781c96e02dc9e89777b9c23c1`
- DOMPurify: `d288ced25e6bda3e5fc76d1fc9bca899260cf886e005e84f232e686ada57f1b4`
- KaTeX: `d8e49f2fea6eeed7cdae2cf4fd48e2f1d348758aa9e5740715e4533c2c96d1ee`
- markdown-it-task-lists: `8e9ed515296f11d716a6460c0bd35ffa163003a373a6d8f65d53ea9f8aec667e`

markdown-it 禁用原始 HTML，Markdown 输出经过 DOMPurify 清理；公式使用 KaTeX 渲染，并设置 `trust: false`、`maxExpand: 1000` 和 `maxSize: 20`。严格的内容安全策略及原生内容拦截规则阻止自动网络加载。Markdown 图片显示为可读占位文字。原生应用只可打开由用户主动点击的 HTTP、HTTPS 或邮件链接。

Raw HTML is disabled in markdown-it, Markdown output is sanitized with DOMPurify, and formulas use KaTeX with `trust: false`, `maxExpand: 1000`, and `maxSize: 20`. A restrictive Content Security Policy and native content-blocking rules prevent automatic network loads. Markdown images display a readable placeholder. Only user-activated HTTP, HTTPS, or email links may be opened by the native app.

回归检查入口：加载 `index.html` 后，调用 `window.timelineRender(source)` 或 `window.TimelineMarkdown.render(source, false)`，返回已渲染公式数及公式错误数。`window.TimelineMarkdown.markdownHTML(source)` 提供清理前的解析器输出，供检查语法标记的行为，不能用于在其他位置插入不可信 HTML。

Regression entry point: after loading `index.html`, call `window.timelineRender(source)` or `window.TimelineMarkdown.render(source, false)`; it returns the number of rendered formulas and formula errors. `window.TimelineMarkdown.markdownHTML(source)` exposes the pre-sanitization parser output for inspecting token behavior, not for inserting untrusted HTML elsewhere.
