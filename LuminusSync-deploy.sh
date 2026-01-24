#!/bin/bash
# LuminusSync-deploy.sh
# ==============================================================================
#  Ubuntu Hybrid Storage Architecture - Automated Deployment Script
#  Features: Cache-First Strategy, Auto Fstab Config, Auto Permission Fix, Auto Sync Script Deployment
#  本脚本会将 SMB 密码写入 /etc/fstab。在多用户共享的服务器环境中使用时请注意安全风险，建议仅在个人独享的 VPS 或虚拟机中使用
# ==============================================================================

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# --- [User Configuration Section] ---
# Windows Remote Connection Info
SMB_HOST=""           # Domain or IP
SMB_SHARE=""          # Shared folder name
SMB_PORT=""           # FRP mapped port
SMB_USER=""           # Windows username
SMB_PASS=""           # Windows password

# --- System Auto-detected Variables ---
USER_NAME="${SUDO_USER:-$(whoami)}"
USER_UID=$(id -u ${USER_NAME})
USER_GID=$(id -g ${USER_NAME})

# --- Directory Planning ---
BASE_DIR="/home/${USER_NAME}"
MERGER_DIR="/home/anime"                        # [Unified Entry] qBittorrent final save path
MOUNT_DIR="/mnt/win_anime"                      # [Remote Mount] Backend Windows
CACHE_DIR="${BASE_DIR}/anime_cache"             # [Local Cache] Backend Cache
TEMP_DL_DIR="${CACHE_DIR}/temp_download"        # [Download Isolation] qBittorrent temp path
SYNC_SCRIPT="${BASE_DIR}/scripts/sync_daemon.sh"

# ==============================================================================
#  Start Execution
# ==============================================================================

if [ "$EUID" -ne 0 ]; then echo "Please run this script with sudo"; exit 1; fi

echo ">>> [1/8] Checking and installing dependencies..."
apt-get update -qq
apt-get install -y cifs-utils mergerfs rsync

echo ">>> [2/8] Initializing directory structure..."
# If directory exists with immutable attributes, try to unlock first to prevent errors
if [ -d "${MOUNT_DIR}" ]; then chattr -i "${MOUNT_DIR}" 2>/dev/null; fi
mkdir -p "${MERGER_DIR}"
mkdir -p "${MOUNT_DIR}"
mkdir -p "${TEMP_DL_DIR}"
mkdir -p "$(dirname "${SYNC_SCRIPT}")"

echo ">>> [3/8] Force fixing permissions (solving Permission Denied)..."
# Ensure cache directory is open to all users, preventing qBittorrent user from being unable to create directories
chown -R ${USER_NAME}:${USER_NAME} "${CACHE_DIR}"
chmod -R 777 "${CACHE_DIR}"
# Fix unified entry ownership
chown -R ${USER_NAME}:${USER_NAME} "${MERGER_DIR}"

echo ">>> [4/8] Setting mount point safety lock..."
# Ensure directory is read-only when not mounted, preventing data from filling system disk
if ! mountpoint -q "${MOUNT_DIR}"; then
    chattr +i "${MOUNT_DIR}"
    echo "    Safety lock activated: ${MOUNT_DIR}"
else
    echo "    Warning: Mount point is occupied, skipping lock."
fi

echo ">>> [5/8] Deploying sync daemon script..."
cat > "${SYNC_SCRIPT}" <<'EOF'
#!/bin/bash
# Auto Sync Daemon (Cache -> Windows)

# Configuration Section
REMOTE_DIR="${MOUNT_DIR}"
CACHE_DIR="${CACHE_DIR}/"
TEMP_FOLDER="temp_download"
SMB_ADDR="//${SMB_HOST}/${SMB_SHARE}"
LOCK_FILE="/tmp/anime_sync.lock"
LOG_FILE="/tmp/anime_sync.log"
MAX_LOG_SIZE=10485760  # 10MB log limit

# Mount parameters: full permissions (0777) + specify port
MOUNT_OPTS="-t cifs -o port=${SMB_PORT},username=${SMB_USER},password=${SMB_PASS},uid=${USER_UID},gid=${USER_GID},iocharset=utf8,dir_mode=0777,file_mode=0777"

# Log rotation function (keep log under 10MB)
rotate_log() {
    if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null) -gt $MAX_LOG_SIZE ]; then
        tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp"
        mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

# Log function (only log important events)
log_event() {
    rotate_log
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Process mutex lock
if [ -f "$LOCK_FILE" ]; then
    PID=$(cat "$LOCK_FILE")
    if ps -p $PID > /dev/null 2>&1; then exit 0; fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"; exit' INT TERM EXIT

# 1. Mount daemon (reconnect on disconnect)
if ! mountpoint -q "$REMOTE_DIR"; then
    if sudo mount $MOUNT_OPTS "$SMB_ADDR" "$REMOTE_DIR" > /dev/null 2>&1; then
        log_event "✓ Remote mount restored: $REMOTE_DIR"
    else
        # Only log mount failures (important event)
        log_event "✗ Mount failed: $SMB_ADDR"
        exit 1
    fi
fi

# 2. Data transfer
if mountpoint -q "$REMOTE_DIR"; then
    # Scan files (exclude temp_download)
    HAS_FILES=$(find "$CACHE_DIR" -type f -not -path "*/$TEMP_FOLDER/*" -print -quit 2>/dev/null)
    
    if [ -n "$HAS_FILES" ]; then
        # Count files to sync
        FILE_COUNT=$(find "$CACHE_DIR" -type f -not -path "*/$TEMP_FOLDER/*" -not -name "*.!qB" 2>/dev/null | wc -l)
        
        if [ "$FILE_COUNT" -gt 0 ]; then
            log_event "→ Syncing $FILE_COUNT file(s) to remote..."
            
            # Rsync: move mode, resume transfer, exclude temp files
            if rsync -av --remove-source-files --no-o --no-g \
                --partial-dir=.rsync-partial \
                --timeout=20 \
                --exclude "$TEMP_FOLDER/" \
                --exclude "*.!qB" \
                "$CACHE_DIR" "$REMOTE_DIR" >> "$LOG_FILE" 2>&1; then
                
                # Clean empty directories (protect temp_download)
                find "$CACHE_DIR" -type d -empty -not -path "*/$TEMP_FOLDER" -delete 2>/dev/null
                
                log_event "✓ Sync completed: $FILE_COUNT file(s) transferred"
            else
                log_event "✗ Sync failed (rsync error)"
            fi
        fi
    fi
    # No files to sync - no log output (avoid spam)
fi
EOF

# Replace variables in the script
sed -i "s|\${MOUNT_DIR}|${MOUNT_DIR}|g" "${SYNC_SCRIPT}"
sed -i "s|\${CACHE_DIR}|${CACHE_DIR}|g" "${SYNC_SCRIPT}"
sed -i "s|\${SMB_HOST}|${SMB_HOST}|g" "${SYNC_SCRIPT}"
sed -i "s|\${SMB_SHARE}|${SMB_SHARE}|g" "${SYNC_SCRIPT}"
sed -i "s|\${SMB_PORT}|${SMB_PORT}|g" "${SYNC_SCRIPT}"
sed -i "s|\${SMB_USER}|${SMB_USER}|g" "${SYNC_SCRIPT}"
sed -i "s|\${SMB_PASS}|${SMB_PASS}|g" "${SYNC_SCRIPT}"
sed -i "s|\${USER_UID}|${USER_UID}|g" "${SYNC_SCRIPT}"
sed -i "s|\${USER_GID}|${USER_GID}|g" "${SYNC_SCRIPT}"

chmod +x "${SYNC_SCRIPT}"
chown ${USER_NAME}:${USER_NAME} "${SYNC_SCRIPT}"

echo ">>> [6/8] Injecting /etc/fstab configuration..."
# Backup first
cp /etc/fstab /etc/fstab.bak.$(date +%F-%T)

# Clean old config (prevent duplicate entries)
sed -i "/${SMB_HOST//\//\\/}/d" /etc/fstab
sed -i "/fuse.mergerfs/d" /etc/fstab

# Write new configuration
# 1. Windows CIFS: use x-systemd.automount to prevent boot hang, use 0777 to solve permission issues
echo "//${SMB_HOST}/${SMB_SHARE} ${MOUNT_DIR} cifs port=${SMB_PORT},username=${SMB_USER},password=${SMB_PASS},uid=${USER_UID},gid=${USER_GID},iocharset=utf8,dir_mode=0777,file_mode=0777,noauto,x-systemd.automount 0 0" >> /etc/fstab

# 2. MergerFS: CACHE first (write to local first), REMOTE second.
echo "${CACHE_DIR}:${MOUNT_DIR} ${MERGER_DIR} fuse.mergerfs defaults,allow_other,nonempty,use_ino,category.create=ff,minfreespace=1G,moveonenospc=true 0 0" >> /etc/fstab

echo "    fstab configuration updated."

echo ">>> [7/8] Registering Crontab scheduled task..."
CRON_JOB="* * * * * ${SYNC_SCRIPT} 2>&1"

# Add task under user context
sudo -u ${USER_NAME} bash -c "(crontab -l 2>/dev/null | grep -F \"${SYNC_SCRIPT}\") || (crontab -l 2>/dev/null; echo \"${CRON_JOB}\") | crontab -"

echo ">>> [8/8] Reloading mounts..."
systemctl daemon-reload
mount -a

echo "=========================================================="
echo "Deployment Complete!"
echo "=========================================================="
echo "Please make sure to configure the following in qBittorrent:"
echo "1. [Default Save Path] -> ${MERGER_DIR}"
echo "2. [Keep incomplete torrents in] -> ${TEMP_DL_DIR}"
echo "   (Must enable 'Append .!qB extension to incomplete files')"
echo ""
echo "Log file location: /tmp/anime_sync.log"
echo "  - Only important events are logged"
echo "  - Auto-rotates when exceeds 10MB"
echo "=========================================================="
