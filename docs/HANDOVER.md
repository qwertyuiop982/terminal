# terminal 接手状态

2026-10-01 当前进度：用户已报告安装前一版 APK。最新本地 APK 已增加固定 `/data/data/com.terminal/files` 运行路径；启动时以 device/inode 校验该目录属于当前 App，环境 `HOME/PWD/PREFIX/TMPDIR`、APT/dpkg 配置及既有 `signed-by` 文本路径统一为 `/data/data`。旧配置先备份至 `usr/var/backups/terminal-paths/`，再保留权限原子改名；用户文件不做目录搬迁。`assembleDebug` 和 `PrivatePathsRegression` 通过。最新 APK 为 46,674,749 字节，SHA256 `2886d594f875dd395e866746a3f7861aba34300f985d3bb5f3109c1831b47927`，下载目录副本为 `/sdcard/Download/Operit/terminal-data-data-fix.apk`。

用户修正的公钥服务为 `http://192.168.31.23:9999/terminal-repo.gpg`；仓库为 `http://192.168.31.23:8080`、套件 `stable`、架构 `arm64`。公钥是 2326 字节的二进制 OpenPGP，SHA256 `aa888291008287167fea96a6d4fd780f1f2c90f464c4ba66c6fbacb7d20cf30c`，完整指纹 `B8342A1AF9D10071761AFB1A3A675C6C2B3B0870`。宿主 `gpgv` 对实际 `InRelease` 返回 GOODSIG/VALIDSIG，`Packages` 的大小和签名哈希链吻合；旧测试 keyring 指纹 `13288D39D9C6F25C3CE68A1C1E66B7E3FFF5EA2A` 不能用于这个仓库。公钥已保存到下载目录，未内置 APK。

设备侧仍待完成：`super_admin:shell` 即使用户报告已挂载 ADB，仍返回 `Current DEBUGGER unavailable: executor unavailable; Shizuku binder is null`；备用安装工具未能访问 APK。当前无法核实用户安装版本、安装本次路径修复 APK、导入私有 keyring，或声称 App UID 的 `apt update` 已通过。下载目录的 `terminal-local-repo-setup.sh` 已准备，固定公钥哈希/签名指纹，使用私有 shell、`signed-by` 与独立 `sources.list.terminal-lan` 验证 8080 源；未在设备执行，不覆盖其他源配置或放宽目录权限。

以下为 2026-09-27 的历史记录。

更新：2026-09-27 23:59。`terminal/main` 原有暂存 APT locale 补丁和领先远端的提交均保留；仓库工作树 `main-repo` 只补充新包路径门禁，已发布 nano/tcc 的原 SHA256 未变，目标 Debian/Termux 主机未部署。新 APK 安装被设备拒绝，本轮没有执行清除 App 数据命令；旧版升级前后的全部用户文件未做比对。早先看到的 `files/home/hhh.txt` 在最终检查时已不存在，原因未确定，不能声称数据完整保留。当前 `remote-repo-client` 工作树 `git status` 报 `bad tree object HEAD`，尚未修复 Git 元数据或提交/推送新的仓库端改动。

## 当前可核对的结果

- 双 ABI dash/JNI、arm64 的 BusyBox/dpkg/file/OpenSSL/CA/apt/gpgv/HTTP(S) methods 已构建；本地最新的 `app/build/outputs/apk/debug/app-debug.apk` 为 46,674,749 字节，SHA256 `581d14ebdce0bd78002d6bbcbbe94b7ec77ab68ee4a8cf0e40456cc3e3603e52`，arm64 dash 含静态 libedit，nano/tcc 不在 APK。`assembleDebug :app:lintDebug`、`check-private-runtime.sh` 和纯 JVM 滚屏回归通过；设备旧版 `com.terminal` 的 App UID 可执行 `apt --version`/`gpgv --version`，新 APK 的 `pm install -r` 返回 `INSTALL_FAILED_ABORTED: User rejected permissions`，**新 APK 未安装**。
- Android 34 上仅以 **shell UID** 在 `/data/local/tmp` 验证原生工具子集；NDK OpenSSL + BusyBox wget 使用私有 CA 成功从 `gh.xmly.dev` 的 GitHub raw 下载仓库包哈希文件。该独立冒烟测试当时没有安装、覆盖 `com.terminal`，也不证明 `Rootfs`、PTY 或 App UID 工作。
- 仓库端真实包通过 `tests/run.sh`、`tests/bootstrap.sh`，后者有临时签名密钥、专用 `signed-by` 和宿主隔离 apt 的 `update`/`download`；未在目标 Debian/Termux 主机验证 nginx 服务。

## 编译完成后的待办

1. `./tools/build-apt.sh` 已通过。API 24 的 libc++ 迭代器、Bionic resolv/locale、RAMFS 宏、xxHash 链接及 OpenSSL method 包含顺序已用可重复补丁修复；旧 `/tmp/terminal-build-apt.log` 不再是当前阻塞证据。
2. `./tools/build-gpgv.sh` 已通过。已从固定 GitHub 源码编译宿主 Bison 3.8.2，并用宿主 flex、Autoconf 数据和上游 AWK 脚本生成缺失文件；libksba/GnuPG Android 二进制依然由 NDK 编译。
3. 新 APK 尚未安装；用户允许设备安装后，在 App UID 依次检查新 dash 方向键、滚屏/IME/resize、APT 的 `$PREFIX/tmp`、专用 `signed-by` 文件源的有效签名 `apt update` 和 `apt download`。设备先前的旧 APK 可运行版本号，但旧版签名更新失败于 `/tmp/apt.conf.*`；宿主隔离 apt 成功不能充当 Android 验收。目标仓库机部署与真实公钥带外指纹验证也仍待完成。

## 操作注意

- 使用已存在的持久终端会话，先检查两工作树状态。`build-ext.sh arm64` 会重建 `out/arm64-v8a`，之后必须按 [SOURCES_AND_BUILD.md](SOURCES_AND_BUILD.md) 中的顺序重建 userland、file、OpenSSL、可选 `.deb` 和 APK。`app/build/`、`build-ext/` 被 Git 忽略；`third_party/` 的源码和 SHA256 应提交。
- 本轮不运行 `build-ext.sh all`/`arm`：仅基础 dash/JNI 已双 ABI；32 位扩展暂停。Android 用户命令 PATH 禁止 `/system/bin`，仅允许系统动态 linker 作加载器；`targetSdk=28`、私有绝对前缀与 API 24 的 ELF 要同时审查。
- 读源码与文档优先 GitHub raw、`gh.xmly.dev/https://github.com/...` 源码归档，须固定版本/哈希；不要请求 GNU/软件包官网或目标平台预编译二进制。构建机的 Perl、gperf、已构建的宿主 Bison 与 flex 均与 NDK 目标 ELF 分开。
- 不把仓库私钥、真实地址猜测值或 `trusted=yes` 写入 App；不要在已安装的 App 上直接清数据做升级实验。设备测试需可重置 arm64 环境，shell UID 隔离结果不能描述为 App UID 验收；Ubuntu 容器内现有 adb 与主机架构不符。

按 [ROADMAP.md](ROADMAP.md) 和 [本分支任务](../TASKS.md) 跟踪下一步；仓库部署/自动导入说明见 [仓库分支 README](https://gh.xmly.dev/https://raw.githubusercontent.com/qwertyuiop982/terminal/main-repo/README.md)。
## 2026-10-01：TCC 独立构建与 OpenJDK 17 调查
- 已搜索并以实际 Git 源码核对 TCC Android 配置；独立 TinyCC 源码 + tcc-android 构建工程解决 CRT/标准头/libtcc1/runmain.o 问题。TCC-only 入口与 build-ext 的 TCC 段统一；32 位扩展仍暂停。
- 新候选 tcc 20260922-2 已构建、重打包哈希相同，并通过 HTTP API/App UID 的隔离 `.o`、PIE 链接执行、可变参数和 `-run` 回归；没有改变旧包 20260922-1 的哈希。详细证据与独立项目列表见 [TCC_ANDROID.md](TCC_ANDROID.md)。
- 新包在 `/sdcard/Download/Operit/tcc_20260922-2_arm64.deb`，SHA256 `0be112b7b68a3a4d0f162162d205a600c3a33fb632ebf612da0b02af1511d5cb`；真实数据库仍装着旧签名版。下一步必须在实际仓库主机用现有私钥发布新版本，再通过 signed-by APT 真实升级并测试不带 -B 的默认路径。
- OpenJDK 上游 17.0.20 和构建调查工程已独立 Git 创建/拉取，做了实际无 GUI cross-configure 基线；当前 config.sub 拒绝 Android triplet，尚未编译/运行 Java。计划 headless + 不含 java.desktop 的 jlink 命令行镜像；不能把当前 Ubuntu boot JDK 当 Android 产物。
- 没有新建 APK、清除 App 数据、扩充仓库全局信任或接触私钥。remote-repo-client 的 bad tree object HEAD 仍未修复，不宣称推送/仓库新版本发布成功。
