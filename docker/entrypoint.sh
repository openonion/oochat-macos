#!/bin/sh
set -eu

# Authentication itself must be able to run before credentials exist.
if [ "${1:-}" = "co" ] && [ "${2:-}" = "auth" ]; then
  exec "$@"
fi

# The hosted Agent stores configuration in the persistent identity directory
# and session records below its workspace. Keep completed sessions long enough
# to behave as chat history while preserving an explicit user setting.
if [ "${1:-}" = "python" ] && [ "${2:-}" = "/app/host_agent.py" ]; then
  co_directory="${CONNECTONION_CO_DIR:-/home/appuser/.co}"
  host_configuration="$co_directory/host.yaml"
  mkdir -p "$co_directory"
  if [ ! -e "$host_configuration" ]; then
    printf '%s\n' 'result_ttl: 315360000' > "$host_configuration"
  elif ! grep -Eq '^[[:space:]]*result_ttl[[:space:]]*:' "$host_configuration"; then
    printf '\n%s\n' 'result_ttl: 315360000' >> "$host_configuration"
  fi
fi

if [ "${CONNECTONION_ALLOW_MISSING_CREDENTIALS:-0}" = "1" ]; then
  exec "$@"
fi

has_environment_credential=0
for credential_name in \
  OPENONION_API_KEY \
  OPENAI_API_KEY \
  ANTHROPIC_API_KEY \
  GEMINI_API_KEY \
  GOOGLE_API_KEY \
  MISTRAL_API_KEY \
  GROQ_API_KEY \
  OPENROUTER_API_KEY \
  XAI_API_KEY
do
  credential_value="$(printenv "$credential_name" 2>/dev/null || true)"
  if [ -n "$credential_value" ]; then
    has_environment_credential=1
    break
  fi
done

credentials_file="${CONNECTONION_CO_DIR:-/home/appuser/.co}/keys.env"
has_persisted_credential=0
if [ -r "$credentials_file" ] && grep -Eq \
  '^[[:space:]]*(OPENONION_API_KEY|OPENAI_API_KEY|ANTHROPIC_API_KEY|GEMINI_API_KEY|GOOGLE_API_KEY|MISTRAL_API_KEY|GROQ_API_KEY|OPENROUTER_API_KEY|XAI_API_KEY)[[:space:]]*=[[:space:]]*[^[:space:]#]+' \
  "$credentials_file"
then
  has_persisted_credential=1
fi

if [ "$has_environment_credential" -ne 1 ] && [ "$has_persisted_credential" -ne 1 ]; then
  echo "error: no model credentials configured; run 'co auth' or set OPENONION_API_KEY or a supported provider API key." >&2
  exit 78
fi

exec "$@"
