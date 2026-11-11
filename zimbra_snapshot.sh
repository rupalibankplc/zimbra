#!/bin/bash
#
# Zimbra Read-Only Incident Snapshot
# Purpose:
#   Collect OS, Zimbra, LDAP, Mailbox, MTA, Proxy, DNS,
#   certificate, network and error information without
#   intentionally modifying Zimbra services/configuration.
#
# Run:
#   sudo bash zimbra_snapshot.sh
#
# Safety:
#   NO zmcontrol restart/start/stop
#   NO postqueue -f
#   NO postsuper
#   NO zmprov modification
#   NO configuration changes
#

set -u

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

TS=$(date +"%Y%m%d_%H%M%S")
HOST=$(hostname -f 2>/dev/null || hostname)

OUT="/tmp/zimbra_snapshot_${HOST}_${TS}.txt"

ZIMBRA_USER="zimbra"
ZIMBRA_HOME="/opt/zimbra"
ZLOG="/var/log/zimbra.log"
MBOXLOG="/opt/zimbra/log/mailbox.log"

# Limit potentially large outputs.
LOG_LINES=200
QUEUE_LINES=500
ERROR_LINES=150


# ------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------

section()
{
    echo
    echo "======================================================================"
    echo "$1"
    echo "======================================================================"
}


run()
{
    echo
    echo "\$ $*"
    "$@" 2>&1 || echo "[WARN] Command failed or returned non-zero status."
}


zrun()
{
    echo
    echo "\$ su - zimbra -c \"$*\""
    su - "$ZIMBRA_USER" -c "$*" 2>&1 ||
        echo "[WARN] Zimbra command failed or returned non-zero status."
}


command_exists()
{
    command -v "$1" >/dev/null 2>&1
}


zimbra_command_exists()
{
    su - "$ZIMBRA_USER" -c "command -v $1" >/dev/null 2>&1
}


# ------------------------------------------------------------
# Start collection
# ------------------------------------------------------------

exec > >(tee "$OUT") 2>&1

section "ZIMBRA READ-ONLY INCIDENT SNAPSHOT"

echo "Snapshot time : $(date)"
echo "Hostname      : $HOST"
echo "Output file   : $OUT"
echo "Script PID    : $$"


# ------------------------------------------------------------
# 1. Host identity
# ------------------------------------------------------------

section "1. HOST IDENTITY"

run hostname
run hostname -f
run date

if command_exists timedatectl; then
    run timedatectl
fi

run uptime


# ------------------------------------------------------------
# 2. OS information
# ------------------------------------------------------------

section "2. OPERATING SYSTEM"

if [ -f /etc/os-release ]; then
    run cat /etc/os-release
fi

run uname -a


# ------------------------------------------------------------
# 3. CPU and memory
# ------------------------------------------------------------

section "3. CPU / MEMORY"

run free -h

if command_exists nproc; then
    run nproc
fi

run ps aux --sort=-%mem

section "TOP MEMORY CONSUMERS"

ps aux --sort=-%mem 2>/dev/null | head -20

section "TOP CPU CONSUMERS"

ps aux --sort=-%cpu 2>/dev/null | head -20


# ------------------------------------------------------------
# 4. Filesystems
# ------------------------------------------------------------

section "4. FILESYSTEM CAPACITY"

run df -h

section "FILESYSTEM INODES"

run df -i

section "/opt/zimbra TOP-LEVEL DISK USAGE"

if [ -d "$ZIMBRA_HOME" ]; then
    du -xhd1 "$ZIMBRA_HOME" 2>/dev/null | sort -h
fi


# ------------------------------------------------------------
# 5. Network
# ------------------------------------------------------------

section "5. NETWORK CONFIGURATION"

run ip addr
run ip route

section "LISTENING TCP/UDP PORTS"

if command_exists ss; then
    run ss -lntup
elif command_exists netstat; then
    run netstat -lntup
fi


# ------------------------------------------------------------
# 6. DNS
# ------------------------------------------------------------

section "6. DNS / NAME RESOLUTION"

if [ -f /etc/resolv.conf ]; then
    run cat /etc/resolv.conf
fi

echo
echo "--- Local FQDN resolution ---"
getent hosts "$HOST" 2>&1


# Known deployment nodes.
# Modify this list if the Zimbra topology changes.

for NODE in \
    ldap01.rupalibank.com.bd \
    ldap02.rupalibank.com.bd \
    mailbox01.rupalibank.com.bd \
    mta01.rupalibank.com.bd \
    mta02.rupalibank.com.bd
do
    echo
    echo "--- $NODE ---"
    getent hosts "$NODE" 2>&1
done


if command_exists dig; then

    echo
    echo "--- MX: rupalibank.com.bd ---"
    dig +noall +answer MX rupalibank.com.bd 2>&1

    echo
    echo "--- A: mail.rupalibank.com.bd ---"
    dig +noall +answer A mail.rupalibank.com.bd 2>&1
fi


# ------------------------------------------------------------
# 7. Zimbra baseline
# ------------------------------------------------------------

section "7. ZIMBRA BASELINE"

if [ -x "$ZIMBRA_HOME/bin/zmcontrol" ]; then

    zrun "zmcontrol -v"
    zrun "zmhostname"

    section "ZIMBRA SERVICE STATUS"

    zrun "zmcontrol status"

else

    echo "[ERROR] $ZIMBRA_HOME/bin/zmcontrol not found."
    echo "This host may not be a Zimbra server."

fi


# ------------------------------------------------------------
# 8. Installed/enabled services
# ------------------------------------------------------------

section "8. ZIMBRA ROLE / ENABLED SERVICES"

if [ -x "$ZIMBRA_HOME/bin/zmprov" ]; then

    zrun "zmprov gs \$(zmhostname) zimbraServiceInstalled"

    echo
    zrun "zmprov gs \$(zmhostname) zimbraServiceEnabled"

fi


# ------------------------------------------------------------
# 9. Zimbra processes
# ------------------------------------------------------------

section "9. ZIMBRA-RELATED PROCESSES"

ps -ef | grep -Ei \
'zimbra|postfix|slapd|amavis|clam|nginx' |
grep -v grep


# ------------------------------------------------------------
# 10. LDAP diagnostics
# ------------------------------------------------------------

section "10. LDAP DIAGNOSTICS"

echo "--- slapd process ---"
ps -ef | grep '[s]lapd'

echo
echo "--- LDAP listening ports ---"

if command_exists ss; then
    ss -lntp 2>/dev/null | grep -E ':389|:636'
fi

if [ -x "$ZIMBRA_HOME/bin/zmlocalconfig" ]; then

    echo
    echo "--- LDAP URLs ---"

    zrun "zmlocalconfig ldap_url"
    zrun "zmlocalconfig ldap_master_url"

fi


# ------------------------------------------------------------
# 11. Inter-node TCP checks
# ------------------------------------------------------------

section "11. INTER-NODE TCP CONNECTIVITY"

if command_exists nc; then

    echo "--- LDAP01 :389 ---"
    nc -vz -w 3 ldap01.rupalibank.com.bd 389 2>&1

    echo
    echo "--- LDAP02 :389 ---"
    nc -vz -w 3 ldap02.rupalibank.com.bd 389 2>&1

    echo
    echo "--- MAILBOX01 :443 ---"
    nc -vz -w 3 mailbox01.rupalibank.com.bd 443 2>&1

    echo
    echo "--- MAILBOX01 :7071 ---"
    nc -vz -w 3 mailbox01.rupalibank.com.bd 7071 2>&1

    echo
    echo "--- MTA01 :25 ---"
    nc -vz -w 3 mta01.rupalibank.com.bd 25 2>&1

    echo
    echo "--- MTA02 :25 ---"
    nc -vz -w 3 mta02.rupalibank.com.bd 25 2>&1

else

    echo "[INFO] nc not installed; TCP connectivity tests skipped."

fi


# ------------------------------------------------------------
# 12. MTA / Postfix
# ------------------------------------------------------------

section "12. MTA / POSTFIX"

if zimbra_command_exists postqueue; then

    echo "--- Postfix queue (limited to first $QUEUE_LINES lines) ---"

    su - "$ZIMBRA_USER" -c "postqueue -p" 2>&1 |
        head -"$QUEUE_LINES"

else

    echo "[INFO] postqueue not available on this node."

fi


if [ -f "$ZLOG" ]; then

    section "RECENT DEFERRED DELIVERY EVENTS"

    grep -i "status=deferred" "$ZLOG" 2>/dev/null |
        tail -"$ERROR_LINES"

    section "RECENT SUCCESSFUL DELIVERY EVENTS"

    grep -i "status=sent" "$ZLOG" 2>/dev/null |
        tail -50

fi


# ------------------------------------------------------------
# 13. Amavis / Antivirus / Antispam
# ------------------------------------------------------------

section "13. AMAVIS / ANTIVIRUS / ANTISPAM"

ps -ef |
    grep -Ei 'amavis|clam|spam' |
    grep -v grep

if [ -f "$ZLOG" ]; then

    echo
    echo "--- Recent filtering-related log entries ---"

    grep -Ei \
    'amavis|clam|antivirus|antispam|spamassassin' \
    "$ZLOG" 2>/dev/null |
        tail -"$ERROR_LINES"

fi


# ------------------------------------------------------------
# 14. Mailbox
# ------------------------------------------------------------

section "14. MAILBOX DIAGNOSTICS"

if [ -f "$MBOXLOG" ]; then

    echo "--- Last $LOG_LINES mailbox.log lines ---"

    tail -"$LOG_LINES" "$MBOXLOG"

    echo
    echo "--- Recent mailbox errors ---"

    grep -Ei \
    'error|exception|fatal|failed|timeout' \
    "$MBOXLOG" 2>/dev/null |
        tail -"$ERROR_LINES"

else

    echo "[INFO] mailbox.log not present on this node."

fi


# ------------------------------------------------------------
# 15. Proxy / nginx
# ------------------------------------------------------------

section "15. PROXY / NGINX"

ps -ef | grep '[n]ginx'


# ------------------------------------------------------------
# 16. Zimbra system log
# ------------------------------------------------------------

section "16. RECENT ZIMBRA LOG"

if [ -f "$ZLOG" ]; then

    tail -"$LOG_LINES" "$ZLOG"

else

    echo "[INFO] $ZLOG not present."

fi


section "17. IMPORTANT ZIMBRA ERRORS"

if [ -f "$ZLOG" ]; then

    grep -Ei \
    'error|fatal|panic|failed|deferred|timeout|refused|unreachable' \
    "$ZLOG" 2>/dev/null |
        tail -"$ERROR_LINES"

fi


# ------------------------------------------------------------
# 18. Kernel / OOM
# ------------------------------------------------------------

section "18. KERNEL / OOM EVENTS"

if command_exists dmesg; then

    dmesg 2>/dev/null |
        grep -Ei \
        'oom|out of memory|killed process|I/O error|filesystem|segfault' |
        tail -100

fi


# ------------------------------------------------------------
# 19. systemd errors
# ------------------------------------------------------------

section "19. RECENT OS ERRORS"

if command_exists journalctl; then

    journalctl \
        --no-pager \
        -p err \
        -n 100 2>&1

fi


# ------------------------------------------------------------
# 20. Certificate status
# ------------------------------------------------------------

section "20. ZIMBRA CERTIFICATE"

if [ -x "$ZIMBRA_HOME/bin/zmcertmgr" ]; then

    zrun "zmcertmgr viewdeployedcrt"

fi


# ------------------------------------------------------------
# 21. Snapshot summary
# ------------------------------------------------------------

section "SNAPSHOT COMPLETE"

echo "Host       : $HOST"
echo "Completed  : $(date)"
echo "Report     : $OUT"

echo
echo "No Zimbra restart/start/stop operation was requested."
echo "No mail queue flush/delete operation was requested."
echo "No Zimbra configuration modification was requested."
