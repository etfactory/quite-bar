import AppKit
import ApplicationServices

/// Resolve the real clock item; neither its localized date nor a fixed corner is reliable.
/// 날짜 표시 언어나 고정된 모서리 좌표 대신 실제 시계 항목을 찾아 사용합니다.
@MainActor enum NotificationCenterSupport {
    private(set) static var lastClockProbe = "아직 시계 위치를 확인하지 않았습니다."
    struct ClockTarget {
        let element: AXUIElement
        let point: CGPoint
    }

    private static let clockIdentifiers: Set<String> = [
        "com.apple.menuextra.clock", "com.apple.controlcenter.clock", "clock"
    ]

    static func clock(at point: CGPoint) -> ClockTarget? {
        guard let primary = NSScreen.screens.first else { return nil }
        let axPoint = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.08)
        var identifiers: [String] = []
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(system, Float(axPoint.x), Float(axPoint.y), &hit) == .success {
            var candidate = hit
            for _ in 0..<6 {
                guard let element = candidate else { break }
                AXUIElementSetMessagingTimeout(element, 0.08)
                if let id = value(element, kAXIdentifierAttribute) as? String { identifiers.append(id) }
                if isClock(element), isSystemOwner(element) {
                    lastClockProbe = "시계 위치 확인: \(identifiers.joined(separator: ", "))"
                    return ClockTarget(element: element, point: point)
                }
                guard let parent = value(element, kAXParentAttribute),
                      CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                candidate = (parent as! AXUIElement)
            }
        }
        // A hosted menu-bar element may expose its identifier only through its owner.
        // 호스팅된 메뉴 막대 항목은 소유 앱의 목록에서만 식별자를 제공할 수 있습니다.
        for id in ["com.apple.controlcenter", "com.apple.systemuiserver"] {
            for owner in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
                let app = AXUIElementCreateApplication(owner.processIdentifier)
                AXUIElementSetMessagingTimeout(app, 0.08)
                guard let raw = value(app, "AXExtrasMenuBar"), CFGetTypeID(raw) == AXUIElementGetTypeID() else { continue }
                let bar = raw as! AXUIElement
                guard let children = value(bar, kAXChildrenAttribute) as? [AXUIElement] else { continue }
                for child in children where isClock(child) {
                    if let frame = frame(child), frame.contains(axPoint) {
                        lastClockProbe = "시계 소유 앱에서 위치 확인: \(frame)"
                        return ClockTarget(element: child, point: point)
                    }
                }
            }
        }
        lastClockProbe = "시계 식별 실패: \(identifiers.joined(separator: ", "))"
        return nil
    }

    static func press(_ target: ClockTarget) -> Bool {
        let element = clock(at: target.point)?.element ?? target.element
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// Read only window ownership and bounds, excluding banners and desktop widgets.
    /// 창 소유 프로세스와 위치·크기만 읽고, 배너와 바탕화면 위젯은 제외합니다.
    static func isPresented() -> Bool? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
            .map(\.processIdentifier))
        guard !pids.isEmpty else { return false }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]], let primary = NSScreen.screens.first else { return nil }
        let screens = NSScreen.screens.map { screen in
            CGRect(x: screen.frame.minX, y: primary.frame.maxY - screen.frame.maxY,
                   width: screen.frame.width, height: screen.frame.height)
        }
        return windows.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  let layer = window[kCGWindowLayer as String] as? Int, layer >= 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return false }
            return screens.contains { screen in
                let visible = rect.intersection(screen)
                return !visible.isNull && visible.width >= 240 && visible.width <= 720
                    && visible.height >= min(400, screen.height * 0.5)
                    && (abs(visible.maxX - screen.maxX) < 24 || abs(visible.minX - screen.minX) < 24)
            }
        }
    }

    private static func isClock(_ element: AXUIElement) -> Bool {
        guard let id = value(element, kAXIdentifierAttribute) as? String else { return false }
        return clockIdentifiers.contains(id.lowercased())
    }

    private static func isSystemOwner(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier?.lowercased() else { return false }
        return ["com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.menubaragent"].contains(id)
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute), let s = value(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
}
