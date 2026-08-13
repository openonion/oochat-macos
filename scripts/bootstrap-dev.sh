#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
VENV_DIRECTORY="$PROJECT_DIRECTORY/.venv"

# Ordered so a machine that has the container's interpreter (python:3.11-slim)
# builds a virtual environment matching production, while newer interpreters
# still work when 3.11 is absent.
PYTHON_CANDIDATES=(python3.11 python3.12 python3.13 python3)

usage() {
  echo "Usage: ./scripts/bootstrap-dev.sh [--reset]" >&2
}

is_supported_python() {
  [[ "$("$1" -c 'import sys; print("SUPPORTED" if sys.version_info >= (3, 11) else "OLD")' 2>/dev/null)" == "SUPPORTED" ]]
}

if [[ $# -gt 1 || "${1:-}" == "--help" ]]; then
  usage
  exit 2
fi

if [[ -n "${PYTHON_BOOTSTRAP_EXECUTABLE:-}" ]]; then
  if ! command -v "$PYTHON_BOOTSTRAP_EXECUTABLE" >/dev/null 2>&1; then
    echo "error: PYTHON_BOOTSTRAP_EXECUTABLE was not found:" \
      "$PYTHON_BOOTSTRAP_EXECUTABLE" >&2
    exit 2
  fi
  if ! is_supported_python "$PYTHON_BOOTSTRAP_EXECUTABLE"; then
    echo "error: PYTHON_BOOTSTRAP_EXECUTABLE must be Python 3.11 or newer." >&2
    exit 2
  fi
  BOOTSTRAP_PYTHON="$PYTHON_BOOTSTRAP_EXECUTABLE"
else
  BOOTSTRAP_PYTHON=""
  for candidate in "${PYTHON_CANDIDATES[@]}"; do
    if command -v "$candidate" >/dev/null 2>&1 \
      && is_supported_python "$candidate"; then
      BOOTSTRAP_PYTHON="$candidate"
      break
    fi
  done

  if [[ -z "$BOOTSTRAP_PYTHON" ]]; then
    echo "error: Python 3.11 or newer is required but none was found." >&2
    echo "Tried: ${PYTHON_CANDIDATES[*]}" >&2
    echo "Install Python 3.11+, or set PYTHON_BOOTSTRAP_EXECUTABLE to its path." >&2
    exit 2
  fi
fi

if [[ -e "$VENV_DIRECTORY" ]]; then
  if [[ "${1:-}" != "--reset" ]]; then
    echo "error: .venv already exists. Run ./scripts/bootstrap-dev.sh --reset to recreate it." >&2
    exit 2
  fi
  rm -rf "$VENV_DIRECTORY"
fi

echo "Using $BOOTSTRAP_PYTHON ($("$BOOTSTRAP_PYTHON" -V 2>&1))"
"$BOOTSTRAP_PYTHON" -m venv "$VENV_DIRECTORY"
"$VENV_DIRECTORY/bin/python" -m pip install --upgrade pip
"$VENV_DIRECTORY/bin/python" -m pip install -r "$PROJECT_DIRECTORY/requirements-dev.txt"

echo "Development environment ready: $VENV_DIRECTORY"
