#!/usr/bin/env bash
# Read-only Zimbra health and service checks.
# Run as the zimbra user: bash zimbra-check.sh

set -u

ZIMBRA_BIN="${ZIMBRA_BIN:-/opt/zimbra/bin}"
HOST="$(hostname -f 2>/dev/null || hostname)"
FAILURES=0

pass() { printf '[OK]   %s\n' "$1"; }
warn() { printf '[WARN] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

run_check() {
    local label="$1"
    shift
    local output rc

    output="$("$@" 2>&1)"
    rc=$?

    if [ -n "$output" ]; then
        printf '%s\n' "$output"
    fi

    if [ "$rc" -eq 0 ]; then
        pass "$label"
    else
        fail "$label (exit code $rc)"
    fi
}

echo "Zimbra health check"
echo "Host: $HOST"
echo "Date: $(date)"
echo

if [ "$(id -un)" != "zimbra" ]; then
    echo "Run this script as the zimbra user, for example:"
    echo "  su - zimbra -c 'bash /path/to/zimbra-check.sh'"
    exit 2
fi

if [ ! -x "$ZIMBRA_BIN/zmcontrol" ]; then
    fail "Cannot find $ZIMBRA_BIN/zmcontrol"
else
    echo "=== Zimbra services (MTA, LDAP, mailbox, proxy, etc.) ==="
    STATUS="$("$ZIMBRA_BIN/zmcontrol" status 2>&1)"
    RC=$?
    printf '%s\n' "$STATUS"

    if [ "$RC" -ne 0 ]; then
        fail "zmcontrol status (exit code $RC)"
    elif printf '%s\n' "$STATUS" | grep -Eiq '(^|[[:space:]])(Stopped|Not running)([[:space:]]|$)'; then
        fail "One or more Zimbra services are stopped"
    else
        pass "zmcontrol status"
    fi
fi

echo
echo "=== Server service configuration ==="
if [ -x "$ZIMBRA_BIN/zmprov" ]; then
    run_check "Read installed/enabled services for $HOST" \
        "$ZIMBRA_BIN/zmprov" gs "$HOST" zimbraServiceInstalled zimbraServiceEnabled
else
    warn "zmprov not found; skipping service configuration check"
fi

echo
echo "=== MTA queue ==="
POSTQUEUE=""
for candidate in \
    /opt/zimbra/common/sbin/postqueue \
    /opt/zimbra/postfix/sbin/postqueue
do
    if [ -x "$candidate" ]; then
        POSTQUEUE="$candidate"
        break
    fi
done

if [ -n "$POSTQUEUE" ]; then
    QUEUE_OUTPUT="$("$POSTQUEUE" -p 2>&1)"
    RC=$?
    if [ "$RC" -eq 0 ]; then
        if printf '%s\n' "$QUEUE_OUTPUT" | grep -qi 'Mail queue is empty'; then
            pass "MTA queue is empty"
        else
            QUEUE_COUNT="$(printf '%s\n' "$QUEUE_OUTPUT" |
                awk '/^[A-F0-9]+[*!]?$/ { n++ } END { print n+0 }')"
            pass "MTA queue command succeeded; estimated queued messages: $QUEUE_COUNT"
            printf '%s\n' "$QUEUE_OUTPUT" | tail -n 20
        fi
    else
        printf '%s\n' "$QUEUE_OUTPUT"
        fail "Could not read the MTA queue (exit code $RC)"
    fi
else
    warn "postqueue not found; skipping MTA queue check"
fi

echo
echo "=== Backup availability ==="
if [ -x "$ZIMBRA_BIN/zmbackupquery" ]; then
    run_check "Query available backups for $HOST" \
        "$ZIMBRA_BIN/zmbackupquery" -s "$HOST"
else
    warn "zmbackupquery not found; backup query is unavailable on this installation"
fi

echo
echo "=== Basic storage check ==="
if command -v df >/dev/null 2>&1; then
    df -h /opt/zimbra
    USE="$(df -P /opt/zimbra 2>/dev/null | awk 'NR==2 {gsub(/%/, "", $5); print $5}')"
    if [ -n "$USE" ] && [ "$USE" -ge 90 ]; then
        fail "Filesystem containing /opt/zimbra is at ${USE}% usage"
    elif [ -n "$USE" ]; then
        pass "Filesystem containing /opt/zimbra is at ${USE}% usage"
    else
        warn "Could not determine /opt/zimbra filesystem usage"
    fi
fi

echo
echo "=== Result ==="
if [ "$FAILURES" -eq 0 ]; then
    echo "No failures detected by these checks."
else
    echo "$FAILURES failure(s) detected."
fi

exit "$FAILURES"
