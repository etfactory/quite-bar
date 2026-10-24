import XCTest
@testable import QuietBarCore

@MainActor private final class EnvironmentLease: VisibilityLease {
    private(set) var invalidated = false
    func invalidate() { invalidated = true }
}

@MainActor private final class EnvironmentDriver: VisibilityDriver {
    var available = true
    struct Request {
        let bundles: [String]
        let completion: @MainActor (Result<any VisibilityLease, Error>) -> Void
    }
    private(set) var requests: [Request] = []

    func activate(allowing bundles: [String], completion: @escaping @MainActor (Result<any VisibilityLease, Error>) -> Void) {
        requests.append(Request(bundles: bundles, completion: completion))
    }

    @discardableResult func succeed(_ index: Int) -> EnvironmentLease {
        let lease = EnvironmentLease()
        requests[index].completion(.success(lease))
        return lease
    }

    func reject(_ index: Int) {
        requests[index].completion(.failure(NSError(domain: "com.example.EnvironmentFailure", code: 1)))
    }
}

final class EnvironmentRecoveryTests: XCTestCase {
    private let ownID = "com.example.MenuController"
    private let hiddenID = "com.example.HiddenOwner"
    private let permanentID = "com.example.PermanentOwner"
    private let visibleID = "com.example.VisibleOwner"
    private let launchedID = "com.example.NewOwner"

    private var layout: BarLayout {
        BarLayout(sections: [hiddenID: .hidden, permanentID: .alwaysHidden, visibleID: .shown])
    }
    private var owners: Set<String> { [ownID, hiddenID, permanentID, visibleID] }

    @MainActor func testSameOwnerListIsForcedAfterEnvironmentChangeWithoutUnfolding() async {
        let driver = EnvironmentDriver()
        let session = VisibilitySession(driver: driver)
        var changes = 0
        var recovered = 0
        session.onChange = { changes += 1 }
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        let old = driver.succeed(0)
        let stableChanges = changes

        session.suspendForEnvironmentChange()
        XCTAssertFalse(old.invalidated)
        XCTAssertEqual(session.state, .collapsed)
        XCTAssertEqual(changes, stableChanges)
        session.reapplyAfterEnvironmentChange(owners) { result in
            if case .success = result { recovered += 1 }
        }

        XCTAssertEqual(driver.requests.count, 2)
        XCTAssertEqual(driver.requests[1].bundles, driver.requests[0].bundles)
        XCTAssertFalse(old.invalidated)
        XCTAssertEqual(session.state, .collapsed)
        let replacement = driver.succeed(1)
        XCTAssertTrue(old.invalidated)
        XCTAssertFalse(replacement.invalidated)
        XCTAssertEqual(session.state, .collapsed)
        XCTAssertEqual(changes, stableChanges)
        XCTAssertEqual(recovered, 1)
        XCTAssertNil(session.lastError)
    }

    @MainActor func testPartialExpansionAndPermanentMembershipSurviveRecovery() async {
        let driver = EnvironmentDriver()
        let session = VisibilitySession(driver: driver)
        var changes = 0
        session.onChange = { changes += 1 }
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: false)
        let old = driver.succeed(0)
        let stableChanges = changes

        session.suspendForEnvironmentChange()
        session.reapplyAfterEnvironmentChange(owners.union([launchedID])) { _ in }

        XCTAssertEqual(Set(driver.requests[1].bundles), [ownID, hiddenID, visibleID, launchedID])
        XCTAssertFalse(driver.requests[1].bundles.contains(permanentID))
        XCTAssertEqual(session.state, .partial)
        XCTAssertFalse(old.invalidated)
        driver.succeed(1)
        XCTAssertTrue(old.invalidated)
        XCTAssertEqual(session.state, .partial)
        XCTAssertEqual(changes, stableChanges)
    }

    @MainActor func testSleepDiscardsPendingSuccessAndFailureWithoutReleasingCommittedLease() async {
        for pendingSucceeds in [false, true] {
            let driver = EnvironmentDriver()
            let session = VisibilitySession(driver: driver)
            var changes = 0
            session.onChange = { changes += 1 }
            session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
            let old = driver.succeed(0)
            session.refreshRunningBundles(owners.union([launchedID]))
            let stableChanges = changes

            session.suspendForEnvironmentChange()
            if pendingSucceeds {
                let obsolete = driver.succeed(1)
                XCTAssertTrue(obsolete.invalidated)
            } else {
                driver.reject(1)
            }

            XCTAssertFalse(old.invalidated)
            XCTAssertEqual(session.state, .collapsed)
            XCTAssertEqual(changes, stableChanges)
            XCTAssertNil(session.lastError)
        }
    }

    @MainActor func testLaunchRefreshWaitsWhileSuspendedAndRecoveryUsesCurrentOwners() async {
        let driver = EnvironmentDriver()
        let session = VisibilitySession(driver: driver)
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        driver.succeed(0)

        session.suspendForEnvironmentChange()
        session.refreshRunningBundles(owners.union([launchedID]))
        XCTAssertEqual(driver.requests.count, 1)
        session.reapplyAfterEnvironmentChange(owners.union([launchedID])) { _ in }

        XCTAssertEqual(driver.requests.count, 2)
        XCTAssertEqual(Set(driver.requests[1].bundles), [ownID, visibleID, launchedID])
        driver.succeed(1)
        session.refreshRunningBundles(owners.union([launchedID]))
        XCTAssertEqual(driver.requests.count, 2)
        XCTAssertEqual(session.state, .collapsed)
    }

    @MainActor func testInitialPendingCollapseKeepsItsIntentAcrossSleep() async {
        let driver = EnvironmentDriver()
        let session = VisibilitySession(driver: driver)
        var changes = 0
        var recovered = 0
        session.onChange = { changes += 1 }
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        let applyingChanges = changes

        session.suspendForEnvironmentChange()
        let obsolete = driver.succeed(0)
        XCTAssertTrue(obsolete.invalidated)
        XCTAssertEqual(session.state, .applying)
        session.reapplyAfterEnvironmentChange(owners) { result in
            if case .success = result { recovered += 1 }
        }
        driver.succeed(1)

        XCTAssertEqual(session.state, .collapsed)
        XCTAssertEqual(changes, applyingChanges + 1)
        XCTAssertEqual(recovered, 1)
    }

    @MainActor func testTransientRecoveryFailureRetainsPlanAndLeaseForRetry() async {
        let driver = EnvironmentDriver()
        let session = VisibilitySession(driver: driver)
        var changes = 0
        var failures = 0
        var recovered = 0
        session.onChange = { changes += 1 }
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        let old = driver.succeed(0)
        let stableChanges = changes
        session.suspendForEnvironmentChange()
        session.reapplyAfterEnvironmentChange(owners) { result in
            if case .failure = result { failures += 1 }
        }

        driver.reject(1)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(session.state, .collapsed)
        XCTAssertFalse(old.invalidated)
        XCTAssertNil(session.lastError)
        XCTAssertEqual(changes, stableChanges)
        session.refreshRunningBundles(owners.union([launchedID]))
        XCTAssertEqual(driver.requests.count, 2)

        session.reapplyAfterEnvironmentChange(owners.union([launchedID])) { result in
            if case .success = result { recovered += 1 }
        }
        XCTAssertEqual(Set(driver.requests[2].bundles), [ownID, visibleID, launchedID])
        driver.succeed(2)
        XCTAssertTrue(old.invalidated)
        XCTAssertEqual(session.state, .collapsed)
        XCTAssertEqual(changes, stableChanges)
        XCTAssertEqual(recovered, 1)
    }

    @MainActor func testManualRevealCancelsRecoveryAndDoesNotResurrectThePlan() async {
        let driver = EnvironmentDriver()
        let session = VisibilitySession(driver: driver)
        var staleCompletions = 0
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        let old = driver.succeed(0)
        session.suspendForEnvironmentChange()
        session.reapplyAfterEnvironmentChange(owners) { _ in staleCompletions += 1 }

        session.revealAll()
        let obsolete = driver.succeed(1)
        session.reapplyAfterEnvironmentChange(owners.union([launchedID])) { _ in }

        XCTAssertTrue(old.invalidated)
        XCTAssertTrue(obsolete.invalidated)
        XCTAssertEqual(staleCompletions, 0)
        XCTAssertEqual(driver.requests.count, 2)
        XCTAssertEqual(session.state, .expanded)
        XCTAssertNil(session.lastError)
    }

    @MainActor func testManualApplySupersedesRecoveryAndUsesTheNewTarget() async {
        let driver = EnvironmentDriver()
        let session = VisibilitySession(driver: driver)
        var staleCompletions = 0
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        let old = driver.succeed(0)
        session.suspendForEnvironmentChange()
        session.reapplyAfterEnvironmentChange(owners) { _ in staleCompletions += 1 }

        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: false)
        let obsolete = driver.succeed(1)
        XCTAssertTrue(obsolete.invalidated)
        XCTAssertFalse(old.invalidated)
        XCTAssertEqual(staleCompletions, 0)
        XCTAssertEqual(session.state, .applying)
        let replacement = driver.succeed(2)
        XCTAssertTrue(old.invalidated)
        XCTAssertFalse(replacement.invalidated)
        XCTAssertEqual(session.state, .partial)
        session.refreshRunningBundles(owners.union([launchedID]))
        XCTAssertEqual(driver.requests.count, 4)
        XCTAssertEqual(Set(driver.requests[3].bundles), [ownID, hiddenID, visibleID, launchedID])
    }

    @MainActor func testManualApplyWhileSuspendedStartsImmediatelyAndResumesOwnerRefreshes() async {
        let driver = EnvironmentDriver()
        let session = VisibilitySession(driver: driver)
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        let old = driver.succeed(0)
        session.suspendForEnvironmentChange()

        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: false)

        XCTAssertEqual(driver.requests.count, 2)
        XCTAssertEqual(session.state, .applying)
        XCTAssertFalse(old.invalidated)
        driver.succeed(1)
        XCTAssertTrue(old.invalidated)
        XCTAssertEqual(session.state, .partial)
        session.refreshRunningBundles(owners.union([launchedID]))
        XCTAssertEqual(driver.requests.count, 3)
        XCTAssertEqual(Set(driver.requests[2].bundles), [ownID, hiddenID, visibleID, launchedID])
    }

    @MainActor func testRepeatedEnvironmentChangesCommitOnlyTheNewestRecovery() async {
        let driver = EnvironmentDriver()
        let session = VisibilitySession(driver: driver)
        var obsoleteCompletions = 0
        var latestCompletions = 0
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        let old = driver.succeed(0)
        session.suspendForEnvironmentChange()
        session.reapplyAfterEnvironmentChange(owners) { _ in obsoleteCompletions += 1 }

        session.suspendForEnvironmentChange()
        session.reapplyAfterEnvironmentChange(owners.union([launchedID])) { _ in latestCompletions += 1 }
        let latest = driver.succeed(2)
        let obsolete = driver.succeed(1)

        XCTAssertTrue(old.invalidated)
        XCTAssertTrue(obsolete.invalidated)
        XCTAssertFalse(latest.invalidated)
        XCTAssertEqual(obsoleteCompletions, 0)
        XCTAssertEqual(latestCompletions, 1)
        XCTAssertEqual(session.state, .collapsed)
    }

    @MainActor func testNoPlanRecoveryCannotCreateAHidingRestriction() async {
        let driver = EnvironmentDriver()
        let session = VisibilitySession(driver: driver)
        var recovered = 0
        session.suspendForEnvironmentChange()
        session.reapplyAfterEnvironmentChange(owners) { result in
            if case .success = result { recovered += 1 }
        }
        session.refreshRunningBundles(owners.union([launchedID]))

        XCTAssertEqual(recovered, 1)
        XCTAssertTrue(driver.requests.isEmpty)
        XCTAssertEqual(session.state, .expanded)
        XCTAssertNil(session.lastError)
    }

    @MainActor func testExplicitFailureAfterRetryLimitReleasesPlanAndCommittedLease() async {
        let driver = EnvironmentDriver()
        let session = VisibilitySession(driver: driver)
        session.apply(layout: layout, runningBundles: owners, ownID: ownID, collapsed: true)
        let old = driver.succeed(0)
        session.suspendForEnvironmentChange()
        session.reapplyAfterEnvironmentChange(owners) { _ in }
        driver.reject(1)

        session.fail("환경 복원을 완료하지 못했습니다.")
        session.reapplyAfterEnvironmentChange(owners.union([launchedID])) { _ in }

        XCTAssertTrue(old.invalidated)
        XCTAssertEqual(session.state, .expanded)
        XCTAssertEqual(session.lastError, "환경 복원을 완료하지 못했습니다.")
        XCTAssertEqual(driver.requests.count, 2)
    }
}
