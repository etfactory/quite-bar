import AppKit
import Combine
#if canImport(QuietBarCore)
import QuietBarCore
#endif

@MainActor final class StatusBarController: NSObject, ObservableObject {
    @Published private(set) var collapsed = false
    @Published private(set) var busy = false
    @Published private(set) var arranging = true
    @Published private(set) var authorized = false
    @Published private(set) var message: String?
    @Published private(set) var counts = [0, 0, 0]
    @Published var shortcutError: String?
    @Published private(set) var diagnosticReport = ""

    let preferences: Preferences
    let native = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    var showPreferences: (() -> Void)?
    var windowVisible = false
    private var toggleItem: NSStatusItem!
    private var divider: NSStatusItem!
    private var permanent: NSStatusItem?
    private let session = VisibilitySession(driver: NativeVisibilityDriver())
    private var layout: BarLayout?
    private var legacyGeometry: Geometry?
    private var inventorySummary = "아직 아이콘 위치를 수집하지 않았습니다."
    private var dividersHidden = false
    private var dragTracker = MenuBarDragTracker()
    private var mouseMonitors: [Any] = []
    private var dragUpdateTask: Task<Void, Never>?
    private var dragGeneration = 0
    private var pendingDragChange = false
    private var dragSnapshotOperation: Int?
    private var dragStatus = "드래그 대기"
    private var expansionFrontApplication: NSRunningApplication?
    private var ownsMenuBarSpace = false
    private var operation = 0
    private var timer: Timer?
    private var environmentTask: Task<Void, Never>?
    private var environmentGeneration = 0
    private var environmentRecoveryPending = false
    private var environmentTogglePending = false
    private var systemSleeping = false
    private var displaysSleeping = false
    private var observers: [NSObjectProtocol] = []
    private var lastAlwaysHidden: Bool
    private let ownID = Bundle.main.bundleIdentifier ?? "local.quietbar.app"

    init(preferences: Preferences) {
        self.preferences = preferences
        lastAlwaysHidden = preferences.alwaysHidden
        super.init()
        authorized = AccessibilityInventory.authorized
        toggleItem = makeItem(name: "QuietBar.Toggle", symbol: "chevron.left", tooltip: "Quiet Bar · 클릭하여 접기/펼치기 · 우클릭하여 설정")
        toggleItem.button?.action = #selector(toggleClicked)
        toggleItem.button?.setAccessibilityLabel("Quiet Bar 접기 또는 펼치기")
        divider = makeItem(name: "QuietBar.Divider", symbol: "line.diagonal", tooltip: "숨김 구분선 · ⌘-드래그로 위치 조정")
        divider.button?.image = dividerImage(dotted: false)
        divider.button?.action = #selector(dividerClicked)
        divider.button?.setAccessibilityLabel("숨김 구분선")
        updatePermanentItem()
        session.onChange = { [weak self] in
            guard let self else { return }
            if self.session.lastError != nil {
                self.cancelEnvironmentRecovery()
                // A failed owner refresh must also invalidate older AX reads.
                // 실행 앱 목록 갱신이 실패하면 이전 AX 읽기 결과도 무효화해야 합니다.
                self.cancelDragUpdate()
                self.operation += 1
                self.timer?.invalidate()
                self.timer = nil
                self.arranging = true
                self.layout = nil
                self.releaseMenuBarSpace()
            }
            self.busy = self.session.state == .applying
            // Keep the last committed presentation while a replacement lease is
            // pending. Restore the markers only once expansion actually succeeds.
            // 새 제한 핸들을 기다리는 동안에는 마지막으로 확정된 표시 상태를 유지합니다.
            // 펼치기가 실제로 성공한 뒤에만 구분선을 복원합니다.
            if !self.busy {
                self.collapsed = self.session.state == .collapsed
                self.setDividersHidden(self.collapsed)
                if self.collapsed { self.releaseMenuBarSpace() }
                else if !self.arranging { self.claimMenuBarSpace() }
            }
            self.message = self.session.lastError
            self.updateIcon()
            if !self.busy && !self.collapsed { self.scheduleAutoHide() }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.prepareEnvironmentRecovery() }
            })
        let workspace = NSWorkspace.shared.notificationCenter
        // Refresh only the allow list; launches and exits keep the user's layout.
        // 허용 목록만 갱신하며, 앱 실행·종료 시 사용자의 구역 배치를 유지합니다.
        observers.append(workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.native, !self.environmentRecoveryPending,
                          !self.environmentSleeping else { return }
                    self.session.refreshRunningBundles(AccessibilityInventory.runningBundles)
                }
            })
        for (name, sleeping) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.systemSleeping = sleeping
                    self.prepareEnvironmentRecovery()
                }
            })
        }
        for (name, sleeping) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.displaysSleeping = sleeping
                    self.prepareEnvironmentRecovery()
                }
            })
        }
        installDragMonitors()
    }

    var installed: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    var engineAvailable: Bool { !native || session.available }

    func refreshDiagnostics() {
        var lines = ["Quiet Bar · \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "앱: \(Bundle.main.bundleURL.path)",
            "AX 승인: \(AccessibilityInventory.authorized) · 엔진: \(engineAvailable)",
            "등록 경로: \(NSWorkspace.shared.urlForApplication(withBundleIdentifier: ownID)?.path ?? "없음")"]
        for (index, screen) in NSScreen.screens.enumerated() {
            lines.append("화면 \(index): \(screen.frame)")
        }
        for (name, item) in [("일반", divider), ("항상", permanent), ("화살표", toggleItem)] {
            guard let button = item?.button, let window = button.window else { lines.append("\(name): 윈도우 없음"); continue }
            lines.append("\(name): 폭 \(item?.length ?? 0) · 아이콘 \(button.image == nil ? "없음" : "표시")")
            lines.append("\(name): 창 \(window.frame) 화면 \(String(describing: window.screen?.frame))")
            lines.append("\(name): 버튼 \(button.bounds) 전역 \(window.convertToScreen(button.convert(button.bounds, to: nil)))")
        }
        if let g = geometry() { lines.append("분류 좌표: 경계 \(g.boundary) 점선 \(String(describing:g.permanent)) 화면 \(g.screen)") }
        else { lines.append("분류 좌표 없음") }
        lines.append(inventorySummary)
        lines.append("자동 배치 반영: \(dragStatus) · 마우스 모니터 \(mouseMonitors.count)개")
        lines.append("환경 복구: \(environmentRecoveryPending) · 시스템 절전 \(systemSleeping) · 화면 절전 \(displaysSleeping)")
        if let layout {
            lines.append("분류: \(layout.sections.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.rawValue)" }.joined(separator: ", "))")
        }
        diagnosticReport = lines.joined(separator: "\n")
    }

    func refreshPermission() {
        authorized = AccessibilityInventory.authorized
        if native && !authorized && (collapsed || session.state == .partial || busy) {
            environmentChanged("손쉬운 사용 권한이 해제되어 전체 표시로 복원했습니다.")
        }
    }

    func preferencesChanged() {
        cancelDragUpdate()
        if !preferences.useFullMenuBar { releaseMenuBarSpace() }
        else if !collapsed && !arranging { claimMenuBarSpace() }
        if lastAlwaysHidden != preferences.alwaysHidden {
            revealAll()
            updatePermanentItem()
            lastAlwaysHidden = preferences.alwaysHidden
        }
        if !preferences.autoHide { timer?.invalidate(); timer = nil }
        else { scheduleAutoHide() }
    }

    func beginArrangement() {
        revealAll()
        arranging = true
    }

    func toggle() {
        cancelDragUpdate()
        if environmentRecoveryPending {
            // Preserve the ordinary arrow action, including always-hidden items.
            // 항상 숨김 구역을 유지하는 일반 화살표 동작을 보존합니다.
            environmentTogglePending.toggle()
            return
        }
        if busy { revealAll(); return }
        if collapsed { expand() } else { collapse() }
    }

    func collapse() {
        guard !environmentSleeping, !environmentRecoveryPending else { return }
        cancelDragUpdate()
        timer?.invalidate()
        refreshPermission()
        guard !busy else { return }
        arranging = false
        if !native { collapseLegacy(); return }
        guard nativeReady() else { return }
        if let layout, session.state == .partial {
            apply(layout, collapsed: true)
            return
        }
        guard let geometry = geometry() else { message = LayoutError.invalidBoundary.localizedDescription; return }
        operation += 1
        let request = operation
        busy = true
        message = nil
        Task { [weak self] in
            let items = await AccessibilityInventory.snapshot()
            guard let self, self.operation == request else { return }
            self.inventorySummary = "AX 항목 \(items.count)개\n" + items.map { "\($0.bundleID): \($0.frame)" }.joined(separator: "\n")
            self.busy = false
            guard self.authorized, let current = self.geometry(),
                  abs(current.boundary.midX - geometry.boundary.midX) < 1,
                  current.permanent == geometry.permanent else {
                self.message = "배치가 바뀌었습니다. 드래그를 마친 뒤 다시 접어 주세요."
                return
            }
            do {
                let layout = try LayoutResolver.resolve(items: items, boundary: current.boundary,
                    permanent: current.permanent, screen: current.screen,
                    leftToRight: NSApp.userInterfaceLayoutDirection == .leftToRight, ownID: self.ownID)
                self.layout = layout
                self.counts = (0...2).map { section in layout.sections.values.filter { $0.rawValue == section }.count }
                if layout.hiddenBundles(collapsed: true).isEmpty {
                    self.message = "숨길 앱이 없습니다. 아이콘을 구분선의 숨김 쪽으로 ⌘-드래그하세요."
                    return
                }
                self.apply(layout, collapsed: true)
            } catch {
                self.message = error.localizedDescription
                self.refreshDiagnostics()
            }
        }
    }

    func expand() {
        guard !environmentSleeping, !environmentRecoveryPending else { return }
        cancelDragUpdate()
        operation += 1
        busy = false
        arranging = false
        if native {
            if preferences.alwaysHidden, let layout { apply(layout, collapsed: false) }
            else { session.revealAll() }
        } else {
            divider.length = 18
            permanent?.length = preferences.alwaysHidden ? collapseLength : 18
            collapsed = false
            setDividersHidden(false)
            updateIcon()
            claimMenuBarSpace()
        }
        scheduleAutoHide()
    }

    func revealAll() {
        cancelEnvironmentRecovery()
        cancelDragUpdate()
        releaseMenuBarSpace()
        operation += 1
        timer?.invalidate()
        timer = nil
        arranging = true
        session.revealAll()
        setDividersHidden(false)
        layout = nil
        legacyGeometry = nil
        divider?.length = 18
        permanent?.length = 18
        collapsed = false
        busy = false
        arranging = true
        updateIcon()
    }

    func windowClosed() {
        windowVisible = false
        // Command-drag applies membership on release. Merely closing the
        // window keeps an untouched arrangement visible until the arrow click.
        // ⌘-드래그한 구역은 키를 놓으면 반영합니다. 배치를 바꾸지 않고 창만 닫았다면
        // 화살표를 누를 때까지 현재 배치를 표시한 상태로 유지합니다.
        if !arranging { scheduleAutoHide() }
    }

    func stop() {
        revealAll()
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors.removeAll()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        for item in [toggleItem, divider, permanent].compactMap({ $0 }) { NSStatusBar.system.removeStatusItem(item) }
    }

    private func apply(_ layout: BarLayout, collapsed: Bool) {
        cancelEnvironmentRecovery()
        session.apply(layout: layout, runningBundles: AccessibilityInventory.runningBundles,
                      ownID: ownID, collapsed: collapsed)
    }

    private func environmentChanged(_ reason: String) { revealAll(); message = reason }

    private var environmentSleeping: Bool { systemSleeping || displaysSleeping }

    private func cancelEnvironmentRecovery(preservingToggle: Bool = false) {
        environmentGeneration += 1
        environmentTask?.cancel()
        environmentTask = nil
        environmentRecoveryPending = false
        if !preservingToggle { environmentTogglePending = false }
    }

    private func prepareEnvironmentRecovery() {
        cancelEnvironmentRecovery(preservingToggle: true)
        environmentRecoveryPending = true
        cancelDragUpdate()
        operation += 1
        timer?.invalidate()
        timer = nil
        legacyGeometry = nil
        if native { session.suspendForEnvironmentChange() }
        // A canceled AX snapshot must not leave the controller busy forever.
        // 취소한 AX 위치 수집 때문에 적용 중 상태가 계속 남지 않게 합니다.
        busy = native && session.state == .applying
        guard !environmentSleeping else { return }
        scheduleEnvironmentRecovery(generation: environmentGeneration, attempt: 0)
    }

    private func scheduleEnvironmentRecovery(generation: Int, attempt: Int) {
        environmentTask?.cancel()
        environmentTask = Task { [weak self] in
            do {
                // Coalesce screen migration notifications before touching the host.
                // 호스트를 갱신하기 전에 연속으로 도착한 화면 전환 알림을 모아 처리합니다.
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000)
            } catch { return }
            guard let self, !Task.isCancelled, generation == self.environmentGeneration,
                  self.environmentRecoveryPending, !self.environmentSleeping else { return }
            self.environmentTask = nil
            self.restoreEnvironment(generation: generation, attempt: attempt)
        }
    }

    private func restoreEnvironment(generation: Int, attempt: Int) {
        if !native {
            if collapsed {
                divider.length = collapseLength
                permanent?.length = 18
            } else {
                divider.length = 18
                if preferences.alwaysHidden, (permanent?.length ?? 18) > 18 {
                    permanent?.length = collapseLength
                }
            }
            finishEnvironmentRecovery(generation: generation)
            return
        }
        refreshPermission()
        guard generation == environmentGeneration, environmentRecoveryPending else { return }
        if session.hasVisibilityPlan && !nativeReady() {
            session.fail(message ?? "화면 환경 변경 후 숨김을 다시 적용할 수 없습니다.")
            return
        }
        session.reapplyAfterEnvironmentChange(AccessibilityInventory.runningBundles) { [weak self] result in
            guard let self, generation == self.environmentGeneration,
                  self.environmentRecoveryPending, !self.environmentSleeping else { return }
            switch result {
            case .success:
                self.finishEnvironmentRecovery(generation: generation)
            case .failure(let error):
                if attempt < 2 {
                    self.scheduleEnvironmentRecovery(generation: generation, attempt: attempt + 1)
                } else {
                    self.session.fail("화면 환경 변경 후 숨김 복구에 실패했습니다: \(error.localizedDescription)")
                }
            }
        }
    }

    private func finishEnvironmentRecovery(generation: Int) {
        guard generation == environmentGeneration else { return }
        let shouldToggle = environmentTogglePending
        environmentTogglePending = false
        environmentRecoveryPending = false
        busy = native && session.state == .applying
        setDividersHidden(collapsed, force: true)
        updateIcon()
        if shouldToggle { toggle() }
        else { scheduleAutoHide() }
    }

    private func nativeReady() -> Bool {
        guard installed else {
            message = "Quiet Bar.app을 응용 프로그램 폴더로 옮긴 뒤 다시 실행해 주세요."
            return false
        }
        guard authorized else { message = "기기 제어 및 데이터 접근을 허용한 뒤 다시 시도해 주세요."; return false }
        guard session.available else { message = "이 macOS에서 숨김 엔진을 사용할 수 없습니다."; return false }
        // Keep the same self-protection check for both manual and drag updates.
        // 앱의 제어 버튼을 보호하기 위해 수동·드래그 갱신에 같은 검사를 적용합니다.
        guard let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ownID),
              registered.resolvingSymlinksInPath().standardizedFileURL == Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL else {
            message = "다른 Quiet Bar 복사본이 등록되어 있습니다. 응용 프로그램 폴더의 복사본만 남기고 다시 실행해 주세요."
            return false
        }
        return true
    }

    private func installDragMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.observeMenuBarDrag(event) }
        }) { mouseMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.observeMenuBarDrag(event) }
            return event
        }) { mouseMonitors.append(monitor) }
    }

    private func observeMenuBarDrag(_ event: NSEvent) {
        guard !environmentRecoveryPending, !environmentSleeping else { dragTracker.cancel(); return }
        let point = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            guard !collapsed, session.state != .applying, !busy || dragSnapshotOperation != nil else {
                dragTracker.cancel()
                return
            }
            let inBar = NSScreen.screens.contains { screen in
                screen.frame.contains(point) && point.y >= screen.frame.maxY - max(28, NSStatusBar.system.thickness)
            }
            let command = event.modifierFlags.contains(.command)
            guard command && inBar else { dragTracker.cancel(); return }
            cancelDragUpdate(preservingPlacement: true)
            timer?.invalidate()
            timer = nil
            dragTracker.began(at: point, command: command, inMenuBar: inBar)
            dragStatus = "⌘-드래그 감지"
        case .leftMouseDragged:
            dragTracker.moved(to: point)
        case .leftMouseUp:
            let wasTracking = dragTracker.isTracking
            if dragTracker.ended(at: point) {
                pendingDragChange = true
                scheduleDragUpdate()
            } else if wasTracking {
                if pendingDragChange { scheduleDragUpdate() }
                else { scheduleAutoHide() }
            }
        default: break
        }
    }

    private func cancelDragUpdate(preservingPlacement: Bool = false) {
        if !preservingPlacement { pendingDragChange = false }
        dragGeneration += 1
        dragTracker.cancel()
        dragUpdateTask?.cancel()
        dragUpdateTask = nil
        if let request = dragSnapshotOperation, operation == request {
            operation += 1
            busy = false
        }
        dragSnapshotOperation = nil
    }

    private func scheduleDragUpdate() {
        cancelDragUpdate(preservingPlacement: true)
        let generation = dragGeneration
        dragStatus = "⌘ 키를 놓으면 자동 반영"
        dragUpdateTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.dragGeneration == generation { self.dragUpdateTask = nil } }
            do {
                // Holding Command permits several consecutive rearrangements.
                // This also avoids collapsing under a still-held mouse button.
                // ⌘ 키를 누른 동안 여러 아이콘을 연속으로 옮길 수 있게 합니다.
                // 마우스 버튼을 누른 상태에서 메뉴 막대가 접히는 일도 막습니다.
                while true {
                    while NSEvent.pressedMouseButtons != 0 || NSEvent.modifierFlags.contains(.command) {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    try await Task.sleep(nanoseconds: 350_000_000)
                    if NSEvent.pressedMouseButtons == 0 && !NSEvent.modifierFlags.contains(.command) { break }
                }
                guard !Task.isCancelled, generation == self.dragGeneration else { return }
                await self.refreshPlacementAfterDrag(generation: generation)
            } catch { /* A manual action or another drag superseded this update.
                       수동 조작 또는 새 드래그가 이 갱신을 대체했습니다. */ }
        }
    }

    private func refreshPlacementAfterDrag(generation: Int, canRetry: Bool = true) async {
        guard generation == dragGeneration, !Task.isCancelled, !collapsed, !busy,
              session.state != .applying else { return }
        if !native {
            arranging = false
            collapseLegacy()
            dragStatus = collapsed ? "드래그 배치 반영 완료" : "배치 확인 필요"
            return
        }
        refreshPermission()
        guard generation == dragGeneration, nativeReady(), let initial = geometry() else { return }
        let previous = layout
        let priorState = session.state
        operation += 1
        let request = operation
        dragSnapshotOperation = request
        busy = true
        dragStatus = "이동한 아이콘 위치 확인 중"
        let items = await AccessibilityInventory.snapshot()
        guard generation == dragGeneration, request == operation, !Task.isCancelled,
              session.state == priorState else { return }
        dragSnapshotOperation = nil
        busy = false
        // Input may have resumed while AX was being read. Keep the current
        // visibility lease and wait for another release/debounce before applying.
        // AX를 읽는 동안 입력이 다시 시작됐을 수 있습니다. 현재 제한 핸들을 유지하고
        // 키와 마우스를 놓은 뒤 안정화 대기 시간이 지나면 다시 적용합니다.
        if NSEvent.pressedMouseButtons != 0 || NSEvent.modifierFlags.contains(.command) {
            scheduleDragUpdate()
            return
        }
        inventorySummary = "AX 항목 \(items.count)개\n" + items.map { "\($0.bundleID): \($0.frame)" }.joined(separator: "\n")
        guard let current = geometry(), current.screen == initial.screen,
              abs(current.boundary.midX - initial.boundary.midX) < 1,
              current.permanent == initial.permanent else {
            if canRetry {
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                await refreshPlacementAfterDrag(generation: generation, canRetry: false)
            } else {
                dragStatus = "배치가 계속 바뀌어 자동 반영 보류"
            }
            return
        }
        do {
            let next: BarLayout
            let ltr = NSApp.userInterfaceLayoutDirection == .leftToRight
            if priorState == .partial, let previous {
                next = try LayoutResolver.refreshingOrdinary(items: items, boundary: current.boundary,
                    screen: current.screen, leftToRight: ltr, ownID: ownID, previous: previous)
            } else {
                next = try LayoutResolver.resolve(items: items, boundary: current.boundary,
                    permanent: current.permanent, screen: current.screen, leftToRight: ltr, ownID: ownID)
            }
            pendingDragChange = false
            layout = next
            counts = (0...2).map { section in next.sections.values.filter { $0.rawValue == section }.count }
            guard previous != next else {
                dragStatus = "숨김 대상 변경 없음"
                scheduleAutoHide()
                return
            }
            arranging = false
            dragStatus = "드래그 배치 반영 완료"
            apply(next, collapsed: true)
        } catch {
            dragStatus = "배치 확인 필요: \(error.localizedDescription)"
            message = error.localizedDescription
        }
    }

    private func makeItem(name: String, symbol: String, tooltip: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: 18)
        item.autosaveName = name
        // No removalAllowed: users can reorder, but cannot accidentally remove their only control.
        // removalAllowed를 켜지 않아 순서만 바꿀 수 있고 유일한 제어 버튼을 실수로 제거하지 못하게 합니다.
        item.behavior = []
        item.isVisible = true
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        item.button?.toolTip = tooltip
        item.button?.target = self
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        return item
    }

    private func updatePermanentItem() {
        if preferences.alwaysHidden, permanent == nil {
            permanent = makeItem(name: "QuietBar.Permanent", symbol: "ellipsis", tooltip: "항상 숨김 구분선 · ⌘-드래그로 위치 조정")
            permanent?.button?.image = dividerImage(dotted: true)
            permanent?.button?.action = #selector(dividerClicked)
            permanent?.button?.setAccessibilityLabel("항상 숨김 구분선")
        } else if !preferences.alwaysHidden, let permanent {
            NSStatusBar.system.removeStatusItem(permanent)
            self.permanent = nil
        }
    }

    private func dividerImage(dotted: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 10, height: 18), flipped: false) { rect in
            NSColor.labelColor.setStroke()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.midX, y: 3))
            path.line(to: NSPoint(x: rect.midX, y: 15))
            path.lineWidth = 1.4
            path.lineCapStyle = .round
            if dotted { path.setLineDash([1, 3], count: 2, phase: 0) }
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    private func setDividersHidden(_ hidden: Bool, force: Bool = false) {
        guard force || dividersHidden != hidden else { return }
        dividersHidden = hidden
        for (item, dotted) in [(divider, false), (permanent, true)] {
            guard let item else { continue }
            item.button?.image = hidden ? nil : dividerImage(dotted: dotted)
            item.button?.isEnabled = !hidden
            item.button?.setAccessibilityHidden(hidden)
            if native {
                // Keep each status item's slot so Cmd-drag order survives.
                // isVisible=false would remove the item and lose its placement.
                // ⌘-드래그한 순서를 보존하도록 각 상태 항목의 자리를 유지합니다.
                // isVisible=false로 설정하면 항목이 제거되어 배치 정보가 사라집니다.
                item.length = hidden ? 0 : 18
            }
        }
    }

    private func updateIcon() {
        toggleItem?.button?.image = NSImage(systemSymbolName: collapsed ? "chevron.left" : "chevron.right",
            accessibilityDescription: collapsed ? "숨김 아이콘 펼치기" : "아이콘 접기")
    }

    private typealias Geometry = StatusItemGeometry

    private func geometry(includePermanent: Bool = true) -> Geometry? {
        guard let window = divider.button?.window,
              let primary = NSScreen.screens.first else { return nil }
        var permanentFrame: CGRect?
        if preferences.alwaysHidden && includePermanent {
            guard let w = permanent?.button?.window else { return nil }
            permanentFrame = w.frame
        }
        return try? StatusItemGeometry.resolve(window: window.frame, permanentWindow: permanentFrame,
            screens: NSScreen.screens.map(\.frame), primaryTop: primary.frame.maxY)
    }

    private var collapseLength: CGFloat { min(10_000, max(500, (NSScreen.screens.map(\.frame.width).max() ?? 2000) * 2)) }

    private func collapseLegacy() {
        // In partial expansion the permanent separator is wide, so reuse its
        // unrestricted position rather than measuring the inflated window.
        // After screen migration a wide permanent item has no usable cached
        // frame. Its physical slot is retained; validate the ordinary boundary.
        // 일반 구역을 펼친 상태에서는 항상 숨김 구분선의 폭이 크므로, 늘어난 창을 측정하는 대신
        // 제한 전의 위치를 재사용합니다. 화면 전환 뒤에는 넓어진 항상 숨김 항목의 유효한 좌표 캐시가
        // 없습니다. 항목의 실제 자리는 유지되므로 일반 구분선의 경계를 검증합니다.
        let candidate = (permanent?.length ?? 18) > 18
            ? (legacyGeometry ?? geometry(includePermanent: false)) : geometry()
        guard let g = candidate, let button = toggleItem.button, let window = button.window else {
            message = LayoutError.invalidBoundary.localizedDescription
            return
        }
        let arrowX = window.convertToScreen(button.convert(button.bounds, to: nil)).midX
        let ltr = NSApp.userInterfaceLayoutDirection == .leftToRight
        guard ltr ? arrowX > g.boundary.midX : arrowX < g.boundary.midX else {
            message = "화살표를 일반 구분선의 표시 쪽으로 ⌘-드래그해 주세요."
            return
        }
        do {
            _ = try LayoutResolver.resolve(items: [], boundary: g.boundary, permanent: g.permanent,
                screen: g.screen, leftToRight: NSApp.userInterfaceLayoutDirection == .leftToRight, ownID: ownID)
        } catch { message = error.localizedDescription; return }
        legacyGeometry = g
        divider.length = collapseLength
        permanent?.length = 18
        collapsed = true
        releaseMenuBarSpace()
        setDividersHidden(true)
        message = nil
        updateIcon()
    }

    private func claimMenuBarSpace() {
        guard preferences.useFullMenuBar, !windowVisible, !ownsMenuBarSpace else { return }
        let front = NSWorkspace.shared.frontmostApplication
        expansionFrontApplication = front?.bundleIdentifier == ownID ? nil : front
        ownsMenuBarSpace = true
        NSApp.activate(ignoringOtherApps: true)
    }

    private func releaseMenuBarSpace() {
        guard ownsMenuBarSpace else { return }
        let previous = expansionFrontApplication
        expansionFrontApplication = nil
        ownsMenuBarSpace = false
        // Respect focus changes the user made while the bar was expanded.
        // 메뉴 막대를 펼친 동안 사용자가 직접 전환한 앱의 포커스를 유지합니다.
        if !windowVisible, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ownID,
           let previous, !previous.isTerminated {
            previous.activate(options: [])
        }
    }

    private func scheduleAutoHide() {
        timer?.invalidate()
        guard preferences.autoHide, !collapsed, !arranging, !windowVisible, !busy,
              !environmentSleeping, !environmentRecoveryPending else { return }
        if native, let layout, layout.hiddenBundles(collapsed: true).isEmpty { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(preferences.delay), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard !self.environmentSleeping, !self.environmentRecoveryPending else { return }
                let pointer = NSEvent.mouseLocation
                let inBar = NSScreen.screens.contains { screen in
                    screen.frame.contains(pointer) && pointer.y >= screen.frame.maxY - max(28, NSStatusBar.system.thickness)
                }
                // Never collapse while the mouse is held or hovering over the menu bar.
                // 마우스를 누르거나 포인터가 메뉴 막대에 있는 동안에는 접지 않습니다.
                if inBar || NSEvent.pressedMouseButtons != 0 || (NSApp.isActive && !self.ownsMenuBarSpace) {
                    self.scheduleAutoHide()
                } else { self.collapse() }
            }
        }
    }

    @objc private func toggleClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { openMenu(on: toggleItem) }
        else if NSEvent.modifierFlags.contains(.option) { beginArrangement(); showPreferences?() }
        else { toggle() }
    }
    @objc private func dividerClicked() { openMenu(on: divider) }

    private func openMenu(on item: NSStatusItem) {
        let menu = NSMenu()
        let title = NSMenuItem(title: "Quiet Bar", action: nil, keyEquivalent: "")
        menu.addItem(title)
        menu.addItem(.separator())
        add("배치 편집 및 설정…", action: #selector(openPreferences), to: menu)
        add("모든 아이콘 복원", action: #selector(restoreClicked), to: menu)
        if NSEvent.modifierFlags.contains(.option) {
            add("진단 정보…", action: #selector(diagnoseClicked), to: menu)
        }
        menu.addItem(.separator())
        add("Quiet Bar 종료", action: #selector(quit), to: menu)
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }
    private func add(_ title: String, action: Selector, to menu: NSMenu) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
    }
    @objc private func diagnoseClicked() {
        refreshDiagnostics()
        let alert = NSAlert()
        alert.messageText = "Quiet Bar 진단 정보"
        alert.addButton(withTitle: "닫기")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 360))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = diagnosticReport
        text.autoresizingMask = [.width]
        scroll.documentView = text
        alert.accessoryView = scroll
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    @objc private func openPreferences() { showPreferences?() }
    @objc private func restoreClicked() { revealAll() }
    @objc private func quit() { NSApp.terminate(nil) }
}
