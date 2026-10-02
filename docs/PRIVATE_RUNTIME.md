# 私有前缀、权限与 dpkg 备份

程序使用的运行前缀统一为 `/data/data/com.terminal/files/usr`，HOME 为 `/data/data/com.terminal/files/home`。Android 包管理器仍可能将 `dataDir` 显示为 `/data/user/0/com.terminal`：两条路径在主用户下指向同一设备号和 inode。`Rootfs` 校验这一点后保留 `/data/data` 的路径写法，不搬迁数据，也不改 Android 管理的 `/data/data` 链接。已有 profile、APT/dpkg 配置和源的 `signed-by` 会迁移这一个 App 的旧路径；原文保存在 `usr/var/backups/terminal-paths/`，配置原子写入并保留模式。

## 2026-10-01 的故障与修复

`dpkg: error creating new backup file .../status-old: Permission denied` 来自 `link(status, status-old)`。App UID 的目录归属、读写/搜索权限都正常，普通文件复制和改名成功，但硬链接失败；因此 `chmod 777` 不能解决根因。

`third_party/dpkg/android-private-backup.patch` 为 Android 增加 `file_link_or_copy`：不跟随源符号链接，只复制普通文件到同目录临时文件，保留模式，fsync 后原子改名；非 Android 保留原来的 link。数据库状态提交在新副本完整前保留当前 status 和旧备份。包内硬链接以内容副本实现，包升级和 conffile 备份也使用这个函数，避免只修空数据库而把下一次升级留在原错误路径。Android 的 dpkg 临时目录回退固定为私有 `usr/tmp`。

`third_party/dpkg/android-busybox-tar.patch` 只在 Android 省略 GNU tar 的 `--warning=no-timestamp` 参数，解包错误仍导致失败；BusyBox tar 同时启用长选项、GNU 扩展、创建和 `-m`，用于 dpkg 控制归档的读取和提取。`diff`、`cmp` 编入自建 BusyBox 并列入资产 applet 清单；`cmp -s -n 1 - file` 的返回值已在设备验证。

## 目录检查

`PrivatePermissions.audit` 从 App 的私有数据目录遍历所有目录，包括 files、home、usr、cache、code_cache 和 no_backup，不跟随下级符号链接。它核对 UID 与实际读写/搜索能力；repair 只给当前 App 所有的目录补充 owner rwx，不增加 group/other 权限、不清除 Android cache 的特殊模式、不尝试抢其他 UID 的目录。dpkg 的已存在状态文件只补 owner rw，不修改整个用户文件树的执行位。

每次启动检查，报告写入 `usr/var/log/terminal-permissions.log`。Debug 服务还提供 `/api/permissions` 与 `/api/permissions/repair`；这是正常 App UID 的检查结果。验收中第一次检查 85 个目录，临时测试目录数量变化时会有所增加，记录的问题数为 0。

## 重建

```sh
# 首次 arm64 基线按 SOURCES_AND_BUILD.md 的完整顺序完成后：
sh tools/build-dpkg.sh
sh tools/build-busybox.sh
./gradlew --no-daemon --offline :app:assembleDebug :app:lintDebug
```

这两个局部构建不清空 `out/arm64-v8a`，不会删除 APT/gpgv、OpenSSL 或 optional 输出。完整 `build-ext.sh arm64` 会调用同一 dpkg 补丁准备入口；`build-userland.sh` 调用同一 BusyBox 配置。32 位扩展仍暂停。

## 定向验收

真实 `dpkg --configure -a` 已返回 0，`status-old` 是 App UID 所有的独立普通文件；`diff` 与 `cmp` 均来自私有 bin。`tools/test-dpkg-lifecycle.py <debug-url> <token-file>` 在另建的 App-owned root/db 中安装两个版本的测试包，验证普通文件升级、归档硬链接、符号链接、用户改过的 conffile `.dpkg-old`、非空 status 备份，再 purge 和 audit；不安装到实际 usr 或修改实际包数据库。测试包的 tar 链接条目直接构造，避免构建宿主 proot 对 link 的模拟影响测试含义。
