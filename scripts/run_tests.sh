#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
cd "$PROJECT_DIRECTORY"

"$SCRIPT_DIRECTORY/run_python_tests.sh"

DERIVED_DATA_PATH="${TMPDIR:-/tmp}/ConnectOnionMacClientDerivedData-${UID}"
RESULT_BUNDLE_PATH="${TMPDIR:-/tmp}/ConnectOnionMacClient-${UID}.xcresult"

# xcodebuild refuses to overwrite an existing result bundle.
rm -rf "$RESULT_BUNDLE_PATH"

COPYFILE_DISABLE=1 xcodebuild test \
  -project ConnectOnionMacClient.xcodeproj \
  -scheme ConnectOnionMacClient \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -enableCodeCoverage YES \
  -resultBundlePath "$RESULT_BUNDLE_PATH"

echo
echo "Swift code coverage by target:"
xcrun xccov view --report --only-targets "$RESULT_BUNDLE_PATH"
