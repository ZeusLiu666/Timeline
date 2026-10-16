import Foundation
import SwiftData
import SwiftUI

/// Compile with the production Swift sources except TimelineApp.swift.
/// These tests call the production save operation; no save implementation is copied.
/// Returning false from persist injects a failure at its normal persistence boundary.
@main
struct TimelineSaveFailureTests {
    @MainActor
    static func main() throws {
        func check(_ value: Bool, _ message: String) { precondition(value, message) }

        let schema = Schema([TimelineProject.self, TimelineEntry.self])
        let configuration = ModelConfiguration("SaveFailureTests", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        context.autosaveEnabled = true

        let originalDate = Date(timeIntervalSince1970: 20)
        let originalUpdatedAt = Date(timeIntervalSince1970: 10)
        let project = TimelineProject(name: "Save failure checks")
        let existing = TimelineEntry(
            title: "Before", date: originalDate, status: .paused, progressPercent: 37,
            progressText: "before progress", issuesText: "before issues", ideasText: "before ideas",
            showProgress: false, showIssues: true, showIdeas: false, project: project, updatedAt: originalUpdatedAt
        )
        let unrelated = TimelineEntry(title: "Unrelated", project: project)
        let originalReference = TimelineReference(sourceEntryID: UUID(), sourceTitle: "Original source", sourceDate: originalDate, excerpt: "original attached quote", createdAt: originalDate)
        let reference = TimelineReference(sourceEntryID: UUID(), sourceTitle: "New source", sourceDate: originalDate, excerpt: "new quote", createdAt: originalDate)
        let retained = TimelineReference(sourceEntryID: UUID(), sourceTitle: "Retained source", sourceDate: originalDate, excerpt: "keep on shelf", createdAt: originalDate)
        existing.references = [originalReference]
        project.pendingReferences = [reference, retained]
        context.insert(project)
        context.insert(existing)
        context.insert(unrelated)
        try context.save()

        // This edit must survive a failed save elsewhere in the same context.
        unrelated.progressText = "unrelated unsaved edit"
        let originalPendingJSON = project.pendingReferencesJSON
        let originalReferencesJSON = existing.referencesJSON
        let originalEntryID = existing.id
        let originalCreatedAt = existing.createdAt
        let originalProjectEntries = Set((project.entries ?? []).map(\.id))
        let draft = EntryDraft(
            title: "After", date: Date(timeIntervalSince1970: 100), progress: EntryStatus.completed.rawValue,
            progressPercent: 100, progressText: "after progress", issuesText: "after issues", ideasText: "after ideas",
            showProgress: true, showIssues: false, showIdeas: true, references: [reference]
        )

        var existingSaveCalls = 0
        let failedExistingSave = TimelineEntrySaveOperation.save(
            draft, project: project, existingEntry: existing,
            additionalReferences: [reference, retained], context: context
        ) { entry in
            existingSaveCalls += 1
            entry.updatedAt = .now
            return false
        }
        check(!failedExistingSave && existingSaveCalls == 1, "Existing save reports failure after exactly one persistence attempt")
        check(existing.title == "Before" && existing.date == originalDate, "Title and date restored")
        check(existing.progress == EntryStatus.paused.rawValue && existing.progressPercent == 37, "Status and percentage restored")
        check(existing.progressText == "before progress" && existing.issuesText == "before issues" && existing.ideasText == "before ideas", "Every text field restored")
        check(!existing.showProgress && existing.showIssues && !existing.showIdeas, "Column visibility restored")
        check(existing.referencesJSON == originalReferencesJSON && existing.updatedAt == originalUpdatedAt, "Attached reference JSON and timestamp restored exactly")
        check(existing.id == originalEntryID && existing.createdAt == originalCreatedAt && existing.project?.id == project.id, "Identity, creation date and project remain intact")
        check(project.pendingReferencesJSON == originalPendingJSON, "Failed save does not consume pending references")
        check(unrelated.progressText == "unrelated unsaved edit", "Failure does not roll back unrelated unsaved edits")
        check(context.autosaveEnabled, "Autosave restored to its prior enabled setting")

        let countBefore = try context.fetchCount(FetchDescriptor<TimelineEntry>())
        context.autosaveEnabled = false
        var newSaveCalls = 0
        var rejectedEntryID: UUID?
        let failedNewSave = TimelineEntrySaveOperation.save(
            draft, project: project, existingEntry: nil,
            additionalReferences: [reference], context: context
        ) { entry in
            newSaveCalls += 1
            rejectedEntryID = entry.id
            check(entry.progressText == draft.progressText && entry.references == draft.references, "New record is complete before its sole persistence attempt")
            return false
        }
        check(!failedNewSave && newSaveCalls == 1, "New save reports failure after exactly one persistence attempt")
        let entriesAfterFailure = try context.fetch(FetchDescriptor<TimelineEntry>())
        check(entriesAfterFailure.count == countBefore && !entriesAfterFailure.contains { $0.id == rejectedEntryID }, "Failed new record does not remain fetchable")
        check(Set((project.entries ?? []).map(\.id)) == originalProjectEntries, "Failed new record removed from project relationship")
        check(context.insertedModelsArray.filter { $0 is TimelineEntry }.isEmpty, "Failed new record removed from insertion queue")
        check(context.deletedModelsArray.filter { ($0 as? TimelineEntry)?.id == rejectedEntryID }.isEmpty, "Failed new record leaves no pending deletion")
        check(project.pendingReferencesJSON == originalPendingJSON && unrelated.progressText == "unrelated unsaved edit", "New-record failure preserves pending references and unrelated edits")
        check(!context.autosaveEnabled, "Autosave restored to its prior disabled setting")

        var successfulSaveCalls = 0
        let successfulSave = TimelineEntrySaveOperation.save(
            draft, project: project, existingEntry: nil,
            additionalReferences: [reference, retained], context: context
        ) { _ in
            successfulSaveCalls += 1
            do { try context.save(); return true } catch { return false }
        }
        check(successfulSave && successfulSaveCalls == 1, "Successful operation persists exactly once")
        check(project.pendingReferences.map(\.id) == [retained.id], "Success consumes only additional references retained in the saved draft")
        let savedEntries = try context.fetch(FetchDescriptor<TimelineEntry>())
        check(savedEntries.count == countBefore + 1, "Successful retry creates exactly one complete record")
        check(savedEntries.contains { $0.title == draft.title && $0.progressText == draft.progressText && $0.references == [reference] }, "Saved record contains edited text and attached reference")
        check(unrelated.progressText == "unrelated unsaved edit", "Successful retry preserves unrelated edits")

        print("PASS: existing-save failure restores fields, references, timestamp and pending quotes")
        print("PASS: unrelated unsaved edits survive without context-wide rollback")
        print("PASS: failed new record is removed from fetches, relationship and pending queues")
        print("PASS: autosave settings restored after failures")
        print("PASS: successful retry saves once and consumes only the attached pending quote")
    }
}

// TimelineApp.swift holds these UI-only declarations beside the App's @main.
// The standalone test executable excludes that file and supplies non-rendering
// stand-ins solely to compile the actual ContentView and editor/save operation.
// No view is mounted, and no persistence or editing behavior is replaced here.
enum TimelineTheme {
    static let accent = Color.accentColor
    static let background = Color.clear
    static let sidebar = Color.clear
    static let ink = Color.primary
    static let muted = Color.secondary
    static let line = Color.gray
}

extension Color {
    init(timelineHex: String) { self = .gray }
}

extension Notification.Name {
    static let timelineNewEntry = Notification.Name("timeline.newEntry")
    static let timelineNewProject = Notification.Name("timeline.newProject")
    static let timelineEditEntry = Notification.Name("timeline.editEntry")
}
