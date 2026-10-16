import Foundation
import SwiftData

/// Real SwiftData stores and real journal files; no network or Keychain access.
@main
@MainActor
struct NutstoreControllerTests {
    static let account = "fixture@example.invalid"
    static let secret = "dummy-app-password"
    static let projectID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let entryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let childID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }

    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message) }
    }

    static func pair() async throws -> (Device, Device, Remote) {
        let remote = Remote()
        let a = try Device(remote: remote)
        let b = try Device(remote: remote)
        try a.seed()
        try await a.configure()
        try await b.configure()
        return (a, b, remote)
    }

    static func textSet(_ device: Device) throws -> Set<String> {
        Set(try device.context.fetch(FetchDescriptor<TimelineEntry>()).map(\.progressText))
    }

    static func compare(_ first: [String: NutstoreRecord], _ second: [String: NutstoreRecord], _ message: String) throws {
        guard first != second else { return }
        var details: [String] = []
        if Set(first.keys) != Set(second.keys) { details.append("different key sets (\(first.count)/\(second.count))") }
        for key in Set(first.keys).intersection(second.keys) where first[key] != second[key] {
            if case .entry(let a) = first[key], case .entry(let b) = second[key] {
                if a.updatedAt != b.updatedAt { details.append("updatedAt delta \(a.updatedAt.timeIntervalSince(b.updatedAt))") }
                if a.createdAt != b.createdAt { details.append("createdAt differs") }
                if a.title != b.title { details.append("title differs") }
                if a.progressText != b.progressText { details.append("contents differ") }
            } else { details.append("project fields differ") }
        }
        throw Failure(message + " " + details.joined(separator: "; "))
    }

    static func edit(_ device: Device, _ text: String) throws {
        guard let entry = try device.context.fetch(FetchDescriptor<TimelineEntry>()).first(where: { $0.id == entryID }) else {
            throw Failure("Missing fixture entry.")
        }
        entry.progressText = text
        entry.updatedAt = device.clock.now
        try device.context.save()
        device.controller.localDidSave()
    }

    static func roundTrip() async throws {
        let (a, b, _) = try await pair()
        defer { a.cleanup(); b.cleanup() }
        try check(try a.controller.localRecords() == b.controller.localRecords(), "First connection did not import the other device.")
        try edit(b, "Edited on B")
        await b.controller.sync()
        await a.controller.sync()
        try check(try textSet(a) == ["Edited on B"], "B-to-A update was lost.")
        try edit(a, "Then on A")
        await a.controller.sync()
        await b.controller.sync()
        try check(try textSet(b) == ["Then on A"], "A-to-B update was lost.")
        try check(a.states.values.contains(where: \.isSyncing), "Status did not report actual synchronization.")
        try check(a.controller.state.lastSync != nil && !a.controller.state.isSyncing, "Completed synchronization did not settle its status.")
    }

    static func concurrentEdits() async throws {
        let (a, b, _) = try await pair()
        defer { a.cleanup(); b.cleanup() }
        try edit(a, "Offline A")
        try edit(b, "Offline B")
        await a.controller.sync()
        await b.controller.sync()
        await a.controller.sync()
        let records = try a.controller.localRecords()
        try compare(records, b.controller.localRecords(), "Conflict copies did not converge through SwiftData.")
        try check(try textSet(a) == ["Offline A", "Offline B"], "An offline edit disappeared.")
        let count = try a.context.fetchCount(FetchDescriptor<TimelineEntry>())
        try check(count == 2, "Expected exactly one conflict copy.")
        await a.controller.sync()
        await b.controller.sync()
        try check(records == a.controller.localRecords() && records == b.controller.localRecords(), "Retry duplicated or changed a conflict copy.")
    }

    static func deletedProjectAndOfflineChild() async throws {
        let (a, b, _) = try await pair()
        defer { a.cleanup(); b.cleanup() }
        guard let projectA = try a.context.fetch(FetchDescriptor<TimelineProject>()).first,
              let projectB = try b.context.fetch(FetchDescriptor<TimelineProject>()).first else { throw Failure("Missing fixture project.") }
        a.context.delete(projectA)
        try a.context.save()
        a.controller.localDidSave()
        let child = TimelineEntry(id: childID, title: "Offline child", progressText: "New child contents", project: projectB)
        b.context.insert(child)
        try b.context.save()
        b.controller.localDidSave()
        await a.controller.sync()
        await b.controller.sync()
        await a.controller.sync()
        try check(try a.controller.localRecords() == b.controller.localRecords(), "Project recovery did not converge.")
        try check(try textSet(a) == ["New child contents"], "Cascade deleted the offline child's recovery copy or restored known deleted children.")
        let projects = try a.context.fetch(FetchDescriptor<TimelineProject>())
        try check(!projects.contains(where: { $0.id == projectID }), "Deleted project was resurrected.")
        for entry in try a.context.fetch(FetchDescriptor<TimelineEntry>()) {
            try check(entry.project != nil && entry.project?.id != projectID, "Recovered child has no valid recovery parent.")
        }
    }

    static func saveDuringNetworkWait() async throws {
        let (a, b, remote) = try await pair()
        defer { a.cleanup(); b.cleanup() }
        try edit(b, "Remote B")
        await b.controller.sync()
        await remote.holdNextFetch()
        let task = Task { @MainActor in await a.controller.sync() }
        await remote.waitForHeldFetch()
        try edit(a, "Local while downloading")
        await remote.releaseFetch()
        await task.value
        await b.controller.sync()
        try check(try textSet(a) == ["Remote B", "Local while downloading"], "A save made during network suspension was overwritten.")
        try compare(a.controller.localRecords(), b.controller.localRecords(), "Mid-request edit did not reach the other device.")
    }

    static func editingDuringNetworkWait() async throws {
        let (a, b, remote) = try await pair()
        defer { a.cleanup(); b.cleanup() }
        try edit(b, "Remote update")
        await b.controller.sync()
        let before = try a.controller.localRecords()
        let lastSuccess = a.controller.state.lastSync
        let owner = UUID()
        await remote.holdNextFetch()
        let task = Task { @MainActor in await a.controller.sync() }
        await remote.waitForHeldFetch()
        a.controller.setEditing(true, owner: owner)
        await remote.releaseFetch()
        await task.value
        try check(before == a.controller.localRecords(), "Remote data changed a record while its editor was open.")
        try check(!a.controller.state.isSyncing && a.controller.state.lastSync != nil, "Editing pause left the controller busy.")
        try check(a.controller.state.lastSync == lastSuccess && NutstoreSyncPreferences(defaults: a.defaults).lastSync == lastSuccess,
                  "Entering editing during a download advanced the last successful sync time.")
        let uploadCount = await remote.uploads
        await a.controller.sync()
        try check(a.controller.state.lastSync == lastSuccess && NutstoreSyncPreferences(defaults: a.defaults).lastSync == lastSuccess,
                  "A manual sync paused by editing advanced the last successful sync time.")
        try check(await remote.uploads == uploadCount, "A manual sync uploaded while editing was active.")
        a.controller.setEditing(false, owner: owner)
        await a.controller.sync()
        try check(try textSet(a) == ["Remote update"], "Synchronization did not resume after editing ended.")
    }

    static func malformedRemoteDoesNotMutateLocal() async throws {
        let (a, b, remote) = try await pair()
        defer { a.cleanup(); b.cleanup() }
        try edit(b, "Valid remote update")
        await b.controller.sync()
        let before = try a.controller.localRecords()
        await remote.setCorrupt(true)
        let uploadCount = await remote.uploads
        await a.controller.sync()
        try check(before == a.controller.localRecords(), "Malformed remote data partially changed the local store.")
        try check(await remote.uploads == uploadCount, "Malformed remote data was followed by an upload.")
        try check(a.controller.state.title == "同步需要关注" && !a.controller.state.isSyncing, "Malformed remote data was reported as synchronized.")
    }

    static func disableAndAccountProtection() async throws {
        let (a, b, remote) = try await pair()
        defer { a.cleanup(); b.cleanup() }
        let before = try a.controller.localRecords()
        await remote.holdNextFetch()
        let task = Task { @MainActor in await a.controller.sync() }
        await remote.waitForHeldFetch()
        let uploads = await remote.uploads
        a.controller.disable()
        await remote.releaseFetch()
        await task.value
        try check(!a.controller.configured && a.controller.state.title == "同步已停用", "In-flight work undid disable.")
        try check(before == a.controller.localRecords(), "Disabling synchronization removed local records.")
        try check(await remote.uploads == uploads, "Disabled in-flight synchronization still uploaded.")
        do {
            try await a.controller.configure(username: "other@example.invalid", password: secret)
            throw Failure("Changing an associated account was silently accepted.")
        } catch NutstoreSyncError.accountChange { }
        try check(a.controller.username == account, "Rejected account change altered persisted account identity.")
        try await a.configure()
        try check(a.controller.configured, "Original account could not be re-enabled.")
    }

    static func journalRestartPreservesDeletion() async throws {
        let (a, b, _) = try await pair()
        defer { a.cleanup(); b.cleanup() }
        guard let entry = try a.context.fetch(FetchDescriptor<TimelineEntry>()).first else { throw Failure("Missing fixture entry.") }
        a.context.delete(entry)
        try a.context.save()
        a.controller.localDidSave()
        try a.restart()
        await a.controller.sync()
        await b.controller.sync()
        try check(try a.context.fetchCount(FetchDescriptor<TimelineEntry>()) == 0, "Restart resurrected a locally deleted record.")
        try check(try b.context.fetchCount(FetchDescriptor<TimelineEntry>()) == 0, "Persisted tombstone did not propagate after restart.")
        try check(try a.context.fetchCount(FetchDescriptor<TimelineProject>()) == 1, "Entry deletion removed its project.")
    }

    static func successfulSyncTimeSurvivesRestart() async throws {
        let a = try Device(remote: Remote())
        defer { a.cleanup() }
        try a.seed()
        try check(a.controller.state.lastSync == nil, "An unused device reported a successful sync time.")
        try await a.configure()
        guard let completedAt = a.controller.state.lastSync else { throw Failure("Successful sync had no completion time.") }
        try a.restart()
        try check(a.controller.state.lastSync == completedAt && a.states.values.last?.lastSync == completedAt,
                  "Recreating the controller lost or failed to publish its last successful sync time.")
        a.controller.disable()
        try a.restart()
        try check(!a.controller.configured && a.controller.state.lastSync == completedAt,
                  "Disabling sync cleared the previous successful sync time after restart.")
    }

    static func failedUploadPreservesLastSyncTime() async throws {
        let remote = Remote()
        let a = try Device(remote: remote)
        defer { a.cleanup() }
        try a.seed()
        await remote.setUploadFailure(true)
        do {
            try await a.configure()
            throw Failure("The simulated upload failure did not reach configuration.")
        } catch Remote.UploadFailure.unavailable { }
        try a.restart()
        try check(a.controller.state.lastSync == nil, "A failed first upload persisted a successful sync time.")
        await remote.setUploadFailure(false)
        await a.controller.sync()
        guard let completedAt = a.controller.state.lastSync else { throw Failure("Recovery from an upload failure did not complete sync.") }
        let uploads = await remote.uploads
        await remote.setUploadFailure(true)
        await a.controller.sync()
        try check(a.controller.state.title == "同步需要关注" && !a.controller.state.isSyncing,
                  "An upload failure was not reported as a settled failure.")
        let uploadsAfterFailure = await remote.uploads
        try check(a.controller.state.lastSync == completedAt && uploadsAfterFailure == uploads,
                  "A failed upload advanced the last successful sync time or remote snapshot.")
        try a.restart()
        try check(a.controller.state.lastSync == completedAt, "A failed upload replaced the persisted successful sync time.")
    }

    static func unchangedContentDoesNotAutoSync() async throws {
        let remote = Remote()
        let a = try Device(remote: remote)
        defer { a.cleanup() }
        try a.seed()
        try await a.configure()
        let fetches = await remote.fetchCount
        let uploads = await remote.uploads
        a.clock.advance(2 * 86_400)
        a.controller.setForeground(true)
        a.controller.localDidSave() // Saving identical content must not mark it dirty.
        await a.controller.syncAutomaticallyIfNeeded()
        a.controller.setForeground(false)
        a.controller.setForeground(true)
        await a.controller.syncAutomaticallyIfNeeded()
        try check(await remote.counts == (fetches, uploads),
                  "Unchanged content or reopening the popup caused automatic network activity.")
    }

    static func localChangesWaitForDailyInterval() async throws {
        let remote = Remote()
        let a = try Device(remote: remote)
        defer { a.cleanup() }
        try a.seed()
        try await a.configure()
        let initialFingerprint = NutstoreSyncPreferences(defaults: a.defaults).lastSyncedContentFingerprint
        try check(initialFingerprint != nil, "A successful sync did not persist its content fingerprint.")
        let fetches = await remote.fetchCount
        let uploads = await remote.uploads
        a.clock.advance(86_399)
        try edit(a, "Changed during cooldown")
        a.controller.setForeground(true)
        await a.controller.syncAutomaticallyIfNeeded()
        try check(await remote.counts == (fetches, uploads),
                  "A local edit bypassed the 24-hour automatic cooldown.")
        a.clock.advance(1)
        await a.controller.syncAutomaticallyIfNeeded()
        try check(await remote.counts == (fetches + 1, uploads + 1),
                  "An eligible local edit did not synchronize at the 24-hour boundary.")
        try check(NutstoreSyncPreferences(defaults: a.defaults).lastSyncedContentFingerprint != initialFingerprint,
                  "A successful changed-content upload did not advance the content fingerprint.")
        a.clock.advance(86_400)
        await a.controller.syncAutomaticallyIfNeeded()
        try check(await remote.fetchCount == fetches + 1, "Already-synchronized content was uploaded again the next day.")
    }

    static func automaticDeletionPropagates() async throws {
        let (a, b, remote) = try await pair()
        defer { a.cleanup(); b.cleanup() }
        guard let entry = try a.context.fetch(FetchDescriptor<TimelineEntry>()).first else { throw Failure("Missing fixture entry.") }
        a.context.delete(entry)
        try a.context.save()
        a.controller.localDidSave()
        a.clock.advance(86_400)
        let fetches = await remote.fetchCount
        a.controller.setForeground(true)
        await a.controller.syncAutomaticallyIfNeeded()
        try check(await remote.fetchCount == fetches + 1, "A local deletion was not recognized as changed content.")
        await b.controller.sync()
        try check(try b.context.fetchCount(FetchDescriptor<TimelineEntry>()) == 0,
                  "The automatic upload did not propagate the local deletion.")
    }

    static func restartPreservesPendingChangesAndCooldown() async throws {
        let remote = Remote()
        let a = try Device(remote: remote)
        defer { a.cleanup() }
        try a.seed()
        try await a.configure()
        let before = NutstoreSyncPreferences(defaults: a.defaults)
        a.clock.advance(43_200)
        try edit(a, "Pending across restart")
        try a.restart()
        let restored = NutstoreSyncPreferences(defaults: a.defaults)
        try check(restored.lastSyncAttempt == before.lastSyncAttempt && restored.lastSyncedContentFingerprint == before.lastSyncedContentFingerprint,
                  "Restart lost the persisted cooldown or last synchronized content fingerprint.")
        let fetches = await remote.fetchCount
        a.controller.setForeground(true)
        await a.controller.syncAutomaticallyIfNeeded()
        try check(await remote.fetchCount == fetches, "Restart reset the automatic cooldown.")
        a.clock.advance(43_200)
        await a.controller.syncAutomaticallyIfNeeded()
        try check(await remote.fetchCount == fetches + 1 && a.controller.state.lastSync == a.clock.now,
                  "Restart lost a pending local change or failed to sync it when eligible.")
        let b = try Device(remote: remote)
        defer { b.cleanup() }
        try await b.configure()
        try check(try textSet(b) == ["Pending across restart"], "The change preserved across restart was not uploaded.")
    }

    static func failedAutomaticAttemptHasPersistentCooldown() async throws {
        let remote = Remote()
        let a = try Device(remote: remote)
        defer { a.cleanup() }
        try a.seed()
        try await a.configure()
        let success = NutstoreSyncPreferences(defaults: a.defaults)
        try edit(a, "Retry after daily cooldown")
        a.clock.advance(86_400)
        a.controller.setForeground(true)
        await remote.setUploadFailure(true)
        let fetches = await remote.fetchCount
        await a.controller.syncAutomaticallyIfNeeded()
        let failed = NutstoreSyncPreferences(defaults: a.defaults)
        try check(await remote.fetchCount == fetches + 1 && failed.lastSyncAttempt == a.clock.now,
                  "A failed network attempt did not persist its attempt time.")
        try check(failed.lastSync == success.lastSync && failed.lastSyncedContentFingerprint == success.lastSyncedContentFingerprint,
                  "A failed upload incorrectly marked local content as synchronized.")
        try a.restart()
        a.controller.setForeground(true)
        await a.controller.syncAutomaticallyIfNeeded()
        a.clock.advance(86_399)
        await a.controller.syncAutomaticallyIfNeeded()
        try check(await remote.fetchCount == fetches + 1, "A failed automatic request retried before its persisted 24-hour cooldown elapsed.")
        a.clock.advance(1)
        await remote.setUploadFailure(false)
        await a.controller.syncAutomaticallyIfNeeded()
        try check(await remote.fetchCount == fetches + 2 && a.controller.state.lastSync == a.clock.now,
                  "A failed upload was not retried after the daily cooldown.")
    }

    static func manualSyncBypassesAutomaticCooldown() async throws {
        let remote = Remote()
        let a = try Device(remote: remote)
        defer { a.cleanup() }
        try a.seed()
        try await a.configure()
        let fetches = await remote.fetchCount
        try edit(a, "Manual update without waiting")
        await a.controller.sync()
        await a.controller.sync() // Even unchanged content may explicitly pull remote changes.
        try check(await remote.fetchCount == fetches + 2,
                  "Manual sync was blocked by automatic cooldown or unchanged-content filtering.")
        let b = try Device(remote: remote)
        defer { b.cleanup() }
        try await b.configure()
        try check(try textSet(b) == ["Manual update without waiting"], "The immediate manual update was not uploaded.")
    }

    static func remoteOnlyChangesRequireManualSync() async throws {
        let (a, b, remote) = try await pair()
        defer { a.cleanup(); b.cleanup() }
        try edit(b, "Remote-only edit")
        await b.controller.sync()
        a.clock.advance(86_400)
        a.controller.setForeground(true)
        let fetches = await remote.fetchCount
        await a.controller.syncAutomaticallyIfNeeded()
        try check(await remote.fetchCount == fetches && textSet(a) == ["Initial"],
                  "An unchanged local store polled for remote changes automatically.")
        await a.controller.sync()
        try check(try textSet(a) == ["Remote-only edit"], "Manual sync could not receive a remote-only update.")
        a.clock.advance(86_400)
        await a.controller.syncAutomaticallyIfNeeded()
        try check(await remote.fetchCount == fetches + 1,
                  "Applying a successfully synchronized remote change left a spurious pending local change.")
    }

    static func editsDuringUploadRemainPending() async throws {
        let (a, b, remote) = try await pair()
        defer { a.cleanup(); b.cleanup() }
        try edit(a, "Snapshot being uploaded")
        a.clock.advance(86_400)
        a.controller.setForeground(true)
        await remote.holdNextUpload()
        let task = Task { @MainActor in await a.controller.syncAutomaticallyIfNeeded() }
        await remote.waitForHeldUpload()
        try edit(a, "Saved after upload started")
        await remote.releaseUpload()
        await task.value
        try check(a.controller.state.title == "有更改待同步", "A save made during upload was incorrectly marked synchronized.")
        let fetches = await remote.fetchCount
        await a.controller.syncAutomaticallyIfNeeded()
        try check(await remote.fetchCount == fetches, "A mid-upload local save bypassed the new cooldown.")
        a.clock.advance(86_400)
        await a.controller.syncAutomaticallyIfNeeded()
        try check(await remote.fetchCount == fetches + 1,
                  "A local save made during upload was absent from the next eligible automatic sync.")
        await b.controller.sync()
        try check(try textSet(b) == ["Saved after upload started"], "The subsequent automatic upload lost a mid-upload local save.")
    }

    static func automaticSyncRespectsActivityGates() async throws {
        let remote = Remote()
        let a = try Device(remote: remote)
        defer { a.cleanup() }
        try a.seed()
        try await a.configure()
        try edit(a, "Eligible pending change")
        a.clock.advance(86_400)
        let fetches = await remote.fetchCount
        await a.controller.syncAutomaticallyIfNeeded()
        try check(await remote.fetchCount == fetches, "A background controller started automatic sync.")
        let owner = UUID()
        a.controller.setEditing(true, owner: owner)
        a.controller.setForeground(true)
        await a.controller.syncAutomaticallyIfNeeded()
        try check(await remote.fetchCount == fetches, "Automatic sync started while an editor was open.")
        a.controller.setEditing(false, owner: owner)
        await remote.holdNextFetch()
        let task = Task { @MainActor in await a.controller.syncAutomaticallyIfNeeded() }
        await remote.waitForHeldFetch()
        await a.controller.syncAutomaticallyIfNeeded()
        try check(await remote.fetchCount == fetches + 1, "A busy controller started a duplicate automatic request.")
        await remote.releaseFetch()
        await task.value

        // Exercise the real timer: a rejected account change must not discard
        // the pending automatic sync already scheduled for the existing account.
        try edit(a, "Pending after rejected configuration")
        a.clock.advance(86_400)
        let beforeRejectedConfiguration = await remote.counts
        a.controller.setForeground(true)
        do {
            try await a.controller.configure(username: "other@example.invalid", password: secret)
            throw Failure("The timer regression fixture accepted a different account.")
        } catch NutstoreSyncError.accountChange { }
        for _ in 0..<50 {
            if await remote.fetchCount > beforeRejectedConfiguration.fetches && !a.controller.state.isSyncing { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try check(await remote.counts == (beforeRejectedConfiguration.fetches + 1, beforeRejectedConfiguration.uploads + 1),
                  "Rejected configuration discarded the pending automatic timer or duplicated its request.")
        try check(!a.controller.state.isSyncing && a.controller.state.lastSync == a.clock.now,
                  "Automatic synchronization did not finish after rejected configuration.")
    }

    static func trashedProjectPreservesChildrenAcrossSyncAndRestore() async throws {
        let (a, b, _) = try await pair()
        defer { a.cleanup(); b.cleanup() }
        guard let project = try a.context.fetch(FetchDescriptor<TimelineProject>()).first,
              let independent = try a.context.fetch(FetchDescriptor<TimelineEntry>()).first else { throw Failure("Missing trash fixtures.") }
        let child = TimelineEntry(id: childID, title: "Child to restore", progressText: "Intact **Markdown** and $x^2$", issuesText: "- [x] Completed task",
                                  ideasText: "Keep this idea", project: project, createdAt: a.clock.now, updatedAt: a.clock.now)
        a.context.insert(child)
        let reference = TimelineReference(sourceEntryID: entryID, sourceTitle: independent.title, sourceDate: independent.date,
                                          excerpt: independent.progressText, contextBefore: "Context before", contextAfter: "Context after", createdAt: a.clock.now)
        child.references = [reference]
        project.pendingReferences = [reference]
        let deletedEntryDate = a.clock.now.addingTimeInterval(-60)
        independent.deletedAt = deletedEntryDate
        project.deletedAt = a.clock.now
        try a.context.save()
        a.controller.localDidSave()
        await a.controller.sync()
        await b.controller.sync()
        try compare(a.controller.localRecords(), b.controller.localRecords(), "Project trash did not converge across devices.")
        guard let receivedProject = try b.context.fetch(FetchDescriptor<TimelineProject>()).first(where: { $0.id == projectID }),
              let receivedChild = try b.context.fetch(FetchDescriptor<TimelineEntry>()).first(where: { $0.id == childID }),
              let receivedIndependent = try b.context.fetch(FetchDescriptor<TimelineEntry>()).first(where: { $0.id == entryID }) else {
            throw Failure("Soft deletion physically removed a project or its child.")
        }
        try check(receivedProject.deletedAt == a.clock.now && receivedProject.isTrashed && receivedChild.isTrashed && receivedChild.deletedAt == nil,
                  "Project trash date or inherited child trash state was not imported.")
        try check(receivedIndependent.deletedAt == deletedEntryDate && receivedChild.project?.id == projectID && receivedProject.entries?.count == 2,
                  "Project trash lost an independent deletion or child-parent relationship.")
        try check(receivedChild.progressText == child.progressText && receivedChild.issuesText == child.issuesText && receivedChild.ideasText == child.ideasText
                  && receivedChild.references == [reference] && receivedProject.pendingReferences == [reference],
                  "Project trash changed contents, checklist state, or reference snapshots.")
        try b.restart()
        guard let projectToRestore = try b.context.fetch(FetchDescriptor<TimelineProject>()).first(where: { $0.id == projectID }) else {
            throw Failure("Restart lost the trashed project.")
        }
        try check(projectToRestore.deletedAt == a.clock.now, "Restart lost the synchronized deletion date.")
        projectToRestore.deletedAt = nil
        try b.context.save()
        b.controller.localDidSave()
        await b.controller.sync()
        await a.controller.sync()
        try compare(a.controller.localRecords(), b.controller.localRecords(), "Project restoration did not converge.")
        try check(project.deletedAt == nil && !project.isTrashed && !child.isTrashed && independent.deletedAt == deletedEntryDate && independent.isTrashed,
                  "Restoring a project restored an independently deleted child or failed to restore its active child.")
        try check(project.sortedEntries.map(\.id) == [childID] && child.references == [reference], "Project restoration changed child visibility or reference contents.")
    }

    static func trashedEntryRestoresSameIdentityAfterRestart() async throws {
        let (a, b, _) = try await pair()
        defer { a.cleanup(); b.cleanup() }
        guard let entry = try a.context.fetch(FetchDescriptor<TimelineEntry>()).first else { throw Failure("Missing fixture entry.") }
        let deletionDate = a.clock.now
        entry.deletedAt = deletionDate
        try a.context.save()
        a.controller.localDidSave()
        await a.controller.sync()
        await b.controller.sync()
        try a.restart()
        guard let reopened = try a.context.fetch(FetchDescriptor<TimelineEntry>()).first(where: { $0.id == entryID }),
              let received = try b.context.fetch(FetchDescriptor<TimelineEntry>()).first(where: { $0.id == entryID }) else { throw Failure("Soft-deleted record was physically removed.") }
        try check(reopened.deletedAt == deletionDate && received.deletedAt == deletionDate && reopened.progressText == "Initial",
                  "Entry trash date or contents did not survive sync and restart.")
        received.deletedAt = nil
        try b.context.save()
        b.controller.localDidSave()
        await b.controller.sync()
        await a.controller.sync()
        try check(reopened.deletedAt == nil && !reopened.isTrashed && reopened.project?.id == projectID,
                  "Cross-device entry restore did not preserve its identity and original project.")
        try check(try a.context.fetchCount(FetchDescriptor<TimelineEntry>()) == 1 && a.controller.localRecords() == b.controller.localRecords(),
                  "Entry restore made a duplicate or left divergent deletion metadata.")
    }

    static func expiryPurgePropagatesWithoutResurrection() async throws {
        let (a, b, _) = try await pair()
        defer { a.cleanup(); b.cleanup() }
        guard let entry = try a.context.fetch(FetchDescriptor<TimelineEntry>()).first else { throw Failure("Missing fixture entry.") }
        entry.deletedAt = a.clock.now
        try a.context.save()
        a.controller.localDidSave()
        await a.controller.sync()
        await b.controller.sync()
        a.clock.advance(30 * 86_400)
        try check(try TimelineTrashSupport.purgeExpired(in: a.context, now: a.clock.now), "Expiry purge did not detect the 30-day-old entry.")
        try a.context.save()
        a.controller.localDidSave()
        try a.restart()
        // B's snapshot still contains the soft-deleted entry. A must retain its
        // terminal deletion when downloading that stale snapshot after restart.
        await a.controller.sync()
        await b.controller.sync()
        for _ in 0..<2 { await a.controller.sync(); await b.controller.sync() }
        try check(try a.context.fetchCount(FetchDescriptor<TimelineEntry>()) == 0 && b.context.fetchCount(FetchDescriptor<TimelineEntry>()) == 0,
                  "A stale remote trash snapshot resurrected an expired, purged record.")
        try check(try a.context.fetchCount(FetchDescriptor<TimelineProject>()) == 1 && b.context.fetchCount(FetchDescriptor<TimelineProject>()) == 1,
                  "Entry expiry unexpectedly deleted its project.")

        guard let project = try a.context.fetch(FetchDescriptor<TimelineProject>()).first else { throw Failure("Missing project for expiry test.") }
        let child = TimelineEntry(id: childID, title: "Project child", progressText: "Cascaded on project expiry", project: project, createdAt: a.clock.now, updatedAt: a.clock.now)
        a.context.insert(child)
        project.deletedAt = a.clock.now
        try a.context.save()
        a.controller.localDidSave()
        await a.controller.sync()
        await b.controller.sync()
        a.clock.advance(30 * 86_400)
        _ = try TimelineTrashSupport.purgeExpired(in: a.context, now: a.clock.now)
        try a.context.save()
        a.controller.localDidSave()
        await a.controller.sync()
        await b.controller.sync()
        await a.controller.sync()
        try a.restart(); try b.restart()
        await a.controller.sync(); await b.controller.sync()
        try check(try a.controller.localRecords().isEmpty && b.controller.localRecords().isEmpty,
                  "Project expiry failed to propagate its cascade or recreated a project/recovery copy.")
    }

    static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("two-device round trip", roundTrip),
            ("offline concurrent edits", concurrentEdits),
            ("project cascade with offline child", deletedProjectAndOfflineChild),
            ("save during network wait", saveDuringNetworkWait),
            ("editing during network wait", editingDuringNetworkWait),
            ("malformed remote isolation", malformedRemoteDoesNotMutateLocal),
            ("disable and account protection", disableAndAccountProtection),
            ("journal restart deletion", journalRestartPreservesDeletion),
            ("last successful sync survives restart", successfulSyncTimeSurvivesRestart),
            ("failed upload preserves last sync time", failedUploadPreservesLastSyncTime),
            ("unchanged content skips automatic network", unchangedContentDoesNotAutoSync),
            ("local edits obey daily automatic interval", localChangesWaitForDailyInterval),
            ("automatic deletion propagation", automaticDeletionPropagates),
            ("restart preserves pending edits and cooldown", restartPreservesPendingChangesAndCooldown),
            ("failed automatic attempt has persistent cooldown", failedAutomaticAttemptHasPersistentCooldown),
            ("manual sync bypasses automatic cooldown", manualSyncBypassesAutomaticCooldown),
            ("remote-only changes need manual sync", remoteOnlyChangesRequireManualSync),
            ("edits during upload remain pending", editsDuringUploadRemainPending),
            ("automatic activity gates", automaticSyncRespectsActivityGates),
            ("trashed project sync, restart, and selective restoration", trashedProjectPreservesChildrenAcrossSyncAndRestore),
            ("trashed entry restores original identity across devices", trashedEntryRestoresSameIdentityAfterRestart),
            ("expired trash purge never resurrects from stale snapshots", expiryPurgePropagatesWithoutResurrection)
        ]
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        print("Nutstore controller tests: \(tests.count - failures) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    @MainActor final class States { var values: [NutstoreSyncStatus] = [] }

    @MainActor final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    final class MemoryCredentials: NutstoreCredentialStoring {
        var values: [String: NutstoreCredentials] = [:]
        func load(username: String) throws -> NutstoreCredentials? { values[username] }
        func save(_ credentials: NutstoreCredentials) throws { values[credentials.username] = credentials }
        func delete(username: String) throws { values.removeValue(forKey: username) }
    }

    @MainActor final class Device {
        let id = UUID()
        let directory: URL
        let defaultsName: String
        let defaults: UserDefaults
        let credentials = MemoryCredentials()
        let states = States()
        let clock = Clock()
        let remote: Remote
        var container: ModelContainer
        var controller: NutstoreSyncController!
        var context: ModelContext { container.mainContext }

        init(remote: Remote) throws {
            self.remote = remote
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("Timeline-sync-test-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defaultsName = "Timeline.SyncTest." + UUID().uuidString
            guard let defaults = UserDefaults(suiteName: defaultsName) else { throw Failure("Could not create isolated defaults.") }
            self.defaults = defaults
            container = try Self.openStore(at: directory)
            createController()
        }

        static func openStore(at directory: URL) throws -> ModelContainer {
            let schema = Schema([TimelineProject.self, TimelineEntry.self])
            let configuration = ModelConfiguration("SyncTest", schema: schema, url: directory.appendingPathComponent("test.store"), cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            container.mainContext.autosaveEnabled = false
            return container
        }

        func createController() {
            let writerID = id
            let observer = states
            let clock = self.clock
            controller = NutstoreSyncController(context: context, defaults: defaults, directory: directory.appendingPathComponent("journal"),
                                                credentialsStore: credentials, deviceIDProvider: { writerID },
                                                transport: Transport(deviceID: id, remote: remote), now: { clock.now },
                                                onState: { observer.values.append($0) })
        }

        func restart() throws {
            controller = nil
            container = try Self.openStore(at: directory)
            createController()
        }

        func configure() async throws {
            try await controller.configure(username: account, password: secret)
        }

        func seed() throws {
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let project = TimelineProject(id: projectID, name: "Fixture project", createdAt: date)
            let entry = TimelineEntry(id: entryID, title: "Fixture entry", date: date, progressText: "Initial", project: project, createdAt: date, updatedAt: date)
            context.insert(project)
            context.insert(entry)
            try context.save()
        }

        func cleanup() {
            controller?.disable()
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    struct Transport: NutstoreWebDAVTransport {
        let deviceID: UUID
        let remote: Remote
        func testConnection(credentials: NutstoreCredentials) async throws { }
        func fetchSnapshots(credentials: NutstoreCredentials) async throws -> [NutstoreRemoteSnapshot] {
            await remote.fetch()
        }
        func uploadSnapshot(_ data: Data, credentials: NutstoreCredentials) async throws {
            let document = try NutstoreJSON.decode(NutstoreSyncDocument.self, from: data)
            try document.validate(expectedDeviceID: deviceID)
            try await remote.upload(deviceID: deviceID, data: data)
        }
    }

    actor Remote {
        enum UploadFailure: Error { case unavailable }
        private var files: [UUID: Data] = [:]
        private var holdNext = false
        private var held: CheckedContinuation<Void, Never>?
        private var watchers: [CheckedContinuation<Void, Never>] = []
        private var corrupt = false
        private var uploadFailure = false
        private var shouldHoldUpload = false
        private var heldUpload: CheckedContinuation<Void, Never>?
        private var uploadWatchers: [CheckedContinuation<Void, Never>] = []
        private(set) var uploads = 0
        private(set) var fetchCount = 0
        var counts: (fetches: Int, uploads: Int) { (fetchCount, uploads) }

        func holdNextFetch() { holdNext = true }
        func waitForHeldFetch() async {
            if held != nil { return }
            await withCheckedContinuation { watchers.append($0) }
        }
        func releaseFetch() { held?.resume(); held = nil }
        func setCorrupt(_ value: Bool) { corrupt = value }
        func setUploadFailure(_ value: Bool) { uploadFailure = value }
        func holdNextUpload() { shouldHoldUpload = true }
        func waitForHeldUpload() async {
            if heldUpload != nil { return }
            await withCheckedContinuation { uploadWatchers.append($0) }
        }
        func releaseUpload() { heldUpload?.resume(); heldUpload = nil }
        func upload(deviceID: UUID, data: Data) async throws {
            if shouldHoldUpload {
                shouldHoldUpload = false
                await withCheckedContinuation { continuation in
                    heldUpload = continuation
                    for watcher in uploadWatchers { watcher.resume() }
                    uploadWatchers.removeAll()
                }
            }
            if uploadFailure { throw UploadFailure.unavailable }
            files[deviceID] = data
            uploads += 1
        }
        func fetch() async -> [NutstoreRemoteSnapshot] {
            fetchCount += 1
            var result = files.map { NutstoreRemoteSnapshot(deviceID: $0.key, data: $0.value, eTag: nil) }
            if corrupt { result.append(.init(deviceID: UUID(), data: Data("invalid snapshot".utf8), eTag: nil)) }
            if holdNext {
                holdNext = false
                await withCheckedContinuation { continuation in
                    held = continuation
                    for watcher in watchers { watcher.resume() }
                    watchers.removeAll()
                }
            }
            return result
        }
    }
}
