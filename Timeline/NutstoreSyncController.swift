import Foundation
import SwiftData
import CryptoKit

struct NutstoreSyncStatus: Equatable {
    var title = "设置同步"
    var detail = "连接坚果云后，可在 Mac 与 iPhone 之间同步项目和记录。当前内容保存在本机。"
    var isSyncing = false
    var lastSync: Date?
}

enum NutstoreSyncError: LocalizedError {
    case busy, accountChange, missingPassword, editing, persistence, cloudBuild, duplicateID, interruptedApply
    var errorDescription: String? {
        switch self {
        case .busy: "正在同步，请等本次操作完成后重试。"
        case .accountChange: "此资料库已关联另一个坚果云账号。为避免将旧账号的数据上传到其他账号，更换账号需要单独迁移。"
        case .missingPassword: "请填写为 Timeline 生成的坚果云应用密码。"
        case .editing: "编辑期间暂缓同步，保存或取消全部草稿后会继续。"
        case .persistence: "本机同步状态无法保存或读取，已暂停同步。你的记录仍保存在此设备。"
        case .cloudBuild: "此版本正在使用 iCloud。请用普通 Timeline 版本配置坚果云，避免同时运行两种同步。"
        case .duplicateID: "本机存在重复的记录标识，已停止同步以保护内容。"
        case .interruptedApply: "发现未完成的同步写入且本机内容已有变化，已保留恢复资料并暂停同步。"
        }
    }
}

/// All SwiftData access stays on the main actor; networking suspends rather than
/// blocking it. The replica is durable after every local save, including deletes.
@MainActor
final class NutstoreSyncController {
    private let context: ModelContext
    private let defaults: UserDefaults
    private let credentialsStore: any NutstoreCredentialStoring
    private let directory: URL
    private let deviceIDProvider: () throws -> UUID
    private let injectedTransport: (any NutstoreWebDAVTransport)?
    private let now: () -> Date
    private let onState: (NutstoreSyncStatus) -> Void
    private(set) var state = NutstoreSyncStatus()
    private var preferences: NutstoreSyncPreferences
    private var replica: NutstoreReplica?
    private var replicaAccount: String?
    private var localContentFingerprint: String?
    private var transport: (any NutstoreWebDAVTransport)?
    private var journalURL: URL?
    private var pendingURL: URL?
    private var autoTask: Task<Void, Never>?
    private var foreground = false
    private var editing = false
    private var editingOwners: Set<UUID> = []
    private var generation = 0
    private static let automaticInterval: TimeInterval = 24 * 60 * 60

    private var hasLocalChanges: Bool {
        guard let localContentFingerprint else { return false }
        return localContentFingerprint != preferences.lastSyncedContentFingerprint
    }

    private var automaticSyncDue: Date {
        max(preferences.lastSync ?? .distantPast, preferences.lastSyncAttempt ?? .distantPast)
            .addingTimeInterval(Self.automaticInterval)
    }

    var configured: Bool { preferences.enabled }
    var username: String { preferences.username }

    init(context: ModelContext, defaults: UserDefaults = .standard, directory: URL,
         credentialsStore: any NutstoreCredentialStoring = NutstoreKeychainCredentialStore(),
         deviceIDProvider: @escaping () throws -> UUID = { try NutstoreKeychainCredentialStore.deviceID() },
         transport: (any NutstoreWebDAVTransport)? = nil,
         now: @escaping () -> Date = Date.init,
         onState: @escaping (NutstoreSyncStatus) -> Void) {
        self.context = context
        self.defaults = defaults
        self.directory = directory
        self.credentialsStore = credentialsStore
        self.deviceIDProvider = deviceIDProvider
        self.injectedTransport = transport
        self.now = now
        self.onState = onState
        preferences = NutstoreSyncPreferences(defaults: defaults)
        state.lastSync = preferences.lastSync
        if !preferences.username.isEmpty {
            do {
                try prepareReplica(username: preferences.username)
                try recoverPendingApply()
                try captureLocal()
                if preferences.enabled {
                    updateIdleStatus()
                } else {
                    state.title = "同步已停用"
                    state.detail = "本机和云端记录均保留。可重新填写应用密码启用。"
                }
            } catch { failure(error) }
        }
        publish()
    }

    deinit { autoTask?.cancel() }

    func configure(username: String, password: String) async throws {
        guard !state.isSyncing else { throw NutstoreSyncError.busy }
        guard !editing else { throw NutstoreSyncError.editing }
        autoTask?.cancel()
        autoTask = nil
        defer { scheduleAutomatic() }
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard preferences.username.isEmpty || preferences.username.lowercased() == account.lowercased() else { throw NutstoreSyncError.accountChange }
        let secret = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentials: NutstoreCredentials
        if secret.isEmpty {
            guard let stored = try credentialsStore.load(username: account) else { throw NutstoreSyncError.missingPassword }
            credentials = stored
        } else { credentials = NutstoreCredentials(username: account, password: secret) }
        guard credentials.isValid else { throw NutstoreCredentialError.invalidCredentials }
        let operation = generation
        state.title = "正在连接坚果云"
        state.detail = "正在验证账户和专用同步文件夹…"
        state.isSyncing = true
        publish()
        do {
            try prepareReplica(username: account)
            guard let transport else { throw NutstoreSyncError.persistence }
            try await transport.testConnection(credentials: credentials)
            guard operation == generation else { throw CancellationError() }
            try credentialsStore.save(credentials)
            preferences.username = account
            preferences.enabled = true
            preferences.save(to: defaults)
            try recoverPendingApply()
            try captureLocal()
            state.isSyncing = false
            try await performSync()
        } catch {
            if operation == generation { failure(error) }
            throw error
        }
    }

    func sync() async {
        guard configured, !state.isSyncing else { return }
        autoTask?.cancel()
        autoTask = nil
        do { try await performSync() }
        catch { failure(error) }
        scheduleAutomatic()
    }

    /// Foreground events and the scheduled deadline share this gate. Manual
    /// sync deliberately bypasses it so a read-only device can fetch updates.
    func syncAutomaticallyIfNeeded() async {
        guard foreground, configured, !editing, !state.isSyncing,
              hasLocalChanges, now() >= automaticSyncDue else { return }
        await sync()
    }

    func disable() {
        generation += 1
        autoTask?.cancel()
        autoTask = nil
        preferences.enabled = false
        preferences.save(to: defaults)
        state.title = "同步已停用"
        state.detail = "本机和云端记录均保留。"
        state.isSyncing = false
        publish()
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if active { scheduleAutomatic() } else { autoTask?.cancel(); autoTask = nil }
    }

    func setEditing(_ value: Bool, owner: UUID) {
        if value { editingOwners.insert(owner) } else { editingOwners.remove(owner) }
        editing = !editingOwners.isEmpty
        scheduleAutomatic()
    }

    func localDidSave() {
        guard !preferences.username.isEmpty else { return }
        do { try recoverPendingApply(); try captureLocal() }
        catch { failure(error); return }
        if configured && !state.isSyncing {
            updateIdleStatus()
            if editing && hasLocalChanges { state.detail = NutstoreSyncError.editing.localizedDescription }
            publish()
        }
        scheduleAutomatic()
    }

    private func performSync() async throws {
        guard configured else { return }
        guard !state.isSyncing else { throw NutstoreSyncError.busy }
        guard !editing else {
            state.title = "编辑完成后同步"
            state.detail = NutstoreSyncError.editing.localizedDescription
            publish()
            return
        }
        let operation = generation
        // Persist the attempt too: failures and relaunches must not cause a
        // tight automatic retry loop. Explicit manual retries remain available.
        preferences.lastSyncAttempt = now()
        preferences.save(to: defaults)
        try prepareReplica(username: preferences.username)
        try recoverPendingApply()
        try context.save()
        try captureLocal()
        guard let transport, let credentials = try credentialsStore.load(username: preferences.username) else { throw NutstoreSyncError.missingPassword }
        state.title = "坚果云同步中"
        state.detail = "正在读取其他设备的记录…"
        state.isSyncing = true
        publish()
        let snapshots = try await transport.fetchSnapshots(credentials: credentials)
        guard configured, operation == generation else { throw CancellationError() }
        if editing {
            state.isSyncing = false
            state.title = "编辑完成后同步"
            state.detail = NutstoreSyncError.editing.localizedDescription
            publish()
            return
        }
        // Reconcile edits made while the network request was suspended.
        try context.save()
        try captureLocal()
        guard var candidate = replica else { throw NutstoreSyncError.persistence }
        var documents: [NutstoreSyncDocument] = []
        for snapshot in snapshots {
            let document = try NutstoreJSON.decode(NutstoreSyncDocument.self, from: snapshot.data)
            try document.validate(expectedDeviceID: snapshot.deviceID)
            documents.append(document)
        }
        try candidate.merge(documents)
        let desired = try candidate.materialize()
        candidate.baseline = desired
        // Expiry is a real, durable delete, including trash first received from
        // another device. Capture it before the atomic model/journal commit so
        // every removed ID gets a terminal tombstone in this upload. Tombstones
        // stay in the journal for clients that have been offline beyond 30 days.
        let retained = removingExpiredTrash(from: desired, now: now())
        if retained != desired { try candidate.capture(retained) }
        let synchronizedFingerprint = try contentFingerprint(candidate.baseline)
        let upload = try NutstoreJSON.encode(candidate.document)
        guard upload.count <= 20 * 1024 * 1024 else { throw NutstoreWebDAVError.fileTooLarge }
        try commit(candidate)
        state.detail = "正在上传此设备的同步记录…"
        publish()
        try await transport.uploadSnapshot(upload, credentials: credentials)
        guard configured, operation == generation else { throw CancellationError() }
        let completedAt = now()
        preferences.lastSync = completedAt
        preferences.lastSyncedContentFingerprint = synchronizedFingerprint
        preferences.save(to: defaults)
        state.lastSync = completedAt
        state.isSyncing = false
        updateIdleStatus()
        publish()
    }

    private func scheduleAutomatic() {
        guard !state.isSyncing else { return }
        autoTask?.cancel()
        autoTask = nil
        guard foreground, configured, !editing, hasLocalChanges else { return }
        let delay = max(2, automaticSyncDue.timeIntervalSince(now()))
        autoTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.autoTask = nil
            await self.syncAutomaticallyIfNeeded()
            // A clock adjustment can move the deadline while the task sleeps.
            if !self.state.isSyncing { self.scheduleAutomatic() }
        }
    }

    private func updateIdleStatus() {
        state.title = hasLocalChanges ? "有更改待同步" : "坚果云已同步"
        state.detail = hasLocalChanges
            ? "已保存到本机；有内容变化且距上次同步尝试至少 24 小时后，在前台自动同步。也可点击立即同步。"
            : "本机内容较上次同步没有变化。需要获取其他设备的新内容时，请点击立即同步。"
    }

    private func contentFingerprint(_ records: [String: NutstoreRecord]) throws -> String {
        let data = try NutstoreJSON.encode(records)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func prepareReplica(username: String) throws {
        if replica != nil && replicaAccount == username.lowercased() { return }
        replica = nil
        let deviceID = try deviceIDProvider()
        let digest = SHA256.hash(data: Data(username.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        journalURL = directory.appendingPathComponent(digest + ".json")
        pendingURL = directory.appendingPathComponent(digest + ".pending.json")
        guard let journalURL else { throw NutstoreSyncError.persistence }
        if FileManager.default.fileExists(atPath: journalURL.path) {
            var saved = try NutstoreJSON.decode(NutstoreReplica.self, from: Data(contentsOf: journalURL))
            try saved.document.validate()
            // A restored installation gets a fresh writer identity; it never
            // overwrites another device's snapshot after a device restore.
            saved.document.deviceID = deviceID
            saved.document.formatVersion = 2
            try write(NutstoreJSON.encode(saved), to: journalURL)
            replica = saved
        } else {
            let local = try localRecords()
            let backup = directory.appendingPathComponent("before-first-sync-" + UUID().uuidString + ".json")
            try write(NutstoreJSON.encode(local), to: backup)
            var created = NutstoreReplica(deviceID: deviceID)
            try created.capture(local)
            try write(NutstoreJSON.encode(created), to: journalURL)
            replica = created
        }
        transport = injectedTransport ?? NutstoreWebDAVClient(deviceID: deviceID)
        replicaAccount = username.lowercased()
    }

    private func captureLocal() throws {
        guard var updated = replica, let journalURL else { return }
        try updated.capture(localRecords())
        let fingerprint = try contentFingerprint(updated.baseline)
        try write(NutstoreJSON.encode(updated), to: journalURL)
        replica = updated
        localContentFingerprint = fingerprint
    }

    private struct PendingApply: Codable {
        var before: [String: NutstoreRecord]
        var candidate: NutstoreReplica
    }

    private func commit(_ candidate: NutstoreReplica) throws {
        guard let pendingURL, let journalURL else { throw NutstoreSyncError.persistence }
        let fingerprint = try contentFingerprint(candidate.baseline)
        let before = try localRecords()
        let pending = PendingApply(before: before, candidate: candidate)
        try write(NutstoreJSON.encode(pending), to: pendingURL)
        do {
            try apply(candidate.baseline)
        } catch {
            context.rollback()
            try? FileManager.default.removeItem(at: pendingURL)
            throw error
        }
        // Keep the pending transaction if this write fails. On the next launch,
        // matching model contents can safely finish the metadata commit.
        try write(NutstoreJSON.encode(candidate), to: journalURL)
        replica = candidate
        localContentFingerprint = fingerprint
        try FileManager.default.removeItem(at: pendingURL)
    }

    private func recoverPendingApply() throws {
        guard let pendingURL, let journalURL, FileManager.default.fileExists(atPath: pendingURL.path) else { return }
        let pending = try NutstoreJSON.decode(PendingApply.self, from: Data(contentsOf: pendingURL))
        try pending.candidate.document.validate()
        let local = try localRecords()
        if local == pending.before { try apply(pending.candidate.baseline) }
        else if local != pending.candidate.baseline { throw NutstoreSyncError.interruptedApply }
        var recovered = pending.candidate
        if let replica { recovered.document.deviceID = replica.document.deviceID }
        recovered.document.formatVersion = 2
        try write(NutstoreJSON.encode(recovered), to: journalURL)
        replica = recovered
        localContentFingerprint = try contentFingerprint(recovered.baseline)
        try FileManager.default.removeItem(at: pendingURL)
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func failure(_ error: Error) {
        if error is CancellationError && !configured { return }
        state.title = error is CancellationError ? "坚果云待同步" : "同步需要关注"
        state.detail = error is CancellationError ? "本机内容已保留，下次进入前台会继续同步。" : error.localizedDescription
        state.isSyncing = false
        publish()
    }
    private func publish() { onState(state) }

    func localRecords() throws -> [String: NutstoreRecord] {
        var result: [String: NutstoreRecord] = [:]
        for project in try context.fetch(FetchDescriptor<TimelineProject>()) {
            let record = NutstoreRecord.project(.init(id: project.id, name: project.name, icon: project.icon, colorHex: project.colorHex, createdAt: project.createdAt, sortOrder: project.sortOrder, pendingReferencesJSON: project.pendingReferencesJSON, deletedAt: project.deletedAt))
            guard result[record.key] == nil else { throw NutstoreSyncError.duplicateID }
            result[record.key] = record
        }
        for entry in try context.fetch(FetchDescriptor<TimelineEntry>()) {
            let record = NutstoreRecord.entry(.init(id: entry.id, projectID: entry.project?.id, title: entry.title, date: entry.date, progress: entry.progress, progressPercent: entry.progressPercent, progressText: entry.progressText, issuesText: entry.issuesText, ideasText: entry.ideasText, showProgress: entry.showProgress, showIssues: entry.showIssues, showIdeas: entry.showIdeas, createdAt: entry.createdAt, updatedAt: entry.updatedAt, referencesJSON: entry.referencesJSON, deletedAt: entry.deletedAt))
            guard result[record.key] == nil else { throw NutstoreSyncError.duplicateID }
            result[record.key] = record
        }
        return result.mapValues { $0.canonicalized }
    }

    private func removingExpiredTrash(from records: [String: NutstoreRecord], now: Date) -> [String: NutstoreRecord] {
        let expiredProjectIDs = Set(records.values.compactMap { record -> UUID? in
            guard case .project(let project) = record,
                  TimelineTrashSupport.isExpired(project.deletedAt, now: now) else { return nil }
            return project.id
        })
        return records.filter { _, record in
            switch record {
            case .project(let project): return !expiredProjectIDs.contains(project.id)
            case .entry(let entry):
                return !TimelineTrashSupport.isExpired(entry.deletedAt, now: now)
                    && !(entry.projectID.map { expiredProjectIDs.contains($0) } ?? false)
            }
        }
    }

    private func apply(_ records: [String: NutstoreRecord]) throws {
        let projects = try context.fetch(FetchDescriptor<TimelineProject>())
        let entries = try context.fetch(FetchDescriptor<TimelineEntry>())
        guard Set(projects.map(\.id)).count == projects.count, Set(entries.map(\.id)).count == entries.count else { throw NutstoreSyncError.duplicateID }
        var projectMap = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let entryMap = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let previousAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = previousAutosave }
        for record in records.values {
            guard case .project(let data) = record else { continue }
            let project: TimelineProject
            if let existing = projectMap[data.id] { project = existing }
            else {
                project = TimelineProject(id: data.id, name: data.name)
                context.insert(project)
                projectMap[data.id] = project
            }
            project.name = data.name; project.icon = data.icon; project.colorHex = data.colorHex
            project.createdAt = data.createdAt; project.sortOrder = data.sortOrder
            project.pendingReferencesJSON = data.pendingReferencesJSON
            project.deletedAt = data.deletedAt
        }
        for record in records.values {
            guard case .entry(let data) = record else { continue }
            let entry: TimelineEntry
            if let existing = entryMap[data.id] { entry = existing }
            else { entry = TimelineEntry(id: data.id, title: data.title); context.insert(entry) }
            entry.project = data.projectID.flatMap { projectMap[$0] }
            entry.title = data.title; entry.date = data.date; entry.progress = data.progress
            entry.progressPercent = data.progressPercent; entry.progressText = data.progressText
            entry.issuesText = data.issuesText; entry.ideasText = data.ideasText
            entry.showProgress = data.showProgress; entry.showIssues = data.showIssues; entry.showIdeas = data.showIdeas
            entry.createdAt = data.createdAt; entry.updatedAt = data.updatedAt; entry.referencesJSON = data.referencesJSON
            entry.deletedAt = data.deletedAt
        }
        for entry in entries where records["e/" + entry.id.uuidString.lowercased()] == nil { context.delete(entry) }
        for project in projects where records["p/" + project.id.uuidString.lowercased()] == nil { context.delete(project) }
        try context.save()
    }
}
