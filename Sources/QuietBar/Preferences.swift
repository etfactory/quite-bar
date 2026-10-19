import AppKit
import Combine
import ServiceManagement
import Carbon

@MainActor final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard
    var onChange: (() -> Void)?
    @Published var showOnLaunch: Bool { didSet { save() } }
    @Published var useFullMenuBar: Bool { didSet { save() } }
    @Published var alwaysHidden: Bool { didSet { save() } }
    @Published var autoHide: Bool { didSet { save() } }
    @Published var delay: Int { didSet { save() } }
    @Published var shortcutEnabled: Bool { didSet { save() } }
    @Published var shortcutCode: UInt32 { didSet { save() } }
    @Published var shortcutModifiers: UInt32 { didSet { save() } }
    @Published var shortcutLabel: String { didSet { save() } }

    init() {
        defaults.register(defaults: ["showOnLaunch": true, "alwaysHidden": false, "useFullMenuBar": false,
                                    "autoHide": true, "delay": 10, "shortcutEnabled": false,
                                    "shortcutCode": 4, "shortcutModifiers": cmdKey | shiftKey,
                                    "shortcutLabel": "⇧⌘H"])
        showOnLaunch = defaults.bool(forKey: "showOnLaunch")
        useFullMenuBar = defaults.bool(forKey: "useFullMenuBar")
        alwaysHidden = defaults.bool(forKey: "alwaysHidden")
        autoHide = defaults.bool(forKey: "autoHide")
        delay = [5, 10, 15, 30, 60].contains(defaults.integer(forKey: "delay")) ? defaults.integer(forKey: "delay") : 10
        shortcutEnabled = defaults.bool(forKey: "shortcutEnabled")
        shortcutCode = UInt32(clamping: defaults.integer(forKey: "shortcutCode"))
        shortcutModifiers = UInt32(clamping: defaults.integer(forKey: "shortcutModifiers"))
        shortcutLabel = defaults.string(forKey: "shortcutLabel") ?? "⇧⌘H"
    }

    private func save() {
        defaults.set(showOnLaunch, forKey: "showOnLaunch")
        defaults.set(useFullMenuBar, forKey: "useFullMenuBar")
        defaults.set(alwaysHidden, forKey: "alwaysHidden")
        defaults.set(autoHide, forKey: "autoHide")
        defaults.set(delay, forKey: "delay")
        defaults.set(shortcutEnabled, forKey: "shortcutEnabled")
        defaults.set(shortcutCode, forKey: "shortcutCode")
        defaults.set(shortcutModifiers, forKey: "shortcutModifiers")
        defaults.set(shortcutLabel, forKey: "shortcutLabel")
        onChange?()
    }

    func setShortcut(code: UInt32, modifiers: UInt32, label: String) {
        // Notify once, so registration doesn't briefly use a half-updated shortcut.
        let notify = onChange
        onChange = nil
        shortcutCode = code
        shortcutModifiers = modifiers
        shortcutLabel = label
        shortcutEnabled = true
        onChange = notify
        notify?()
    }
}

@MainActor final class LoginService: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var needsApproval = false
    @Published var error: String?

    init() { refresh() }
    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }
    func setEnabled(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch { self.error = error.localizedDescription }
        refresh()
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
