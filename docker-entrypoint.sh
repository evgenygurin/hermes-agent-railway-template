#!/bin/sh
set -eu

dashboard_username="${HERMES_DASHBOARD_BASIC_AUTH_USERNAME:-${ADMIN_USERNAME:-admin}}"
dashboard_password="${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD:-${ADMIN_PASSWORD:-}}"

if [ -z "$dashboard_password" ]; then
    dashboard_password="$(python -c 'import secrets; print(secrets.token_urlsafe(16))')"
    echo "Generated admin password: $dashboard_password"
fi

dashboard_secret="${HERMES_DASHBOARD_BASIC_AUTH_SECRET:-}"
if [ -z "$dashboard_secret" ]; then
    dashboard_secret="$(
        ADMIN_PASSWORD="$dashboard_password" python -c \
            'import base64, hashlib, os; print(base64.b64encode(hashlib.sha256(("hermes-dashboard-session:" + os.environ["ADMIN_PASSWORD"]).encode()).digest()).decode())'
    )"
fi

export HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-${PORT:-8080}}"
export HERMES_DASHBOARD_BASIC_AUTH_USERNAME="$dashboard_username"
export HERMES_DASHBOARD_BASIC_AUTH_PASSWORD="$dashboard_password"
export HERMES_DASHBOARD_BASIC_AUTH_SECRET="$dashboard_secret"

# Supermemory is embedded in the same Hermes container.
export SUPERMEMORY_DATA_DIR="${SUPERMEMORY_DATA_DIR:-/data/.supermemory}"
export SUPERMEMORY_INSTALL_DIR="${SUPERMEMORY_INSTALL_DIR:-/data/.supermemory-runtime}"
export SUPERMEMORY_BIN_DIR="${SUPERMEMORY_BIN_DIR:-/data/.supermemory-bin}"
export SUPERMEMORY_PORT="${SUPERMEMORY_PORT:-6767}"
mkdir -p "$SUPERMEMORY_DATA_DIR" "$SUPERMEMORY_INSTALL_DIR" "$SUPERMEMORY_BIN_DIR"

# Install the native Supermemory server inside the Hermes container on the
# first boot. The binary and its download cache live on the persistent volume.
if [ ! -x "$SUPERMEMORY_BIN_DIR/supermemory-server" ]; then
    echo "Installing self-hosted Supermemory server into the Hermes container..."
    OPENAI_API_KEY="${OPENROUTER_API_KEY:-}" \
    SUPERMEMORY_INSTALL_DIR="$SUPERMEMORY_INSTALL_DIR" \
    SUPERMEMORY_BIN_DIR="$SUPERMEMORY_BIN_DIR" \
    SUPERMEMORY_NO_START=1 \
    SUPERMEMORY_NO_PROMPT=1 \
    curl -fsSL https://supermemory.ai/install | bash -s -- 0.0.8
fi

# Keep the server private to the container; Hermes talks to it over loopback.
rm -f /data/.supermemory.pid
printf '%s\n' "Starting self-hosted Supermemory on 127.0.0.1:${SUPERMEMORY_PORT}"

OPENAI_API_KEY="${OPENROUTER_API_KEY:-}" \
OPENAI_BASE_URL="${SUPERMEMORY_OPENAI_BASE_URL:-https://openrouter.ai/api/v1}" \
OPENAI_MODEL="${SUPERMEMORY_OPENAI_MODEL:-openrouter/free}" \
SUPERMEMORY_DATA_DIR="$SUPERMEMORY_DATA_DIR" \
SUPERMEMORY_PORT="$SUPERMEMORY_PORT" \
SUPERMEMORY_DISABLE_TELEMETRY="${SUPERMEMORY_DISABLE_TELEMETRY:-1}" \
"$SUPERMEMORY_INSTALL_DIR/bin/supermemory-server" >/data/supermemory.log 2>&1 &
echo $! >/data/.supermemory.pid

SM_READY=0
for _ in $(seq 1 90); do
    if curl -fsS "http://127.0.0.1:${SUPERMEMORY_PORT}/v3/health" >/dev/null 2>&1 \
        || curl -fsS "http://127.0.0.1:${SUPERMEMORY_PORT}/health" >/dev/null 2>&1; then
        SM_READY=1
        break
    fi
    if ! kill -0 "$(cat /data/.supermemory.pid 2>/dev/null)" 2>/dev/null; then
        echo "Supermemory failed to start:" >&2
        cat /data/supermemory.log >&2 || true
        exit 1
    fi
    sleep 1
done

if [ "$SM_READY" -ne 1 ]; then
    echo "Supermemory did not become ready within 90s:" >&2
    cat /data/supermemory.log >&2 || true
    exit 1
fi

# First boot prints the bearer key; reuse that key on every restart.
# The auth secret itself remains persisted under SUPERMEMORY_DATA_DIR.
if [ -z "${SUPERMEMORY_API_KEY:-}" ]; then
    sm_key="$(grep -oE 'sm_[A-Za-z0-9_-]{20,}' /data/supermemory.log 2>/dev/null | head -1 || true)"
    if [ -n "$sm_key" ]; then
        export SUPERMEMORY_API_KEY="$sm_key"
    fi
fi

if [ -z "${SUPERMEMORY_API_KEY:-}" ]; then
    echo "Supermemory started but no sm_* API key was found in its startup output." >&2
    cat /data/supermemory.log >&2 || true
    exit 1
fi

export SUPERMEMORY_BASE_URL="http://127.0.0.1:${SUPERMEMORY_PORT}"
mkdir -p "$HERMES_HOME"

cat > "$HERMES_HOME/supermemory.json" <<JSON
{
  "base_url": "${SUPERMEMORY_BASE_URL}",
  "container_tag": "hermes",
  "auto_recall": true,
  "auto_capture": true,
  "max_recall_results": 10,
  "profile_frequency": 50,
  "capture_mode": "all",
  "search_mode": "hybrid",
  "api_timeout": 5.0
}
JSON

# Hermes ships the Supermemory provider; no MCP adapter is needed.
/opt/hermes/.venv/bin/hermes config set memory.provider supermemory >/dev/null

printf '%s\n' "Supermemory ready: ${SUPERMEMORY_BASE_URL}"
exec /opt/hermes/docker/entrypoint-dispatch.sh "$@"
