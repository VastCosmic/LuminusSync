#!/bin/bash
# LuminusSync_cleanup.sh - LuminusSync System Cleanup
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

# Permission check
if [ "$EUID" -ne 0 ]; then 
    echo "[ERROR] Run with sudo"
    exit 1
fi

echo "=========================================================="
echo "  LuminusSync System Cleanup"
echo "=========================================================="
echo ""
echo "This will:"
echo "  - Stop all sync processes"
echo "  - Unmount all mount points"
echo "  - Remove cron jobs"
echo "  - Clean fstab config"
echo ""
echo "SAFE:"
echo "  - Cache data kept at: ${CACHE_DIR}"
echo "  - Windows data NOT affected"
echo ""
read -p "Type y to continue: " CONFIRM

if [ "$CONFIRM" != "y" ]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo ">>> [1/6] Stopping processes..."
# Kill sync daemon
if [ -f "$LOCK_FILE" ]; then
    SYNC_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$SYNC_PID" ] && ps -p $SYNC_PID > /dev/null 2>&1; then
        echo "    Killing sync daemon PID: $SYNC_PID"
        kill -9 $SYNC_PID 2>/dev/null
    fi
    rm -f "$LOCK_FILE"
fi

# Kill all rsync processes
pkill -9 -f "rsync.*anime" 2>/dev/null
sleep 1
echo "    [OK]"

echo ">>> [2/6] Removing cron jobs..."
sudo -u ${USER_NAME} bash -c "crontab -l 2>/dev/null | grep -v 'sync_daemon' | crontab -" 2>/dev/null
echo "    [OK]"

echo ">>> [3/6] Unmounting MergerFS..."
if mountpoint -q "${MERGER_DIR}" 2>/dev/null; then
    echo "    Unmounting ${MERGER_DIR}..."
    timeout 5 umount -l "${MERGER_DIR}" 2>/dev/null
    if [ $? -ne 0 ]; then
        fusermount -uz "${MERGER_DIR}" 2>/dev/null
        umount -f "${MERGER_DIR}" 2>/dev/null
    fi
    sleep 1
    if mountpoint -q "${MERGER_DIR}" 2>/dev/null; then
        echo "    [WARN] Still mounted"
    else
        echo "    [OK]"
    fi
else
    echo "    [SKIP] Not mounted"
fi

echo ">>> [4/6] Unmounting CIFS..."
if mountpoint -q "${MOUNT_DIR}" 2>/dev/null; then
    echo "    Removing immutable flag..."
    timeout 3 chattr -i "${MOUNT_DIR}" 2>/dev/null &
    sleep 1
    
    echo "    Unmounting ${MOUNT_DIR}..."
    timeout 10 umount -l "${MOUNT_DIR}" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "    Force unmounting..."
        umount -f "${MOUNT_DIR}" 2>/dev/null
        sleep 1
        fuser -km "${MOUNT_DIR}" 2>/dev/null
        umount -f -l "${MOUNT_DIR}" 2>/dev/null
    fi
    
    sleep 1
    if mountpoint -q "${MOUNT_DIR}" 2>/dev/null; then
        echo "    [WARN] Still mounted (reboot may be needed)"
    else
        echo "    [OK]"
    fi
else
    echo "    [SKIP] Not mounted"
    timeout 2 chattr -i "${MOUNT_DIR}" 2>/dev/null &
fi

echo ">>> [5/6] Cleaning fstab..."
if [ -f /etc/fstab ]; then
    BACKUP_FILE="/etc/fstab.bak.$(date +%s)"
    cp /etc/fstab "$BACKUP_FILE"
    echo "    Backup: $BACKUP_FILE"
    
    sed -i '/smb.vastcosmic.cn/d' /etc/fstab
    sed -i '\|/home/anime|d' /etc/fstab
    sed -i '\|/mnt/win_anime|d' /etc/fstab
    
    echo "    [OK]"
fi

echo ">>> [6/6] Reloading systemd..."
systemctl daemon-reexec 2>/dev/null
echo "    [OK]"

# Final status
echo ""
echo "=========================================================="
echo "  CLEANUP RESULTS"
echo "=========================================================="
echo ""
echo "Mount Status:"
echo "  MergerFS: $(mountpoint -q ${MERGER_DIR} 2>/dev/null && echo '[STILL MOUNTED]' || echo '[OK]')"
echo "  CIFS:     $(mountpoint -q ${MOUNT_DIR} 2>/dev/null && echo '[STILL MOUNTED]' || echo '[OK]')"
echo ""
echo "Config Status:"
echo "  Crontab:  [REMOVED]"
echo "  Fstab:    [CLEANED]"
echo ""
echo "Data Status:"
echo "  Cache:    ${CACHE_DIR} [KEPT]"
echo "  Windows:  [NOT AFFECTED]"
echo ""

# Check if reboot needed
NEED_REBOOT=0
mountpoint -q "${MERGER_DIR}" 2>/dev/null && NEED_REBOOT=1
mountpoint -q "${MOUNT_DIR}" 2>/dev/null && NEED_REBOOT=1

if [ $NEED_REBOOT -eq 1 ]; then
    echo "=========================================================="
    echo "  ACTION REQUIRED"
    echo "=========================================================="
    echo ""
    echo "Some mounts are still active. To complete cleanup:"
    echo ""
    echo "  sudo reboot"
    echo ""
else
    echo "=========================================================="
    echo "  CLEANUP COMPLETED SUCCESSFULLY"
    echo "=========================================================="
    echo ""
fi

echo "Optional cleanup commands:"
echo "  Remove cache:  sudo rm -rf ${CACHE_DIR}"
echo "  Remove script: rm ${SYNC_SCRIPT}"
echo "  Check status:  ./LuminusSync-status.sh"
echo ""
