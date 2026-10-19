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

    public init(driver: any VisibilityDriver) { self.driver = driver }
    public var available: Bool { driver.available }

    public func apply(layout: BarLayout, runningBundles: Set<String>, ownID: String, collapsed: Bool) {
        let hidden = layout.hiddenBundles(collapsed: collapsed)
        guard !hidden.isEmpty else { revealAll(); return }
        let plan = Plan(hidden: hidden, ownID: ownID, collapsed: collapsed)
        self.plan = plan
        activate(plan, runningBundles: runningBundles, showsProgress: true)
    }

    /// Update ownership without changing the user's section membership or presentation.
    /// Stable refreshes stay silent so an in-flight AX read or drag is not interrupted.
    public func refreshRunningBundles(_ runningBundles: Set<String>) {
        guard let plan else { return }
        let allowed = runningBundles.subtracting(plan.hidden).union([plan.ownID]).sorted()
        guard allowed != requestedAllowed else { return }
        activate(plan, runningBundles: runningBundles, showsProgress: false)
    }

    private func activate(_ plan: Plan, runningBundles: Set<String>, showsProgress: Bool) {
        guard driver.available else { fail("이 macOS에서 숨김 엔진을 사용할 수 없습니다."); return }
        generation += 1
        let request = generation
        // Preserve ALL other running owners, including unknown and system apps.
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
            case .failure(let error): self.fail(error.localizedDescription)
            }
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
        state = .expanded
    }

    public func fail(_ message: String) {
        reset()
        lastError = message
        onChange?()
    }
}
