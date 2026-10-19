import XCTest
@testable import QuietBarCore

@MainActor private final class Lease: VisibilityLease {
    var invalidated = false
    func invalidate() { invalidated = true }
}
@MainActor private final class Driver: VisibilityDriver {
    var available = true
    struct Request {
        let bundles: [String]
        let completion: @MainActor (Result<any VisibilityLease, Error>) -> Void
    }
    var requests: [Request] = []
    func activate(allowing bundles: [String], completion: @escaping @MainActor (Result<any VisibilityLease, Error>) -> Void) {
        requests.append(Request(bundles: bundles, completion: completion))
    }
    @discardableResult func succeed(_ index: Int) -> Lease {
        let lease = Lease()
        requests[index].completion(.success(lease))
        return lease
    }
}

final class VisibilityTests: XCTestCase {
    private let layout = BarLayout(sections: ["hidden": .hidden, "permanent": .alwaysHidden, "visible": .shown])
    private let owners: Set<String> = ["self", "hidden", "permanent", "visible", "unknown", "com.apple.example.systemItem"]

    @MainActor func testAllowListKeepsSystemUnknownAndSelf() async {
        let driver = Driver()
        let session = VisibilitySession(driver: driver)
        session.apply(layout: layout, runningBundles: owners, ownID: "self", collapsed: true)
        XCTAssertEqual(Set(driver.requests[0].bundles), ["visible", "unknown", "com.apple.example.systemItem", "self"])
        XCTAssertEqual(session.state, .applying)
        driver.succeed(0)
        XCTAssertEqual(session.state, .collapsed)
    }

    @MainActor func testRestoreDuringActivationDisposesLateSuccess() async {
        let driver = Driver()
        let session = VisibilitySession(driver: driver)
        session.apply(layout: layout, runningBundles: owners, ownID: "self", collapsed: true)
        session.revealAll()
        let stale = driver.succeed(0)
        XCTAssertTrue(stale.invalidated)
        XCTAssertEqual(session.state, .expanded)
    }

    @MainActor func testReplacingLeaseActivatesBeforeInvalidatingOld() async {
        let driver = Driver()
        let session = VisibilitySession(driver: driver)
        session.apply(layout: layout, runningBundles: owners, ownID: "self", collapsed: true)
        let old = driver.succeed(0)
        session.apply(layout: layout, runningBundles: owners, ownID: "self", collapsed: false)
        XCTAssertFalse(old.invalidated)
        XCTAssertTrue(driver.requests[1].bundles.contains("hidden"))
        XCTAssertFalse(driver.requests[1].bundles.contains("permanent"))
        let new = driver.succeed(1)
        XCTAssertTrue(old.invalidated)
        XCTAssertFalse(new.invalidated)
        XCTAssertEqual(session.state, .partial)
        session.revealAll()
        XCTAssertTrue(new.invalidated)
    }

    @MainActor func testFailureRestoresExistingLease() async {
        let driver = Driver()
        let session = VisibilitySession(driver: driver)
        session.apply(layout: layout, runningBundles: owners, ownID: "self", collapsed: true)
        let old = driver.succeed(0)
        session.apply(layout: layout, runningBundles: owners, ownID: "self", collapsed: false)
        driver.requests[1].completion(.failure(NSError(domain: "test", code: 1)))
        XCTAssertTrue(old.invalidated)
        XCTAssertEqual(session.state, .expanded)
        XCTAssertNotNil(session.lastError)
    }

    @MainActor func testOlderRequestCannotReplaceNewerState() async {
        let driver = Driver()
        let session = VisibilitySession(driver: driver)
        session.apply(layout: layout, runningBundles: owners, ownID: "self", collapsed: true)
        session.apply(layout: layout, runningBundles: owners, ownID: "self", collapsed: false)
        let newest = driver.succeed(1)
        let old = driver.succeed(0)
        XCTAssertTrue(old.invalidated)
        XCTAssertFalse(newest.invalidated)
        XCTAssertEqual(session.state, .partial)
    }

    @MainActor func testUnavailableAndNoHiddenItemsNeverActivate() async {
        let driver = Driver()
        driver.available = false
        let session = VisibilitySession(driver: driver)
        session.apply(layout: layout, runningBundles: owners, ownID: "self", collapsed: true)
        XCTAssertEqual(session.state, .expanded)
        XCTAssertNotNil(session.lastError)
        session.apply(layout: BarLayout(sections: ["visible": .shown]), runningBundles: owners, ownID: "self", collapsed: true)
        XCTAssertNil(session.lastError)
        XCTAssertTrue(driver.requests.isEmpty)
    }
}
