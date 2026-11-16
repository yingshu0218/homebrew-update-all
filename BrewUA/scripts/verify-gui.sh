#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_DIR/.." && pwd)"
DERIVED_DATA_PATH="${TMPDIR:-/tmp}/brewua-gui-derived"
MODE="${1:-all}"

cd "$REPO_ROOT"
command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen is required" >&2; exit 2; }
xcodegen generate --spec "$PROJECT_DIR/project.yml" --project "$PROJECT_DIR"

run_tests() {
  xcodebuild \
    -project "$PROJECT_DIR/BrewUA.xcodeproj" \
    -scheme BrewUA \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    test
}

run_tsan() {
  xcodebuild \
    -project "$PROJECT_DIR/BrewUA.xcodeproj" \
    -scheme BrewUA \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA_PATH-tsan" \
    -enableThreadSanitizer YES \
    -only-testing:BrewUATests/ProcessTests/testPollingMonitorSerializesStreamingAndTimerSamples \
    test
}

typecheck_render_tool() {
  local sdk_path
  sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
  local sources=()
  while IFS= read -r source; do
    [[ "$source" == "$PROJECT_DIR/Sources/App/BrewUAApp.swift" ]] || sources+=("$source")
  done < <(find "$PROJECT_DIR/Sources" -name '*.swift' -print | sort)
  xcrun --sdk macosx swiftc \
    -typecheck \
    -parse-as-library \
    -module-name BrewUARenderTool \
    -target "$(uname -m)-apple-macos14.0" \
    -sdk "$sdk_path" \
    -framework AppKit \
    -framework SwiftUI \
    "${sources[@]}" \
    "$PROJECT_DIR/Tools/RenderTool.swift"
}

case "$MODE" in
  test) run_tests ;;
  tsan) run_tsan ;;
  render) typecheck_render_tool ;;
  all)
    run_tests
    run_tsan
    typecheck_render_tool
    ;;
  *) echo "usage: $0 [test|tsan|render|all]" >&2; exit 2 ;;
esac
