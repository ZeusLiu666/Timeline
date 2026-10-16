import CloudKit
import Combine
import CoreData
import Foundation
import SwiftData

enum SyncState: Equatable {
    case localOnly(String)
    case waiting
    case syncing(String)
    case activity(Date, String)
    case unavailable(String)
    case failed(String)

    var title: String {
        switch self {
        case .localOnly: "本地存储"
        case .waiting: "等待 iCloud"
        case .syncing: "iCloud 同步中"
        case .activity: "iCloud 已更新"
        case .unavailable: "iCloud 暂不可用"
        case .failed: "同步需要关注"
        }
    }

    var label: String { title }

    var detail: String {
        switch self {
        case let .localOnly(reason), let .unavailable(reason), let .failed(reason):
            return reason
        case .waiting:
            return "记录已保存在此设备，正在等待 iCloud 的同步事件。"
        case let .syncing(operation):
            return operation
        case let .activity(date, operation):
            return "\(operation) · \(date.formatted(date: .abbreviated, time: .shortened))。此状态表示最近一次服务器操作已完成。"
        }
    }

    var symbol: String {
        switch self {
        case .localOnly: "internaldrive"
        case .waiting: "icloud"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .activity: "checkmark.icloud"
        case .unavailable, .failed: "exclamationmark.icloud"
        }
    }

    var isError: Bool {
        switch self {
        case .failed, .unavailable: true
        default: false
        }
    }
}

@MainActor
final class TimelineStore: ObservableObject {
    let container: ModelContainer
    let isUITesting: Bool
    let cloudKitContainerIdentifier: String?

    @Published private(set) var syncState: SyncState
    @Published private(set) var persistenceNotice: String?
    @Published private(set) var lastSaveError: String?
    @Published private(set) var isRecoveryMode: Bool = false
    @Published private(set) var nutstoreState = NutstoreSyncStatus()
    private var nutstoreSync: NutstoreSyncController?
    private var trashMaintenanceTask: Task<Void, Never>?
    private var trashMaintenanceActive = false
    private var editingOwners: Set<UUID> = []

    private var cloudEventObserver: NSObjectProtocol?
    private var accountObserver: NSObjectProtocol?
    private var activeCloudEvents: Set<UUID> = []
    private let defaults: UserDefaults
    private var seedKey = "Timeline.didCreateWelcomeProjects.v1"

    var modelContext: ModelContext { container.mainContext }
    var isCloudEnabled: Bool { cloudKitContainerIdentifier != nil }

    init(inMemory: Bool = false, defaults: UserDefaults = .standard) {
        let isolated = inMemory || ProcessInfo.processInfo.arguments.contains("--timeline-ui-testing")
        self.isUITesting = isolated
        self.defaults = defaults

        let schema = Schema([TimelineProject.self, TimelineEntry.self])
        var openedContainer: ModelContainer?
        var cloudIdentifier: String?
        var notice: String?
        var recoveryNeeded = false
        var initialState = SyncState.localOnly("记录会自动保存在此设备。启用已签名的 iCloud 版本后可同步到 iPhone 和 Mac。")

        if isolated {
            let configuration = ModelConfiguration("TimelinePreview", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            openedContainer = try? ModelContainer(for: schema, configurations: [configuration])
            initialState = .localOnly("演示模式使用临时数据，不会修改你的正式记录。")
        } else {
            do {
                let directory = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                ).appendingPathComponent("Timeline", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let storeURL = directory.appendingPathComponent("Timeline.store")
                // Preferences can survive a switch from a development build to a
                // sandboxed app. Scope welcome initialization to the actual store.
                seedKey += ":" + storeURL.path
                let automatic = ModelConfiguration("Timeline", schema: schema, url: storeURL, cloudKitDatabase: .automatic)
                do {
                    openedContainer = try ModelContainer(for: schema, configurations: [automatic])
                    cloudIdentifier = automatic.cloudKitContainerIdentifier
                    if cloudIdentifier != nil { initialState = .waiting }
                } catch {
                    // Retry the same store locally; never delete or replace a failed database.
                    let local = ModelConfiguration("Timeline", schema: schema, url: storeURL, cloudKitDatabase: .none)
                    openedContainer = try ModelContainer(for: schema, configurations: [local])
                    notice = "iCloud 初始化失败，当前记录保存在此设备。\(error.localizedDescription)"
                    initialState = .localOnly(notice!)
                }
            } catch {
                recoveryNeeded = true
                notice = "无法打开本地数据库：\(error.localizedDescription)。原数据库未被删除或替换，现已暂停编辑以保护记录。请检查设备存储空间与访问权限，然后重新打开 Timeline。"
                initialState = .localOnly(notice!)
            }
        }

        if let openedContainer {
            self.container = openedContainer
        } else {
            let emergency = ModelConfiguration("TimelineRecovery", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            do {
                self.container = try ModelContainer(for: schema, configurations: [emergency])
            } catch {
                // An in-memory schema failure is a programming error, not a recoverable user-data failure.
                fatalError("Timeline 无法初始化数据模型：\(error.localizedDescription)")
            }
        }
        self.cloudKitContainerIdentifier = cloudIdentifier
        self.syncState = initialState
        self.persistenceNotice = notice
        self.isRecoveryMode = recoveryNeeded
        container.mainContext.autosaveEnabled = !recoveryNeeded

        if recoveryNeeded {
            // The empty in-memory container only lets the app present a recovery
            // screen. It must never accept edits or masquerade as a usable store.
        } else if cloudIdentifier != nil {
            observeCloudEvents()
            Task { await refreshAccountStatus() }
            // The first import runs before seeding on a new cloud device, so remote
            // projects arrive before deciding whether a welcome workspace is needed.
        } else if isolated {
            seedWelcomeProjectsIfNeeded()
        }
        if !isolated && !recoveryNeeded && cloudIdentifier == nil {
            do {
                let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent("Timeline/NutstoreSync", isDirectory: true)
                nutstoreSync = NutstoreSyncController(context: modelContext, defaults: defaults, directory: directory) { [weak self] state in
                    self?.nutstoreState = state
                    self?.scheduleTrashMaintenance()
                }
                // Welcome content is generated from generic source literals,
                // only for a fresh, unlinked local workspace. Never replace
                // existing records or populate a linked account's empty store.
                if let nutstoreSync, !nutstoreSync.configured, nutstoreSync.username.isEmpty {
                    seedWelcomeProjectsIfNeeded()
                }
            } catch {
                nutstoreState = NutstoreSyncStatus(title: "同步需要关注", detail: NutstoreSyncError.persistence.localizedDescription)
            }
        }
        if !recoveryNeeded { purgeExpiredTrash() }
    }

    deinit {
        trashMaintenanceTask?.cancel()
        if let cloudEventObserver { NotificationCenter.default.removeObserver(cloudEventObserver) }
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
    }

    @discardableResult
    func addProject(name: String, icon: String = "folder", colorHex: String = "5856D6") -> TimelineProject {
        guard !isRecoveryMode else {
            lastSaveError = "数据库尚未恢复，暂时无法创建项目。"
            return TimelineProject(name: name, icon: icon, colorHex: colorHex)
        }
        let descriptor = FetchDescriptor<TimelineProject>(sortBy: [SortDescriptor(\TimelineProject.sortOrder, order: .reverse)])
        let highestOrder = (try? modelContext.fetch(descriptor).first?.sortOrder) ?? -1
        let project = TimelineProject(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新项目" : name.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: icon,
            colorHex: colorHex,
            sortOrder: highestOrder + 1
        )
        modelContext.insert(project)
        save()
        return project
    }

    @discardableResult
    func addEntry(to project: TimelineProject, title: String = "新的进展", date: Date = .now) -> TimelineEntry {
        guard !isRecoveryMode, !project.isTrashed else {
            lastSaveError = project.isTrashed ? "请先从回收站恢复项目。" : "数据库尚未恢复，暂时无法创建记录。"
            return TimelineEntry(title: title, date: date)
        }
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = TimelineEntry(title: cleanedTitle.isEmpty ? "新的进展" : cleanedTitle, date: date, project: project)
        modelContext.insert(entry)
        save()
        return entry
    }

    @discardableResult
    func touch(_ entry: TimelineEntry) -> Bool {
        guard !isRecoveryMode, !entry.isTrashed else {
            lastSaveError = entry.isTrashed ? "这条记录已在回收站，请先恢复。" : "数据库尚未恢复，当前不接受编辑或保存。"
            return false
        }
        let previousUpdatedAt = entry.updatedAt
        let previousPercent = entry.progressPercent
        entry.updatedAt = .now
        entry.progressPercent = min(100, max(0, entry.progressPercent))
        guard save() else {
            entry.updatedAt = previousUpdatedAt
            entry.progressPercent = previousPercent
            return false
        }
        return true
    }

    @discardableResult
    func deleteEntry(_ entry: TimelineEntry) -> Bool {
        guard !isRecoveryMode, !entry.isTrashed else { return false }
        let previousUpdatedAt = entry.updatedAt
        entry.deletedAt = .now
        entry.updatedAt = .now
        guard save() else {
            entry.deletedAt = nil
            entry.updatedAt = previousUpdatedAt
            scheduleTrashMaintenance()
            return false
        }
        return true
    }

    @discardableResult
    func deleteProject(_ project: TimelineProject) -> Bool {
        guard !isRecoveryMode, !project.isTrashed else { return false }
        project.deletedAt = .now
        guard save() else {
            project.deletedAt = nil
            scheduleTrashMaintenance()
            return false
        }
        return true
    }

    @discardableResult
    func restoreProject(_ project: TimelineProject) -> Bool {
        guard !isRecoveryMode, let deletedAt = project.deletedAt else { return false }
        guard !TimelineTrashSupport.isExpired(deletedAt, now: .now) else {
            purgeExpiredTrash()
            lastSaveError = "该项目已超过 30 天保留期，无法恢复。"
            return false
        }
        project.deletedAt = nil
        guard save() else {
            project.deletedAt = deletedAt
            scheduleTrashMaintenance()
            return false
        }
        return true
    }

    @discardableResult
    func restoreEntry(_ entry: TimelineEntry) -> Bool {
        guard !isRecoveryMode, let deletedAt = entry.deletedAt else { return false }
        guard entry.project?.isTrashed != true else {
            lastSaveError = "请先恢复这条记录所属的项目。"
            return false
        }
        guard !TimelineTrashSupport.isExpired(deletedAt, now: .now) else {
            purgeExpiredTrash()
            lastSaveError = "这条记录已超过 30 天保留期，无法恢复。"
            return false
        }
        let previousUpdatedAt = entry.updatedAt
        entry.deletedAt = nil
        entry.updatedAt = .now
        guard save() else {
            entry.deletedAt = deletedAt
            entry.updatedAt = previousUpdatedAt
            scheduleTrashMaintenance()
            return false
        }
        return true
    }

    @discardableResult
    func purgeExpiredTrash(now: Date = .now) -> Bool {
        guard !isRecoveryMode, editingOwners.isEmpty, !nutstoreState.isSyncing else { return false }
        defer { scheduleTrashMaintenance() }
        do {
            guard try TimelineTrashSupport.purgeExpired(in: modelContext, now: now) else { return false }
            guard save() else { modelContext.rollback(); return false }
            return true
        } catch {
            modelContext.rollback()
            lastSaveError = "回收站清理失败，内容仍保留：\(error.localizedDescription)"
            return false
        }
    }

    private func scheduleTrashMaintenance() {
        trashMaintenanceTask?.cancel()
        trashMaintenanceTask = nil
        guard trashMaintenanceActive, !isRecoveryMode, editingOwners.isEmpty,
              !nutstoreState.isSyncing else { return }
        do {
            guard let deadline = try TimelineTrashSupport.nextExpiration(in: modelContext) else { return }
            // A failed local save must not create an immediate retry loop.
            let remaining = deadline.timeIntervalSinceNow
            let delay = remaining > 0 ? remaining : 60
            trashMaintenanceTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, !Task.isCancelled, self.trashMaintenanceActive else { return }
                self.trashMaintenanceTask = nil
                self.purgeExpiredTrash()
            }
        } catch {
            lastSaveError = "无法检查回收站保留期：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func save() -> Bool {
        guard !isRecoveryMode else {
            lastSaveError = "数据库尚未恢复，当前不接受编辑或保存。"
            return false
        }
        do {
            try modelContext.save()
            lastSaveError = nil
            nutstoreSync?.localDidSave()
            scheduleTrashMaintenance()
            return true
        } catch {
            lastSaveError = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    var nutstoreConfigured: Bool { nutstoreSync?.configured ?? false }
    func nutstoreUsername() -> String { nutstoreSync?.username ?? "" }
    func configureNutstore(username: String, password: String) async throws {
        guard !isCloudEnabled else { throw NutstoreSyncError.cloudBuild }
        guard let nutstoreSync else { throw NutstoreSyncError.persistence }
        try await nutstoreSync.configure(username: username, password: password)
    }
    func syncNutstore() async { await nutstoreSync?.sync() }
    func disableNutstore() { nutstoreSync?.disable() }
    func setNutstoreActive(_ active: Bool) {
        trashMaintenanceActive = active
        if active { purgeExpiredTrash() }
        scheduleTrashMaintenance()
        nutstoreSync?.setForeground(active)
    }
    func setNutstoreEditing(_ editing: Bool, owner: UUID) {
        if editing { editingOwners.insert(owner) } else { editingOwners.remove(owner) }
        nutstoreSync?.setEditing(editing, owner: owner)
        if editingOwners.isEmpty { purgeExpiredTrash() }
        scheduleTrashMaintenance()
    }

    func refreshAccountStatus() async {
        guard let identifier = cloudKitContainerIdentifier else { return }
        do {
            let status = try await CKContainer(identifier: identifier).accountStatus()
            switch status {
            case .available:
                if case .unavailable = syncState { syncState = .waiting }
            case .noAccount:
                syncState = .unavailable("请在系统设置中登录 iCloud。记录仍会保存在此设备。")
                seedWelcomeProjectsIfNeeded()
            case .restricted:
                syncState = .unavailable("此设备的 iCloud 访问受到限制。记录仍会保存在此设备。")
                seedWelcomeProjectsIfNeeded()
            case .temporarilyUnavailable:
                syncState = .unavailable("iCloud 服务暂时不可用，系统会在恢复后继续尝试同步。")
            case .couldNotDetermine:
                syncState = .unavailable("暂时无法确定 iCloud 账户状态。记录仍会保存在此设备。")
            @unknown default:
                syncState = .unavailable("暂时无法确定 iCloud 账户状态。")
            }
        } catch {
            syncState = .unavailable(error.localizedDescription)
        }
    }

    private func observeCloudEvents() {
        cloudEventObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            Task { @MainActor [weak self] in self?.handleCloudEvent(event) }
        }
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshAccountStatus() }
        }
    }

    private func handleCloudEvent(_ event: NSPersistentCloudKitContainer.Event) {
        guard isCloudEnabled else { return }
        let operation: String
        switch event.type {
        case .setup: operation = "正在连接 iCloud"
        case .import: operation = "正在接收其他设备的记录"
        case .export: operation = "正在上传此设备的记录"
        @unknown default: operation = "正在处理 iCloud 记录"
        }
        guard let endDate = event.endDate else {
            activeCloudEvents.insert(event.identifier)
            syncState = .syncing(operation)
            return
        }
        activeCloudEvents.remove(event.identifier)
        if !event.succeeded {
            syncState = .failed(event.error?.localizedDescription ?? "最近一次 iCloud 操作未完成，系统会继续尝试。")
        } else if !activeCloudEvents.isEmpty {
            syncState = .syncing("正在处理其余 iCloud 记录")
        } else {
            switch event.type {
            case .setup: syncState = .waiting
            case .import: syncState = .activity(endDate, "已接收 iCloud 记录")
            case .export: syncState = .activity(endDate, "已向 iCloud 上传记录")
            @unknown default: syncState = .activity(endDate, "iCloud 操作已完成")
            }
        }
        if event.type == .import && event.succeeded { seedWelcomeProjectsIfNeeded() }
    }

    private func seedWelcomeProjectsIfNeeded() {
        guard !isRecoveryMode else { return }
        guard isUITesting || !defaults.bool(forKey: seedKey) else { return }
        do {
            let count = try modelContext.fetchCount(FetchDescriptor<TimelineProject>())
            guard count == 0 else {
                if !isUITesting { defaults.set(true, forKey: seedKey) }
                return
            }
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: .now)
            func day(_ daysAgo: Int, hour: Int = 10, minute: Int = 0) -> Date {
                let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
                return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
            }

            let timeline = TimelineProject(name: "Timeline", icon: "square.stack.3d.up", colorHex: "7068F3", sortOrder: 0, createdAt: day(8))
            let research = TimelineProject(name: "研究与探索", icon: "sparkles", colorHex: "D49A45", sortOrder: 1, createdAt: day(7))
            let personal = TimelineProject(name: "个人计划", icon: "leaf", colorHex: "4C9C7A", sortOrder: 2, createdAt: day(6))
            [timeline, research, personal].forEach { modelContext.insert($0) }

            let entries = [
                TimelineEntry(
                    title: "让每一次进展，都有迹可循",
                    date: day(0, hour: 9, minute: 41), status: .inProgress, progressPercent: 72,
                    progressText: "把**进展、问题与灵感**放在同一条时间线上。\n\n- [x] 项目管理、时间线与 Markdown 编辑\n- [ ] 在真实设备上验证 iCloud 同步",
                    issuesText: "- 同一天的多条记录，需要保留准确时间。",
                    ideasText: "> 项目不只需要一个终点，也需要看得见的过程。",
                    project: timeline, createdAt: day(0, hour: 9, minute: 41), updatedAt: day(0, hour: 9, minute: 41)
                ),
                TimelineEntry(
                    title: "确定时间线的信息层级",
                    date: day(1, hour: 15, minute: 20), status: .completed,
                    progressText: "确定两个浏览层级：\n\n1. 未聚焦时，只展示日期、标题与状态。\n2. 点击节点后展开完整卡片。\n\n用足够的留白，让记录本身成为主角。",
                    issuesText: "", ideasText: "把每个内容栏目做成可选项。简单的一天，只写一段进展也很好。", showIssues: false,
                    project: timeline, createdAt: day(1, hour: 15, minute: 20), updatedAt: day(1, hour: 15, minute: 20)
                ),
                TimelineEntry(
                    title: "从一个小而完整的版本开始",
                    date: day(3, hour: 11, minute: 5), status: .completed,
                    progressText: "第一版聚焦核心循环：**创建项目 → 添加记录 → 回看进展**。\n\n支持 Mac 与 iPhone，共用同一套数据结构。",
                    issuesText: "同步状态需要诚实反映系统反馈，不能把本地保存显示成同步完成。",
                    ideasText: "以后可以探索每周回顾与记录之间的关联。", project: timeline,
                    createdAt: day(3, hour: 11, minute: 5), updatedAt: day(3, hour: 11, minute: 5)
                ),
                TimelineEntry(
                    title: "把阅读变成可以继续的问题",
                    date: day(0, hour: 8, minute: 30), status: .inProgress, progressPercent: 35,
                    progressText: "整理本周阅读笔记，按**证据、推断、未知**区分结论。\n\n- [x] 汇总关键问题\n- [ ] 为每个问题建立可验证的下一步",
                    issuesText: "哪些结论有直接证据？哪些只是合理假设？",
                    ideasText: "阅读笔记的结尾固定留一个问题，让下一次工作有明确入口。", project: research,
                    createdAt: day(0, hour: 8, minute: 30), updatedAt: day(0, hour: 8, minute: 30)
                ),
                TimelineEntry(
                    title: "建立轻量的研究记录习惯",
                    date: day(4, hour: 16), status: .completed,
                    progressText: "每次实验或阅读之后记录三件事：\n\n- 实际做了什么\n- 看到了什么证据\n- 下一步如何验证",
                    ideasText: "让记录服务于判断，避免只积累工作量。", showIssues: false, project: research,
                    createdAt: day(4, hour: 16), updatedAt: day(4, hour: 16)
                ),
                TimelineEntry(
                    title: "给重要的事情留一点时间",
                    date: day(2, hour: 20, minute: 15), status: .inProgress, progressPercent: 40,
                    progressText: "这周安排两次运动，以及一个不被打扰的阅读时段。\n\n- [x] 完成第一次运动\n- [ ] 周末散步与回顾",
                    ideasText: "周日回看这一条时间线，看看哪些安排让自己更有能量。", showIssues: false, project: personal,
                    createdAt: day(2, hour: 20, minute: 15), updatedAt: day(2, hour: 20, minute: 15)
                )
            ]
            entries.forEach { modelContext.insert($0) }
            if save(), !isUITesting { defaults.set(true, forKey: seedKey) }
        } catch {
            lastSaveError = "无法创建欢迎记录：\(error.localizedDescription)"
        }
    }
}
