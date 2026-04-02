#!/bin/bash

set -euo pipefail

source /opt/hiclaw/scripts/lib/base.sh

PROVIDER="${HICLAW_LLM_PROVIDER:-qwen}"
PORT="${HICLAW_OPENAI_CODEX_PROXY_PORT:-1455}"
TOKEN_FILE="/run/hiclaw-openai-codex-refresh-token"

if [ "${PROVIDER}" != "openai-codex" ]; then
    log "OpenAI Codex OAuth proxy running in passive mode (provider=${PROVIDER}, port=${PORT})"
else
    log "Starting OpenAI Codex OAuth proxy on port ${PORT}"
    if [ -z "${HICLAW_OPENAI_CODEX_REFRESH_TOKEN:-}" ]; then
        log "ERROR: missing HICLAW_OPENAI_CODEX_REFRESH_TOKEN for openai-codex provider"
        exit 1
    fi
    install -d -m 700 /run
    umask 077
    printf '%s' "${HICLAW_OPENAI_CODEX_REFRESH_TOKEN}" > "${TOKEN_FILE}"
    export HICLAW_OPENAI_CODEX_REFRESH_TOKEN_FILE="${TOKEN_FILE}"
    unset HICLAW_OPENAI_CODEX_REFRESH_TOKEN
fi

exec node /opt/hiclaw/scripts/codex/openai-codex-proxy.mjs
