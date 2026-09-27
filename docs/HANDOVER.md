# terminal 接手状态

更新：2026-09-27 09:50。本轮工作开始时有大量未提交的 Kotlin、脚本和第三方源码；以下变更将按原样纳入 `main`，不要清理构建输入或用户数据。GitHub 远端为同一仓库两个**分别维护**的分支：`terminal` 工作树在 `main`，`../remote-repo-client` 工作树在已推送的 `main-repo`（文档提交 `bab7423`）。后者已含 NDK 构建的真实 nano/tcc `.deb`，但没有在目标仓库主机部署。

## 当前可核对的结果

- 双 ABI 基础 dash/JNI 已构建；arm64 的 BusyBox 常用命令、dpkg、file、OpenSSL 与 Mozilla CA bundle 已 staged。nano/ncurses 与 tcc/NDK 头/CRT 在 `build-ext/out/arm64-v8a/optional/`，APK 的 `final/` 没有它们。`check-private-runtime.sh` 和 `./gradlew :app:assembleDebug :app:lintDebug` 通过；APK 路径是 `app/build/outputs/apk/debug/app-debug.apk`，目前尚无 apt/gpgv。
- Android 34 上仅以 **shell UID** 在 `/data/local/tmp` 验证原生工具子集；NDK OpenSSL + BusyBox wget 使用私有 CA 成功从 `gh.xmly.dev` 的 GitHub raw 下载仓库包哈希文件。此测试没有安装、覆盖已存在的 `com.terminal`，也不证明 `Rootfs`、PTY 或 App UID 工作。
- 仓库端真实包通过 `tests/run.sh`、`tests/bootstrap.sh`，后者有临时签名密钥、专用 `signed-by` 和宿主隔离 apt 的 `update`/`download`；未在目标 Debian/Termux 主机验证 nginx 服务。

## 当前编译阻塞点

1. `./tools/build-apt.sh` 的 APT 2.8.1 NDK API 24 编译：gnulib `glob` 替代实现与 C++/NDK 的 `glob-libc.gl.h` 声明冲突，错误含 `restrict` 重复参数与 `rpl_glob` 类型不匹配。日志 `/tmp/terminal-build-apt.log`，源适配脚本 `tools/prepare-apt-source.sh`。不要用宿主 glibc 的 glob 或把未完成的 apt 放进 APK。
2. `./tools/build-gpgv.sh` 的 GnuPG 验证器构建：libassuan、npth 已过，libksba 的 `asn1-parse.y` 需要可用的宿主 yacc；Bison 3.8.2 GitHub 源码已固定，但宿主编译仍失败。日志 `/tmp/terminal-build-gpgv.log`；应从 GitHub 固定源码构建宿主工具，NDK 继续编译 Android 目标。
3. 即使以后出现 apt/gpgv ELF，仍须完成 `--version`、HTTP(S) 下载、GPG 验签、专用 keyring、私有配置/状态目录与真实签名仓库的 App UID 验收；不能把宿主隔离 apt 的通过算作 Android apt 结果。

## 操作注意

- 使用已存在的持久终端会话，先检查两工作树状态。`build-ext.sh arm64` 会重建 `out/arm64-v8a`，之后必须按 [SOURCES_AND_BUILD.md](SOURCES_AND_BUILD.md) 中的顺序重建 userland、file、OpenSSL、可选 `.deb` 和 APK。`app/build/`、`build-ext/` 被 Git 忽略；`third_party/` 的源码和 SHA256 应提交。
- 本轮不运行 `build-ext.sh all`/`arm`：仅基础 dash/JNI 已双 ABI；32 位扩展暂停。Android 用户命令 PATH 禁止 `/system/bin`，仅允许系统动态 linker 作加载器；`targetSdk=28`、私有绝对前缀与 API 24 的 ELF 要同时审查。
- 读源码与文档优先 GitHub raw、`gh.xmly.dev/https://github.com/...` 源码归档，须固定版本/哈希；不要请求 GNU/软件包官网或目标平台预编译二进制。构建机的 Perl、gperf 和将来宿主 yacc 与 NDK 目标 ELF 分开。
- 不把仓库私钥、真实地址猜测值或 `trusted=yes` 写入 App；不要在已安装的 App 上直接清数据做升级实验。设备测试需可重置 arm64 环境，shell UID 隔离结果不能描述为 App UID 验收；Ubuntu 容器内现有 adb 与主机架构不符。

按 [ROADMAP.md](ROADMAP.md) 和 [本分支任务](../TASKS.md) 跟踪下一步；仓库部署/自动导入说明见 [仓库分支 README](https://gh.xmly.dev/https://raw.githubusercontent.com/qwertyuiop982/terminal/main-repo/README.md)。