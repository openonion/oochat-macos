#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
ROBUSTNESS_PYTHON="${ROBUSTNESS_PYTHON:-python3}"

cd "$PROJECT_DIRECTORY"

"$ROBUSTNESS_PYTHON" -m unittest \
  tests.test_deployment_robustness \
  tests.test_host_agent.BashWorkspaceTests.test_resolve_workspace_path_rejects_symlink_escape \
  -v

"$ROBUSTNESS_PYTHON" offline_eval.py --validate

if ! command -v docker >/dev/null 2>&1; then
  echo "error: Docker is required for deployment robustness validation." >&2
  exit 1
fi
docker compose --env-file .env.example config --no-env-resolution --quiet

if command -v xcodebuild >/dev/null 2>&1; then
  DERIVED_DATA_PATH="${TMPDIR:-/tmp}/ConnectOnionRobustnessDerivedData-${UID}"
  COPYFILE_DISABLE=1 xcodebuild test \
    -project ConnectOnionMacClient.xcodeproj \
    -scheme ConnectOnionMacClient \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -only-testing:ConnectOnionMacClientTests/DockerRuntimeRobustnessTests \
    CODE_SIGNING_ALLOWED=NO
else
  echo "Xcode is unavailable; Swift robustness tests run in the macOS CI job."
fi
