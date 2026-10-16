import Foundation
import SwiftData

@main
struct TimelineReferenceTests {
    @MainActor
    static func main() throws {
        func check(_ value: Bool, _ message: String) { precondition(value, message) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TimelineReferenceChecks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema([TimelineProject.self, TimelineEntry.self])
        func open(_ url: URL) throws -> ModelContainer {
            try ModelContainer(for: schema, configurations: [ModelConfiguration("References", schema: schema, url: url, cloudKitDatabase: .none)])
        }
        let url = directory.appendingPathComponent("check.store")
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        var sourceID = UUID()
        do {
            let container = try open(url), context = container.mainContext
            let project = TimelineProject(name: "引用验证")
            let source = TimelineEntry(title: "历史来源", date: stamp, progressText: "保留 **原文** 与 $x^2$", project: project)
            sourceID = source.id
            let destination = TimelineEntry(title: "当前记录", date: stamp.addingTimeInterval(86400), project: project)
            context.insert(project); context.insert(source); context.insert(destination)
            let quote = TimelineReference(sourceEntryID: source.id, sourceTitle: source.title, sourceDate: source.date, excerpt: source.progressText, createdAt: stamp)
            destination.references = [quote]; project.pendingReferences = [quote]
            try context.save()
            check(TimelineReferenceCodec.decode(TimelineReferenceCodec.encode([quote])) == [quote], "Reference JSON round trip")
        }
        do {
            let container = try open(url), context = container.mainContext
            let records = try context.fetch(FetchDescriptor<TimelineEntry>())
            let destination = records.first { $0.title == "当前记录" }!
            let project = try context.fetch(FetchDescriptor<TimelineProject>()).first!
            check(destination.references.first?.excerpt == "保留 **原文** 与 $x^2$", "Attached excerpt survives reopen")
            check(project.pendingReferences.count == 1, "Pending shelf survives reopen")
            context.delete(records.first { $0.id == sourceID }!); try context.save()
            check(destination.references.first?.sourceTitle == "历史来源", "Deleting source retains snapshot")
        }
        let legacyReference = TimelineReference(sourceEntryID: UUID(), sourceTitle: "旧引用", sourceDate: stamp, excerpt: "旧版片段", createdAt: stamp)
        let legacyData = Data(TimelineReferenceCodec.encode([legacyReference]).utf8)
        var legacyObjects = try JSONSerialization.jsonObject(with: legacyData) as! [[String: Any]]
        legacyObjects[0].removeValue(forKey: "contextBefore")
        legacyObjects[0].removeValue(forKey: "contextAfter")
        let legacyJSON = String(data: try JSONSerialization.data(withJSONObject: legacyObjects), encoding: .utf8)!
        check(TimelineReferenceCodec.decode(legacyJSON) == [legacyReference], "Legacy references without context remain decodable")
        let longContext = ReferenceContextSupport.snapshot(excerpt: "被引片段", sources: [String(repeating: "前", count: 160) + "被引片段" + String(repeating: "后", count: 160)])
        check(longContext.before == "…" + String(repeating: "前", count: 110), "Leading context is bounded and marked")
        check(longContext.after == String(repeating: "后", count: 110) + "…", "Trailing context is bounded and marked")
        let markdownContext = ReferenceContextSupport.snapshot(excerpt: "核心   想法", sources: ["首先记下 **核心 想法** 然后继续"])
        check(markdownContext.before == "首先记下 " && markdownContext.after == " 然后继续", "Rendered Markdown selection retains surrounding context")
        let formulaContext = ReferenceContextSupport.snapshot(excerpt: "𝑥² + α = 1", sources: ["历史推导显示 $x^2 + \\alpha = 1$ 后续验证继续"])
        check(formulaContext.before == "历史推导显示 " && formulaContext.after == " 后续验证继续", "Rendered Unicode mathematics matches source TeX")
        check(ReferenceContextSupport.snapshot(excerpt: "完全不存在内容", sources: ["另一个样本"]) == .init(), "Unmatched selections never invent context")
        let contextQuote = TimelineReference(sourceEntryID: UUID(), sourceTitle: "上下文", sourceDate: stamp, excerpt: "当前片段", contextBefore: "此前 ", contextAfter: " 此后", createdAt: stamp)
        check(TimelineReferenceCodec.decode(TimelineReferenceCodec.encode([contextQuote])) == [contextQuote], "Context snapshots survive JSON round trip")
        let store = TimelineStore(inMemory: true)
        let project = store.addProject(name: "交互验证")
        let entry = store.addEntry(to: project, title: "来源")
        let interaction = ReferenceInteraction(project: project, store: store)
        entry.progressText = "前面的说明，核心词，后面的计划。"
        let contextual = interaction.capture(text: "核心词", from: entry)!
        check(contextual.contextBefore == "前面的说明，" && contextual.contextAfter == "，后面的计划。", "Capture persists context snapshots")
        interaction.remove(contextual)
        let oldPending = TimelineReference(sourceEntryID: entry.id, sourceTitle: entry.title, sourceDate: entry.date, excerpt: "核心词")
        project.pendingReferences = [oldPending]
        let enriched = interaction.capture(text: "核心词", from: entry)!
        check(enriched.id == oldPending.id && enriched.contextBefore == "前面的说明，" && project.pendingReferences.count == 1, "Recapturing a legacy pending quote enriches it without duplication")
        interaction.remove(enriched)
        let quote = interaction.capture(text: "完整引用内容", from: entry)!
        check(interaction.isShelfVisible && project.pendingReferences.count == 1, "Capture opens persisted shelf")
        _ = interaction.capture(text: "完整引用内容", from: entry)
        check(project.pendingReferences.count == 1, "Repeated selection is deduplicated")
        var dropped = false
        interaction.onDrop = { target, reference in dropped = target == .entry(entry.id) && reference.id == quote.id }
        interaction.updateWorkspaceBounds(CGRect(x: 0, y: 0, width: 800, height: 600))
        interaction.updateFeedViewport(CGRect(x: 0, y: 70, width: 550, height: 460))
        interaction.updateTargets([.entry(entry.id): CGRect(x: 50, y: 50, width: 400, height: 160)])
        interaction.updateShelfFrame(CGRect(x: 550, y: 0, width: 250, height: 600))
        interaction.beginDragging(quote, at: CGPoint(x: 650, y: 100))
        check(interaction.hoveredTarget == nil, "Shelf area is not a target")
        interaction.updateDragging(to: CGPoint(x: 180, y: 100))
        check(interaction.hoveredTarget == .entry(entry.id), "Drag resolves target record")
        interaction.endDragging(at: CGPoint(x: 180, y: 100))
        check(dropped && interaction.references.count == 1, "Drop opens editor without consuming pending quote")
        // A partially clipped row still has its full layout frame in a lazy
        // stack. The hidden part must not turn headers or toolbars into targets.
        dropped = false
        interaction.updateTargets([.entry(entry.id): CGRect(x: 50, y: -120, width: 400, height: 260)])
        interaction.beginDragging(quote, at: CGPoint(x: 650, y: 100))
        interaction.updateDragging(to: CGPoint(x: 180, y: 35))
        check(interaction.hoveredTarget == nil, "Header rejects a clipped historical row")
        interaction.endDragging(at: CGPoint(x: 180, y: 35))
        check(!dropped && interaction.references.count == 1, "Header drop never opens a hidden record")
        interaction.beginDragging(quote, at: CGPoint(x: 650, y: 100))
        interaction.updateDragging(to: CGPoint(x: 180, y: 100))
        check(interaction.hoveredTarget == .entry(entry.id), "Visible part of a clipped row remains a target")
        interaction.cancelDragging()
        interaction.updateTargets([.entry(entry.id): CGRect(x: 50, y: 480, width: 400, height: 220)])
        interaction.beginDragging(quote, at: CGPoint(x: 650, y: 100))
        interaction.updateDragging(to: CGPoint(x: 180, y: 560))
        check(interaction.hoveredTarget == nil, "Footer rejects a clipped historical row")
        interaction.endDragging(at: CGPoint(x: 180, y: 560))
        check(!dropped && interaction.references.count == 1, "Footer drop never opens a hidden record")
        interaction.remove(quote)
        check(project.pendingReferences.isEmpty, "Explicit shelf deletion persists")
        print("PASS: reference persistence, source snapshots, capture/dedup, drag hit testing, deferred consumption")
        if let index = CommandLine.arguments.firstIndex(of: "--migration-check"), CommandLine.arguments.indices.contains(index + 1) {
            let migrated = try open(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            let projects = try migrated.mainContext.fetch(FetchDescriptor<TimelineProject>())
            let records = try migrated.mainContext.fetch(FetchDescriptor<TimelineEntry>())
            check(!projects.isEmpty && !records.isEmpty, "Existing database records remain readable")
            print("PASS: old database copy migrated with \(projects.count) projects and \(records.count) records")
        }
    }
}
