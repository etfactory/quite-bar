import Foundation

@MainActor public protocol VisibilityLease: AnyObject {
    func invalidate()
}

@MainActor public protocol VisibilityDriver: AnyObject {
    var available: Bool { get }
    func activate(allowing bundles: [String], completion: @escaping @MainActor (Result<any VisibilityLease, Error>) -> Void)
}

/// Owns the asynchronous transaction. Late results are invalidated, never installed.
/// Injected driver lets tests exercise cancellation without changing the real menu bar.
///
/// 비동기 적용 작업을 관리하며, 늦게 도착한 결과는 채택하지 않고 무효화합니다.
/// 드라이버를 주입해 실제 메뉴 막대를 바꾸지 않고 취소 동작을 시험할 수 있습니다.
@MainActor public final class VisibilitySession {
    public enum State: Equatable { case expanded, applying, collapsed, partial }
    public private(set) var state: State = .expanded
    public private(set) var lastError: String?
    public var onChange: (() -> Void)?
    private var generation = 0
    private var lease: (any VisibilityLease)?
    private let driver: any VisibilityDriver
    private struct Plan {
        let hidden: Set<String>
        let ownID: String
        let collapsed: Bool
    }
    private var plan: Plan?
    private var requestedAllowed: [String]?
    private var environmentSuspended = false

    public init(driver: any VisibilityDriver) { self.driver = driver }
    public var available: Bool { driver.available }
    public var hasVisibilityPlan: Bool { plan != nil }

    public func apply(layout: BarLayout, runningBundles: Set<String>, ownID: String, collapsed: Bool) {
        environmentSuspended = false
        let hidden = layout.hiddenBundles(collapsed: collapsed)
        guard !hidden.isEmpty else { revealAll(); return }
        let plan = Plan(hidden: hidden, ownID: ownID, collapsed: collapsed)
        self.plan = plan
        activate(plan, runningBundles: runningBundles, showsProgress: true)
    }

    /// Update ownership without changing the user's section membership or presentation.
    /// Stable refreshes stay silent so an in-flight AX read or drag is not interrupted.
    ///
    /// 사용자의 구역 소속과 표시 상태를 바꾸지 않고 실행 앱 허용 목록을 갱신합니다.
    /// 확정된 표시 상태를 유지하는 갱신은 별도 알림 없이 처리해 AX 읽기나 드래그를 방해하지 않습니다.
    public func refreshRunningBundles(_ runningBundles: Set<String>) {
        guard !environmentSuspended, let plan else { return }
        let allowed = runningBundles.subtracting(plan.hidden).union([plan.ownID]).sorted()
        guard allowed != requestedAllowed else { return }
        activate(plan, runningBundles: runningBundles, showsProgress: false)
    }

    /// Keep the current restriction and intent while the menu-bar host changes.
    ///
    /// 메뉴 막대 호스트가 바뀌는 동안 현재 제한과 사용자가 지정한 숨김 계획을 유지합니다.
    public func suspendForEnvironmentChange() {
        generation += 1
        requestedAllowed = nil
        environmentSuspended = true
    }

    /// The OS may have rebuilt the host even when the allow list is unchanged.
    /// A transient failure retains the old lease so the caller can retry.
    ///
    /// 허용 목록이 같아도 운영체제가 호스트를 다시 생성했을 수 있습니다.
    /// 일시적인 실패에는 기존 제한 핸들을 유지해 호출자가 재시도할 수 있게 합니다.
    public func reapplyAfterEnvironmentChange(_ runningBundles: Set<String>,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        environmentSuspended = false
        guard let plan else { completion(.success(())); return }
        activate(plan, runningBundles: runningBundles, showsProgress: false, recoveryCompletion: completion)
    }

    private func activate(_ plan: Plan, runningBundles: Set<String>, showsProgress: Bool,
        recoveryCompletion: (@MainActor (Result<Void, Error>) -> Void)? = nil) {
        generation += 1
        let request = generation
        guard driver.available else {
            activationFailed(NSError(domain: "QuietBar.Visibility", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "이 macOS에서 숨김 엔진을 사용할 수 없습니다."]),
                recoveryCompletion: recoveryCompletion)
            return
        }
        // Preserve ALL other running owners, including unknown and system apps.
        // 확인되지 않은 앱과 시스템 앱을 포함해 다른 모든 실행 앱의 표시를 허용합니다.
        let allowed = runningBundles.subtracting(plan.hidden).union([plan.ownID]).sorted()
        requestedAllowed = allowed
        lastError = nil
        if showsProgress {
            state = .applying
            onChange?()
        }
        driver.activate(allowing: allowed) { [weak self] result in
            guard let self, self.generation == request else {
                if case .success(let stale) = result { stale.invalidate() }
                return
            }
            switch result {
            case .success(let newLease):
                let oldLease = self.lease
                self.lease = newLease
                oldLease?.invalidate()
                let next: State = plan.collapsed ? .collapsed : .partial
                let changed = self.state != next
                self.state = next
                if changed { self.onChange?() }
                recoveryCompletion?(.success(()))
            case .failure(let error): self.activationFailed(error, recoveryCompletion: recoveryCompletion)
            }
        }
    }

    private func activationFailed(_ error: Error,
        recoveryCompletion: (@MainActor (Result<Void, Error>) -> Void)?) {
        if let recoveryCompletion {
            environmentSuspended = true
            requestedAllowed = nil
            recoveryCompletion(.failure(error))
        } else {
            fail(error.localizedDescription)
        }
    }

    public func revealAll() {
        reset()
        lastError = nil
        onChange?()
    }

    private func reset() {
        generation += 1
        lease?.invalidate()
        lease = nil
        plan = nil
        requestedAllowed = nil
        environmentSuspended = false
        state = .expanded
    }

    public func fail(_ message: String) {
        reset()
        lastError = message
        onChange?()
    }
}
