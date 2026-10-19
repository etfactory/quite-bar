# 빌드·실행·서명

## 요구 사항

- macOS 13 이상. macOS 27 이상에서는 별도의 가시성 제한 엔진을 선택합니다.
- Swift 6.0 이상을 제공하는 Xcode. 검증 환경은 Xcode 27.0 / Swift 6.4입니다.
- 외부 의존성 없음. AppKit, SwiftUI, ApplicationServices, Carbon, ServiceManagement만 사용합니다.
- 앱 언어 모드는 Swift 5, 코어 패키지 언어 모드는 Swift 6입니다. 코어의 비동기 상태는 MainActor로 격리했습니다.

## 로컬 앱 생성

저장소를 내려받은 디렉터리에서 실행합니다.

```bash
./scripts/build.sh
```

스크립트는 임시 디렉터리에 Release 앱을 빌드하고, 로컬 ad-hoc 서명을 적용·검증한 뒤 `build/Quiet Bar.app`에 복사합니다. 기존 앱을 덮어쓰지 않습니다. 재빌드할 때 기존 `build/Quiet Bar.app`을 이동하거나 직접 삭제하세요. 소스나 설정 파일은 삭제하지 않습니다.

```bash
# Debug가 필요할 때
CONFIGURATION=Debug ./scripts/build.sh

# 빌드 캐시를 재사용할 때
QUIETBAR_BUILD_DIR=/tmp/quietbar-development ./scripts/build.sh
```

Documents의 파일 공급자가 복사 직후 `FinderInfo`를 다시 붙이는 환경에서는 `build/` 복사본의 서명 검증이 실패할 수 있습니다. 이때 빌드 로그에 있는 임시 경로의 서명된 앱을 `ditto --norsrc --noextattr`로 `/Applications`에 복사한 뒤 설치본의 서명을 검증하세요.

생성한 앱을 `/Applications` 또는 `~/Applications`에 옮겨 실행합니다. 현재 실행 경로와 LaunchServices의 번들 해석 경로가 같은지 확인한 다음에만 네이티브 숨김을 적용합니다. Xcode 빌드 산출물에서는 설정 UI를 확인할 수 있지만 macOS 27 실제 숨김은 설치 경로 확인에 막힙니다.

## Xcode

`QuietBar.xcodeproj`를 열고 `QuietBar` 스킴에서 `My Mac`을 선택합니다. 프로젝트는 Debug와 Release, 공유 스킴을 포함합니다. 기본 서명은 로컬 개발용 ad-hoc입니다. 배포용으로 바꿀 때는 Signing & Capabilities에서 본인의 팀과 인증서를 지정하세요.

App Sandbox는 끈 상태입니다. 켜면 macOS 27에서 필요한 다른 앱의 AX 정보 읽기가 막힙니다. 문서화되지 않은 시스템 프레임워크는 링크 단계에서 연결하지 않고 런타임에 선택적으로 로드합니다.

## 테스트

```bash
./scripts/test.sh
```

코어만 Swift Package로 빌드합니다. 실제 메뉴 막대를 변경하거나 권한을 요청하지 않습니다. 테스트 빌드·캐시도 기본적으로 임시 디렉터리를 사용해 Documents의 파일 동기화 메타데이터가 서명에 간섭하는 상황을 줄입니다.

## 제한된 실행 환경

중첩된 컴파일러 플러그인 sandbox 실행을 허용하지 않는 개발 환경에서는 SwiftUI `@State` 매크로가 `sandbox_apply: Operation not permitted`로 실패할 수 있습니다. 해당 환경에서만 다음 옵션을 사용합니다. 앱 권한이나 TCC 설정을 바꾸는 옵션은 아닙니다.

```bash
QUIETBAR_COMPILER_NO_SANDBOX=1 ./scripts/build.sh
QUIETBAR_COMPILER_NO_SANDBOX=1 ./scripts/test.sh
```

기본 명령으로 실패하는 경우에만 이 옵션을 사용하세요.

## 아이콘

`THIRD_PARTY_NOTICES.md`는 앱 번들의 Resources에도 복사됩니다. 배포할 때 기존 저작권 및 라이선스 고지를 함께 포함합니다.

`Resources/AppIcon.icns`는 포함되어 있습니다. AppKit 벡터 드로잉으로 재생성할 수 있습니다.

```bash
xcrun swift scripts/make-icon.swift Resources
```

## 배포 범위

제공 빌드 스크립트는 로컬 ad-hoc 서명을 사용하며 Developer ID 서명이나 공증을 수행하지 않습니다. 배포용 앱의 Developer ID 서명과 Apple 공증은 별도 절차로 진행해야 합니다. 문서화되지 않은 시스템 인터페이스 사용 때문에 현재 구현은 Mac App Store 제출용이 아닙니다. 자동 업데이터와 배포 파이프라인은 포함하지 않습니다.
