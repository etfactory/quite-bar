import AppKit
import ApplicationServices
#if canImport(QuietBarCore)
import QuietBarCore
#endif

struct AppOwner: Sendable {
    let pid: pid_t
    let bundleID: String
}

enum AccessibilityInventory {
    @MainActor static var authorized: Bool { AXIsProcessTrusted() }

    @MainActor static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor static var runningBundles: Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    @MainActor static func snapshot() async -> [BarItem] {
        let owners = NSWorkspace.shared.runningApplications.compactMap { app -> AppOwner? in
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  app.bundleURL?.pathExtension == "app", let id = app.bundleIdentifier else { return nil }
            return AppOwner(pid: app.processIdentifier, bundleID: id)
        }
        return await Task.detached(priority: .userInitiated) { scan(owners) }.value
    }

    private static func scan(_ owners: [AppOwner]) -> [BarItem] {
        var items: [BarItem] = []
        for owner in owners {
            let app = AXUIElementCreateApplication(owner.pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            guard let barValue = value(app, "AXExtrasMenuBar"),
                  CFGetTypeID(barValue) == AXUIElementGetTypeID() else { continue }
            let bar = barValue as! AXUIElement
            guard let children = value(bar, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for child in children {
                guard let p = value(child, kAXPositionAttribute), let s = value(child, kAXSizeAttribute),
                      CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { continue }
                var point = CGPoint.zero
                var size = CGSize.zero
                guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
                      AXValueGetValue(s as! AXValue, .cgSize, &size) else { continue }
                items.append(BarItem(bundleID: owner.bundleID, frame: CGRect(origin: point, size: size)))
            }
        }
        return items
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
}
