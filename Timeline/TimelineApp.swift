import SwiftUI
import SwiftData

@main
struct TimelineApp: App {
    @StateObject private var store = TimelineStore()
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @NSApplicationDelegateAdaptor(TimelineMacApplication.self) private var macApplication
    #endif

    var body: some Scene {
        #if os(macOS)
        Window("Timeline", id: "main") {
            workspace
                .frame(minWidth: 760, minHeight: 560)
                .background(TimelineMainWindowAccessor(application: macApplication))
                .onAppear { macApplication.configure(store: store) }
        }
        .defaultSize(width: 1200, height: 830)
        .windowStyle(.hiddenTitleBar)
        .commands { TimelineMacCommands(application: macApplication) }
        #else
        WindowGroup {
            workspace
                .onChange(of: scenePhase, initial: true) { _, phase in
                    store.setNutstoreActive(phase == .active)
                }
        }
        #endif
    }

    private var workspace: some View {
        Group {
                if store.isRecoveryMode {
                    ContentUnavailableView {
                        Label("暂时无法打开记录", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text(store.persistenceNotice ?? "请检查磁盘空间和访问权限后重新打开 Timeline。原有数据库已保留。")
                    }
                    .padding(30)
                } else {
                    ContentView()
                }
            }
                .environmentObject(store)
                .modelContainer(store.container)
                .tint(TimelineTheme.accent)
                .preferredColorScheme(.light)
    }
}

extension Notification.Name {
    static let timelineNewEntry = Notification.Name("timeline.newEntry")
    static let timelineNewProject = Notification.Name("timeline.newProject")
    static let timelineEditEntry = Notification.Name("timeline.editEntry")
}

enum TimelineTheme {
    static let accent = Color(red: 0.78, green: 0.34, blue: 0.25)
    static let background = Color(red: 0.99, green: 0.99, blue: 0.99)
    static let sidebar = Color(red: 0.965, green: 0.965, blue: 0.965)
    static let ink = Color(red: 0.18, green: 0.20, blue: 0.20)
    static let muted = Color(red: 0.49, green: 0.50, blue: 0.48)
    static let line = Color(red: 0.87, green: 0.87, blue: 0.84)
}

extension Color {
    init(timelineHex: String) {
        let clean = timelineHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(clean, radix: 16) ?? 0xC75740
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}
