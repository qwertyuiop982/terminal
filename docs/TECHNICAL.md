# terminal 技术状态

更新：2026-09-27 09:50（设备本地时间）。本轮已成功构建 **不含 apt/gpgv/nano/tcc 的** APK，并在 Android 隔离目录以 shell UID 验证 NDK/OpenSSL HTTPS 下载；尚未安装这份 APK 或测试 App UID。源码、GitHub 加速链接和重建步骤见 [SOURCES_AND_BUILD.md](SOURCES_AND_BUILD.md)，验收任务见 [ROADMAP.md](ROADMAP.md)。

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

Gradle 的 `packagePrefixAssets` 只从 `build-ext/out/<abi>/final/` 生成普通 APK assets，同时实体化软链接并生成 `MANAGED_FILES`/`VERSION`；`optional/` 下的文件不能混入 `final/`。JNI `libpty.so` 从 `jniLibs` 加载；其他私有动态库由 `Rootfs` 放入 `$USR/lib`。`Rootfs` 依据旧 manifest 和哈希清理未修改资产，并读取 `var/lib/dpkg/info/*.list` 跳过已登记文件；新文件不覆盖已存在文件，BusyBox applet 软链接用 `Os.symlink` 建立。shell 安装使用临时文件后改名，普通资产先写临时文件再用 `Os.link` 防止并发覆盖。这些措施**没有证明**升级、dpkg 文件归属和失败回滚的一致性，须用 App UID 场景继续验收。

两种 ABI 的基础 dash 以及 BusyBox 仅使用 `$USR/bin:$USR/sbin:$USR/libexec` 查找命令；dpkg 内置脚本和可选 nano 的 shell 回退使用 `$USR/bin/sh`。Android `/system/bin/linker64` / `linker` 是 Bionic 动态加载器，不是可调用的系统用户命令。`minSdk=24`，当前 `targetSdk=28` 与私有前缀 execve 设计有关；不可不经设备验收直接提升。只有 arm64 有完整的扩展前缀；32 位扩展未授权恢复。

`grep sed awk tar gzip nslookup nc ls cat cp mv rm mkdir touch echo sleep env date uname whoami wget` 都由 BusyBox applet + 私有 symlink 提供；`file`、`dpkg`、`dash` 单独内置。`wget` 使用同样由 NDK 编译的 OpenSSL 3.5.4 验证 TLS 证书，BusyBox 不验签的内部 HTTPS 后端保持禁用。固定的 Mozilla CA bundle 安装至 `etc/ssl/cert.pem`，终端会话设置 `SSL_CERT_FILE`；`nslookup` 使用私有 `etc/resolv.conf`（优先 Android 网络 DNS，必要时保留自定义配置）。初始 `sources.list` 留空，签名仓库尚未配置。源包从 GitHub 原始文件/归档优先获取，版本和 SHA256 见上述构建文档；不采用 glibc/Termux 预编译目标包。

## 有记录的验证

- `./tools/build-dash.sh`（基础双 ABI）、`./tools/build-ext.sh arm64`、`./tools/build-userland.sh`、`./tools/build-file.sh`、`./tools/build-openssl.sh` 均完成 NDK 构建，`./tools/check-private-runtime.sh` 通过，CA 源文件和 staging 副本一致。
- `./gradlew :app:assembleDebug :app:lintDebug` 成功。当前 `app/build/outputs/apk/debug/app-debug.apk` 大小 16,964,230 字节；APK ZIP 列表显示 arm64 `busybox`、`dpkg`、`openssl`、`etc/ssl/cert.pem`，且未显示 `apt`、`gpgv`、`nano`、`tcc`。**上述 APK 是 apt/gpgv 完成前的阶段产物**，旧文档记载的 14,035,379 字节和 3578 项资产数不代表现在版本；后续重建必须重新核对 SHA256、ZIP、ELF 依赖和 16 KB 对齐。
- Android 34 的 `/data/local/tmp` 独立目录以 shell UID 验证基础 dash 与部分 BusyBox 命令；本轮 `openssl version` 返回 3.5.4，并用私有 `PATH`、私有 CA bundle 和 BusyBox `wget` 通过 HTTPS 下载已上传到 `main-repo` 的 `packages/SHA256SUMS`，下载内容 SHA256 与本地完全一致。去掉可用 CA 时 HTTPS 验证失败。**这不是 App UID、Rootfs、PTY 或 UI 验收**，没有安装、覆盖现有 `com.terminal` 或清空其数据。
- 独立 `remote-repo-client/main-repo` 已推送到 GitHub（当前文档提交 `bab7423`，真实包构建提交 `a12fed7`）；`tests/run.sh`、`tests/bootstrap.sh` 通过。真实 nano/tcc 包在宿主隔离 APT 中通过专用 `signed-by` 的文件仓库 `update` 与 `download`，默认 `gh.xmly.dev` raw URL 的真实 HTTPS 下载及哈希验证也通过。尚无远端 Debian/Termux 主机服务部署记录，不能称仓库上线。

## 编译中与未验收的部分

APT 2.8.1 及 libgpg-error/libgcrypt、libiconv、LZ4、xxHash 的来源已固定并交叉编译了部分依赖；APT 的 NDK 构建目前停止于 API 24 缺少 `glob()` 时导入 gnulib 头文件发生 `restrict`/`rpl_glob` 声明冲突（见 `/tmp/terminal-build-apt.log`）。GnuPG 2.4.8 的验证工具及 libassuan/npth/libksba 源码已固定；gpgv 构建到 libksba 时缺少可用宿主 `yacc`（已固定 GitHub 的 Bison 3.8.2 源码，但宿主编译仍需修复）（见 `/tmp/terminal-build-gpgv.log`）。应修复原始源码/构建适配并重编，不从官网或发行版下载目标二进制；**apt、HTTP(S) methods、GnuPG gpgv 尚未进入 APK，不能对 App 执行可信的 `apt update`**。

还需在可重置 arm64 设备以 App UID 检查释放/更新、签名 apt、`dpkg -i`、可选包安装后的 `nano`/`tcc -run`、`file` 默认数据库路径、HTTPS 下载、PTY 输入与全屏程序、IME/方向键/UTF-8、窗口调整以及包管理文件冲突与回滚。普通 Debian 的维护脚本如 `#!/bin/sh` 会找系统解释器，不能直接安装；目标包必须使用私有 shell 和与 `$USR` 相容的文件路径。`TerminalScreen` 只覆盖部分 VT，交互体验不能仅以编译通过推断。Ubuntu proot 环境中的 ADB 与主机架构不符，可使用 Android 系统 shell 做隔离测试，但不可当作 App UID 结果。