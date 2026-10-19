import Foundation
#if canImport(QuietBarCore)
import QuietBarCore
#endif

@MainActor final class NativeVisibilityDriver: VisibilityDriver {
    var available: Bool { QBVisibilityAvailable() }

    func activate(allowing bundles: [String], completion: @escaping @MainActor (Result<any VisibilityLease, Error>) -> Void) {
        QBVisibilityActivate(bundles) { raw, error in
            // The ObjC boundary always returns on the main queue.
            MainActor.assumeIsolated {
                if let raw { completion(.success(NativeLease(raw))) }
                else { completion(.failure(error ?? NSError(domain: "QuietBar", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "숨김 세션을 시작하지 못했습니다."]))) }
            }
        }
    }

    private final class NativeLease: VisibilityLease {
        private var raw: Any?
        init(_ raw: Any) { self.raw = raw }
        func invalidate() {
            guard let raw else { return }
            self.raw = nil
            QBVisibilityInvalidate(raw)
        }
        deinit { if let raw { QBVisibilityInvalidate(raw) } }
    }
}
