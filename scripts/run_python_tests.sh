#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"

is_supported_python() {
  [[ "$("$1" -c 'import sys; print("SUPPORTED" if sys.version_info >= (3, 11) else "OLD")' 2>/dev/null)" == "SUPPORTED" ]]
}

if [[ -n "${PYTHON_TEST_EXECUTABLE:-}" ]]; then
  if ! is_supported_python "$PYTHON_TEST_EXECUTABLE"; then
    echo "error: PYTHON_TEST_EXECUTABLE must point to Python 3.11 or newer." >&2
    exit 2
  fi
  TEST_PYTHON="$PYTHON_TEST_EXECUTABLE"
elif [[ -x "$PROJECT_DIRECTORY/.venv/bin/python" ]] \
  && is_supported_python "$PROJECT_DIRECTORY/.venv/bin/python"; then
  TEST_PYTHON="$PROJECT_DIRECTORY/.venv/bin/python"
else
  TEST_PYTHON=""
  for candidate in python3.11 python3; do
    if command -v "$candidate" >/dev/null 2>&1 \
      && is_supported_python "$candidate"; then
      TEST_PYTHON="$candidate"
      break
    fi
  done

  if [[ -z "$TEST_PYTHON" ]]; then
    echo "error: Python 3.11 or newer is required for the test pipeline." >&2
    echo "Run: ./scripts/bootstrap-dev.sh --reset" >&2
    exit 2
  fi
fi

cd "$PROJECT_DIRECTORY"

if ! "$TEST_PYTHON" -c 'import coverage, connectonion' >/dev/null 2>&1; then
  echo "error: Python test dependencies are not installed for $TEST_PYTHON." >&2
  echo "Run: ./scripts/bootstrap-dev.sh --reset" >&2
  exit 2
fi

"$TEST_PYTHON" -m coverage erase
"$TEST_PYTHON" -m coverage run -m unittest discover -s tests -p "test_*.py" -v
"$TEST_PYTHON" -m coverage report --fail-under=85
"$TEST_PYTHON" offline_eval.py --validate
