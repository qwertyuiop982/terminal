# terminal：Android 私有前缀终端

Android App 通过 `MainActivity`、`TerminalSurface`/`TerminalScreen` 展示终端，`TerminalSession` 与 JNI `libpty.so` 驱动 PTY 内的 dash；`Rootfs` 把内置资产释放到应用私有的 `files/usr`。`minSdk=24`，当前 `targetSdk=28`。基础 dash/JNI 有 arm64-v8a 与 armeabi-v7a 两种 ABI，**扩展用户态只构建了 arm64**，32 位扩展继续暂停。

`main` 保存 App 源码；同一 GitHub 仓库的 `main-repo` 分支对应独立的 [remote-repo-client](https://gh.xmly.dev/https://raw.githubusercontent.com/qwertyuiop982/terminal/main-repo/README.md) 工作树，安装脚本运行于另一台 Debian/Termux 仓库主机。nano 和 tcc 是仓库分支的 arm64 bionic `.deb`，**不内置在 APK**。当前 APK 内置 dash、dpkg、file、OpenSSL/CA 与 BusyBox 的 `grep sed awk tar gzip nslookup nc ls cat cp mv rm mkdir touch echo sleep env date uname whoami wget` 等 applets；`apt`/`gpgv` 尚在源码兼容性适配中，**没有进入 APK**，`sources.list` 仍为空。

命令 PATH 仅为 `$USR/bin:$USR/sbin:$USR/libexec`，随 App 提供的脚本使用私有 shell；Android PIE 运行所需的 `/system/bin/linker64`/`linker` 是 OS 加载器，不能据此允许 `/system/bin` 的普通命令。目标程序由 Android NDK 编译，采用 Bionic 动态 PIE 和 16 KB LOAD 对齐；禁止混入 glibc/Termux 目标二进制或无法在私有前缀运行的默认 `#!/bin/sh` 维护脚本。

## 当前证据与界限

- `./tools/build-dash.sh`、`./tools/build-ext.sh arm64`、`./tools/build-userland.sh`、`./tools/build-file.sh`、`./tools/build-openssl.sh` 与 `./tools/check-private-runtime.sh` 有成功的本地结果；`./gradlew :app:assembleDebug :app:lintDebug` 也通过。Debug APK 在 [app-debug.apk](app/build/outputs/apk/debug/app-debug.apk)，是 **apt/gpgv 尚未打包的阶段版本**；Gradle 在缺失扩展树时也可能构建 dash-only APK，不能只看构建成功。
- Android 34 的 `/data/local/tmp` 独立测试目录以 shell UID 验证部分原生工具与私有 CA 的 HTTPS 下载；仓库 `main-repo` 已推送并以隔离宿主 apt 对真实 nano/tcc 包进行带签名 `update`/`download` 验证。当前 APK **没有安装并在 App UID 下验收**；仓库也未在目标主机上线。
- `Rootfs` 的 manifest/hash 保留策略、包文件目录保护和 `TerminalScreen` 的 VT 实现尚缺真机升级、文件归属、IME/全屏程序验证。APT 2.8.1 编译停在 gnulib/glob 头文件冲突，GnuPG gpgv 停在 libksba 的宿主 yacc 依赖（已固定 Bison 源码，构建未通过）；不能运行可信的 Android `apt update`。

源码版本、GitHub raw/源码归档加速地址、固定 SHA256、NDK 顺序和所有注意事项在 [源码与构建](docs/SOURCES_AND_BUILD.md)；技术状态见 [TECHNICAL.md](docs/TECHNICAL.md)，待办与验收见 [ROADMAP.md](docs/ROADMAP.md)，工作区接手点见 [HANDOVER.md](docs/HANDOVER.md)。跨项目任务见 [TASKS.md](TASKS.md)。优先使用 `https://gh.xmly.dev/https://github.com/...` 和 `https://gh.xmly.dev/https://raw.githubusercontent.com/...` 读取固定源码与文档，不用软件官网、GNU 官网或他人编译好的 Android 包。目标仓库地址和签名公钥确定前不预置假的 apt 源、不关闭验签。
