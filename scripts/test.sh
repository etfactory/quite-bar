#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="${QUIETBAR_TEST_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/quietbar-tests.XXXXXX")}"
mkdir -p "$scratch/cache" "$scratch/modules"
set --
if [[ "${QUIETBAR_COMPILER_NO_SANDBOX:-0}" == "1" ]]; then set -- --disable-sandbox; fi
CLANG_MODULE_CACHE_PATH="$scratch/modules" SWIFTPM_MODULECACHE_OVERRIDE="$scratch/modules" \
    swift test --package-path "$project_root" --scratch-path "$scratch/build" \
    --cache-path "$scratch/cache" "$@"
