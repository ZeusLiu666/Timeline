import Foundation
import SwiftData

/// Isolated, on-disk stores exercise retention and relationship preservation.
/// 独立临时数据库验证保留期限、关系与重开持久性，不接触用户数据。
@main
@MainActor
struct TimelineTrashTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let retention: TimeInterval = 30 * 86_400

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }

    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message) }
    }

    @MainActor final class Store {
        let directory: URL
        var container: ModelContainer
        var context: ModelContext { container.mainContext }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("Timeline-TrashTest-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            container = try Self.open(directory)
        }

        static func open(_ directory: URL) throws -> ModelContainer {
            let schema = Schema([TimelineProject.self, TimelineEntry.self])
            let configuration = ModelConfiguration("TrashTest", schema: schema, url: directory.appendingPathComponent("test.store"), cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            container.mainContext.autosaveEnabled = false
            return container
        }

        func reopen() throws { container = try Self.open(directory) }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }

        func seed() throws -> (TimelineProject, TimelineEntry, TimelineEntry) {
            let project = TimelineProject(name: "Trash fixture", icon: "flask", colorHex: "456789", sortOrder: 7, createdAt: now.addingTimeInterval(-retention * 2))
            let source = TimelineEntry(title: "First record", date: now.addingTimeInterval(-86_400), status: .paused, progressPercent: 37,
                                       progressText: "Preserve **Markdown** and $x^2$", issuesText: "- [x] Retain checklist\n- [ ] Continue", ideasText: "A useful idea",
                                       showProgress: true, showIssues: false, showIdeas: true, project: project, createdAt: now.addingTimeInterval(-100), updatedAt: now.addingTimeInterval(-50))
            let child = TimelineEntry(title: "Second record", progressText: "Another intact record", project: project, createdAt: now, updatedAt: now)
            context.insert(project); context.insert(source); context.insert(child)
            let quote = TimelineReference(sourceEntryID: source.id, sourceTitle: source.title, sourceDate: source.date,
                                          excerpt: "Markdown", contextBefore: "Preserve ", contextAfter: " and formula", createdAt: now)
            child.references = [quote]
            project.pendingReferences = [quote]
            try context.save()
            return (project, source, child)
        }
    }

    static func projectRestorePreservesIndependentEntryDeletion() throws {
        let store = try Store()
        defer { store.cleanup() }
        let (project, first, second) = try store.seed()
        let projectID = project.id, firstID = first.id, secondID = second.id
        let pending = project.pendingReferencesJSON, references = second.referencesJSON
        let createdAt = first.createdAt, updatedAt = first.updatedAt, entryDate = first.date
        let independentDeletion = now.addingTimeInterval(-1_000)
        first.deletedAt = independentDeletion
        project.deletedAt = now
        try store.context.save()
        try check(project.isTrashed && first.isTrashed && second.isTrashed, "Deleting a project must hide every child without changing their own deletion state.")
        try check(second.deletedAt == nil, "Project trash mutated the active child's own deletion date.")
        try check(project.sortedEntries.isEmpty, "Trashed project exposed a normal timeline.")
        try store.reopen()
        let restored = try store.context.fetch(FetchDescriptor<TimelineProject>()).first { $0.id == projectID }!
        let entries = try store.context.fetch(FetchDescriptor<TimelineEntry>())
        let firstReloaded = entries.first { $0.id == firstID }!, secondReloaded = entries.first { $0.id == secondID }!
        try check(restored.deletedAt == now && firstReloaded.deletedAt == independentDeletion && secondReloaded.deletedAt == nil,
                  "Restart lost project trash or independent entry trash metadata.")
        try check(firstReloaded.project?.id == projectID && secondReloaded.project?.id == projectID && restored.entries?.count == 2,
                  "Trash or reopening severed the project-child relationship.")
        restored.deletedAt = nil
        try store.context.save()
        try check(!restored.isTrashed && firstReloaded.isTrashed && !secondReloaded.isTrashed,
                  "Restoring a project also restored an independently deleted entry.")
        try check(restored.sortedEntries.map(\.id) == [secondID], "The restored project timeline included independently deleted content.")
        try check(restored.name == "Trash fixture" && restored.icon == "flask" && restored.colorHex == "456789" && restored.sortOrder == 7,
                  "Project metadata changed during trash/restore.")
        try check(restored.pendingReferencesJSON == pending && secondReloaded.referencesJSON == references,
                  "Project trash/restore changed pending or attached reference snapshots.")
        try check(firstReloaded.progressText == "Preserve **Markdown** and $x^2$" && firstReloaded.issuesText == "- [x] Retain checklist\n- [ ] Continue"
                  && firstReloaded.ideasText == "A useful idea" && firstReloaded.progress == "paused" && firstReloaded.progressPercent == 37
                  && firstReloaded.showProgress && !firstReloaded.showIssues && firstReloaded.showIdeas,
                  "Trashing changed record contents, checklist state, or visible sections.")
        try check(firstReloaded.createdAt == createdAt && firstReloaded.updatedAt == updatedAt && firstReloaded.date == entryDate,
                  "Trash metadata overwrote record timestamps.")
        firstReloaded.deletedAt = nil
        try store.context.save()
        try store.reopen()
        let reopened = try store.context.fetch(FetchDescriptor<TimelineProject>()).first { $0.id == projectID }!
        try check(reopened.sortedEntries.count == 2 && reopened.sortedEntries.allSatisfy { !$0.isTrashed }, "Explicit restoration did not survive reopening.")
    }

    static func exactEntryRetentionBoundary() throws {
        let store = try Store()
        defer { store.cleanup() }
        let (project, first, second) = try store.seed()
        let firstID = first.id, secondID = second.id, projectID = project.id
        first.deletedAt = now.addingTimeInterval(-retention)
        second.deletedAt = now.addingTimeInterval(-retention + 0.001)
        try store.context.save()
        try check(try TimelineTrashSupport.purgeExpired(in: store.context, now: now), "An entry exactly 30 days old was not purged.")
        try store.context.save()
        try store.reopen()
        let entries = try store.context.fetch(FetchDescriptor<TimelineEntry>())
        try check(!entries.contains { $0.id == firstID } && entries.contains { $0.id == secondID },
                  "Retention did not distinguish exactly 30 days from 1 ms before expiry.")
        try check(try store.context.fetch(FetchDescriptor<TimelineProject>()).contains { $0.id == projectID }, "Purging an entry removed its parent.")
        try check(!(try TimelineTrashSupport.purgeExpired(in: store.context, now: now)), "A no-op purge claimed it changed the store.")
        try check(try TimelineTrashSupport.purgeExpired(in: store.context, now: now.addingTimeInterval(0.001)), "The remaining entry did not expire at its exact boundary.")
        try store.context.save()
        try check(try store.context.fetchCount(FetchDescriptor<TimelineEntry>()) == 0, "An expired entry remained after saving the purge.")
    }

    static func projectCascadeBoundaryAndRestoredProtection() throws {
        let store = try Store()
        defer { store.cleanup() }
        let (project, first, second) = try store.seed()
        let projectID = project.id
        project.deletedAt = now.addingTimeInterval(-retention)
        first.deletedAt = nil
        second.deletedAt = now // A younger independent deletion must still cascade with its expired parent.
        let active = TimelineProject(name: "Restored project", createdAt: now.addingTimeInterval(-retention * 10))
        let activeEntry = TimelineEntry(title: "Restored entry", date: now.addingTimeInterval(-retention * 10), project: active)
        store.context.insert(active); store.context.insert(activeEntry)
        let activeID = active.id, activeEntryID = activeEntry.id
        active.deletedAt = now.addingTimeInterval(-retention * 2); active.deletedAt = nil
        activeEntry.deletedAt = now.addingTimeInterval(-retention * 2); activeEntry.deletedAt = nil
        try store.context.save()
        try check(try TimelineTrashSupport.purgeExpired(in: store.context, now: now), "An expired project was not purged.")
        try store.context.save()
        try store.reopen()
        let projects = try store.context.fetch(FetchDescriptor<TimelineProject>())
        let entries = try store.context.fetch(FetchDescriptor<TimelineEntry>())
        try check(!projects.contains { $0.id == projectID } && projects.map(\.id) == [activeID], "Expired project purge removed a restored project or left the expired one.")
        try check(entries.map(\.id) == [activeEntryID] && entries.first?.project?.id == activeID,
                  "Expired project cascade orphaned children or removed a restored entry.")
    }

    static func purgeDoesNotSaveUnrelatedChanges() throws {
        let store = try Store()
        defer { store.cleanup() }
        let (project, first, _) = try store.seed()
        let firstID = first.id
        first.deletedAt = now.addingTimeInterval(-retention)
        try store.context.save()
        project.name = "Unsaved unrelated draft"
        _ = try TimelineTrashSupport.purgeExpired(in: store.context, now: now)
        try check(store.context.hasChanges, "Purge saved unrelated edits without caller authorization.")
        store.context.rollback()
        try store.reopen()
        let entry = try store.context.fetch(FetchDescriptor<TimelineEntry>()).first { $0.id == firstID }
        try check(entry?.deletedAt == now.addingTimeInterval(-retention), "Purge saved its deletion instead of allowing rollback.")
        try check(try store.context.fetch(FetchDescriptor<TimelineProject>()).first?.name == "Trash fixture", "Purge committed an unrelated draft.")
    }

    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("project restore preserves children, metadata, and independent trash", projectRestorePreservesIndependentEntryDeletion),
            ("entry purge at exact 30-day boundary", exactEntryRetentionBoundary),
            ("expired project cascades while restored content survives", projectCascadeBoundaryAndRestoredProtection),
            ("purge remains caller-saveable and rollback-safe", purgeDoesNotSaveUnrelatedChanges)
        ]
        var failures = 0
        for (name, test) in tests {
            do { try test(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        print("Timeline trash tests: \(tests.count - failures) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
