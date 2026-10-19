import Foundation
import CoreGraphics

public enum BarSection: Int, Comparable, Sendable {
    case alwaysHidden, hidden, shown
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct BarItem: Sendable {
    public let bundleID: String
    public let frame: CGRect
    public init(bundleID: String, frame: CGRect) {
        self.bundleID = bundleID
        self.frame = frame
    }
}

public struct BarLayout: Equatable, Sendable {
    public let sections: [String: BarSection]
    public init(sections: [String: BarSection]) { self.sections = sections }

    public func hiddenBundles(collapsed: Bool) -> Set<String> {
        Set(sections.compactMap { id, section in
            section == .alwaysHidden || (collapsed && section == .hidden) ? id : nil
        })
    }
}

public enum LayoutError: LocalizedError {
    case invalidBoundary, reversedDividers
    public var errorDescription: String? {
        switch self {
        case .invalidBoundary: return "구분선 위치를 읽지 못했습니다. 메뉴 막대를 표시한 뒤 다시 시도하세요."
        case .reversedDividers: return "점선 구분선을 일반 구분선의 숨김 쪽으로 ⌘-드래그해 주세요."
        }
    }
}

public enum LayoutResolver {
    /// A partially expanded bar still conceals the permanent section. Those AX
    /// positions are stale: freeze that membership and re-read ordinary items only.
    public static func refreshingOrdinary(items: [BarItem], boundary: CGRect,
                                         screen: CGRect, leftToRight: Bool,
                                         ownID: String, previous: BarLayout) throws -> BarLayout {
        let permanent = previous.sections.filter { $0.value == .alwaysHidden }
        let visible = try resolve(items: items.filter { permanent[$0.bundleID] == nil },
                                  boundary: boundary, permanent: nil, screen: screen,
                                  leftToRight: leftToRight, ownID: ownID)
        return BarLayout(sections: visible.sections.merging(permanent) { _, frozen in frozen })
    }

    /// Frames are in Accessibility's global, top-left coordinate system.
    /// A bundle spanning sections uses its most visible item. Unknown owners stay visible.
    public static func resolve(items: [BarItem], boundary: CGRect, permanent: CGRect?,
                               screen: CGRect, leftToRight: Bool, ownID: String) throws -> BarLayout {
        guard valid(boundary), screen.contains(CGPoint(x: boundary.midX, y: boundary.midY)) else {
            throw LayoutError.invalidBoundary
        }
        func behind(_ x: CGFloat, _ divider: CGFloat) -> Bool {
            leftToRight ? x < divider : x > divider
        }
        if let permanent {
            guard valid(permanent), abs(permanent.midY - boundary.midY) < 12,
                  screen.contains(CGPoint(x: permanent.midX, y: permanent.midY)),
                  behind(permanent.midX, boundary.midX) else { throw LayoutError.reversedDividers }
        }
        var sections: [String: BarSection] = [:]
        for item in items {
            guard !item.bundleID.isEmpty, item.bundleID != ownID,
                  !item.bundleID.hasPrefix("com.apple."), valid(item.frame),
                  abs(item.frame.midY - boundary.midY) < 12,
                  screen.contains(CGPoint(x: item.frame.midX, y: item.frame.midY)) else { continue }
            let section: BarSection
            if !behind(item.frame.midX, boundary.midX) { section = .shown }
            else if let permanent, behind(item.frame.midX, permanent.midX) { section = .alwaysHidden }
            else { section = .hidden }
            sections[item.bundleID] = max(sections[item.bundleID] ?? .alwaysHidden, section)
        }
        return BarLayout(sections: sections)
    }

    private static func valid(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0 && frame.height < 100
    }
}

/// Mouse coordinates only; no key contents or application events are retained.
public struct MenuBarDragTracker: Sendable {
    private var origin: CGPoint?
    private var movedEnough = false
    public var isTracking: Bool { origin != nil }
    public init() {}

    public mutating func began(at point: CGPoint, command: Bool, inMenuBar: Bool) {
        cancel()
        guard command && inMenuBar else { return }
        origin = point
    }

    public mutating func moved(to point: CGPoint) {
        guard let origin else { return }
        if hypot(point.x - origin.x, point.y - origin.y) >= 4 { movedEnough = true }
    }

    public mutating func ended(at point: CGPoint) -> Bool {
        moved(to: point)
        let result = origin != nil && movedEnough
        cancel()
        return result
    }

    public mutating func cancel() { origin = nil; movedEnough = false }
}

/// NSStatusItem's hosted button can report temporary or scene-local geometry on
/// macOS 27. Its owning window is the stable AppKit boundary. Do not trust the
/// window.screen association during a menu-bar host migration between displays.
public struct StatusItemGeometry: Equatable, Sendable {
    public let boundary: CGRect
    public let permanent: CGRect?
    public let screen: CGRect

    public static func resolve(window: CGRect, permanentWindow: CGRect?,
                               screens: [CGRect], primaryTop: CGFloat) throws -> Self {
        guard primaryTop.isFinite, window.width > 0, window.height > 0,
              window.width.isFinite, window.height.isFinite,
              let display = screens.first(where: { $0.contains(CGPoint(x: window.midX, y: window.midY)) }) else {
            throw LayoutError.invalidBoundary
        }
        func ax(_ frame: CGRect) -> CGRect {
            CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
        }
        return Self(boundary: ax(window), permanent: permanentWindow.map(ax), screen: ax(display))
    }
}
