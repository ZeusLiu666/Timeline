import Foundation
import SwiftData

/// Execute with Models.swift and TimelineStore.swift. Uses isolated data only.
@main
struct TimelineSmokeTests {
    @MainActor
    static func main() throws {
        func check(_ condition: Bool, _ message: String = "Check failed") { precondition(condition, message) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TimelineChecks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.store")
        let schema = Schema([TimelineProject.self, TimelineEntry.self])
        func open() throws -> ModelContainer {
            try ModelContainer(for: schema, configurations: [ModelConfiguration("Check", schema: schema, url: url, cloudKitDatabase: .none)])
        }
        let projectID = UUID()
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            let container = try open()
            let context = container.mainContext
            let project = TimelineProject(id: projectID, name: "验证项目", colorHex: "C75740")
            context.insert(project)
            let old = TimelineEntry(title: "较早的记录", date: stamp.addingTimeInterval(-86400), project: project)
            let new = TimelineEntry(title: "新进展", date: stamp, status: .completed,
                                    progressText: "## 已完成\n- **本地保存**", issuesText: "- [ ] 待处理",
                                    ideasText: "验证跨次启动", showIssues: false, project: project)
            context.insert(old)
            context.insert(new)
            try context.save()
            check(project.sortedEntries.map(\.title) == ["新进展", "较早的记录"], "Timeline ordering failed")
            check(new.progressPercent == 100, "Completed percentage failed")
            check(new.searchableText.contains("验证项目"), "Search fields failed")
            print("PASS: relationship, date order, status, searchable fields")
        }
        do {
            let container = try open()
            let context = container.mainContext
            let projects = try context.fetch(FetchDescriptor<TimelineProject>())
            check(projects.count == 1 && projects[0].id == projectID, "Project did not persist")
            let records = projects[0].sortedEntries
            check(records.count == 2 && records[0].issuesText == "- [ ] 待处理" && !records[0].showIssues, "Hidden content lost")
            records[0].title = "修改后主题"
            records[0].showIssues = true
            try context.save()
            print("PASS: reopen persisted dates, Markdown and hidden content; editing")
            context.delete(records[1])
            try context.save()
            check(try context.fetchCount(FetchDescriptor<TimelineEntry>()) == 1, "Record deletion failed")
            context.delete(projects[0])
            try context.save()
            check(try context.fetchCount(FetchDescriptor<TimelineEntry>()) == 0, "Cascade deletion failed")
            print("PASS: record deletion and project cascade deletion")
        }
        let defaultsName = "TimelineChecks-\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = TimelineStore(inMemory: true, defaults: defaults)
        check(try store.modelContext.fetchCount(FetchDescriptor<TimelineProject>()) == 3)
        check(try store.modelContext.fetchCount(FetchDescriptor<TimelineEntry>()) == 6)
        let welcomeProjectIDs = Set(try store.modelContext.fetch(FetchDescriptor<TimelineProject>()).map(\.id))
        let welcomeEntryIDs = Set(try store.modelContext.fetch(FetchDescriptor<TimelineEntry>()).map(\.id))
        let project = store.addProject(name: "  新项目  ")
        check(project.name == "新项目")
        let entry = store.addEntry(to: project, title: "  测试记录  ")
        check(entry.title == "测试记录")
        entry.progressText = "Keep **Markdown** and $x^2$"
        entry.issuesText = "- [x] Finished\n- [ ] Pending"
        entry.ideasText = "Keep idea"
        entry.progressPercent = 200
        store.touch(entry)
        check(entry.progressPercent == 100 && store.lastSaveError == nil)
        let child = store.addEntry(to: project, title: "项目内另一条记录")
        let reference = TimelineReference(sourceEntryID: entry.id, sourceTitle: entry.title, sourceDate: entry.date,
                                          excerpt: entry.progressText, contextBefore: "Before", contextAfter: "After")
        child.references = [reference]
        project.pendingReferences = [reference]
        check(store.save())
        // Compare the actually stored codec payload. Date() may include a
        // fraction finer than the JSON codec's millisecond precision.
        // 比较赋值后实际存储的 JSON；原始 Date() 的亚毫秒精度不属于持久化契约。
        let originalChildReferencesJSON = child.referencesJSON
        let originalPendingReferencesJSON = project.pendingReferencesJSON
        let originalChildReferences = TimelineReferenceCodec.decode(originalChildReferencesJSON)
        let originalPendingReferences = TimelineReferenceCodec.decode(originalPendingReferencesJSON)
        let originalEntryID = entry.id, originalChildID = child.id, originalProjectID = project.id

        check(store.deleteEntry(entry), "Store failed to move entry to trash")
        let firstDeletionDate = entry.deletedAt!
        check(entry.isTrashed && entry.project?.id == project.id && project.sortedEntries.map(\.id) == [child.id], "Entry trash lost its parent or stayed visible")
        check(try store.modelContext.fetchCount(FetchDescriptor<TimelineEntry>()) == 8, "Store physically deleted a trashed entry")
        check(!store.deleteEntry(entry) && entry.deletedAt == firstDeletionDate, "Repeated deletion reset the retention clock")
        check(store.restoreEntry(entry) && entry.id == originalEntryID && !entry.isTrashed, "Store failed to restore the same entry")
        check(entry.progressText == "Keep **Markdown** and $x^2$" && entry.issuesText == "- [x] Finished\n- [ ] Pending" && entry.ideasText == "Keep idea", "Store restore changed record contents")
        check(!store.restoreEntry(entry), "Restoring an active record claimed to change it")
        print("PASS: Store entry trash retains identity, contents, relationship and supports restoration")

        check(store.deleteEntry(entry))
        let independentDeletionDate = entry.deletedAt!
        check(store.deleteProject(project), "Store failed to move project to trash")
        check(project.isTrashed && entry.isTrashed && child.isTrashed && child.deletedAt == nil && project.sortedEntries.isEmpty, "Project trash did not hide children through their parent")
        check(try store.modelContext.fetchCount(FetchDescriptor<TimelineProject>()) == 4 && store.modelContext.fetchCount(FetchDescriptor<TimelineEntry>()) == 8, "Store physically cascaded a project soft deletion")
        check(!store.restoreEntry(entry), "Entry restored while its parent was still in trash")
        check(store.restoreProject(project) && project.id == originalProjectID && !project.isTrashed, "Store did not restore the same project")
        check(!child.isTrashed && child.id == originalChildID && entry.isTrashed && entry.deletedAt == independentDeletionDate, "Project restore revived an independently deleted entry")
        check(child.referencesJSON == originalChildReferencesJSON && project.pendingReferencesJSON == originalPendingReferencesJSON,
              "Project trash/restore changed stored reference snapshot JSON")
        check(child.references == originalChildReferences && project.pendingReferences == originalPendingReferences,
              "Project trash/restore changed decoded reference snapshots")
        check(store.restoreEntry(entry) && project.sortedEntries.count == 2, "Explicit child restore did not restore its timeline visibility")
        check(!store.restoreProject(project), "Restoring an active project claimed to change it")
        print("PASS: Store project trash preserves children; restoration leaves independent trash intact")

        check(store.deleteEntry(entry))
        let entryExpiry = entry.deletedAt!.addingTimeInterval(30 * 86_400)
        check(!store.purgeExpiredTrash(now: entryExpiry.addingTimeInterval(-0.001)), "Store purged an entry before 30 days")
        check(store.purgeExpiredTrash(now: entryExpiry), "Store did not purge entry at the 30-day boundary")
        check(try store.modelContext.fetchCount(FetchDescriptor<TimelineEntry>()) == 7 && store.modelContext.fetchCount(FetchDescriptor<TimelineProject>()) == 4, "Entry expiry removed its parent or left expired entry data")
        check(try !store.modelContext.fetch(FetchDescriptor<TimelineEntry>()).contains { $0.id == originalEntryID }, "Expired entry UUID remained in the store")
        check(child.referencesJSON == originalChildReferencesJSON && child.references == originalChildReferences,
              "Permanent source deletion changed an attached reference snapshot")

        check(store.deleteProject(project))
        let projectExpiry = project.deletedAt!.addingTimeInterval(30 * 86_400)
        check(!store.purgeExpiredTrash(now: projectExpiry.addingTimeInterval(-0.001)), "Store purged a project before 30 days")
        check(store.purgeExpiredTrash(now: projectExpiry), "Store did not purge project at the 30-day boundary")
        check(Set(try store.modelContext.fetch(FetchDescriptor<TimelineProject>()).map(\.id)) == welcomeProjectIDs, "Project expiry changed unrelated projects")
        check(Set(try store.modelContext.fetch(FetchDescriptor<TimelineEntry>()).map(\.id)) == welcomeEntryIDs, "Expired project failed to cascade or removed unrelated records")
        check(!store.purgeExpiredTrash(now: projectExpiry), "Repeated completed purge claimed another change")
        check(!store.isCloudEnabled && store.save())
        print("PASS: Store entry/project expiry obeys 30-day boundary, cascades, and preserves unrelated data")
        print("PASS: sample data, store CRUD, percentage bounds, local-only state")
        print("All Timeline model and persistence checks passed.")
    }
}
