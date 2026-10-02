# 源码、GitHub 加速与 Android NDK 构建

更新：2026-09-27。适用于 `terminal/main` 与同一 GitHub 仓库的 `main-repo` 分支。`main-repo` 是独立的仓库服务项目工作树；它的 `packages/` 保存可选 nano/tcc 包，APK 只从 `terminal/build-ext/out/<abi>/final/` 取内置资产。下文的“已构建”不等于 App UID 或仓库目标机验收。

## 网络和来源

优先读取 GitHub 仓库的 **raw 文件或源码归档**，不要用 GitHub 网页页面当脚本输入，也不要为了构建去访问 GNU/软件包官网或抓取任何现成目标二进制。本环境可使用的读地址格式是：

```text
https://gh.xmly.dev/https://github.com/<owner>/<repo>/archive/refs/tags/<tag>.tar.gz
https://gh.xmly.dev/https://github.com/<owner>/<repo>/archive/<commit>.tar.gz
https://gh.xmly.dev/https://raw.githubusercontent.com/<owner>/<repo>/<commit-or-tag>/<path>
```

例如，[OpenSSL 的 Android 构建说明](https://gh.xmly.dev/https://raw.githubusercontent.com/openssl/openssl/openssl-3.5.4/NOTES-ANDROID.md)、[GnuPG 2.4.8 README](https://gh.xmly.dev/https://raw.githubusercontent.com/gpg/gnupg/gnupg-2.4.8/README) 和 [BusyBox 1.38 wget 源码](https://gh.xmly.dev/https://raw.githubusercontent.com/mirror/busybox/fc71374dfccd46448c62947269a35f1420d7ee28/networking/wget.c) 都可用固定引用读取。镜像是下载通道，不是签名或来源证明；归档必须与已提交的 SHA256 清单匹配，来源变更要重新审查和固定摘要。`git push` 仍使用已配置凭证的 `https://github.com/qwertyuiop982/terminal.git`，**不向加速服务提交凭证、私钥或写请求**。

| 原始源码/资料 | GitHub 固定引用（经 `gh.xmly.dev` 读取） | 本地核验 |
| --- | --- | --- |
| BusyBox 1.38.0，镜像提交 `fc71374dfccd46448c62947269a35f1420d7ee28` | `https://gh.xmly.dev/https://github.com/mirror/busybox/archive/fc71374dfccd46448c62947269a35f1420d7ee28.tar.gz` | `third_party/userland-SHA256SUMS` |
| GNU nano 9.2，镜像提交 `88ae189f6845e738224448cbedb2cee2fb3eff66` | `https://gh.xmly.dev/https://github.com/madnight/nano/archive/88ae189f6845e738224448cbedb2cee2fb3eff66.tar.gz` | 同上；gnulib 快照单独核验 |
| ncurses 6.4，镜像提交 `79b9071f2be20a24c7be031655a5638f6032f29f` | `https://gh.xmly.dev/https://github.com/mirror/ncurses/archive/79b9071f2be20a24c7be031655a5638f6032f29f.tar.gz` | 同上 |
| OpenSSL 3.5.4 | `https://gh.xmly.dev/https://github.com/openssl/openssl/archive/refs/tags/openssl-3.5.4.tar.gz` | `third_party/userland-SHA256SUMS` |
| GNU libiconv 1.18 的原始源码镜像 | `https://gh.xmly.dev/https://github.com/roboticslibrary/libiconv/archive/refs/tags/v1.18.tar.gz` | `third_party/apt/SHA256SUMS` |
| GnuPG 2.4.8 | `https://gh.xmly.dev/https://github.com/gpg/gnupg/archive/refs/tags/gnupg-2.4.8.tar.gz` | `third_party/apt/gnupg/SHA256SUMS` |
| libassuan 2.5.7 | `https://gh.xmly.dev/https://github.com/gpg/libassuan/archive/refs/tags/libassuan-2.5.7.tar.gz` | 同上 |
| libksba 1.6.7 | `https://gh.xmly.dev/https://github.com/gpg/libksba/archive/refs/tags/libksba-1.6.7.tar.gz` | 同上 |
| npth 1.7 | `https://gh.xmly.dev/https://github.com/gpg/npth/archive/refs/tags/npth-1.7.tar.gz` | 同上 |
| NetBSD libedit 源码镜像，提交 `cabe0cf6a78a93fc9389e5fe1e3814790a6d8787` | `https://gh.xmly.dev/https://github.com/ThomasAdam/libedit/archive/cabe0cf6a78a93fc9389e5fe1e3814790a6d8787.tar.gz` | `third_party/dash/libedit/SHA256SUMS`；NDK 静态链接进 arm64 dash |
| 宿主构建工具 gperf，提交 `1a8e476f99335ad5a553f24f1956a084fc6adc10` | `https://gh.xmly.dev/https://github.com/roboticslibrary/gperf/archive/1a8e476f99335ad5a553f24f1956a084fc6adc10.tar.gz` | `third_party/apt/host/SHA256SUMS`；只在构建机运行 |
| 宿主解析器 Bison 3.8.2（已构建） | `https://gh.xmly.dev/https://github.com/akimd/bison/archive/refs/tags/v3.8.2.tar.gz` | `third_party/apt/host/SHA256SUMS`；不得进入 APK |
| Mozilla CA bundle，`bagder/ca-bundle` 提交 `ab325adf04921579c89f77559fce20f964695ca9` | `https://gh.xmly.dev/https://raw.githubusercontent.com/bagder/ca-bundle/ab325adf04921579c89f77559fce20f964695ca9/ca-bundle.crt` | `third_party/ca/SHA256SUMS`；源数据 2026-09-03 |

`third_party/SHA256SUMS` 另固定 dpkg 1.22.6、tinycc mob、zlib、bzip2、xz、zstd、libmd；`third_party/dash/SHA256SUMS`、`third_party/file/SHA256SUMS` 和 `third_party/apt/SHA256SUMS` 固定 dash 0.5.13.5、file 5.48、APT 2.8.1 等归档。**这些已有归档不一定来自 GitHub 镜像**；保留原文件与 SHA256，不能为了统一网址无校验地换源。`gnulib-snapshot.tar.gz` 固定了字节哈希，但文件名尚未记录完整上游提交，补充来源记录列入任务清单；构建期间不要让脚本从网络更新 gnulib。除 BusyBox 等项目自身源码外，不引入 Termux 包、glibc `.deb`、发行版二进制或未经审查的第三方补丁。

## 构建次序（当前能完成的部分）

1. 使用同一个已装 Android NDK 29 的持久终端会话，保留工作区现有未提交代码和用户数据；`build-ext.sh arm64` **会清空 `build-ext/out/arm64-v8a`**，每次重跑都必须重新生成其后的阶段。不要运行 `build-ext.sh all` 或 `build-ext.sh arm`：32 位扩展仍暂停；双 ABI 基础 dash/JNI 不受这一条限制。
2. 在 `terminal/` 下按顺序执行：

   ```sh
   ./tools/build-dash.sh
   ./tools/build-ext.sh arm64
   ./tools/build-userland.sh
   ./tools/build-dash-edit.sh
   ./tools/build-file.sh
   ./tools/build-openssl.sh
   ./tools/build-apt.sh
   ./tools/build-gpgv.sh
   ./tools/check-private-runtime.sh
   ./gradlew :app:assembleDebug :app:lintDebug
   ```

   `build-ext.sh` 将 tcc、NDK 头文件和 CRT 输出到 `build-ext/out/arm64-v8a/optional/tcc`；`build-userland.sh` 将 nano、ncurses、terminfo 输出到 `optional/nano`。`build-dash-edit.sh` 从固定 GitHub 提交的 libedit 与 NDK ncurses 静态构建 arm64 行编辑 shell，并提供私有 terminfo；必须在基础双 ABI `build-dash.sh` 后运行，否则会被旧 arm64 dash 覆盖。Gradle 只打包 `final/`，因此升级脚本也必须检查旧 APK 是否仍含 nano/tcc；`app/build/` 和 `build-ext/` 都不是 Git 源码。`file` 的 `magic.mgc` 由宿主构建阶段生成数据库，目标 `file`/libmagic 来自 NDK 交叉编译。
3. 可选包构建在另一工作树运行 `sh ../remote-repo-client/build-packages.sh`，得到 `packages/nano_9.2-1_arm64.deb`、`tcc_20260922-1_arm64.deb` 及 `SHA256SUMS`。`.deb` 内的 `bin/`、`lib/`、`include/` 是**相对应用私有 `usr` 根**的路径，不是安装到 Android `/bin`。新建版本必须通过 `tools/check-package-paths.sh <staging-root>`，拒绝 `/tmp`、`/usr`、`/etc`、系统 shell shebang 和越界软链接，构建入口会执行此门禁。已发布 nano 9.2-1 带有旧 `/tmp/` 回退字符串，只在 App 私有 `TMPDIR` 下使用；修复并重新发布须另设版本，旧版本不可覆盖同名不同哈希的云端包。
4. `./tools/build-apt.sh`、`./tools/build-gpgv.sh` 已在本地成功，宿主 Bison 3.8.2/flex 仅用于源码生成，Android ELF 均由 NDK 构建。包含 apt/gpgv/HTTP(S) methods、arm64 libedit dash 的新 APK 已通过 `:app:assembleDebug :app:lintDebug` 和 `check-private-runtime.sh`；设备上的**旧 APK**曾用 `pm install -r` 升级，但没有升级前后全部用户文件比对，不能保证数据完整性。2026-09-27 22:00 的新 APK 安装请求被系统以 `INSTALL_FAILED_ABORTED: User rejected permissions` 拒绝；不能把新 APK 当作 App UID 验收。没有签名目标仓库上线或可信 `apt update` 证据。如重置 `out/arm64-v8a`，仍须按上述顺序重建所有阶段。

Bionic/API 24 的目标产物应是带 `/system/bin/linker64` 的 NDK 动态 PIE，检查 `readelf -l/-d`、ELF 架构、未解析依赖和 LOAD 段 16 KB 对齐。构建时使用的宿主 Perl、gperf、gnulib、`magic.mgc` 生成器不应被误打入 APK；依赖 `.a` 参与动态 PIE 的链接不等于发布全静态 Android 可执行文件。私有命令的 PATH 只能是 `$USR/bin:$USR/sbin:$USR/libexec`，允许 Android 的 linker 作为 OS 加载器，不允许用 `/system/bin` 下的普通命令代替缺失功能。APK 的 `targetSdk=28` 与私有数据目录 execve 有关，调整需要重新做真机验证。

## 内置/可选命令和验收范围

`grep sed awk tar gzip nslookup nc ls cat cp mv rm mkdir touch echo sleep env date uname whoami wget` 由 NDK 编译的 BusyBox applets 提供；`file` 和 `dpkg` 是额外内置命令；`dash` 为 shell。`wget` 用 NDK 编译的 OpenSSL CLI 验证 TLS 证书，BusyBox 自带**不验证证书**的 HTTPS 实现被禁用。APK 内置固定 SHA256 的 Mozilla CA bundle，`SSL_CERT_FILE=$USR/etc/ssl/cert.pem`；证书需定期从固定 GitHub 提交更新并重新校验。`nslookup` 读取私有 `etc/resolv.conf`，App 优先从设备网络获取 DNS，网络服务不可用时保留现有文件/初始回退值。`nano`、`tcc` 只能从兼容仓库按需安装；`apt`/gpgv/HTTP(S) methods 已内置 arm64 APK，实际签名验收仍待完成。

Android `/data/local/tmp` 的早期 shell UID 冒烟与设备 `run-as com.terminal` 的旧版 App UID `apt --version`、`gpgv --version` 均有记录；旧版首次释放 `MANAGED_FILES` 曾因 Android 拒绝硬链接失败，后改为校验后的私有文件原子改名，随后安装的版本已成功释放。当前含行编辑 dash、APT 私有路径修复、滚屏 resize 修复的新 APK **只做到了构建/静态审计，未安装**（系统拒绝安装权限）。仍需 App UID 签名 apt、方向键/IME、PTY/滚屏/resize 和升级验证；不能清除现有 `com.terminal` 数据。`Rootfs` 的资产冲突及 dpkg 数据库回滚尚未完成验收。

APT 源列表保持空白，直到已部署仓库地址、可信仓库公钥指纹与客户端专用 `signed-by` keyring 都确定。不能用 `trusted=yes`、关闭 TLS/签名验证或预置不存在的地址代替验收；仓库签名私钥绝不可打包到 APK 或推送 Git。独立仓库项目工作说明见 [仓库 README](https://gh.xmly.dev/https://raw.githubusercontent.com/qwertyuiop982/terminal/main-repo/README.md)，任务状态见 [本分支任务清单](../TASKS.md) 和 [仓库分支任务](https://gh.xmly.dev/https://raw.githubusercontent.com/qwertyuiop982/terminal/main-repo/TASKS.md)。