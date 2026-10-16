import Foundation
import CryptoKit

struct NutstoreProjectRecord: Codable, Equatable {
    var id: UUID
    var name: String
    var icon: String
    var colorHex: String
    var createdAt: Date
    var sortOrder: Int
    var pendingReferencesJSON: String
    var deletedAt: Date? = nil
}

struct NutstoreEntryRecord: Codable, Equatable {
    var id: UUID
    var projectID: UUID?
    var title: String
    var date: Date
    var progress: String
    var progressPercent: Int
    var progressText: String
    var issuesText: String
    var ideasText: String
    var showProgress: Bool
    var showIssues: Bool
    var showIdeas: Bool
    var createdAt: Date
    var updatedAt: Date
    var referencesJSON: String
    var deletedAt: Date? = nil
}

enum NutstoreRecord: Codable, Equatable {
    case project(NutstoreProjectRecord)
    case entry(NutstoreEntryRecord)

    var id: UUID {
        switch self { case .project(let p): p.id; case .entry(let e): e.id }
    }
    var key: String {
        switch self { case .project: "p/" + id.uuidString.lowercased(); case .entry: "e/" + id.uuidString.lowercased() }
    }
    var deletedAt: Date? {
        switch self { case .project(let project): project.deletedAt; case .entry(let entry): entry.deletedAt }
    }
    var canonicalized: NutstoreRecord {
        func date(_ value: Date) -> Date {
            let milliseconds = (value.timeIntervalSince1970 * 1000).rounded()
            guard milliseconds.isFinite, abs(milliseconds) < 9e15 else { return value }
            return Date(timeIntervalSince1970: Double(Int64(milliseconds)) / 1000)
        }
        switch self {
        case .project(var project):
            project.createdAt = date(project.createdAt); project.deletedAt = project.deletedAt.map(date)
            return .project(project)
        case .entry(var entry):
            entry.date = date(entry.date); entry.createdAt = date(entry.createdAt); entry.updatedAt = date(entry.updatedAt)
            entry.deletedAt = entry.deletedAt.map(date)
            return .entry(entry)
        }
    }
}

/// Vector clocks record observed edits, not wall-clock time. Device snapshots
/// have separate filenames, so concurrent uploads never overwrite one another.
struct NutstoreRecordVersion: Codable, Equatable {
    var revisionID: UUID
    var clock: [String: Int]
    var deleted: Bool
    var record: NutstoreRecord
}

struct NutstoreSyncDocument: Codable, Equatable {
    // Version 2 adds recoverable trash. Version 1 clients reject this document
    // rather than dropping deletion dates when they rewrite a snapshot.
    var formatVersion = 2
    var deviceID: UUID
    var clock: [String: Int] = [:]
    var records: [String: [NutstoreRecordVersion]] = [:]

    func validate(expectedDeviceID: UUID? = nil) throws {
        guard (1...2).contains(formatVersion), expectedDeviceID == nil || expectedDeviceID == deviceID,
              records.count <= 100_000 else { throw NutstoreMergeError.invalidDocument }
        for (key, versions) in records {
            guard !versions.isEmpty, versions.count <= 128 else { throw NutstoreMergeError.invalidDocument }
            for version in versions {
                guard version.record.key == key, version.clock.count <= 128,
                      version.record == version.record.canonicalized,
                      version.clock.allSatisfy({ UUID(uuidString: $0.key)?.uuidString.lowercased() == $0.key && $0.value >= 0 }),
                      NutstoreReplica.covers(clock, version.clock) else {
                    throw NutstoreMergeError.invalidDocument
                }
                switch version.record {
                case .project(let project):
                    guard project.name.utf8.count <= 1_000_000, Self.validDate(project.createdAt),
                          project.deletedAt.map(Self.validDate) ?? true else { throw NutstoreMergeError.invalidDocument }
                case .entry(let entry):
                    guard entry.progressText.utf8.count + entry.issuesText.utf8.count + entry.ideasText.utf8.count <= 10_000_000,
                          [entry.date, entry.createdAt, entry.updatedAt].allSatisfy(Self.validDate),
                          entry.deletedAt.map(Self.validDate) ?? true else { throw NutstoreMergeError.invalidDocument }
                }
            }
        }
        guard clock.count <= 128, clock.allSatisfy({ UUID(uuidString: $0.key)?.uuidString.lowercased() == $0.key && $0.value >= 0 }) else { throw NutstoreMergeError.invalidDocument }
    }
    private static func validDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && seconds >= -62_135_596_800 && seconds <= 253_402_300_799
    }
}

enum NutstoreMergeError: LocalizedError {
    case invalidDocument, revisionCollision, counterOverflow
    var errorDescription: String? {
        switch self {
        case .invalidDocument: "云端 Timeline 数据格式不兼容或不完整，已停止本次同步，本机记录保持不变。"
        case .revisionCollision: "云端存在不一致的记录版本，已停止同步以保留数据。"
        case .counterOverflow: "同步版本计数异常，已停止同步以保留数据。"
        }
    }
}

enum NutstoreJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
            guard milliseconds.isFinite, abs(milliseconds) < 9e15 else { throw NutstoreMergeError.invalidDocument }
            var container = encoder.singleValueContainer()
            try container.encode(Int64(milliseconds))
        }
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}

/// The baseline describes the last values actually applied to SwiftData. It is
/// persisted beside the local database and never sent as a credential or config.
struct NutstoreReplica: Codable, Equatable {
    var document: NutstoreSyncDocument
    var baseline: [String: NutstoreRecord] = [:]

    init(deviceID: UUID) { document = NutstoreSyncDocument(deviceID: deviceID) }

    mutating func capture(_ values: [String: NutstoreRecord]) throws {
        document.formatVersion = 2
        let local = values.mapValues { $0.canonicalized }
        for key in Set(baseline.keys).union(local.keys).sorted() where baseline[key] != local[key] {
            guard let record = local[key] ?? baseline[key] else { continue }
            let device = document.deviceID.uuidString.lowercased()
            guard document.clock[device, default: 0] < Int.max else { throw NutstoreMergeError.counterOverflow }
            document.clock[device, default: 0] += 1
            let version = NutstoreRecordVersion(revisionID: UUID(), clock: document.clock,
                                                deleted: local[key] == nil, record: record)
            try insert(version)
        }
        baseline = local
    }

    mutating func merge(_ remote: [NutstoreSyncDocument]) throws {
        document.formatVersion = 2
        for snapshot in remote {
            try snapshot.validate()
            for (device, count) in snapshot.clock { document.clock[device] = max(document.clock[device, default: 0], count) }
            for versions in snapshot.records.values {
                for version in versions { try insert(version) }
            }
        }
    }

    /// Conflict and recovery copies have deterministic IDs. Deleting or editing
    /// a copy therefore persists across retries instead of recreating the copy.
    mutating func materialize() throws -> [String: NutstoreRecord] {
        for _ in 0..<8 {
            let before = document.records
            for (key, versions) in before {
                let deletions = versions.filter(\.deleted)
                let live = versions.filter { !$0.deleted }
                let winner = deletions.isEmpty ? live.max(by: Self.visibleOrder) : nil
                for version in live where winner?.revisionID != version.revisionID {
                    if deletions.contains(where: { Self.covers($0.clock, version.clock) }) { continue }
                    var copy = version
                    let id = Self.stableID("conflict/" + key + "/" + version.revisionID.uuidString)
                    switch copy.record {
                    case .project(var project):
                        project.id = id; project.name += "（冲突副本）"
                        copy.record = .project(project)
                    case .entry(var entry):
                        entry.id = id; entry.title += "（冲突副本）"
                        copy.record = .entry(entry)
                    }
                    copy.revisionID = Self.stableID("copy-version/" + version.revisionID.uuidString)
                    try insert(copy)
                }
            }

            var result = visibleRecords()
            for (key, record) in result.sorted(by: { $0.key < $1.key }) {
                guard case .entry(let entry) = record else { continue }
                let parentKey = entry.projectID.map { "p/" + $0.uuidString.lowercased() }
                if let parentKey, result[parentKey] != nil { continue }
                guard let original = document.records[key]?.filter({ !$0.deleted }).max(by: Self.visibleOrder) else { continue }
                let parentDeletes = parentKey.flatMap { document.records[$0] }?.filter(\.deleted) ?? []
                if let deletion = parentDeletes.filter({ Self.covers($0.clock, original.clock) }).max(by: Self.revisionOrder) {
                    let cascade = NutstoreRecordVersion(revisionID: Self.stableID("cascade/" + deletion.revisionID.uuidString + "/" + key), clock: deletion.clock, deleted: true, record: record)
                    try insert(cascade)
                } else {
                    let recoveryID = Self.stableID("recovery-project/" + (entry.projectID?.uuidString ?? "unassigned"))
                    let recovery = NutstoreProjectRecord(id: recoveryID, name: "恢复的记录", icon: "tray.full", colorHex: "A06A3B", createdAt: Date(timeIntervalSince1970: 0), sortOrder: Int.max / 2, pendingReferencesJSON: "[]")
                    try insert(.init(revisionID: Self.stableID("recovery-version/" + recoveryID.uuidString), clock: [:], deleted: false, record: .project(recovery)))
                    var recovered = entry
                    recovered.id = Self.stableID("orphan/" + key + "/" + original.revisionID.uuidString)
                    recovered.projectID = recoveryID
                    recovered.title += "（恢复副本）"
                    try insert(.init(revisionID: Self.stableID("orphan-version/" + original.revisionID.uuidString), clock: original.clock, deleted: false, record: .entry(recovered)))
                }
                result.removeValue(forKey: key)
            }
            if before == document.records {
                // Original orphans remain in the journal for causality but are
                // represented only by their recovery copy in the local model.
                return result
            }
        }
        throw NutstoreMergeError.invalidDocument
    }

    private func visibleRecords() -> [String: NutstoreRecord] {
        document.records.compactMapValues { versions in
            guard !versions.contains(where: \.deleted) else { return nil }
            return versions.max(by: Self.visibleOrder)?.record
        }
    }

    private mutating func insert(_ version: NutstoreRecordVersion) throws {
        let key = version.record.key
        var versions = document.records[key, default: []]
        if let existing = versions.first(where: { $0.revisionID == version.revisionID }) {
            guard existing == version else { throw NutstoreMergeError.revisionCollision }
            return
        }
        for (device, count) in version.clock { document.clock[device] = max(document.clock[device, default: 0], count) }
        versions.append(version)
        // A tombstone is terminal for its original ID. Concurrent/late edits
        // can become copies, but never silently resurrect the original record.
        versions = versions.filter { candidate in
            !versions.contains { other in
                guard other.revisionID != candidate.revisionID else { return false }
                if candidate.deleted && !other.deleted { return false }
                return Self.dominates(other.clock, candidate.clock)
            }
        }
        document.records[key] = versions.sorted(by: Self.revisionOrder)
    }

    static func covers(_ lhs: [String: Int], _ rhs: [String: Int]) -> Bool {
        rhs.allSatisfy { lhs[$0.key, default: 0] >= $0.value }
    }
    static func dominates(_ lhs: [String: Int], _ rhs: [String: Int]) -> Bool {
        covers(lhs, rhs) && Set(lhs.keys).union(rhs.keys).contains { lhs[$0, default: 0] > rhs[$0, default: 0] }
    }
    private static func revisionOrder(_ lhs: NutstoreRecordVersion, _ rhs: NutstoreRecordVersion) -> Bool {
        lhs.revisionID.uuidString < rhs.revisionID.uuidString
    }
    /// Causally later restores already replace prior trash versions in insert.
    /// Concurrent old-client edits must not make a trashed original visible.
    private static func visibleOrder(_ lhs: NutstoreRecordVersion, _ rhs: NutstoreRecordVersion) -> Bool {
        if (lhs.record.deletedAt != nil) != (rhs.record.deletedAt != nil) {
            return lhs.record.deletedAt == nil
        }
        return revisionOrder(lhs, rhs)
    }
    static func stableID(_ value: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
