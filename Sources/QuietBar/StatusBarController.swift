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
                // A failed owner refresh must also invalidate older AX reads.
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
                Task { @MainActor in self?.environmentChanged("디스플레이가 바뀌어 전체 표시로 복원했습니다. 배치를 확인한 뒤 다시 접어 주세요.") }
            })
        let workspace = NSWorkspace.shared.notificationCenter
        // Refresh only the allow list; launches and exits keep the user's layout.
        observers.append(workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.native else { return }
                    self.session.refreshRunningBundles(AccessibilityInventory.runningBundles)
                }
            })
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.revealAll() }
        })
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
        if busy { revealAll(); return }
        if collapsed { expand() } else { collapse() }
    }

    func collapse() {
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
        session.apply(layout: layout, runningBundles: AccessibilityInventory.runningBundles,
                      ownID: ownID, collapsed: collapsed)
    }

    private func environmentChanged(_ reason: String) { revealAll(); message = reason }

    private func nativeReady() -> Bool {
        guard installed else {
            message = "Quiet Bar.app을 응용 프로그램 폴더로 옮긴 뒤 다시 실행해 주세요."
            return false
        }
        guard authorized else { message = "기기 제어 및 데이터 접근을 허용한 뒤 다시 시도해 주세요."; return false }
        guard session.available else { message = "이 macOS에서 숨김 엔진을 사용할 수 없습니다."; return false }
        // Keep the same self-protection check for both manual and drag updates.
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
                while true {
                    while NSEvent.pressedMouseButtons != 0 || NSEvent.modifierFlags.contains(.command) {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    try await Task.sleep(nanoseconds: 350_000_000)
                    if NSEvent.pressedMouseButtons == 0 && !NSEvent.modifierFlags.contains(.command) { break }
                }
                guard !Task.isCancelled, generation == self.dragGeneration else { return }
                await self.refreshPlacementAfterDrag(generation: generation)
            } catch { /* A manual action or another drag superseded this update. */ }
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

    private func setDividersHidden(_ hidden: Bool) {
        guard dividersHidden != hidden else { return }
        dividersHidden = hidden
        for (item, dotted) in [(divider, false), (permanent, true)] {
            guard let item else { continue }
            item.button?.image = hidden ? nil : dividerImage(dotted: dotted)
            item.button?.isEnabled = !hidden
            item.button?.setAccessibilityHidden(hidden)
            if native {
                // Keep each status item's slot so Cmd-drag order survives.
                // isVisible=false would remove the item and lose its placement.
                item.length = hidden ? 0 : 18
            }
        }
    }

    private func updateIcon() {
        toggleItem?.button?.image = NSImage(systemSymbolName: collapsed ? "chevron.left" : "chevron.right",
            accessibilityDescription: collapsed ? "숨김 아이콘 펼치기" : "아이콘 접기")
    }

    private typealias Geometry = StatusItemGeometry

    private func geometry() -> Geometry? {
        guard let window = divider.button?.window,
              let primary = NSScreen.screens.first else { return nil }
        var permanentFrame: CGRect?
        if preferences.alwaysHidden {
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
        let candidate = (permanent?.length ?? 18) > 18 ? legacyGeometry : geometry()
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
        if !windowVisible, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ownID,
           let previous, !previous.isTerminated {
            previous.activate(options: [])
        }
    }

    private func scheduleAutoHide() {
        timer?.invalidate()
        guard preferences.autoHide, !collapsed, !arranging, !windowVisible, !busy else { return }
        if native, let layout, layout.hiddenBundles(collapsed: true).isEmpty { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(preferences.delay), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let pointer = NSEvent.mouseLocation
                let inBar = NSScreen.screens.contains { screen in
                    screen.frame.contains(pointer) && pointer.y >= screen.frame.maxY - max(28, NSStatusBar.system.thickness)
                }
                // Never collapse while the mouse is held or hovering over the menu bar.
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
