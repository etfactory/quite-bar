import XCTest
@testable import QuietBarCore

@MainActor private final class RunningRefreshLease: VisibilityLease {
    private(set) var invalidationCount = 0
    var invalidated: Bool { invalidationCount > 0 }
    func invalidate() { invalidationCount += 1 }
}

@MainActor private final class RunningRefreshDriver: VisibilityDriver {
    var available = true
    struct Request {
        let bundles: [String]
        let completion: @MainActor (Result<any VisibilityLease, Error>) -> Void
    }
    private(set) var requests: [Request] = []

    func activate(allowing bundles: [String], completion: @escaping @MainActor (Result<any VisibilityLease, Error>) -> Void) {
        requests.append(Request(bundles: bundles, completion: completion))
    }

    @discardableResult func succeed(_ index: Int) -> RunningRefreshLease {
        let lease = RunningRefreshLease()
        requests[index].completion(.success(lease))
        return lease
    }

    func reject(_ index: Int) {
        requests[index].completion(.failure(NSError(domain: "com.example.RefreshFailure", code: 1)))
    }
}

final class RunningBundleRefreshTests: XCTestCase {
    private let ownID = "com.example.MenuController"
    private let hiddenID = "com.example.HiddenOwner"
    private let permanentID = "com.example.PermanentOwner"
    private let visibleID = "com.example.VisibleOwner"
    private let launchedID = "com.example.NewOwner"
    private let anotherID = "com.example.AnotherOwner"

    private var layout: BarLayout {
        BarLayout(sections: [hiddenID: .hidden, permanentID: .alwaysHidden, visibleID: .shown])
    }

    private var owners: Set<String> { [ownID, hiddenID, permanentID, visibleID] }

    @MainActor func testCollapsedRefreshPreservesPresentationAndOldLeaseUntilReplacement() async {
        let driver = RunningRefreshDriver()
        let session = VisibilitySession(driver: driver)
        var changes = 0
        session.onChange = { changes += 1 }
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        let oldLease = driver.succeed(0)
        let stableChanges = changes

        session.refreshRunningBundles(owners.union([launchedID]))

        XCTAssertEqual(driver.requests.count, 2)
        XCTAssertEqual(Set(driver.requests[1].bundles), [ownID, visibleID, launchedID])
        XCTAssertEqual(session.state, .collapsed)
        XCTAssertEqual(changes, stableChanges)
        XCTAssertFalse(oldLease.invalidated)
        let replacement = driver.succeed(1)
        XCTAssertTrue(oldLease.invalidated)
        XCTAssertFalse(replacement.invalidated)
        XCTAssertEqual(session.state, .collapsed)
        XCTAssertEqual(changes, stableChanges)
        XCTAssertNil(session.lastError)
    }

    @MainActor func testPartialRefreshKeepsOrdinaryItemsAllowedAndPermanentItemsHidden() async {
        let driver = RunningRefreshDriver()
        let session = VisibilitySession(driver: driver)
        var changes = 0
        session.onChange = { changes += 1 }
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: false)
        let oldLease = driver.succeed(0)
        let stableChanges = changes

        session.refreshRunningBundles(owners.union([launchedID]))

        XCTAssertEqual(Set(driver.requests[1].bundles), [ownID, hiddenID, visibleID, launchedID])
        XCTAssertFalse(oldLease.invalidated)
        XCTAssertEqual(session.state, .partial)
        driver.succeed(1)
        XCTAssertTrue(oldLease.invalidated)
        XCTAssertEqual(session.state, .partial)
        XCTAssertEqual(changes, stableChanges)
    }

    @MainActor func testRefreshDuringFirstActivationOnlyLatestSuccessCompletesApply() async {
        let driver = RunningRefreshDriver()
        let session = VisibilitySession(driver: driver)
        var changes = 0
        session.onChange = { changes += 1 }
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        let applyingChanges = changes

        session.refreshRunningBundles(owners.union([launchedID]))

        XCTAssertEqual(session.state, .applying)
        XCTAssertEqual(changes, applyingChanges)
        let obsolete = driver.succeed(0)
        XCTAssertTrue(obsolete.invalidated)
        XCTAssertEqual(session.state, .applying)
        XCTAssertEqual(changes, applyingChanges)
        let replacement = driver.succeed(1)
        XCTAssertFalse(replacement.invalidated)
        XCTAssertEqual(session.state, .collapsed)
        XCTAssertEqual(changes, applyingChanges + 1)
    }

    @MainActor func testRapidLaunchesDiscardIntermediateLeaseAndKeepExistingRestriction() async {
        let driver = RunningRefreshDriver()
        let session = VisibilitySession(driver: driver)
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        let oldLease = driver.succeed(0)

        session.refreshRunningBundles(owners.union([launchedID]))
        session.refreshRunningBundles(owners.union([launchedID, anotherID]))

        XCTAssertEqual(driver.requests.count, 3)
        let obsolete = driver.succeed(1)
        XCTAssertTrue(obsolete.invalidated)
        XCTAssertFalse(oldLease.invalidated)
        XCTAssertEqual(session.state, .collapsed)
        XCTAssertEqual(Set(driver.requests[2].bundles), [ownID, visibleID, launchedID, anotherID])
        let latest = driver.succeed(2)
        XCTAssertTrue(oldLease.invalidated)
        XCTAssertFalse(latest.invalidated)
        XCTAssertEqual(session.state, .collapsed)
    }

    @MainActor func testRevealCancelsPendingRefreshAndLaterRefreshDoesNothing() async {
        let driver = RunningRefreshDriver()
        let session = VisibilitySession(driver: driver)
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        let oldLease = driver.succeed(0)
        session.refreshRunningBundles(owners.union([launchedID]))

        session.revealAll()
        let lateLease = driver.succeed(1)
        session.refreshRunningBundles(owners.union([launchedID, anotherID]))

        XCTAssertTrue(oldLease.invalidated)
        XCTAssertTrue(lateLease.invalidated)
        XCTAssertEqual(driver.requests.count, 2)
        XCTAssertEqual(session.state, .expanded)
        XCTAssertNil(session.lastError)
    }

    @MainActor func testIdenticalAllowedSetSkipsStableAndPendingDuplicateRequests() async {
        let driver = RunningRefreshDriver()
        let session = VisibilitySession(driver: driver)
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        driver.succeed(0)

        session.refreshRunningBundles(owners)
        session.refreshRunningBundles(owners.subtracting([hiddenID, permanentID]))
        XCTAssertEqual(driver.requests.count, 1)

        let updatedOwners = owners.union([launchedID])
        session.refreshRunningBundles(updatedOwners)
        session.refreshRunningBundles(updatedOwners.subtracting([hiddenID]))
        XCTAssertEqual(driver.requests.count, 2)
        driver.succeed(1)
        session.refreshRunningBundles(updatedOwners)
        XCTAssertEqual(driver.requests.count, 2)
        XCTAssertEqual(session.state, .collapsed)
    }

    @MainActor func testRefreshFailureReleasesOldLeaseAndClearsRefreshPlan() async {
        let driver = RunningRefreshDriver()
        let session = VisibilitySession(driver: driver)
        var observedStates: [(VisibilitySession.State, String?)] = []
        session.onChange = { observedStates.append((session.state, session.lastError)) }
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        let oldLease = driver.succeed(0)
        session.refreshRunningBundles(owners.union([launchedID]))
        observedStates.removeAll()

        driver.reject(1)
        session.refreshRunningBundles(owners.union([anotherID]))

        XCTAssertTrue(oldLease.invalidated)
        XCTAssertEqual(session.state, .expanded)
        XCTAssertNotNil(session.lastError)
        XCTAssertEqual(driver.requests.count, 2)
        XCTAssertEqual(observedStates.count, 1)
        XCTAssertEqual(observedStates.first?.0, .expanded)
        XCTAssertNotNil(observedStates.first?.1)
        XCTAssertFalse(observedStates.contains { $0.0 == .expanded && $0.1 == nil })
    }

    @MainActor func testRefreshDuringPendingExpansionRetainsPartialTarget() async {
        let driver = RunningRefreshDriver()
        let session = VisibilitySession(driver: driver)
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        let oldLease = driver.succeed(0)
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: false)

        session.refreshRunningBundles(owners.union([launchedID]))

        XCTAssertEqual(session.state, .applying)
        XCTAssertFalse(oldLease.invalidated)
        XCTAssertEqual(Set(driver.requests[2].bundles), [ownID, hiddenID, visibleID, launchedID])
        let replacement = driver.succeed(2)
        let obsolete = driver.succeed(1)
        XCTAssertTrue(obsolete.invalidated)
        XCTAssertTrue(oldLease.invalidated)
        XCTAssertFalse(replacement.invalidated)
        XCTAssertEqual(session.state, .partial)
    }

    @MainActor func testRelaunchedHiddenOwnersKeepTheirExistingMembership() async {
        let driver = RunningRefreshDriver()
        let session = VisibilitySession(driver: driver)
        let withoutHiddenOwners = owners.subtracting([hiddenID, permanentID])
        session.apply(layout: layout, runningBundles: withoutHiddenOwners, ownID: ownID, collapsed: true)
        let oldLease = driver.succeed(0)

        session.refreshRunningBundles(owners)
        XCTAssertEqual(driver.requests.count, 1)
        session.refreshRunningBundles(owners.union([launchedID]))

        XCTAssertEqual(Set(driver.requests[1].bundles), [ownID, visibleID, launchedID])
        XCTAssertFalse(driver.requests[1].bundles.contains(hiddenID))
        XCTAssertFalse(driver.requests[1].bundles.contains(permanentID))
        XCTAssertFalse(oldLease.invalidated)
        driver.succeed(1)
        XCTAssertEqual(session.state, .collapsed)
    }

    @MainActor func testManualApplySupersedesPendingRefreshAndItsFailure() async {
        let driver = RunningRefreshDriver()
        let session = VisibilitySession(driver: driver)
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        let oldLease = driver.succeed(0)
        session.refreshRunningBundles(owners.union([launchedID]))
        session.apply(layout: layout, runningBundles: owners.union([launchedID]), ownID: ownID, collapsed: false)

        driver.reject(1)
        XCTAssertEqual(session.state, .applying)
        XCTAssertNil(session.lastError)
        XCTAssertFalse(oldLease.invalidated)
        let replacement = driver.succeed(2)
        XCTAssertTrue(oldLease.invalidated)
        XCTAssertFalse(replacement.invalidated)
        XCTAssertEqual(session.state, .partial)
    }

    @MainActor func testRefreshWithoutAnActivePlanDoesNotActivate() async {
        let driver = RunningRefreshDriver()
        let session = VisibilitySession(driver: driver)

        session.refreshRunningBundles(owners)
        session.apply(layout: BarLayout(sections: [visibleID: .shown]), runningBundles: owners, ownID: ownID, collapsed: true)
        session.refreshRunningBundles(owners.union([launchedID]))

        XCTAssertTrue(driver.requests.isEmpty)
        XCTAssertEqual(session.state, .expanded)
    }
}
