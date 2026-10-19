import XCTest
import CoreGraphics
@testable import QuietBarCore

final class MenuBarDragTrackerTests: XCTestCase {
    private let start = CGPoint(x: 300, y: 20)

    func testOnlyCommandGesturesStartingInMenuBarAreTracked() {
        for (command, inMenuBar) in [(false, false), (false, true), (true, false)] {
            var tracker = MenuBarDragTracker()
            tracker.began(at: start, command: command, inMenuBar: inMenuBar)
            XCTAssertFalse(tracker.isTracking)
            tracker.moved(to: CGPoint(x: 350, y: 20))
            XCTAssertFalse(tracker.ended(at: CGPoint(x: 350, y: 20)))
        }
        var tracker = MenuBarDragTracker()
        tracker.began(at: start, command: true, inMenuBar: true)
        XCTAssertTrue(tracker.isTracking)
    }

    func testOrdinaryAndCommandClicksDoNotCountAsDrags() {
        for command in [false, true] {
            var tracker = MenuBarDragTracker()
            tracker.began(at: start, command: command, inMenuBar: true)
            XCTAssertFalse(tracker.ended(at: start))
            XCTAssertFalse(tracker.isTracking)
        }
    }

    func testFourPointThresholdIncludesBothAxesAndDirections() {
        for offset in [CGPoint(x: 4, y: 0), CGPoint(x: -4, y: 0),
                       CGPoint(x: 0, y: 4), CGPoint(x: 0, y: -4)] {
            var tracker = MenuBarDragTracker()
            tracker.began(at: start, command: true, inMenuBar: true)
            let end = CGPoint(x: start.x + offset.x, y: start.y + offset.y)
            tracker.moved(to: end)
            XCTAssertTrue(tracker.ended(at: end), "Threshold offset: \(offset)")
        }
    }

    func testMovementBelowThresholdDoesNotCount() {
        var tracker = MenuBarDragTracker()
        tracker.began(at: start, command: true, inMenuBar: true)
        let nearby = CGPoint(x: start.x + 2, y: start.y + 3)
        tracker.moved(to: nearby)
        XCTAssertFalse(tracker.ended(at: nearby))
    }

    func testMouseUpPositionCountsWhenDraggedEventIsMissing() {
        var tracker = MenuBarDragTracker()
        tracker.began(at: start, command: true, inMenuBar: true)
        XCTAssertTrue(tracker.ended(at: CGPoint(x: start.x + 4, y: start.y)))
    }

    func testMouseUpReportsDragOnlyOnceAndClearsTracking() {
        var tracker = MenuBarDragTracker()
        tracker.began(at: start, command: true, inMenuBar: true)
        let end = CGPoint(x: 500, y: 20)
        tracker.moved(to: end)
        XCTAssertTrue(tracker.ended(at: end))
        XCTAssertFalse(tracker.isTracking)
        XCTAssertFalse(tracker.ended(at: end))
        tracker.moved(to: end)
        XCTAssertFalse(tracker.ended(at: end))
    }

    func testCancellationDiscardsAnAlreadyRecognizedDrag() {
        var tracker = MenuBarDragTracker()
        tracker.began(at: start, command: true, inMenuBar: true)
        let end = CGPoint(x: 500, y: 20)
        tracker.moved(to: end)
        tracker.cancel()
        XCTAssertFalse(tracker.isTracking)
        XCTAssertFalse(tracker.ended(at: end))
    }

    func testExcursionStillCountsAfterReturningToOrigin() {
        var tracker = MenuBarDragTracker()
        tracker.began(at: start, command: true, inMenuBar: true)
        tracker.moved(to: CGPoint(x: start.x + 10, y: start.y))
        tracker.moved(to: start)
        XCTAssertTrue(tracker.ended(at: start))
    }

    func testNewMouseDownClearsThePreviousGesture() {
        var tracker = MenuBarDragTracker()
        tracker.began(at: start, command: true, inMenuBar: true)
        tracker.moved(to: CGPoint(x: start.x + 30, y: start.y))
        let next = CGPoint(x: 600, y: 20)
        tracker.began(at: next, command: true, inMenuBar: true)
        XCTAssertFalse(tracker.ended(at: next))
        tracker.began(at: start, command: true, inMenuBar: true)
        tracker.moved(to: next)
        tracker.began(at: next, command: false, inMenuBar: true)
        XCTAssertFalse(tracker.isTracking)
        XCTAssertFalse(tracker.ended(at: start))
    }
}

final class OrdinaryMembershipRefreshTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    private let boundary = CGRect(x: 1000, y: 0, width: 20, height: 24)
    private let ownID = "local.quietbar.app"

    private func item(_ bundle: String, _ x: CGFloat, y: CGFloat = 0) -> BarItem {
        BarItem(bundleID: bundle, frame: CGRect(x: x, y: y, width: 20, height: 24))
    }

    private func refresh(_ items: [BarItem], previous: [String: BarSection],
                         leftToRight: Bool = true) throws -> BarLayout {
        try LayoutResolver.refreshingOrdinary(items: items, boundary: boundary,
            screen: screen, leftToRight: leftToRight, ownID: ownID,
            previous: BarLayout(sections: previous))
    }

    func testDraggingAcrossOrdinaryDividerAddsAndRemovesMembership() throws {
        let layout = try refresh([item("newlyHidden", 800), item("newlyShown", 1200)],
            previous: ["newlyHidden": .shown, "newlyShown": .hidden])
        XCTAssertEqual(layout.sections, ["newlyHidden": .hidden, "newlyShown": .shown])
        XCTAssertEqual(layout.hiddenBundles(collapsed: true), ["newlyHidden"])
        XCTAssertEqual(layout.hiddenBundles(collapsed: false), [])
    }

    func testPermanentMembershipSurvivesMissingAndStaleAXPositions() throws {
        let layout = try refresh([item("stalePermanent", 1300), item("ordinary", 800)],
            previous: ["stalePermanent": .alwaysHidden, "missingPermanent": .alwaysHidden,
                       "ordinary": .shown])
        XCTAssertEqual(layout.sections, ["stalePermanent": .alwaysHidden,
            "missingPermanent": .alwaysHidden, "ordinary": .hidden])
        XCTAssertEqual(layout.hiddenBundles(collapsed: false), ["stalePermanent", "missingPermanent"])
    }

    func testMultipleStalePermanentItemsCannotBecomeOrdinaryOrShown() throws {
        let layout = try refresh([item("permanent", 700), item("permanent", 1500),
            BarItem(bundleID: "permanent", frame: .zero), item("shown", 1400)],
            previous: ["permanent": .alwaysHidden])
        XCTAssertEqual(layout.sections, ["permanent": .alwaysHidden, "shown": .shown])
    }

    func testOrdinaryMembershipIsFreshAndDoesNotKeepMissingOwners() throws {
        let layout = try refresh([item("newOwner", 800)],
            previous: ["removedHidden": .hidden, "removedShown": .shown,
                       "permanent": .alwaysHidden])
        XCTAssertEqual(layout.sections, ["newOwner": .hidden, "permanent": .alwaysHidden])
    }

    func testFreshItemsOfSameOwnerPreferTheVisibleSection() throws {
        let layout = try refresh([item("split", 700), item("split", 1400)],
            previous: ["split": .hidden])
        XCTAssertEqual(layout.sections, ["split": .shown])
        XCTAssertTrue(layout.hiddenBundles(collapsed: true).isEmpty)
    }

    func testRightToLeftRefreshMirrorsOrdinarySectionsAndKeepsPermanent() throws {
        let layout = try refresh([item("newlyHidden", 1400), item("newlyShown", 700),
            item("permanent", 500)], previous: ["newlyHidden": .shown,
                "newlyShown": .hidden, "permanent": .alwaysHidden], leftToRight: false)
        XCTAssertEqual(layout.sections, ["newlyHidden": .hidden,
            "newlyShown": .shown, "permanent": .alwaysHidden])
        XCTAssertEqual(layout.hiddenBundles(collapsed: false), ["permanent"])
    }

    func testFreshInventoryProtectsSelfSystemAndInvalidOrOtherDisplayItems() throws {
        let layout = try refresh([item(ownID, 700), item("com.apple.example.systemItem", 700),
            item("", 700), item("otherDisplay", 2100), item("otherRow", 700, y: 100),
            BarItem(bundleID: "invalid", frame: .zero), item("valid", 800)], previous: [:])
        XCTAssertEqual(layout.sections, ["valid": .hidden])
    }

    func testEmptyPreviousLayoutClassifiesNewOwnersWithoutPermanentSection() throws {
        let layout = try refresh([item("left", 500), item("right", 1400)], previous: [:])
        XCTAssertEqual(layout.sections, ["left": .hidden, "right": .shown])
        XCTAssertTrue(layout.hiddenBundles(collapsed: false).isEmpty)
    }

    func testInvalidBoundaryFailsEvenWhenPreviousPermanentMembershipExists() {
        XCTAssertThrowsError(try LayoutResolver.refreshingOrdinary(items: [], boundary: .zero,
            screen: screen, leftToRight: true, ownID: ownID,
            previous: BarLayout(sections: ["permanent": .alwaysHidden])))
    }
}
