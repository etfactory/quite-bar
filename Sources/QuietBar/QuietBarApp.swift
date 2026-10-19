import AppKit
import SwiftUI

@main enum QuietBarApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
            print("Bundle: \(Bundle.main.bundleURL.path)")
            print("Native visibility API: \(QBVisibilityAvailable())")
            print("Accessibility granted: \(AccessibilityInventory.authorized)")
            print("Diagnostics only: no status items or visibility sessions created.")
            return
        }
        let app = NSApplication.shared
        // Launching a second copy must not create competing visibility restrictions.
        if let id = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [])
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let preferences = Preferences()
    private let login = LoginService()
    private var controller: StatusBarController!
    private let shortcut = GlobalShortcut()
    private var window: NSWindow?
    private var permissionTimer: Timer?
    private var recordingShortcut = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Quiet Bar")
        let settings = NSMenuItem(title: "Quiet Bar 설정…", action: #selector(settingsClicked), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quiet Bar 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
        controller = StatusBarController(preferences: preferences)
        controller.showPreferences = { [weak self] in self?.openPreferences() }
        shortcut.action = { [weak self] in self?.controller.toggle() }
        preferences.onChange = { [weak self] in
            guard let self else { return }
            self.controller.preferencesChanged()
            if !self.recordingShortcut { self.controller.shortcutError = self.shortcut.configure(self.preferences) }
        }
        controller.shortcutError = shortcut.configure(preferences)
        if preferences.showOnLaunch || (controller.native && (!controller.authorized || !controller.installed)) {
            openPreferences()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPreferences()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller?.refreshPermission()
        login.refresh()
    }

    func openPreferences() {
        controller.beginArrangement()
        controller.windowVisible = true
        if window == nil {
            let view = PreferencesView(preferences: preferences, controller: controller, login: login) { [weak self] recording in
                guard let self else { return }
                self.recordingShortcut = recording
                if recording { self.shortcut.suspend() }
                else { self.controller.shortcutError = self.shortcut.configure(self.preferences) }
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 752, height: 632),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Quiet Bar"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view)
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.controller.refreshPermission(); self?.login.refresh() }
        }
    }

    @objc private func settingsClicked() { openPreferences() }

    func windowWillClose(_ notification: Notification) {
        permissionTimer?.invalidate()
        permissionTimer = nil
        controller.windowClosed()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        shortcut.stop()
        controller?.stop()
    }
}
