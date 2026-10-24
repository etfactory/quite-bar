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
    ///
    /// 일반 구역을 펼쳐도 항상 숨김 구역은 계속 가려져 있습니다. 해당 앱의 AX 좌표는
    /// 오래된 값일 수 있으므로 기존 구역 소속을 고정하고 일반 항목만 다시 읽습니다.
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
    ///
    /// 프레임은 왼쪽 위를 원점으로 하는 Accessibility 전역 좌표계입니다. 한 앱의 아이콘이
    /// 여러 구역에 걸치면 가장 잘 보이는 구역을 적용하고, 확인되지 않은 소유 앱은 표시합니다.
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
///
/// 마우스 좌표만 보관하며, 키 입력 내용이나 앱 이벤트는 저장하지 않습니다.
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
///
/// macOS 27에서는 상태 항목의 호스팅된 버튼이 일시적이거나 장면 내부의 좌표를 반환할 수 있습니다.
/// 안정적인 AppKit 경계는 버튼을 소유한 창입니다. 메뉴 막대 호스트가 디스플레이 사이를
/// 이동하는 동안에는 window.screen 연결 정보를 신뢰하지 않습니다.
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
