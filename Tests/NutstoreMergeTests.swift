import Foundation

/// Standalone, deterministic merge checks. This executable needs only the sync
/// document source, so it cannot touch a user's SwiftData store or credentials.
@main
struct NutstoreMergeTests {
    static let deviceA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    static let deviceB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    static let projectID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let entryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let otherID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    enum Failure: Error, CustomStringConvertible {
        case assertion(String)
        var description: String {
            switch self { case .assertion(let message): message }
        }
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.assertion(message) }
    }

    static func project(_ id: UUID = projectID, name: String = "Fixture project") -> NutstoreRecord {
        .project(.init(id: id, name: name, icon: "folder", colorHex: "777777", createdAt: epoch,
                       sortOrder: 0, pendingReferencesJSON: "[]"))
    }

    static func entry(_ id: UUID = entryID, parent: UUID? = projectID, text: String = "Initial") -> NutstoreRecord {
        .entry(.init(id: id, projectID: parent, title: "Fixture entry", date: epoch, progress: "inProgress",
                     progressPercent: 50, progressText: text, issuesText: "- [ ] Fixture task", ideasText: "Idea",
                     showProgress: true, showIssues: true, showIdeas: true, createdAt: epoch, updatedAt: epoch,
                     referencesJSON: "[]"))
    }

    static func records(_ values: [NutstoreRecord]) -> [String: NutstoreRecord] {
        Dictionary(uniqueKeysWithValues: values.map { ($0.key, $0) })
    }

    static func contents(_ values: [String: NutstoreRecord]) -> Set<String> {
        Set(values.values.compactMap { value in
            if case .entry(let e) = value { return e.progressText }
            return nil
        })
    }

    static func entryCount(_ values: [String: NutstoreRecord]) -> Int {
        values.values.reduce(0) { count, value in
            if case .entry = value { return count + 1 }
            return count
        }
    }

    /// Models what a successful store import does after materialization.
    @discardableResult
    static func apply(_ replica: inout NutstoreReplica) throws -> [String: NutstoreRecord] {
        let projection = try replica.materialize()
        replica.baseline = projection
        return projection
    }

    static func shared() throws -> (NutstoreReplica, NutstoreReplica) {
        var a = NutstoreReplica(deviceID: deviceA)
        var b = NutstoreReplica(deviceID: deviceB)
        try a.capture(records([project(), entry()]))
        try b.merge([a.document])
        try apply(&b)
        return (a, b)
    }

    static func initialUnion() throws {
        var a = NutstoreReplica(deviceID: deviceA)
        var b = NutstoreReplica(deviceID: deviceB)
        try a.capture(records([project(), entry()]))
        try b.capture(records([project(otherID, name: "Other project"), entry(otherID, parent: otherID, text: "Other")]))
        let originalA = a.document
        let originalB = b.document
        try a.merge([originalB])
        try b.merge([originalA])
        let pa = try apply(&a)
        let pb = try apply(&b)
        try check(pa == pb && pa.count == 4, "Initial synchronization must union independent local workspaces.")
        try check(contents(pa) == ["Initial", "Other"], "Initial union lost entry contents.")
        let documentBefore = a.document
        try a.capture(pa)
        try check(a.document == documentBefore, "Applying remote values must not manufacture local edits.")
    }

    static func sequentialBidirectionalEdits() throws {
        var (a, b) = try shared()
        var local = b.baseline
        local[entry().key] = entry(text: "Edited on B")
        try b.capture(local)
        try a.merge([b.document])
        let first = try apply(&a)
        try check(entryCount(first) == 1 && contents(first) == ["Edited on B"], "A causal edit must replace its ancestor.")
        local = first
        local[entry().key] = entry(text: "Then edited on A")
        try a.capture(local)
        try b.merge([a.document])
        let second = try apply(&b)
        try check(entryCount(second) == 1 && contents(second) == ["Then edited on A"], "Bidirectional causal edits must not create conflicts.")
    }

    static func concurrentEditsAndIdempotence() throws {
        var (a, b) = try shared()
        var localA = a.baseline
        var localB = b.baseline
        localA[entry().key] = entry(text: "Offline A")
        localB[entry().key] = entry(text: "Offline B")
        try a.capture(localA)
        try b.capture(localB)
        let docA = a.document
        let docB = b.document
        try a.merge([docB])
        try b.merge([docA])
        let pa = try apply(&a)
        let pb = try apply(&b)
        try check(pa == pb, "Concurrent merge order must converge.")
        try check(entryCount(pa) == 2 && contents(pa) == ["Offline A", "Offline B"], "Concurrent contents need exactly two preserved entries.")
        let convergedA = a.document
        for _ in 0..<4 {
            try a.merge([docA, docB, b.document])
            let repeated = try apply(&a)
            try check(repeated == pa, "Retrying synchronization must not duplicate conflict copies.")
        }
        try check(a.document == convergedA, "Idempotent synchronization changed the causal document.")
    }

    static func deleteAgainstConcurrentEdit() throws {
        var (a, b) = try shared()
        var localA = a.baseline
        localA.removeValue(forKey: entry().key)
        try a.capture(localA)
        var localB = b.baseline
        localB[entry().key] = entry(text: "Unsynchronized edit")
        try b.capture(localB)
        let deletion = a.document
        let edit = b.document
        try a.merge([edit])
        try b.merge([deletion])
        let pa = try apply(&a)
        let pb = try apply(&b)
        try check(pa == pb, "Delete/edit conflicts must converge in both directions.")
        try check(pa[entry().key] == nil, "A tombstoned original must not resurrect.")
        try check(entryCount(pa) == 1 && contents(pa) == ["Unsynchronized edit"], "A concurrent edit must survive as a recovery copy.")
        try a.merge([edit, deletion])
        let repeated = try apply(&a)
        try check(repeated == pa, "A stale snapshot resurrected or duplicated deleted data.")
    }

    static func projectDeleteAgainstOfflineChild() throws {
        var (a, b) = try shared()
        try a.capture([:]) // The store captures all known children before cascade.
        var localB = b.baseline
        localB[entry(otherID).key] = entry(otherID, text: "Offline new child")
        try b.capture(localB)
        let deletion = a.document
        let addition = b.document
        try a.merge([addition])
        try b.merge([deletion])
        let pa = try apply(&a)
        let pb = try apply(&b)
        try check(pa == pb, "Project deletion and an unseen child must converge.")
        try check(pa[project().key] == nil && pa[entry().key] == nil, "A deleted project or known child reappeared.")
        try check(entryCount(pa) == 1 && contents(pa) == ["Offline new child"], "Offline child must be retained once in recovery.")
        for value in pa.values {
            if case .entry(let recovered) = value {
                try check(recovered.projectID != projectID, "Recovered child still points at a deleted project.")
                let parent = recovered.projectID.map { "p/" + $0.uuidString.lowercased() }
                try check(parent.flatMap { pa[$0] } != nil, "Recovered child has no visible recovery project.")
            }
        }
        try a.merge([addition, deletion])
        let repeated = try apply(&a)
        try check(repeated == pa, "Project recovery must be idempotent.")
    }

    static func deletingConflictCopyIsPermanent() throws {
        var (a, b) = try shared()
        var localA = a.baseline
        var localB = b.baseline
        localA[entry().key] = entry(text: "A")
        localB[entry().key] = entry(text: "B")
        try a.capture(localA)
        try b.capture(localB)
        let oldA = a.document
        let oldB = b.document
        try a.merge([oldB])
        let projection = try apply(&a)
        let copyKey = try projection.keys.first(where: { $0.hasPrefix("e/") && $0 != entry().key })
            .unwrap("Concurrent editing did not create a copy.")
        var remaining = projection
        remaining.removeValue(forKey: copyKey)
        try a.capture(remaining)
        for _ in 0..<3 {
            try a.merge([oldA, oldB])
            let repeated = try apply(&a)
            try check(repeated == remaining && repeated[copyKey] == nil, "An explicitly deleted conflict copy was regenerated.")
        }
    }

    static func deletingRecoveryCopyIsPermanent() throws {
        var (a, b) = try shared()
        try a.capture([:])
        var localB = b.baseline
        localB[entry(otherID).key] = entry(otherID, text: "New child")
        try b.capture(localB)
        let oldB = b.document
        try a.merge([oldB])
        let projection = try apply(&a)
        let copyKey = try projection.keys.first(where: { $0.hasPrefix("e/") })
            .unwrap("Project deletion did not create a recovery copy.")
        var remaining = projection
        remaining.removeValue(forKey: copyKey)
        try a.capture(remaining)
        try a.merge([oldB])
        let repeated = try apply(&a)
        try check(repeated == remaining && repeated[copyKey] == nil, "An explicitly deleted recovery copy was regenerated.")
    }

    static func localReappearanceCannotEraseTombstone() throws {
        var (a, _) = try shared()
        var local = a.baseline
        local.removeValue(forKey: entry().key)
        try a.capture(local)
        try apply(&a)
        // A stale model object, restored draft, or future backup import may
        // contain an old UUID. Capture must retain terminal deletion history.
        local[entry().key] = entry(text: "Restored local contents")
        try a.capture(local)
        let projection = try apply(&a)
        try check(projection[entry().key] == nil, "Capturing a stale local ID erased its terminal tombstone.")
        try check(contents(projection) == ["Restored local contents"], "Post-deletion local contents must remain available as a copy.")
        try check(a.document.records[entry().key]?.contains(where: \.deleted) == true, "The deletion history was discarded.")
    }

    static func rejectsInvalidDocuments() throws {
        let (a, _) = try shared()
        func rejected(_ document: NutstoreSyncDocument, _ message: String) throws {
            var target = NutstoreReplica(deviceID: deviceB)
            do {
                try target.merge([document])
                throw Failure.assertion(message)
            } catch is NutstoreMergeError { }
        }
        var bad = a.document
        bad.formatVersion = 999
        try rejected(bad, "Unsupported schema must be rejected.")
        bad = a.document
        bad.records["e/not-an-id"] = bad.records.removeValue(forKey: entry().key)
        try rejected(bad, "Mismatched entity keys must be rejected.")
        bad = a.document
        bad.clock["not-a-device"] = 1
        try rejected(bad, "Invalid device clocks must be rejected.")
        bad = a.document
        bad.clock[deviceA.uuidString.lowercased()] = -1
        try rejected(bad, "Negative device clocks must be rejected.")
        bad = a.document
        var versions = try bad.records[entry().key].unwrap("Missing fixture version.")
        versions[0].record = entry(text: "Different payload under same revision")
        bad.records[entry().key] = versions
        var target = a
        do {
            try target.merge([bad])
            throw Failure.assertion("A revision collision must be rejected.")
        } catch NutstoreMergeError.revisionCollision { }
        let encoded = try NutstoreJSON.encode(a)
        let decoded = try NutstoreJSON.decode(NutstoreReplica.self, from: encoded)
        try check(decoded == a, "Persisted replica must preserve baseline and causal metadata.")
    }

    static func legacyV1JSONIsReadable() throws {
        let (source, _) = try shared()
        let data = try NutstoreJSON.encode(source.document)
        func legacy(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                var result = dictionary.filter { $0.key != "deletedAt" }.mapValues(legacy)
                if result["formatVersion"] != nil { result["formatVersion"] = 1 }
                return result
            }
            if let array = value as? [Any] { return array.map(legacy) }
            return value
        }
        let legacyData = try JSONSerialization.data(withJSONObject: legacy(JSONSerialization.jsonObject(with: data)))
        let decoded = try NutstoreJSON.decode(NutstoreSyncDocument.self, from: legacyData)
        try decoded.validate()
        try check(decoded.formatVersion == 1, "Legacy JSON fixture did not preserve schema version 1.")
        var target = NutstoreReplica(deviceID: deviceB)
        try target.merge([decoded])
        let projection = try apply(&target)
        try check(projection == source.baseline, "Version 1 records without trash dates did not retain their original fields.")
        for record in projection.values {
            switch record {
            case .project(let project): try check(project.deletedAt == nil, "A legacy project was imported into trash.")
            case .entry(let entry): try check(entry.deletedAt == nil, "A legacy record was imported into trash.")
            }
        }
        try check(target.document.formatVersion == 2, "A merged legacy replica did not write the current format version.")
    }

    static func softDeletionRestoreAndPurge() throws {
        var (a, b) = try shared()
        let trashDate = epoch.addingTimeInterval(1_234)
        var record: NutstoreEntryRecord
        guard case .entry(let original) = entry() else { throw Failure.assertion("Missing fixture entry.") }
        record = original
        record.deletedAt = trashDate
        var local = a.baseline
        local[entry().key] = .entry(record)
        try a.capture(local)
        let trashedDocument = a.document
        try b.merge([trashedDocument])
        let trashedProjection = try apply(&b)
        try check(trashedProjection[entry().key] == .entry(record), "Trash date or record payload was lost across replicas.")
        try check(b.document.records[entry().key]?.contains(where: \.deleted) == false,
                  "Soft deletion incorrectly created a terminal deletion tombstone.")
        record.deletedAt = nil
        local = b.baseline
        local[entry().key] = .entry(record)
        try b.capture(local)
        try a.merge([b.document])
        let restored = try apply(&a)
        try check(restored[entry().key] == entry() && entryCount(restored) == 1,
                  "Restoring a trashed record lost its identity or generated a conflict copy.")
        try b.merge([a.document])
        _ = try apply(&b)
        record.deletedAt = trashDate
        local = a.baseline
        local[entry().key] = .entry(record)
        try a.capture(local)
        try b.merge([a.document])
        _ = try apply(&b)
        let staleTrash = b.document
        local = a.baseline
        local.removeValue(forKey: entry().key) // Expiry performs the terminal physical deletion.
        try a.capture(local)
        for _ in 0..<3 {
            try a.merge([trashedDocument, staleTrash])
            let purged = try apply(&a)
            try check(purged[entry().key] == nil && entryCount(purged) == 0,
                      "A stale remote trash snapshot resurrected a purged record.")
        }
        try b.merge([a.document])
        let remotePurged = try apply(&b)
        try check(remotePurged[entry().key] == nil && entryCount(remotePurged) == 0,
                  "The purge tombstone did not propagate to the other device.")
    }

    static func concurrentEditCannotSilentlyRestoreTrash() throws {
        var (a, b) = try shared()
        guard case .entry(var trashed) = entry() else { throw Failure.assertion("Missing fixture entry.") }
        trashed.deletedAt = epoch.addingTimeInterval(60)
        var localA = a.baseline, localB = b.baseline
        localA[entry().key] = .entry(trashed)
        localB[entry().key] = entry(text: "Offline contents from an older client")
        try a.capture(localA)
        try b.capture(localB)
        let trashDocument = a.document, offlineDocument = b.document
        try a.merge([offlineDocument])
        try b.merge([trashDocument])
        let pa = try apply(&a), pb = try apply(&b)
        try check(pa == pb, "Concurrent trash and an offline edit did not converge.")
        try check(pa[entry().key] == .entry(trashed), "An offline client without trash metadata silently restored the original record.")
        try check(contents(pa).contains("Offline contents from an older client"), "Protecting trash discarded the concurrent offline edit.")
        try a.merge([trashDocument, offlineDocument])
        let repeated = try apply(&a)
        try check(repeated == pa, "Retrying a concurrent trash/edit merge made duplicate recovery copies.")
    }

    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("initial union", initialUnion),
            ("causal bidirectional edits", sequentialBidirectionalEdits),
            ("concurrent edits and retries", concurrentEditsAndIdempotence),
            ("delete versus concurrent edit", deleteAgainstConcurrentEdit),
            ("project deletion versus offline child", projectDeleteAgainstOfflineChild),
            ("deleted conflict copy remains deleted", deletingConflictCopyIsPermanent),
            ("deleted recovery copy remains deleted", deletingRecoveryCopyIsPermanent),
            ("local stale ID cannot erase deletion", localReappearanceCannotEraseTombstone),
            ("invalid documents and durable round trip", rejectsInvalidDocuments),
            ("legacy v1 JSON without trash fields", legacyV1JSONIsReadable),
            ("soft-delete restore and terminal purge", softDeletionRestoreAndPurge),
            ("concurrent offline edit cannot restore trash", concurrentEditCannotSilentlyRestoreTrash)
        ]
        var failures = 0
        for (name, test) in tests {
            do {
                try test()
                print("PASS: \(name)")
            } catch {
                failures += 1
                print("FAIL: \(name): \(error)")
            }
        }
        print("Nutstore merge tests: \(tests.count - failures) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}

private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let value = self else { throw NutstoreMergeTests.Failure.assertion(message) }
        return value
    }
}
