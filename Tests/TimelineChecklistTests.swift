import Foundation

@main
struct TimelineChecklistTests {
    static func main() {
        let source = "## 问题\n\n- 保留 **原文**\n- [x] 已解决\n普通问题\n\n```swift\n- 不是任务\n```"
        let checked = IssueChecklistSupport.togglingTask(in: source, atLine: 2)
        precondition(checked == source.replacingOccurrences(of: "- 保留 **原文**", with: "- [x] 保留 **原文**"), "Toggling must preserve unrelated Markdown")
        let unchecked = IssueChecklistSupport.togglingTask(in: source, atLine: 3)
        precondition(unchecked.contains("- [ ] 已解决"), "Completed issue must become open")
        let plain = IssueChecklistSupport.togglingTask(in: source, atLine: 4)
        precondition(plain.contains("- [x] 普通问题"), "Plain issue must become a persisted task")
        let progress = "- [x] 已完成\n- [ ] 下一步\n```md\n- [x] 代码原文\n```"
        precondition(IssueChecklistSupport.progressDisplaySource(progress) == "- 已完成\n- 下一步\n```md\n- [x] 代码原文\n```", "Progress must use bullets without changing code")
        precondition(EntryEditorSupport.title(explicit: "", progress: "\n- [x] **完成快速记录**\n第二行", issues: "", ideas: "") == "完成快速记录", "Content-only records need a clean automatic title")
        precondition(EntryEditorSupport.title(explicit: "  自定主题  ", progress: "其他正文", issues: "", ideas: "") == "自定主题", "An explicit title must be preserved")
        precondition(EntryEditorSupport.title(explicit: "", progress: "", issues: "- [ ] 待解决的问题", ideas: "") == "待解决的问题", "Issue-only records must save")
        precondition(EntryEditorSupport.title(explicit: "", progress: String(repeating: "长", count: 80), issues: "", ideas: "").count == 36, "Automatic titles must stay short")
        print("PASS: issue toggle and reopen markers; Markdown/blank lines preserved; progress dots; fenced code unchanged")
    }
}
