#if os(macOS)
import AppKit
import SwiftUI
import SwiftData

/// Owns the menu bar entry and keeps the main workspace alive when its window closes.
@MainActor
final class TimelineMacApplication: NSObject, NSApplicationDelegate, NSPopoverDelegate, ObservableObject {
    private static let dockPreference = "timeline.mac.hideDockIcon"
    private let defaults: UserDefaults
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private weak var store: TimelineStore?
    private var mainWindow: NSWindow?
    private var retainedWindowDelegate: TimelineRetainedWindowDelegate?
    private var isApplyingActivationPolicy = false
    private var isHandlingPopoverAction = false
    private var isClosingPopover = false

    @Published var hideDockIcon: Bool {
        didSet {
            guard oldValue != hideDockIcon, !isApplyingActivationPolicy else { return }
            applyActivationPolicy()
        }
    }

    override init() {
        let isolated = ProcessInfo.processInfo.arguments.contains("--timeline-ui-testing")
        defaults = isolated ? UserDefaults(suiteName: "Timeline.MenuBar.UITesting")! : .standard
        hideDockIcon = defaults.bool(forKey: Self.dockPreference)
        super.init()
    }

    func configure(store: TimelineStore) {
        guard statusItem == nil else { return }
        self.store = store
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "TimelineMenuBar"
        // Keep a recovery entry available even while the Dock icon is hidden.
        item.behavior = []
        item.isVisible = true
        if let button = item.button {
            let image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "Timeline")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Timeline · 时间线速览"
            button.setAccessibilityLabel("Timeline 时间线速览")
            button.target = self
            button.action = #selector(togglePopover)
            // Handle the same mouse-down that can dismiss a transient popover,
            // rather than reopening it on a later mouse-up.
            button.sendAction(on: [.leftMouseDown])
        }
        statusItem = item
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 420, height: 580)
        popover.contentViewController = NSHostingController(rootView:
            TimelineMenuBarHost(application: self)
            .environmentObject(store)
            .modelContainer(store.container)
            .preferredColorScheme(.light)
        )
        applyActivationPolicy()
        updateSyncActivity()
    }

    func attachMainWindow(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        mainWindow = window
        window.identifier = NSUserInterfaceItemIdentifier("TimelineMainWindow")
        window.isReleasedWhenClosed = false
        let bridge = TimelineRetainedWindowDelegate(original: window.delegate, owner: self)
        retainedWindowDelegate = bridge
        window.delegate = bridge
        updateSyncActivity()
    }

    func showMainWindow() {
        popover.performClose(nil)
        guard let window = mainWindow else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateSyncActivity()
    }

    func editEntry(_ entry: TimelineEntry) {
        // Route before activating the workspace so its editing lock is in place
        // before foreground sync resumes. Existing drafts stay in ContentView.
        NotificationCenter.default.post(name: .timelineEditEntry, object: entry.id)
        showMainWindow()
    }

    @objc func togglePopover() {
        guard !isClosingPopover else { return }
        isHandlingPopoverAction = true
        defer { isHandlingPopoverAction = false }
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem?.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            // Browsing must not activate the application: AppKit activation
            // also brings its existing main/key windows to the front.
        }
    }

    private func applyActivationPolicy() {
        // Create the status item first, so a hidden Dock never strands the user.
        guard statusItem != nil else { return }
        let policy: NSApplication.ActivationPolicy = hideDockIcon ? .accessory : .regular
        let changed = NSApp.activationPolicy() == policy || NSApp.setActivationPolicy(policy)
        let actuallyHidden = NSApp.activationPolicy() == .accessory
        if hideDockIcon != actuallyHidden {
            isApplyingActivationPolicy = true
            hideDockIcon = actuallyHidden
            isApplyingActivationPolicy = false
        }
        defaults.set(actuallyHidden, forKey: Self.dockPreference)
        if !changed { NSSound.beep() }
        updateSyncActivity()
    }

    func updateSyncActivity() {
        let visibleWorkspace = mainWindow?.isVisible == true && mainWindow?.isMiniaturized == false
        store?.setNutstoreActive(popover.isShown || (NSApp.isActive && visibleWorkspace))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !isHandlingPopoverAction, !isClosingPopover, !popover.isShown else { return false }
        showMainWindow()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        updateSyncActivity()
    }
    func applicationDidResignActive(_ notification: Notification) { updateSyncActivity() }
    func popoverDidShow(_ notification: Notification) {
        isClosingPopover = false
        updateSyncActivity()
    }
    func popoverWillClose(_ notification: Notification) { isClosingPopover = true }
    func popoverDidClose(_ notification: Notification) {
        isClosingPopover = false
        updateSyncActivity()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.setNutstoreActive(false)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}

private struct TimelineMenuBarHost: View {
    @ObservedObject var application: TimelineMacApplication

    var body: some View {
        TimelineMenuBarView(hideDockIcon: $application.hideDockIcon,
                           onEditEntry: { application.editEntry($0) },
                           onQuit: { NSApp.terminate(nil) })
    }
}

struct TimelineMacCommands: Commands {
    @ObservedObject var application: TimelineMacApplication

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建记录") {
                application.showMainWindow()
                NotificationCenter.default.post(name: .timelineNewEntry, object: nil)
            }.keyboardShortcut("n", modifiers: .command)
            Button("新建项目") {
                application.showMainWindow()
                NotificationCenter.default.post(name: .timelineNewProject, object: nil)
            }.keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button("菜单栏速览") { application.togglePopover() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Toggle("隐藏程序坞图标", isOn: $application.hideDockIcon)
        }
    }
}

/// Preserve SwiftUI's delegate callbacks while changing close into hide.
/// Retaining the workspace also retains unsaved drafts and their sync editing lock.
@MainActor
private final class TimelineRetainedWindowDelegate: NSObject, NSWindowDelegate {
    private let original: NSWindowDelegate?
    private weak var owner: TimelineMacApplication?

    init(original: NSWindowDelegate?, owner: TimelineMacApplication) {
        self.original = original
        self.owner = owner
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        owner?.updateSyncActivity()
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        original?.windowDidBecomeKey?(notification)
        owner?.updateSyncActivity()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        original?.windowDidMiniaturize?(notification)
        owner?.updateSyncActivity()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        original?.windowDidDeminiaturize?(notification)
        owner?.updateSyncActivity()
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if original?.responds(to: aSelector) == true { return original }
        return super.forwardingTarget(for: aSelector)
    }
}

struct TimelineMainWindowAccessor: NSViewRepresentable {
    let application: TimelineMacApplication

    func makeNSView(context: Context) -> WindowProbe {
        let probe = WindowProbe()
        probe.application = application
        return probe
    }

    func updateNSView(_ view: WindowProbe, context: Context) {
        view.application = application
        if let window = view.window { application.attachMainWindow(window) }
    }

    final class WindowProbe: NSView {
        weak var application: TimelineMacApplication?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                if let window { self?.application?.attachMainWindow(window) }
            }
        }
    }
}
#endif
