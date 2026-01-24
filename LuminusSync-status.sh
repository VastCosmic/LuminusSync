#!/bin/bash
# LuminusSync_status.sh - LuminusSync Status Checker
# ==============================================================================

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

USER_NAME="${SUDO_USER:-$(whoami)}"
BASE_DIR="/home/${USER_NAME}"
MERGER_DIR="/home/anime"
MOUNT_DIR="/mnt/win_anime"
CACHE_DIR="${BASE_DIR}/anime_cache"
SYNC_SCRIPT="${BASE_DIR}/scripts/sync_daemon.sh"
LOCK_FILE="/tmp/anime_sync.lock"

echo "=========================================================="
echo "  LuminusSync System Status"
echo "=========================================================="
echo ""

# 1. Mount Status
echo "=== MOUNT POINTS ==="
if mountpoint -q "${MERGER_DIR}" 2>/dev/null; then
    echo "[ACTIVE] MergerFS: ${MERGER_DIR}"
else
    echo "[  OFF ] MergerFS: ${MERGER_DIR}"
fi

if mountpoint -q "${MOUNT_DIR}" 2>/dev/null; then
    echo "[ACTIVE] CIFS:     ${MOUNT_DIR}"
else
    echo "[  OFF ] CIFS:     ${MOUNT_DIR}"
fi

# 2. Process Status
echo ""
echo "=== PROCESSES ==="
SYNC_PID=""
if [ -f "$LOCK_FILE" ]; then
    SYNC_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$SYNC_PID" ] && ps -p $SYNC_PID > /dev/null 2>&1; then
        echo "[ACTIVE] Sync daemon: PID $SYNC_PID"
    else
        echo "[  OFF ] Sync daemon (stale lock file)"
    fi
else
    echo "[  OFF ] Sync daemon"
fi

RSYNC_COUNT=$(pgrep -f "rsync.*anime" 2>/dev/null | wc -l)
if [ "$RSYNC_COUNT" -gt 0 ]; then
    echo "[ACTIVE] Rsync: $RSYNC_COUNT process(es)"
    pgrep -f "rsync.*anime" | xargs ps -p 2>/dev/null | tail -n +2
else
    echo "[  OFF ] Rsync"
fi

# 3. Cron Job Status
echo ""
echo "=== SCHEDULED TASKS ==="
CRON_CHECK=$(sudo -u ${USER_NAME} crontab -l 2>/dev/null | grep -c "sync_daemon")
if [ "$CRON_CHECK" -gt 0 ]; then
    echo "[ACTIVE] Crontab: $CRON_CHECK job(s)"
    sudo -u ${USER_NAME} crontab -l 2>/dev/null | grep "sync_daemon"
else
    echo "[  OFF ] Crontab"
fi

# 4. Fstab Configuration
echo ""
echo "=== AUTO-MOUNT CONFIG ==="
FSTAB_LINES=$(grep -c "anime\|smb.vastcosmic.cn" /etc/fstab 2>/dev/null)
if [ "$FSTAB_LINES" -gt 0 ]; then
    echo "[ACTIVE] Fstab: $FSTAB_LINES line(s)"
    grep "anime\|smb.vastcosmic.cn" /etc/fstab 2>/dev/null | sed 's/^/  /'
else
    echo "[  OFF ] Fstab"
fi

# 5. Storage Status
echo ""
echo "=== STORAGE ==="
if [ -d "${CACHE_DIR}" ]; then
    CACHE_SIZE=$(du -sh "${CACHE_DIR}" 2>/dev/null | cut -f1)
    CACHE_FILES=$(find "${CACHE_DIR}" -type f 2>/dev/null | wc -l)
    echo "Cache:  ${CACHE_SIZE} (${CACHE_FILES} files)"
    echo "  Path: ${CACHE_DIR}"
else
    echo "Cache:  Not found"
fi

if [ -f "${SYNC_SCRIPT}" ]; then
    echo "Script: Exists"
    echo "  Path: ${SYNC_SCRIPT}"
else
    echo "Script: Not found"
fi

# 6. Recent Sync Log
echo ""
echo "=== RECENT SYNC LOG ==="
if [ -f /tmp/anime_sync.log ]; then
    echo "Last 5 entries:"
    tail -n 5 /tmp/anime_sync.log | sed 's/^/  /'
else
    echo "No log file found"
fi

# 7. System Summary
echo ""
echo "=========================================================="
echo "  SYSTEM SUMMARY"
echo "=========================================================="

ACTIVE_COUNT=0
[ "$(mountpoint -q ${MERGER_DIR} 2>/dev/null && echo 1)" ] && ((ACTIVE_COUNT++))
[ "$(mountpoint -q ${MOUNT_DIR} 2>/dev/null && echo 1)" ] && ((ACTIVE_COUNT++))
[ "$CRON_CHECK" -gt 0 ] && ((ACTIVE_COUNT++))
[ -n "$SYNC_PID" ] && ps -p $SYNC_PID > /dev/null 2>&1 && ((ACTIVE_COUNT++))

if [ $ACTIVE_COUNT -eq 0 ]; then
    echo "Status: INACTIVE (All services stopped)"
elif [ $ACTIVE_COUNT -ge 3 ]; then
    echo "Status: RUNNING (System operational)"
else
    echo "Status: PARTIAL (Some services down)"
fi

echo "=========================================================="
