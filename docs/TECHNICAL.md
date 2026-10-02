# terminal 技术状态

2026-10-01 当前进度：用户已报告安装前一版 APK。最新本地 APK 已增加固定 `/data/data/com.terminal/files` 运行路径；启动时以 device/inode 校验该目录属于当前 App，环境 `HOME/PWD/PREFIX/TMPDIR`、APT/dpkg 配置及既有 `signed-by` 文本路径统一为 `/data/data`。旧配置先备份至 `usr/var/backups/terminal-paths/`，再保留权限原子改名；用户文件不做目录搬迁。`assembleDebug` 和 `PrivatePathsRegression` 通过。最新 APK 为 46,674,749 字节，SHA256 `2886d594f875dd395e866746a3f7861aba34300f985d3bb5f3109c1831b47927`，下载目录副本为 `/sdcard/Download/Operit/terminal-data-data-fix.apk`。

用户修正的公钥服务为 `http://192.168.31.23:9999/terminal-repo.gpg`；仓库为 `http://192.168.31.23:8080`、套件 `stable`、架构 `arm64`。公钥是 2326 字节的二进制 OpenPGP，SHA256 `aa888291008287167fea96a6d4fd780f1f2c90f464c4ba66c6fbacb7d20cf30c`，完整指纹 `B8342A1AF9D10071761AFB1A3A675C6C2B3B0870`。宿主 `gpgv` 对实际 `InRelease` 返回 GOODSIG/VALIDSIG，`Packages` 的大小和签名哈希链吻合；旧测试 keyring 指纹 `13288D39D9C6F25C3CE68A1C1E66B7E3FFF5EA2A` 不能用于这个仓库。公钥已保存到下载目录，未内置 APK。

设备侧仍待完成：`super_admin:shell` 即使用户报告已挂载 ADB，仍返回 `Current DEBUGGER unavailable: executor unavailable; Shizuku binder is null`；备用安装工具未能访问 APK。当前无法核实用户安装版本、安装本次路径修复 APK、导入私有 keyring，或声称 App UID 的 `apt update` 已通过。下载目录的 `terminal-local-repo-setup.sh` 已准备，固定公钥哈希/签名指纹，使用私有 shell、`signed-by` 与独立 `sources.list.terminal-lan` 验证 8080 源；未在设备执行，不覆盖其他源配置或放宽目录权限。

以下为 2026-09-27 的历史记录。

更新：2026-09-27 23:59（设备本地时间）。新 arm64 APK 已本地编译，包含 NDK libedit dash、APT/GnuPG gpgv、APT 私有临时目录补丁与滚屏/resize 修复；nano/tcc 仍只在可选包中。新 APK 的 `pm install -r` 返回 `INSTALL_FAILED_ABORTED: User rejected permissions`，**未安装**；现有 `com.terminal` 仍是 15:52 安装的旧版本，用户文件完整性未做全量比对。源码和重建步骤见 [SOURCES_AND_BUILD.md](SOURCES_AND_BUILD.md)，验收任务见 [ROADMAP.md](ROADMAP.md)。

## 运行与资产边界

```text
MainActivity -> TerminalSurface/TerminalScreen (部分 VT、IME/按键)
             -> TerminalSession -> Pty.kt/libpty.so -> dash -i
Rootfs.ensure -> files/home + files/usr
             <- assets/bin/dash-<abi> (arm64 与 armeabi-v7a 基础 shell)
             <- assets/prefix/arm64-v8a/{VERSION,MANAGED_FILES,bin,lib,etc,share}
NDK 编译的 nano/ncurses 与 tcc/headers/CRT -> optional/{nano,tcc}
                                              -> main-repo/packages/*.deb (不进 APK)
```

Gradle 的 `packagePrefixAssets` 只从 `build-ext/out/<abi>/final/` 生成普通 APK assets，同时实体化软链接并生成 `MANAGED_FILES`/`VERSION`；`optional/` 下的文件不能混入 `final/`。JNI `libpty.so` 从 `jniLibs` 加载；其他私有动态库由 `Rootfs` 放入 `$USR/lib`。`Rootfs` 依据旧 manifest 和哈希清理未修改资产，并读取 `var/lib/dpkg/info/*.list` 跳过已登记文件；新文件不覆盖已存在文件，BusyBox applet 软链接用 `Os.symlink` 建立。shell 与普通资产先写同目录临时文件，哈希验证后原子改名；设备证实 App 私有目录拒绝 `Os.link` 硬链接，所以不再依赖它。升级中断时旧清单会保留以支持重试。这些措施**没有证明**升级、dpkg 文件归属和失败回滚的一致性，须在可重置 App UID 场景继续验收。

dash 和 BusyBox 仅使用 `$USR/bin:$USR/sbin:$USR/libexec` 查找命令；新版 arm64 dash 静态链接 NDK libedit/ncurses 并通过私有 `etc/profile` 打开 emacs 行编辑、历史输入，32 位仍是基础 dash。dpkg 内置脚本和可选 nano 的 shell 回退使用 `$USR/bin/sh`。Android `/system/bin/linker64` / `linker` 是 Bionic 动态加载器，不是可调用的系统用户命令。`minSdk=24`，当前 `targetSdk=28` 与私有前缀 execve 设计有关；不可不经设备验收直接提升。只有 arm64 有完整的扩展前缀；32 位扩展未授权恢复。

`grep sed awk tar gzip nslookup nc ls cat cp mv rm mkdir touch echo sleep env date uname whoami wget` 都由 BusyBox applet + 私有 symlink 提供；`file`、`dpkg`、`dash` 单独内置。`wget` 使用同样由 NDK 编译的 OpenSSL 3.5.4 验证 TLS 证书，BusyBox 不验签的内部 HTTPS 后端保持禁用。固定的 Mozilla CA bundle 安装至 `etc/ssl/cert.pem`，终端会话设置 `SSL_CERT_FILE`；`nslookup` 使用私有 `etc/resolv.conf`（优先 Android 网络 DNS，必要时保留自定义配置）。初始 `sources.list` 留空，签名仓库尚未配置。源包从 GitHub 原始文件/归档优先获取，版本和 SHA256 见上述构建文档；不采用 glibc/Termux 预编译目标包。

## 有记录的验证

- `./tools/build-dash.sh`（基础双 ABI）、`./tools/build-ext.sh arm64`、`./tools/build-userland.sh`、`./tools/build-file.sh`、`./tools/build-openssl.sh` 均完成 NDK 构建，`./tools/check-private-runtime.sh` 通过，CA 源文件和 staging 副本一致。
- `./tools/build-apt.sh`、`./tools/build-gpgv.sh`、`./tools/build-dash-edit.sh`、`./tools/check-private-runtime.sh` 与 `./gradlew --no-daemon --offline :app:assembleDebug :app:lintDebug` 通过。最新 `app/build/outputs/apk/debug/app-debug.apk` 为 46,674,749 字节，SHA256 `581d14ebdce0bd78002d6bbcbbe94b7ec77ab68ee4a8cf0e40456cc3e3603e52`；ZIP 有 apt/gpgv/HTTP(S) methods、私有 terminfo、两 ABI dash，不含 nano/tcc。arm64 dash 为动态 PIE、16 KB LOAD，仅依赖 Android 公共库；libedit/ncurses 是 NDK 静态链接，不是整包全静态可执行文件。`./tools/test-terminal-screen.sh` 的纯 JVM 回归覆盖初次布局、行尾换行、滚屏/resize、备用屏幕与 UTF-8。**只证明构建和静态检查，不是新 APK 的 App UID 验收**。
- Android 34 的 `/data/local/tmp` 曾以 shell UID 验证基础 dash、部分 BusyBox 和私有 CA 的 HTTPS `wget`，去掉 CA 时证书验证失败。旧 APK 曾通过 `pm install -r` 升级（无显式清数据；没有全量用户文件比对），App UID 执行 `apt --version` 和 `gpgv --version` 成功，`apt update` 则因 `/tmp/apt.conf.*` 路径失败。**shell UID 冒烟和旧版 App UID 证据都不等于新 APK 的签名源/PTY/UI 验收**。
- 独立 `remote-repo-client/main-repo` 已推送到 GitHub（当前文档提交 `bab7423`，真实包构建提交 `a12fed7`）；`tests/run.sh`、`tests/bootstrap.sh` 通过。真实 nano/tcc 包在宿主隔离 APT 中通过专用 `signed-by` 的文件仓库 `update` 与 `download`，默认 `gh.xmly.dev` raw URL 的真实 HTTPS 下载及哈希验证也通过。尚无远端 Debian/Termux 主机服务部署记录，不能称仓库上线。

## 已编译产物与未验收的部分

APT/GnuPG 的固定源码已交叉编译；宿主 Bison 3.8.2、gperf/flex 与 NDK 产物隔离。API 24 的 `faccessat(...,AT_EACCESS)` 导致旧版 APT 将 `$USR/tmp` 错判后退到不可写的 `/tmp`，因此设备上旧版带 `signed-by` 的隔离文件源 `apt update` 返回 100；现有补丁强制私有临时目录、压缩器路径、GnuPG/libgcrypt 配置路径并重编 APK，但尚未在新版本 App UID 验签。旧版在 `run-as com.terminal` 下 `apt --version`、`gpgv --version` 已返回正常版本号，不能代替新 APK 的端到端验收。

还需在可重置 arm64 设备以 App UID 检查释放/更新、签名 apt、`dpkg -i`、可选包安装后的 `nano`/`tcc -run`、`file` 默认数据库路径、HTTPS 下载、PTY 输入与全屏程序、IME/方向键/UTF-8、窗口调整以及包管理文件冲突与回滚。普通 Debian 的维护脚本如 `#!/bin/sh` 会找系统解释器，不能直接安装；目标包必须使用私有 shell 和与 `$USR` 相容的文件路径。`TerminalScreen` 只覆盖部分 VT，交互体验不能仅以编译通过推断。Ubuntu proot 环境中的 ADB 与主机架构不符，可使用 Android 系统 shell 做隔离测试，但不可当作 App UID 结果。