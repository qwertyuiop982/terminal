# terminal：任务与验收顺序

更新：2026-09-27 13:58。`[x]` 表示有范围明确的本地结果；`[ ]` 表示尚未达到对应验收标准。本分支概览在 [../TASKS.md](../TASKS.md)，跨项目本地清单在工作区 `/home/Project/Android/TASKS.md`，源码和网络说明在 [SOURCES_AND_BUILD.md](SOURCES_AND_BUILD.md)。完成 build、Gradle 或 shell UID 冒烟测试不等于 App UID/仓库上线。

## 已验证的本地基线

- [x] 双 ABI 基础 dash/JNI、arm64 的 BusyBox applets、dpkg、file/libmagic、OpenSSL/CA 由 NDK 构建；`grep sed awk tar gzip nslookup nc ls cat cp mv rm mkdir touch echo sleep env date uname whoami wget` 均列入 APK 资产清单。`check-private-runtime.sh` 通过。
- [x] nano/ncurses/terminfo 与 tcc/NDK 头/CRT 输出到 `optional/`；仓库工作树从这些源码产物生成真实 arm64 `.deb`，无 nano/tcc 进入本次 APK。仓库 `main-repo` 已推送，宿主隔离 APT 使用临时测试密钥和专用 `signed-by` 下载两包通过。
- [x] 最新本地 APK 的 `:app:assembleDebug :app:lintDebug`、`check-private-runtime.sh` 和 `tools/test-terminal-screen.sh` 通过；Android 34 以前仅以 shell UID 测 NDK `openssl`、BusyBox `wget` 使用私有 CA 的 HTTPS，不能充当新 APK 的 App UID 结果。

## 接下来的代码与构建任务

1. [x] APT 2.8.1 已用固定源码/可重复 Android 补丁交叉编译，包含 apt、apt-get/apt-cache、apt-key、HTTP(S) methods；旧版在 App UID 下可执行 `apt --version`，但签名文件源 `update` 因 `/tmp/apt.conf.*` 失败。最新构建改为 `$PREFIX/tmp` 和私有工具/加密配置路径，**新 APK 尚未获设备安装许可，未验签**。
2. [x] GitHub 固定源码的宿主 Bison 3.8.2 已编译，已安装宿主 flex 并补齐缺失的生成文件；NDK 构建的 libksba、GnuPG 2.4.8 gpgv 已 staged 到 arm64 `final/`，宿主工具不进 APK。
3. [ ] ZIP 清单含 apt/gpgv/HTTP(S)、libc++、私有 terminfo，不含 nano/tcc；`check-private-runtime.sh`、lint 与抽样 ELF AArch64/PIE/16 KB 对齐已通过。`TerminalScreen` 纯 JVM 回归覆盖滚屏/resize/UTF-8；新 dash 的方向键、APT 签名更新、HTTP(S) 与私有路径仍需新 APK 的 App UID 验证，不得关闭 TLS/验签。未来新发布的可选包必须经 `tools/check-package-paths.sh`，旧版 nano 9.2-1 的 `/tmp/` 回退须在新版本中修复并重新签名。
4. [ ] 为 `third_party/nano/gnulib-snapshot.tar.gz` 补充完整 GitHub 提交来源记录；现有归档 SHA256 已固定但上游提交尚无记录。构建资料只读 GitHub raw/源码归档，优先使用 `https://gh.xmly.dev/<GitHub URL>`，不拉取软件官网或 Termux 预编译目标包。

## 设备和端到端任务

5. [ ] 在**可重置 arm64 设备**安装最新构建 APK，按 App UID 检查首启释放、重复启动、BusyBox 链接、`file` 默认 `magic.mgc`、网络 DNS/CA/wget、21 个 applets 与 `dpkg --version`。已安装的旧版 `com.terminal` 不清数据；最新 APK 安装请求被设备拒绝 (`INSTALL_FAILED_ABORTED: User rejected permissions`)，需用户允许后重试并验证，不得当成新版本已安装。
6. [ ] 用签名仓库的专用公钥和真实 `<IPv4>:<端口>` 配置 `sources.list`（默认仍留空），按 `apt --version` → **有效签名**的 `apt update` → `apt download nano tcc` → `dpkg -i`/`apt install` → 重启/升级验证。客户端绝不可使用 `trusted=yes`、关闭 GPG 校验或下载 glibc/Termux 包；远端私钥不进入源码/APK。
7. [ ] 在 App 终端交互验证 nano/terminfo、`tcc -run`/编译可执行程序、PTY 输入输出、Ctrl/方向键、IME、UTF-8、粘贴、滚动、窗口 resize 和全屏程序。`TerminalScreen` 尚不是完整 VT 仿真器，需要实际设备观察。
8. [ ] 对 `Rootfs` 与 dpkg 共享的 `$USR` 用同名包、用户修改、升级中断、安装失败、BusyBox 链接残留、包文件删除后重启等场景检查数据库/磁盘一致性；当前“不覆盖文件”只是风险缓解。维护脚本和内置脚本必须使用私有 `$USR/bin/sh`，不能让 `/system/bin` 的普通工具混入 PATH。
9. [ ] 32 位**扩展**单列暂停：只有双 ABI 基础 dash/JNI。未经恢复任务的明确指令，不运行 `build-ext.sh all`/`arm`，不将 arm64 文件复制进 `armeabi-v7a`，不称当前 APK 为双 ABI 全功能发行版。

验收记录要区分宿主静态检查、Android shell UID 冒烟、App UID 操作及远端仓库部署，不能互相代替。构建顺序、版本/SHA256 与 GitHub 加速地址详见 [SOURCES_AND_BUILD.md](SOURCES_AND_BUILD.md)。