# LuminusSync

**“缓存优先写入 + 异步自动同步 + 下载物理隔离 + 断线自动保护”**。

This Doc is **AI-generated** ! **All operations carry risks.**

免责声明：请勿随意执行任何操作，请务必确认明白自己在做什么，一切后果与该解决方案的作者无关！

# 基于MergerFS-CIFS的缓存优先异步同步系统 

## ——适用于小流量网站的低成本番剧订阅混合存储简易解决方案

## 1. 方案概述

本方案旨在解决云服务器通过公网 (FRP) 以 CIFS 挂载本地 Windows 物理存储时，因**网络波动**、**带宽限制**或物理存储**断电关机**时导致的**挂载失效**、**传输中断**及**下载卡顿**问题。

实现番剧订阅自动下载时，qBittorrent 以云存储为缓存，并自动同步搬运到本地物理存储。配合FRP连接非公网物理存储，可节省高昂云存储费用，且无需本地存储计算机长期开机，以节约电力消耗。

本解决方案为解决作者本人实际情况的简易方案，其他任何情况都未必最优。

### 核心架构图

```
用户/qBittorrent
      │
      ▼
[统一入口: /home/anime] (MergerFS - Ubuntu) 
      │
      ├── (写入策略: 缓存优先) ──────┐
      ▼                            ▼
[本地缓存: ~/anime_cache]    [远程挂载: /mnt/win_anime] (CIFS - Windows)
      │                            ▲
      │                            │
      │   (后台脚本每分钟同步)       │
      └─────── Rsync 搬运 ─────────┘
```

---

## 2. 模块功能与问题解决对照表

| 模块组件                          | 解决的核心问题                                               | 技术实现细节                                                 |
| :-------------------------------- | :----------------------------------------------------------- | :----------------------------------------------------------- |
| **本地缓存优先 (Cache-First)**    | 解决 **Windows 断线/关机时写入报错**；解决 **远程写入 I/O 延迟导致的下载卡顿**。 | MergerFS 配置中，将 `${CACHE_DIR}` 放在 `${MOUNT_DIR}` 之前，策略为 `first found`。 |
| **异步自动同步 (Rsync Script)**   | 解决 **数据分散** 问题；实现 **断点续传** (防止断电导致文件损坏)。 | 利用 `rsync --remove-source-files` 搬运数据；使用 `--partial-dir` 保护传输中断的文件。 |
| **下载物理隔离 (Temp Isolation)** | 解决 **同步脚本搬运未下载完成的文件** 导致的坏文件问题。     | qBittorrent 将临时文件写入物理路径 `temp_download`，同步脚本配置 `--exclude` 严格忽略此目录。 |
| **权限全开 (Mode 0777)**          | 解决 **`mkdir: Permission denied`** 报错。                   | CIFS 挂载参数添加 `dir_mode=0777,file_mode=0777`。           |
| **Systemd Automount**             | 解决 **Windows 离线导致 Ubuntu 开机/重启卡死**。             | fstab 中配置 `noauto,x-systemd.automount`，实现按需连接，不阻塞启动。 |
| **安全锁 (chattr +i)**            | 解决 **挂载失败时数据误写入系统盘**。                        | 对挂载点 `/mnt/win_anime` 加 immutable 锁，未挂载时只读。    |

---

## 3. 异常处理与验证测试方法

部署完成后，建议进行以下测试以验证系统的健壮性。

### 测试 A：断线写入测试 (模拟 Windows 宕机)

1. **操作**：手动强制卸载 Windows 挂载点。

   ```bash
   sudo umount -l /mnt/win_anime
   ```

2. **动作**：向统一入口写入一个测试文件。

   ```bash
   touch /home/anime/offline_test.txt
   ```

3. **预期结果**：

   *   **不报错**。
   *   `ls /home/ubuntu/anime_cache` 能看到该文件。
   *   `ls /mnt/win_anime` 应该是空的（或者报错无法访问）。

### 测试 B：恢复同步测试 (模拟 Windows 上线)

1. **操作**：等待 1 分钟，或者手动运行脚本。

   ```bash
   sudo ~/scripts/sync_daemon.sh
   ```

   *(注：脚本内部逻辑会尝试自动挂载 Windows)*

2. **预期结果**：

   *   脚本日志显示 `Sync Completed`。
   *   `ls /home/ubuntu/anime_cache` 中的 `offline_test.txt` **消失**。
   *   `ls /mnt/win_anime` 中**出现** `offline_test.txt`。

### 测试 C：权限测试 (qBittorrent)

1.  **操作**：在 qBittorrent 中下载一个任务，路径设为 `/home/anime`。
2.  **预期结果**：
    *   下载开始时，文件出现在 `/home/ubuntu/anime_cache/temp_download`。
    *   **不报错** `Permission denied`。
    *   下载完成后，文件自动从 `temp_download` 移动到 `anime_cache` 根目录。
    *   随后被脚本搬运至 Windows。

---

## 4. 常用维护命令

* **查看同步日志**：

  ```bash
  tail -f /tmp/anime_sync.log
  ```

* **查看挂载状态**：

  ```bash
  df -h | grep anime
  ```

* **手动触发同步**：

  ```bash
  /home/ubuntu/scripts/sync_daemon.sh
  ```
## 5. 附件: LuminusSync-deploy.sh

* **运行前，先配置好 Windows 下的 FRP 与 CIFS，并填写 sh 文件中的用户配置区**

* 注意：本脚本会将 SMB 密码写入 /etc/fstab。在多用户共享的服务器环境中使用时**请注意安全风险**，建议仅在个人独享的 VPS 或虚拟机中使用