import Foundation
import SwiftData

struct TimelineReference: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var sourceEntryID: UUID
    var sourceTitle: String
    var sourceDate: Date
    var excerpt: String
    var contextBefore: String = ""
    var contextAfter: String = ""
    var createdAt: Date = .now

    init(id: UUID = UUID(), sourceEntryID: UUID, sourceTitle: String, sourceDate: Date,
         excerpt: String, contextBefore: String = "", contextAfter: String = "", createdAt: Date = .now) {
        self.id = id
        self.sourceEntryID = sourceEntryID
        self.sourceTitle = sourceTitle
        self.sourceDate = sourceDate
        self.excerpt = excerpt
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceEntryID, sourceTitle, sourceDate, excerpt, contextBefore, contextAfter, createdAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        sourceEntryID = try values.decode(UUID.self, forKey: .sourceEntryID)
        sourceTitle = try values.decode(String.self, forKey: .sourceTitle)
        sourceDate = try values.decode(Date.self, forKey: .sourceDate)
        excerpt = try values.decode(String.self, forKey: .excerpt)
        contextBefore = try values.decodeIfPresent(String.self, forKey: .contextBefore) ?? ""
        contextAfter = try values.decodeIfPresent(String.self, forKey: .contextAfter) ?? ""
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }
}

enum TimelineReferenceCodec {
    static func decode(_ value: String) -> [TimelineReference] {
        guard let data = value.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return (try? decoder.decode([TimelineReference].self, from: data)) ?? []
    }

    static func encode(_ references: [TimelineReference]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(references), let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }
}

enum EntryStatus: String, Codable, CaseIterable, Identifiable {
    case notStarted
    case inProgress
    case completed
    case paused

    var id: String { rawValue }

    var label: String {
        switch self {
        case .notStarted: "未开始"
        case .inProgress: "进行中"
        case .completed: "已完成"
        case .paused: "已暂停"
        }
    }

    var symbol: String {
        switch self {
        case .notStarted: "circle.dashed"
        case .inProgress: "circle.lefthalf.filled"
        case .completed: "checkmark.circle.fill"
        case .paused: "pause.circle.fill"
        }
    }

    var defaultPercent: Int {
        switch self {
        case .notStarted: 0
        case .inProgress: 50
        case .completed: 100
        case .paused: 50
        }
    }
}

/// Defaults and optional inverse relationships keep this schema compatible with
/// SwiftData's private CloudKit database. UUIDs are deliberately not unique attributes.
@Model
final class TimelineProject {
    var id: UUID = UUID()
    var name: String = "新项目"
    var icon: String = "folder"
    var colorHex: String = "5856D6"
    var createdAt: Date = Date()
    var sortOrder: Int = 0
    var pendingReferencesJSON: String = "[]"
    var deletedAt: Date? = nil

    var isTrashed: Bool { deletedAt != nil }

    var pendingReferences: [TimelineReference] {
        get { TimelineReferenceCodec.decode(pendingReferencesJSON) }
        set { pendingReferencesJSON = TimelineReferenceCodec.encode(newValue) }
    }

    @Relationship(deleteRule: .cascade, inverse: \TimelineEntry.project)
    var entries: [TimelineEntry]? = nil

    init(
        id: UUID = UUID(),
        name: String,
        icon: String = "folder",
        colorHex: String = "5856D6",
        sortOrder: Int = 0,
        createdAt: Date = .now,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }

    var sortedEntries: [TimelineEntry] {
        (entries ?? []).filter { !$0.isTrashed }.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.createdAt > $1.createdAt
        }
    }
}

@Model
final class TimelineEntry {
    var id: UUID = UUID()
    var title: String = "新的进展"
    var date: Date = Date()
    /// Keep the enum's raw value as a primitive string for CloudKit compatibility.
    var progress: String = "inProgress"
    var progressPercent: Int = 50
    var progressText: String = ""
    var issuesText: String = ""
    var ideasText: String = ""
    var showProgress: Bool = true
    var showIssues: Bool = true
    var showIdeas: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var referencesJSON: String = "[]"
    var deletedAt: Date? = nil
    var project: TimelineProject? = nil

    var isTrashed: Bool { deletedAt != nil || project?.isTrashed == true }

    var references: [TimelineReference] {
        get { TimelineReferenceCodec.decode(referencesJSON) }
        set { referencesJSON = TimelineReferenceCodec.encode(newValue) }
    }

    init(
        id: UUID = UUID(),
        title: String,
        date: Date = .now,
        status: EntryStatus = .inProgress,
        progressPercent: Int? = nil,
        progressText: String = "",
        issuesText: String = "",
        ideasText: String = "",
        showProgress: Bool = true,
        showIssues: Bool = true,
        showIdeas: Bool = true,
        project: TimelineProject? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.progress = status.rawValue
        self.progressPercent = min(100, max(0, progressPercent ?? status.defaultPercent))
        self.progressText = progressText
        self.issuesText = issuesText
        self.ideasText = ideasText
        self.showProgress = showProgress
        self.showIssues = showIssues
        self.showIdeas = showIdeas
        self.project = project
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    var status: EntryStatus {
        get { EntryStatus(rawValue: progress) ?? .inProgress }
        set { progress = newValue.rawValue }
    }

    var searchableText: String {
        [title, progressText, issuesText, ideasText, project?.name ?? ""]
            .joined(separator: "\n")
    }
}

/// Trash retains the original objects and relationships until its deadline.
/// Saving and journaling the resulting permanent deletions belong to the caller.
enum TimelineTrashSupport {
    static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    @MainActor
    @discardableResult
    static func purgeExpired(in context: ModelContext, now: Date = .now) throws -> Bool {
        let projects = try context.fetch(FetchDescriptor<TimelineProject>())
        let expiredProjects = projects.filter { isExpired($0.deletedAt, now: now) }
        let expiredProjectIDs = Set(expiredProjects.map(\.id))
        let entries = try context.fetch(FetchDescriptor<TimelineEntry>())
        let expiredEntries = entries.filter {
            isExpired($0.deletedAt, now: now) && !($0.project.map { expiredProjectIDs.contains($0.id) } ?? false)
        }
        for entry in expiredEntries { context.delete(entry) }
        for project in expiredProjects { context.delete(project) }
        return !expiredProjects.isEmpty || !expiredEntries.isEmpty
    }

    @MainActor
    static func nextExpiration(in context: ModelContext) throws -> Date? {
        let projects = try context.fetch(FetchDescriptor<TimelineProject>())
        let entries = try context.fetch(FetchDescriptor<TimelineEntry>())
        return (projects.compactMap(\.deletedAt) + entries.compactMap(\.deletedAt))
            .min()?.addingTimeInterval(retentionInterval)
    }

    static func isExpired(_ deletedAt: Date?, now: Date) -> Bool {
        guard let deletedAt else { return false }
        return now.timeIntervalSince(deletedAt) >= retentionInterval
    }
}
