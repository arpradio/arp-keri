#!/usr/bin/env sh
# Bring up the production KERI stack, publishing KERIA's ports on this
# host's primary IP. Detection order: KERIA_BIND_IP already in the
# environment or .env, then the source IP of the default route, then the
# first address from `hostname -I`. If none is found, KERIA_BIND_IP stays
# unset and compose publishes on all interfaces.
set -eu
cd "$(dirname "$0")"

if [ -z "${KERIA_BIND_IP:-}" ] && [ -f .env ]; then
    KERIA_BIND_IP=$(sed -n 's/^KERIA_BIND_IP=//p' .env | tail -n 1)
fi

if [ -z "${KERIA_BIND_IP:-}" ] && command -v ip >/dev/null 2>&1; then
    KERIA_BIND_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
fi

if [ -z "${KERIA_BIND_IP:-}" ] && command -v hostname >/dev/null 2>&1; then
    KERIA_BIND_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi

if [ -n "${KERIA_BIND_IP:-}" ]; then
    echo "Publishing KERIA on ${KERIA_BIND_IP}"
    export KERIA_BIND_IP
else
    echo "Could not detect host IP; publishing KERIA on all interfaces" >&2
    unset KERIA_BIND_IP
fi

exec docker compose -f docker-compose.keri.prod.yml up -d "$@"
