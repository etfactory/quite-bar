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

    public init(driver: any VisibilityDriver) { self.driver = driver }
    public var available: Bool { driver.available }

    public func apply(layout: BarLayout, runningBundles: Set<String>, ownID: String, collapsed: Bool) {
        generation += 1
        let request = generation
        let hidden = layout.hiddenBundles(collapsed: collapsed)
        guard !hidden.isEmpty else { revealAll(); return }
        guard driver.available else { fail("이 macOS에서 숨김 엔진을 사용할 수 없습니다."); return }
        // Preserve ALL other running owners, including unknown and system apps.
        let allowed = runningBundles.subtracting(hidden).union([ownID]).sorted()
        state = .applying
        lastError = nil
        onChange?()
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
                self.state = collapsed ? .collapsed : .partial
                self.onChange?()
            case .failure(let error): self.fail(error.localizedDescription)
            }
        }
    }

    public func revealAll() {
        generation += 1
        lease?.invalidate()
        lease = nil
        state = .expanded
        lastError = nil
        onChange?()
    }

    public func fail(_ message: String) {
        revealAll()
        lastError = message
        onChange?()
    }
}
