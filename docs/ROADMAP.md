# terminal：任务与验收顺序

更新：2026-09-27 09:50。`[x]` 表示有范围明确的本地结果；`[ ]` 表示尚未达到对应验收标准。本分支概览在 [../TASKS.md](../TASKS.md)，跨项目本地清单在工作区 `/home/Project/Android/TASKS.md`，源码和网络说明在 [SOURCES_AND_BUILD.md](SOURCES_AND_BUILD.md)。完成 build、Gradle 或 shell UID 冒烟测试不等于 App UID/仓库上线。

## 已验证的本地基线

- [x] 双 ABI 基础 dash/JNI、arm64 的 BusyBox applets、dpkg、file/libmagic、OpenSSL/CA 由 NDK 构建；`grep sed awk tar gzip nslookup nc ls cat cp mv rm mkdir touch echo sleep env date uname whoami wget` 均列入 APK 资产清单。`check-private-runtime.sh` 通过。
- [x] nano/ncurses/terminfo 与 tcc/NDK 头/CRT 输出到 `optional/`；仓库工作树从这些源码产物生成真实 arm64 `.deb`，无 nano/tcc 进入本次 APK。仓库 `main-repo` 已推送，宿主隔离 APT 使用临时测试密钥和专用 `signed-by` 下载两包通过。
- [x] `:app:assembleDebug :app:lintDebug` 完成（APK 不含 apt/gpgv）。Android 34 `/data/local/tmp` **shell UID** 的 NDK `openssl` 和 BusyBox `wget` 使用私有 PATH 和固定 CA 从 GitHub 加速 raw URL 成功下载校验清单；此前双 ABI dash 与基础命令也在该隔离目录冒烟通过。

## 接下来的代码与构建任务

1. [ ] 修复 APT 2.8.1 在 NDK API 24 的 `glob`/gnulib 头文件冲突：`apt-gnulib-headers/glob-libc.gl.h` 的 `restrict` 与 `rpl_glob` 声明不兼容。只修改可复现的源码补丁和构建步骤，不把宿主 glibc 的 glob 库打入 Android；重新检查 apt、apt-get、apt-cache、apt-config、HTTP(S) methods、apt-key 和 `libc++_shared.so` 的 ELF 依赖。完整错误见 `/tmp/terminal-build-apt.log`。
2. [ ] 为 libksba 的 `asn1-parse.y` 完成已固定 GitHub 的 Bison 3.8.2 **宿主** 构建，提供 `yacc` 接口；或复用经核验的上游生成文件；确保宿主程序不进 APK。继续完成 GnuPG `gpgv` 及 libassuan、npth、libksba 构建与 Bionic 兼容检查。当前错误见 `/tmp/terminal-build-gpgv.log`。
3. [ ] 在 NDK 动态 PIE 上逐个检查 `apt --version`、`gpgv --version`、`readelf -d/-l`、API 24 符号可用性、16 KB LOAD 对齐、可执行 shebang、私有 PATH、CA 读取。完成后重跑 `check-private-runtime.sh` 与 Gradle，并核对 APK ZIP/资产哈希中确实有 apt/gpgv/HTTP(S) method、确实没有 nano/tcc；不能用关闭 TLS 或验签换取构建成功。
4. [ ] 为 `third_party/nano/gnulib-snapshot.tar.gz` 补充完整 GitHub 提交来源记录；现有归档 SHA256 已固定但上游提交尚无记录。构建资料只读 GitHub raw/源码归档，优先使用 `https://gh.xmly.dev/<GitHub URL>`，不拉取软件官网或 Termux 预编译目标包。

## 设备和端到端任务

5. [ ] 在**可重置 arm64 设备**安装新构建 APK，按 App UID 检查首启释放、重复启动、损坏后恢复、BusyBox 链接、`file` 默认 `magic.mgc`、网络 DNS/CA/wget，实际执行指定的 21 个 applets 与 `dpkg --version`。既有设备 `com.terminal` 数据不作为实验对象，先明确可覆盖范围。
6. [ ] 用签名仓库的专用公钥和真实 `<IPv4>:<端口>` 配置 `sources.list`（默认仍留空），按 `apt --version` → **有效签名**的 `apt update` → `apt download nano tcc` → `dpkg -i`/`apt install` → 重启/升级验证。客户端绝不可使用 `trusted=yes`、关闭 GPG 校验或下载 glibc/Termux 包；远端私钥不进入源码/APK。
7. [ ] 在 App 终端交互验证 nano/terminfo、`tcc -run`/编译可执行程序、PTY 输入输出、Ctrl/方向键、IME、UTF-8、粘贴、滚动、窗口 resize 和全屏程序。`TerminalScreen` 尚不是完整 VT 仿真器，需要实际设备观察。
8. [ ] 对 `Rootfs` 与 dpkg 共享的 `$USR` 用同名包、用户修改、升级中断、安装失败、BusyBox 链接残留、包文件删除后重启等场景检查数据库/磁盘一致性；当前“不覆盖文件”只是风险缓解。维护脚本和内置脚本必须使用私有 `$USR/bin/sh`，不能让 `/system/bin` 的普通工具混入 PATH。
9. [ ] 32 位**扩展**单列暂停：只有双 ABI 基础 dash/JNI。未经恢复任务的明确指令，不运行 `build-ext.sh all`/`arm`，不将 arm64 文件复制进 `armeabi-v7a`，不称当前 APK 为双 ABI 全功能发行版。

验收记录要区分宿主静态检查、Android shell UID 冒烟、App UID 操作及远端仓库部署，不能互相代替。构建顺序、版本/SHA256 与 GitHub 加速地址详见 [SOURCES_AND_BUILD.md](SOURCES_AND_BUILD.md)。