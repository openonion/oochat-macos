#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
EXPECTED_RUFF_VERSION="0.16.0"
ACTION="${1:-all}"

usage() {
  echo "Usage: ./scripts/run_lint.sh [all|swift|python]" >&2
}

run_python_lint() {
  local ruff_command
  if [[ -x "$PROJECT_DIRECTORY/.venv/bin/ruff" ]]; then
    ruff_command="$PROJECT_DIRECTORY/.venv/bin/ruff"
  elif command -v ruff >/dev/null 2>&1; then
    ruff_command="$(command -v ruff)"
  else
    echo "error: Ruff is not installed." >&2
    echo "Run: ./scripts/bootstrap-dev.sh --reset" >&2
    return 127
  fi

  local installed_version
  installed_version="$("$ruff_command" --version)"
  if [[ "$installed_version" != "ruff $EXPECTED_RUFF_VERSION" ]]; then
    echo "error: expected Ruff $EXPECTED_RUFF_VERSION, found: $installed_version" >&2
    echo "Run: ./scripts/bootstrap-dev.sh --reset" >&2
    return 1
  fi

  echo "Running Python lint with $installed_version"
  (
    cd "$PROJECT_DIRECTORY"
    "$ruff_command" check .
  )
}

run_swift_lint() {
  if ! command -v swiftlint >/dev/null 2>&1; then
    echo "error: SwiftLint is not installed." >&2
    echo "Run: brew bundle --file Brewfile" >&2
    return 127
  fi

  local arguments=(lint --config "$PROJECT_DIRECTORY/.swiftlint.yml" --no-cache)
  if [[ -n "${SWIFTLINT_REPORTER:-}" ]]; then
    arguments+=(--reporter "$SWIFTLINT_REPORTER")
  fi

  echo "Running Swift lint with $(swiftlint version)"
  (
    cd "$PROJECT_DIRECTORY"
    swiftlint "${arguments[@]}"
  )
}

if [[ $# -gt 1 ]]; then
  usage
  exit 2
fi

case "$ACTION" in
  all)
    run_python_lint
    run_swift_lint
    ;;
  swift)
    run_swift_lint
    ;;
  python)
    run_python_lint
    ;;
  *)
    usage
    exit 2
    ;;
esac
