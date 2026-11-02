import XCTest
@testable import QuietBarCore

@MainActor private final class SystemInteractionLease: VisibilityLease {
    private(set) var invalidationCount = 0
    var invalidated: Bool { invalidationCount > 0 }
    func invalidate() { invalidationCount += 1 }
}

@MainActor private final class SystemInteractionDriver: VisibilityDriver {
    var available = true
    struct Request {
        let bundles: [String]
        let completion: @MainActor (Result<any VisibilityLease, Error>) -> Void
    }
    private(set) var requests: [Request] = []

    func activate(allowing bundles: [String], completion: @escaping @MainActor (Result<any VisibilityLease, Error>) -> Void) {
        requests.append(Request(bundles: bundles, completion: completion))
    }

    @discardableResult func succeed(_ index: Int) -> SystemInteractionLease {
        let lease = SystemInteractionLease()
        requests[index].completion(.success(lease))
        return lease
    }

    func reject(_ index: Int) {
        requests[index].completion(.failure(NSError(domain: "com.example.SystemInteractionFailure", code: 1)))
    }
}

final class SystemInteractionTests: XCTestCase {
    private let ownID = "com.example.MenuController"
    private let hiddenID = "com.example.HiddenOwner"
    private let permanentID = "com.example.PermanentOwner"
    private let visibleID = "com.example.VisibleOwner"
    private let launchedID = "com.example.NewOwner"

    private var layout: BarLayout {
        BarLayout(sections: [hiddenID: .hidden, permanentID: .alwaysHidden, visibleID: .shown])
    }
    private var owners: Set<String> { [ownID, hiddenID, permanentID, visibleID] }

    @MainActor func testClockInteractionReleasesRestrictionWithoutChangingCollapsedIntent() async {
        let driver = SystemInteractionDriver()
        let session = VisibilitySession(driver: driver)
        var changes = 0
        session.onChange = { changes += 1 }
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        let old = driver.succeed(0)
        let stableChanges = changes

        XCTAssertTrue(session.suspendForSystemInteraction())

        XCTAssertTrue(old.invalidated)
        XCTAssertTrue(session.systemInteractionSuspended)
        XCTAssertTrue(session.hasVisibilityPlan)
        XCTAssertEqual(session.state, .collapsed)
        XCTAssertEqual(changes, stableChanges)
        XCTAssertNil(session.lastError)
        XCTAssertEqual(driver.requests.count, 1)
    }

    @MainActor func testPartialStateResumesWithOnlyAlwaysHiddenOwnersRestricted() async {
        let driver = SystemInteractionDriver()
        let session = VisibilitySession(driver: driver)
        var changes = 0
        session.onChange = { changes += 1 }
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: false)
        driver.succeed(0)
        let stableChanges = changes
        XCTAssertTrue(session.suspendForSystemInteraction())

        session.resumeAfterSystemInteraction(owners)

        XCTAssertFalse(session.systemInteractionSuspended)
        XCTAssertEqual(driver.requests.count, 2)
        XCTAssertEqual(Set(driver.requests[1].bundles), [ownID, hiddenID, visibleID])
        XCTAssertFalse(driver.requests[1].bundles.contains(permanentID))
        XCTAssertEqual(session.state, .partial)
        let replacement = driver.succeed(1)
        XCTAssertFalse(replacement.invalidated)
        XCTAssertEqual(session.state, .partial)
        XCTAssertEqual(changes, stableChanges)
    }

    @MainActor func testLaunchesWaitUntilInteractionEndsThenUseLatestOwners() async {
        let driver = SystemInteractionDriver()
        let session = VisibilitySession(driver: driver)
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        driver.succeed(0)
        XCTAssertTrue(session.suspendForSystemInteraction())

        session.refreshRunningBundles(owners.union([launchedID]))
        XCTAssertEqual(driver.requests.count, 1)
        session.resumeAfterSystemInteraction(owners.union([launchedID]))

        XCTAssertEqual(driver.requests.count, 2)
        XCTAssertEqual(Set(driver.requests[1].bundles), [ownID, visibleID, launchedID])
        driver.succeed(1)
        XCTAssertEqual(session.state, .collapsed)
    }

    @MainActor func testOldOwnerRefreshCannotReinstateRestrictionDuringInteraction() async {
        for pendingSucceeds in [false, true] {
            let driver = SystemInteractionDriver()
            let session = VisibilitySession(driver: driver)
            session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
            let old = driver.succeed(0)
            session.refreshRunningBundles(owners.union([launchedID]))
            XCTAssertTrue(session.suspendForSystemInteraction())

            if pendingSucceeds {
                let stale = driver.succeed(1)
                XCTAssertTrue(stale.invalidated)
            } else {
                driver.reject(1)
            }

            XCTAssertTrue(old.invalidated)
            XCTAssertTrue(session.systemInteractionSuspended)
            XCTAssertEqual(session.state, .collapsed)
            XCTAssertNil(session.lastError)
            session.resumeAfterSystemInteraction(owners.union([launchedID]))
            XCTAssertEqual(driver.requests.count, 3)
            driver.succeed(2)
            XCTAssertEqual(session.state, .collapsed)
        }
    }

    @MainActor func testDuplicateInteractionAndResumeAreIdempotent() async {
        let driver = SystemInteractionDriver()
        let session = VisibilitySession(driver: driver)
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        let old = driver.succeed(0)

        XCTAssertTrue(session.suspendForSystemInteraction())
        XCTAssertFalse(session.suspendForSystemInteraction())
        XCTAssertEqual(old.invalidationCount, 1)
        session.resumeAfterSystemInteraction(owners)
        session.resumeAfterSystemInteraction(owners)

        XCTAssertEqual(driver.requests.count, 2)
        driver.succeed(1)
        XCTAssertEqual(session.state, .collapsed)
    }

    @MainActor func testExpandedAndInitialPendingSessionsCannotBeSuspended() async {
        let driver = SystemInteractionDriver()
        let session = VisibilitySession(driver: driver)

        XCTAssertFalse(session.suspendForSystemInteraction())
        session.resumeAfterSystemInteraction(owners)
        XCTAssertTrue(driver.requests.isEmpty)
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        XCTAssertFalse(session.suspendForSystemInteraction())
        XCTAssertFalse(session.systemInteractionSuspended)
        XCTAssertEqual(session.state, .applying)
        driver.succeed(0)
        XCTAssertEqual(session.state, .collapsed)
    }

    @MainActor func testPendingManualExpansionKeepsItsOriginalTarget() async {
        let driver = SystemInteractionDriver()
        let session = VisibilitySession(driver: driver)
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        let old = driver.succeed(0)
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: false)

        XCTAssertFalse(session.suspendForSystemInteraction())
        XCTAssertFalse(old.invalidated)
        driver.succeed(1)
        XCTAssertTrue(old.invalidated)
        XCTAssertEqual(session.state, .partial)
    }

    @MainActor func testFullRestoreCancelsInteractionRestorationIntent() async {
        let driver = SystemInteractionDriver()
        let session = VisibilitySession(driver: driver)
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        driver.succeed(0)
        XCTAssertTrue(session.suspendForSystemInteraction())

        session.revealAll()
        session.resumeAfterSystemInteraction(owners)

        XCTAssertFalse(session.systemInteractionSuspended)
        XCTAssertFalse(session.hasVisibilityPlan)
        XCTAssertEqual(session.state, .expanded)
        XCTAssertEqual(driver.requests.count, 1)
    }

    @MainActor func testManualApplySupersedesInteractionWithNewTarget() async {
        let driver = SystemInteractionDriver()
        let session = VisibilitySession(driver: driver)
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        driver.succeed(0)
        XCTAssertTrue(session.suspendForSystemInteraction())

        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: false)
        session.resumeAfterSystemInteraction(owners.union([launchedID]))

        XCTAssertFalse(session.systemInteractionSuspended)
        XCTAssertEqual(driver.requests.count, 2)
        XCTAssertEqual(Set(driver.requests[1].bundles), [ownID, hiddenID, visibleID])
        driver.succeed(1)
        XCTAssertEqual(session.state, .partial)
    }

    @MainActor func testEnvironmentRecoveryWaitsForOpenInteraction() async {
        let driver = SystemInteractionDriver()
        let session = VisibilitySession(driver: driver)
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        driver.succeed(0)
        XCTAssertTrue(session.suspendForSystemInteraction())
        session.suspendForEnvironmentChange()
        var recovered = 0

        session.reapplyAfterEnvironmentChange(owners) { result in
            if case .success = result { recovered += 1 }
        }

        XCTAssertEqual(recovered, 1)
        XCTAssertEqual(driver.requests.count, 1)
        XCTAssertTrue(session.systemInteractionSuspended)
        XCTAssertEqual(session.state, .collapsed)
        session.resumeAfterSystemInteraction(owners.union([launchedID]))
        XCTAssertEqual(driver.requests.count, 2)
        XCTAssertEqual(Set(driver.requests[1].bundles), [ownID, visibleID, launchedID])
        driver.succeed(1)
        XCTAssertEqual(session.state, .collapsed)
    }

    @MainActor func testInteractionEndingWhileAsleepWaitsForEnvironmentRecovery() async {
        let driver = SystemInteractionDriver()
        let session = VisibilitySession(driver: driver)
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: false)
        driver.succeed(0)
        XCTAssertTrue(session.suspendForSystemInteraction())
        session.suspendForEnvironmentChange()

        session.resumeAfterSystemInteraction(owners)

        XCTAssertFalse(session.systemInteractionSuspended)
        XCTAssertEqual(driver.requests.count, 1)
        XCTAssertEqual(session.state, .partial)
        session.refreshRunningBundles(owners.union([launchedID]))
        XCTAssertEqual(driver.requests.count, 1)
        session.reapplyAfterEnvironmentChange(owners.union([launchedID])) { _ in }
        XCTAssertEqual(driver.requests.count, 2)
        XCTAssertEqual(Set(driver.requests[1].bundles), [ownID, hiddenID, visibleID, launchedID])
        driver.succeed(1)
        XCTAssertEqual(session.state, .partial)
    }

    @MainActor func testResumeFailureRestoresEverythingAndClearsIntent() async {
        let driver = SystemInteractionDriver()
        let session = VisibilitySession(driver: driver)
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        driver.succeed(0)
        XCTAssertTrue(session.suspendForSystemInteraction())
        session.resumeAfterSystemInteraction(owners)

        driver.reject(1)

        XCTAssertEqual(session.state, .expanded)
        XCTAssertFalse(session.systemInteractionSuspended)
        XCTAssertFalse(session.hasVisibilityPlan)
        XCTAssertNotNil(session.lastError)
        session.resumeAfterSystemInteraction(owners)
        session.refreshRunningBundles(owners.union([launchedID]))
        XCTAssertEqual(driver.requests.count, 2)
    }

    @MainActor func testFullRestoreWhileResumeIsPendingDiscardsItsLateLease() async {
        let driver = SystemInteractionDriver()
        let session = VisibilitySession(driver: driver)
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        driver.succeed(0)
        XCTAssertTrue(session.suspendForSystemInteraction())
        session.resumeAfterSystemInteraction(owners)
        session.revealAll()

        let stale = driver.succeed(1)

        XCTAssertTrue(stale.invalidated)
        XCTAssertEqual(session.state, .expanded)
        XCTAssertFalse(session.hasVisibilityPlan)
        XCTAssertFalse(session.systemInteractionSuspended)
    }
}
