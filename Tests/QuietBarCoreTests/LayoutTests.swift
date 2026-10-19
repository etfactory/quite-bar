import XCTest
import CoreGraphics
@testable import QuietBarCore

final class LayoutTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    private func rect(_ x: CGFloat, y: CGFloat = 0) -> CGRect { CGRect(x: x, y: y, width: 20, height: 24) }
    private func item(_ id: String, _ x: CGFloat, y: CGFloat = 0) -> BarItem { BarItem(bundleID: id, frame: rect(x, y: y)) }

    func testThreeSectionsAndGroupedAppPreferVisibility() throws {
        let layout = try LayoutResolver.resolve(items: [item("a", 100), item("b", 600), item("c", 1200),
            item("split", 100), item("split", 1300)], boundary: rect(1000), permanent: rect(500),
            screen: screen, leftToRight: true, ownID: "self")
        XCTAssertEqual(layout.sections, ["a": .alwaysHidden, "b": .hidden, "c": .shown, "split": .shown])
        XCTAssertEqual(layout.hiddenBundles(collapsed: true), ["a", "b"])
        XCTAssertEqual(layout.hiddenBundles(collapsed: false), ["a"])
    }

    func testRightToLeftMirrorsSections() throws {
        let layout = try LayoutResolver.resolve(items: [item("a", 1700), item("b", 800), item("c", 100)],
            boundary: rect(500), permanent: rect(1400), screen: screen, leftToRight: false, ownID: "self")
        XCTAssertEqual(layout.sections, ["a": .alwaysHidden, "b": .hidden, "c": .shown])
    }

    func testProtectsSystemOwnInvalidAndOtherDisplayItems() throws {
        let layout = try LayoutResolver.resolve(items: [item("self", 100), item("com.apple.example.systemItem", 200),
            item("otherDisplay", 2100), item("otherRow", 300, y: 400), item("", 100),
            BarItem(bundleID: "invalid", frame: .zero), item("valid", 500)],
            boundary: rect(1000), permanent: nil, screen: screen, leftToRight: true, ownID: "self")
        XCTAssertEqual(layout.sections, ["valid": .hidden])
    }

    func testRejectsReversedOrCrossDisplayPermanentDivider() {
        for permanent in [rect(1400), rect(300, y: 100)] {
            XCTAssertThrowsError(try LayoutResolver.resolve(items: [], boundary: rect(1000), permanent: permanent,
                screen: screen, leftToRight: true, ownID: "self"))
        }
    }

    func testRejectsMissingAndOffScreenBoundary() {
        for boundary in [CGRect.zero, rect(2200), CGRect(x: CGFloat.nan, y: 0, width: 20, height: 24)] {
            XCTAssertThrowsError(try LayoutResolver.resolve(items: [], boundary: boundary, permanent: nil,
                screen: screen, leftToRight: true, ownID: "self"))
        }
    }

    func testHostedStatusWindowOnPrimaryDisplay() throws {
        let displays = [CGRect(x: 0, y: 0, width: 2560, height: 1440),
                        CGRect(x: -1800, y: 78, width: 1800, height: 1169),
                        CGRect(x: 2560, y: 0, width: 1080, height: 1920)]
        let geometry = try StatusItemGeometry.resolve(window: CGRect(x: 2192, y: 1405, width: 34, height: 39),
            permanentWindow: CGRect(x: 1773, y: 1405, width: 34, height: 39), screens: displays, primaryTop: 1440)
        XCTAssertEqual(geometry.boundary, CGRect(x: 2192, y: -4, width: 34, height: 39))
        let layout = try LayoutResolver.resolve(items: [item("hidden", 2000, y: 4), item("shown", 2300, y: 4)],
            boundary: geometry.boundary, permanent: geometry.permanent, screen: geometry.screen,
            leftToRight: true, ownID: "self")
        XCTAssertEqual(layout.sections, ["hidden": .hidden, "shown": .shown])
    }

    func testTallerDisplayProducesNegativeAXCoordinates() throws {
        let displays = [CGRect(x: 0, y: 0, width: 2560, height: 1440),
                        CGRect(x: 2560, y: 0, width: 1080, height: 1920)]
        let geometry = try StatusItemGeometry.resolve(window: CGRect(x: 3067, y: 1885, width: 40, height: 39),
            permanentWindow: nil, screens: displays, primaryTop: 1440)
        XCTAssertEqual(geometry.screen, CGRect(x: 2560, y: -480, width: 1080, height: 1920))
        let layout = try LayoutResolver.resolve(items: [item("hidden", 2900, y: -475), item("shown", 3200, y: -475)],
            boundary: geometry.boundary, permanent: nil, screen: geometry.screen, leftToRight: true, ownID: "self")
        XCTAssertEqual(layout.sections, ["hidden": .hidden, "shown": .shown])
    }

    func testGeometryChoosesDisplayFromWindowLocation() throws {
        let displays = [CGRect(x: 0, y: 0, width: 2560, height: 1440),
                        CGRect(x: -1800, y: 78, width: 1800, height: 1169)]
        let geometry = try StatusItemGeometry.resolve(window: CGRect(x: -100, y: 1212, width: 34, height: 39),
            permanentWindow: nil, screens: displays, primaryTop: 1440)
        XCTAssertEqual(geometry.screen, CGRect(x: -1800, y: 193, width: 1800, height: 1169))
        XCTAssertThrowsError(try StatusItemGeometry.resolve(window: .zero, permanentWindow: nil,
            screens: displays, primaryTop: 1440))
    }
}
