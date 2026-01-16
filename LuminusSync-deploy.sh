#!/bin/bash
# LuminusSync-deploy.sh
# ==============================================================================
#  Ubuntu 混合存储架构全自动部署脚本
#  功能：Cache-First 策略，自动配置 Fstab，自动修复权限，自动部署同步脚本
#  注意：本脚本会将 SMB 密码写入 /etc/fstab。在多用户共享的服务器环境中使用时请注意安全风险，建议仅在个人独享的 VPS 或虚拟机中使用
# ==============================================================================

# --- [用户配置区] ---
# Windows 远程连接信息
SMB_HOST=""                # 域名或IP
SMB_SHARE=""               # 共享文件夹名
SMB_PORT=""                # FRP 映射端口
SMB_USER=""                # Windows 用户名
SMB_PASS=""                # Windows 密码

# --- 系统自动获取变量 ---
USER_NAME="${SUDO_USER:-$(whoami)}"
USER_UID=$(id -u ${USER_NAME})
USER_GID=$(id -g ${USER_NAME})

# --- 目录规划 ---
BASE_DIR="/home/${USER_NAME}"
MERGER_DIR="/home/anime"                        # [统一入口] qBittorrent 最终保存路径
MOUNT_DIR="/mnt/win_anime"                      # [远程挂载] 底层 Windows
CACHE_DIR="${BASE_DIR}/anime_cache"             # [本地缓存] 底层 Cache
TEMP_DL_DIR="${CACHE_DIR}/temp_download"        # [下载隔离] qBittorrent 临时路径
SYNC_SCRIPT="${BASE_DIR}/scripts/sync_daemon.sh"

# ==============================================================================
#  开始执行
# ==============================================================================

if [ "$EUID" -ne 0 ]; then echo "请使用 sudo 运行此脚本"; exit 1; fi

echo ">>> [1/8] 检查并安装依赖..."
apt-get update -qq
apt-get install -y cifs-utils mergerfs rsync

echo ">>> [2/8] 初始化目录结构..."
# 如果目录存在且有不可写属性，先尝试解锁，防止报错
if [ -d "${MOUNT_DIR}" ]; then chattr -i "${MOUNT_DIR}" 2>/dev/null; fi

mkdir -p "${MERGER_DIR}"
mkdir -p "${MOUNT_DIR}"
mkdir -p "${TEMP_DL_DIR}"
mkdir -p "$(dirname "${SYNC_SCRIPT}")"

echo ">>> [3/8] 暴力修复权限 (解决 Permission Denied)..."
# 确保缓存目录对所有用户开放，防止 qBittorrent 用户无法创建目录
chown -R ${USER_NAME}:${USER_NAME} "${CACHE_DIR}"
chmod -R 777 "${CACHE_DIR}"
# 修正统一入口所有权
chown -R ${USER_NAME}:${USER_NAME} "${MERGER_DIR}"

echo ">>> [4/8] 设置挂载点安全锁..."
# 确保未挂载时目录不可写，防止数据写满系统盘
if ! mountpoint -q "${MOUNT_DIR}"; then
    chattr +i "${MOUNT_DIR}"
    echo "    安全锁已激活: ${MOUNT_DIR}"
else
    echo "    警告: 挂载点已被占用，跳过加锁。"
fi

echo ">>> [5/8] 部署同步守护脚本..."
cat > "${SYNC_SCRIPT}" <<EOF
#!/bin/bash
# Auto Sync Daemon (Cache -> Windows)

# 配置区
REMOTE_DIR="${MOUNT_DIR}"
CACHE_DIR="${CACHE_DIR}/"
TEMP_FOLDER="temp_download"
SMB_ADDR="//${SMB_HOST}/${SMB_SHARE}"
LOCK_FILE="/tmp/anime_sync.lock"
# 挂载参数: 权限全开 (0777) + 指定端口
MOUNT_OPTS="-t cifs -o port=${SMB_PORT},username=${SMB_USER},password=${SMB_PASS},uid=${USER_UID},gid=${USER_GID},iocharset=utf8,dir_mode=0777,file_mode=0777"

# 进程互斥锁
if [ -f "\$LOCK_FILE" ]; then
    PID=\$(cat "\$LOCK_FILE")
    if ps -p \$PID > /dev/null; then exit 0; fi
fi
echo \$\$ > "\$LOCK_FILE"
trap 'rm -f "\$LOCK_FILE"; exit' INT TERM EXIT

# 1. 挂载守护 (断线重连)
if ! mountpoint -q "\$REMOTE_DIR"; then
    sudo mount \$MOUNT_OPTS "\$SMB_ADDR" "\$REMOTE_DIR" > /dev/null 2>&1
fi

# 2. 数据搬运
if mountpoint -q "\$REMOTE_DIR"; then
    # 扫描文件 (排除 temp_download)
    HAS_FILES=\$(find "\$CACHE_DIR" -type f -not -path "*/\$TEMP_FOLDER/*" -print -quit)

    if [ -n "\$HAS_FILES" ]; then
        echo "[$(date)] 开始同步..."
        
        # Rsync: 搬运模式, 断点续传, 排除临时文件
        # --remove-source-files: 搬运模式
        # --partial-dir: 断点续传保护
        # --exclude: 绝对禁止同步临时目录和未完成文件
        
        rsync -av --remove-source-files --no-o --no-g \\
        --partial-dir=.rsync-partial \\
        --timeout=20 \\
        --exclude "\$TEMP_FOLDER/" \\
        --exclude "*.!qB" \\
        "\$CACHE_DIR" "\$REMOTE_DIR"
        
        # 清理空目录 (保护 temp_download)
        find "\$CACHE_DIR" -type d -empty -not -path "*/\$TEMP_FOLDER" -delete
        echo "[$(date)] 同步完成。"
    fi
fi
EOF

chmod +x "${SYNC_SCRIPT}"
chown ${USER_NAME}:${USER_NAME} "${SYNC_SCRIPT}"

echo ">>> [6/8] 注入 /etc/fstab 配置..."
# 先备份
cp /etc/fstab /etc/fstab.bak.$(date +%F-%T)
# 清理旧配置 (防止重复添加)
sed -i "/${SMB_HOST//\//\\/}/d" /etc/fstab
sed -i "/fuse.mergerfs/d" /etc/fstab

# 写入新配置
# 1. Windows CIFS: 使用 x-systemd.automount 防止开机卡死，使用 0777 解决权限问题
echo "//${SMB_HOST}/${SMB_SHARE} ${MOUNT_DIR} cifs port=${SMB_PORT},username=${SMB_USER},password=${SMB_PASS},uid=${USER_UID},gid=${USER_GID},iocharset=utf8,dir_mode=0777,file_mode=0777,noauto,x-systemd.automount 0 0" >> /etc/fstab

# 2. MergerFS: CACHE 在前 (优先写本地)，REMOTE 在后。
echo "${CACHE_DIR}:${MOUNT_DIR} ${MERGER_DIR} fuse.mergerfs defaults,allow_other,nonempty,use_ino,category.create=ff,minfreespace=1G,moveonenospc=true 0 0" >> /etc/fstab

echo "    fstab 配置已更新。"

echo ">>> [7/8] 注册 Crontab 定时任务..."
CRON_JOB="* * * * * ${SYNC_SCRIPT} >> /tmp/anime_sync.log 2>&1"
# 切换用户身份添加任务
sudo -u ${USER_NAME} bash -c "(crontab -l 2>/dev/null | grep -F \"${SYNC_SCRIPT}\") || (crontab -l 2>/dev/null; echo \"${CRON_JOB}\") | crontab -"

echo ">>> [8/8] 重新加载挂载..."
systemctl daemon-reload
mount -a

echo "=========================================================="
echo "部署完成！"
echo "=========================================================="
echo "请务必进入 qBittorrent 设置以下两项："
echo "1. [默认保存路径] -> ${MERGER_DIR}"
echo "2. [未完成的 torrent 保存到] -> ${TEMP_DL_DIR}"
echo "   (必须勾选 '为不完整文件添加扩展名 .!qB')"
echo "=========================================================="