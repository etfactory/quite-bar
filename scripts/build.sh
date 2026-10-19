#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${QUIETBAR_BUILD_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/quietbar-build.XXXXXX")}"
config="${CONFIGURATION:-Release}"
compiler_flags='$(inherited)'
# Optional only for environments that prohibit nested compiler-plugin sandboxes.
if [[ "${QUIETBAR_COMPILER_NO_SANDBOX:-0}" == "1" ]]; then
    compiler_flags="$compiler_flags -disable-sandbox"
fi
xcodebuild -project "$project_root/QuietBar.xcodeproj" -scheme QuietBar \
    -configuration "$config" -derivedDataPath "$build_root" \
    CODE_SIGNING_ALLOWED=NO "OTHER_SWIFT_FLAGS=$compiler_flags" build
app="$build_root/Build/Products/$config/Quiet Bar.app"
# Finder metadata on generated bundles can prevent code signing in synced folders.
xattr -dr com.apple.FinderInfo "$app" 2>/dev/null || true
codesign --force --deep --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
mkdir -p "$project_root/build"
if [[ -e "$project_root/build/Quiet Bar.app" ]]; then
    echo "기존 build/Quiet Bar.app을 직접 이동하거나 삭제한 뒤 다시 실행하세요." >&2
    echo "새 빌드는 $app 에 있습니다." >&2
    exit 1
fi
ditto --norsrc --noextattr "$app" "$project_root/build/Quiet Bar.app"
xattr -dr com.apple.FinderInfo "$project_root/build/Quiet Bar.app" 2>/dev/null || true
codesign --verify --deep --strict "$project_root/build/Quiet Bar.app"
echo "앱: $project_root/build/Quiet Bar.app"
echo "응용 프로그램 폴더로 옮긴 다음 실행하세요."
