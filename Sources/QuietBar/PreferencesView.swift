import SwiftUI
import Carbon

struct PreferencesView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var controller: StatusBarController
    @ObservedObject var login: LoginService
    var recordingChanged: (Bool) -> Void
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("설정 화면", selection: $tab) {
                Text("일반").tag(0)
                Text("정보").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 152)
            .padding(.top, 9)
            .padding(.bottom, 15)

            if tab == 0 {
                arrangement
                general
            } else {
                about
            }
        }
        .frame(width: 752, height: 632)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var arrangement: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                zone(symbols: ["drop", "cup.and.saucer", "gamecontroller"], title: "항상 숨김")
                    .opacity(preferences.alwaysHidden ? 1 : 0.3)
                sectionBoundary(dotted: true)
                    .opacity(preferences.alwaysHidden ? 1 : 0.3)
                zone(symbols: ["wifi", "magnifyingglass"], title: "숨김")
                sectionBoundary(dotted: false)
                zone(symbols: ["chevron.right", "switch.2", "battery.100"], title: "항상 표시")
            }
            .padding(.horizontal, 43)
            .padding(.top, 19)

            Spacer(minLength: 22)

            Text("메뉴 막대에서 ⌘ 키를 누른 채 아이콘을 구분선 안팎으로 옮기세요.\n⌘ 키를 놓으면 숨김 구역에 자동으로 반영됩니다.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.bottom, 24)
        }
        .frame(height: 244)
        .background(Color.primary.opacity(0.045))
    }

    private func zone(symbols: [String], title: String) -> some View {
        VStack(spacing: 38) {
            HStack(spacing: 17) {
                ForEach(symbols, id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .regular))
                        .frame(width: 22, height: 24)
                }
            }
            Text(title)
                .font(.system(size: 25, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(.secondary)
    }

    private func sectionBoundary(dotted: Bool) -> some View {
        VStack(spacing: 27) {
            Group {
                if dotted {
                    Image(systemName: "ellipsis")
                        .rotationEffect(.degrees(90))
                } else {
                    Text("│")
                }
            }
            .font(.system(size: 19))
            .frame(height: 24)

            VStack(spacing: -3) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 19, weight: .light))
                Rectangle().frame(width: 1.3, height: 43)
            }
        }
        .foregroundStyle(.tertiary)
        .frame(width: 24)
    }

    private var general: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                Text("설정").font(.system(size: 27, weight: .semibold))

                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 18) {
                        Toggle("로그인 시 Quiet Bar 실행", isOn: Binding(
                            get: { login.enabled },
                            set: { login.setEnabled($0) }
                        ))
                        Toggle("시작할 때 설정 표시", isOn: $preferences.showOnLaunch)
                        Toggle("펼칠 때 메뉴 막대 전체 사용", isOn: $preferences.useFullMenuBar)
                        Toggle("항상 숨김 구역 사용", isOn: $preferences.alwaysHidden)
                            .help("점선 구분선 안쪽의 아이콘은 메뉴 막대를 펼쳐도 숨겨 둡니다.")
                        HStack(spacing: 10) {
                            Toggle("자동으로 다시 숨기기", isOn: $preferences.autoHide)
                            Picker("자동 숨김 대기 시간", selection: $preferences.delay) {
                                ForEach([5, 10, 15, 30, 60], id: \.self) { seconds in
                                    Text("\(seconds)초 후").tag(seconds)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 95)
                            .disabled(!preferences.autoHide)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 15) {
                        Text("전역 단축키")
                            .font(.system(size: 15, weight: .semibold))
                        ShortcutRecorder(preferences: preferences, recordingChanged: recordingChanged)
                    }
                    .frame(width: 210)
                }

                if let requirement = permissionRequirement {
                    HStack(spacing: 10) {
                        Text(requirement)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        if !controller.installed {
                            Button("앱 위치 보기") {
                                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                            }
                        } else if !controller.authorized {
                            Button("권한 설정 열기") { AccessibilityInventory.requestPermission() }
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                } else if let error = actionError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if login.needsApproval {
                    HStack {
                        Text("로그인 항목을 승인해 주세요.")
                        Spacer()
                        Button("설정 열기") { login.openSettings() }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 24)
            .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var permissionRequirement: String? {
        guard controller.native else { return nil }
        if !controller.installed { return "Quiet Bar를 응용 프로그램 폴더에서 실행해 주세요." }
        if !controller.authorized { return "메뉴 막대를 정리하려면 기기 제어 및 데이터 접근을 허용해 주세요." }
        if !controller.engineAvailable { return "이 macOS에서는 메뉴 막대를 숨길 수 없습니다." }
        return nil
    }

    private var actionError: String? {
        if let error = login.error ?? controller.shortcutError { return error }
        // Restoration notices belong to the app's status, rather than this compact settings view.
        guard let message = controller.message,
              !message.contains("전체 표시로 복원했습니다.") else { return nil }
        return message
    }

    private var about: some View {
        VStack(spacing: 0) {
            HStack(spacing: 33) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 152, height: 152)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quiet Bar")
                        .font(.system(size: 43, weight: .semibold))
                    Text("메뉴 막대 정리")
                        .font(.system(size: 25))
                        .foregroundStyle(.secondary)
                    Text(version)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .background(Color.primary.opacity(0.045))

            VStack(alignment: .leading, spacing: 27) {
                contact("etfactory.dev", systemImage: "safari", url: "https://etfactory.dev")
                contact("etfactory", systemImage: "chevron.left.forwardslash.chevron.right", url: "https://github.com/etfactory")
                contact("factory@etfactory.dev", systemImage: "envelope.fill", url: "mailto:factory@etfactory.dev")
            }
            .padding(.top, 34)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "개발 버전"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "버전 \(version) (\($0))" } ?? "버전 \(version)"
    }

    private func contact(_ title: String, systemImage: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 17) {
                Image(systemName: systemImage)
                    .font(.system(size: 27, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 31)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(.primary)
            }
            .frame(width: 294, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ShortcutRecorder: View {
    @ObservedObject var preferences: Preferences
    var recordingChanged: (Bool) -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint = ""

    var body: some View {
        HStack(spacing: 5) {
            Button(buttonTitle) {
                if recording { finish() } else { start() }
            }
            .font(.system(size: 12, weight: .medium))
            .frame(minWidth: 127)
            .help("클릭해 단축키 입력 · Esc로 취소 · ⌘, ⌃, ⌥ 중 하나 필요")

            Button {
                finish()
                preferences.shortcutEnabled = false
            } label: {
                Image(systemName: "delete.left")
                    .font(.system(size: 13))
            }
            .help("단축키 지우기")
            .accessibilityLabel("단축키 지우기")
            .disabled(!preferences.shortcutEnabled && !recording)
        }
        .padding(9)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .onDisappear { finish() }
    }

    private var buttonTitle: String {
        if recording { return hint.isEmpty ? "키 조합 입력…" : hint }
        return preferences.shortcutEnabled ? preferences.shortcutLabel : "단축키 설정"
    }

    private func start() {
        recording = true
        hint = ""
        recordingChanged(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { finish(); return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.intersection([.command, .control, .option]).isEmpty else {
                hint = "⌘ / ⌃ / ⌥ 필요"
                return nil
            }
            var carbon: UInt32 = 0
            var label = ""
            if flags.contains(.control) { carbon |= UInt32(controlKey); label += "⌃" }
            if flags.contains(.option) { carbon |= UInt32(optionKey); label += "⌥" }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey); label += "⇧" }
            if flags.contains(.command) { carbon |= UInt32(cmdKey); label += "⌘" }
            let special: [UInt16: String] = [49: "스페이스", 36: "↩", 48: "⇥", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑"]
            label += special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "키 \(event.keyCode)"
            preferences.setShortcut(code: UInt32(event.keyCode), modifiers: carbon, label: label)
            finish()
            return nil
        }
    }

    private func finish() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard recording else { return }
        recording = false
        recordingChanged(false)
    }
}
