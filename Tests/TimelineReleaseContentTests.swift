import Foundation
import SwiftData

/// Checks the exact generic welcome content used by a fresh release workspace.
@main @MainActor
struct TimelineReleaseContentTests {
    static func main() throws {
        let suite = "TimelineReleaseContentChecks-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TimelineStore(inMemory: true, defaults: defaults)
        let projects = try store.modelContext.fetch(FetchDescriptor<TimelineProject>())
        let entries = try store.modelContext.fetch(FetchDescriptor<TimelineEntry>())
        let expectedProjects = Set(["Timeline", "研究与探索", "个人计划"])
        let expectedTitles = Set(["让每一次进展，都有迹可循", "确定时间线的信息层级", "从一个小而完整的版本开始",
                                  "把阅读变成可以继续的问题", "建立轻量的研究记录习惯", "给重要的事情留一点时间"])
        precondition(projects.count == 3 && Set(projects.map(\.name)) == expectedProjects)
        precondition(entries.count == 6 && Set(entries.map(\.title)) == expectedTitles)
        precondition(projects.allSatisfy { $0.deletedAt == nil && $0.pendingReferences.isEmpty })
        precondition(entries.allSatisfy { $0.project != nil && $0.references.isEmpty && !$0.isTrashed })
        precondition(!store.nutstoreConfigured && store.nutstoreUsername().isEmpty)
        precondition(Set(projects.flatMap { $0.entries?.map(\.id) ?? [] }) == Set(entries.map(\.id)))
        print("PASS: three allowlisted sample projects, six allowlisted sample entries, no linked account or saved references")
    }
}
