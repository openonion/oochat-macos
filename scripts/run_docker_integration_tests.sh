#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
INTEGRATION_PYTHON="${DOCKER_INTEGRATION_PYTHON:-python3}"
CONNECTONION_IMAGE="${CONNECTONION_IMAGE:-connectonion-agent:test}"

cd "$PROJECT_DIRECTORY"

if ! docker image inspect "$CONNECTONION_IMAGE" >/dev/null 2>&1; then
  echo "error: Docker image '$CONNECTONION_IMAGE' does not exist." >&2
  echo "Run: docker build --tag '$CONNECTONION_IMAGE' ." >&2
  exit 1
fi

CONNECTONION_IMAGE="$CONNECTONION_IMAGE" \
  "$INTEGRATION_PYTHON" tests/docker_integration.py
