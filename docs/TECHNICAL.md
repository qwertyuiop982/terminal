# terminal 技术文档

> 更新时间：2026-09-26 · 分支 `main` · 基线提交 `151d56d`

---

## 1. 项目概述

一个极度精简的 Android 终端 App：自带交叉编译的 **dash 0.5.13.5** 作为 shell，运行期在应用私有目录搭建 POSIX 前缀（`files/usr`），通过 JNI PTY 与之交互。

- `minSdk` 24 / `targetSdk` **28**（刻意低于 Android 10 的 W^X 限制，允许在数据目录内 `execve()`）
- `compileSdk` 35，AGP 8.13，Kotlin 2.1，NDK r29（29.0.14206865）
- 双 ABI：`arm64-v8a`、`armeabi-v7a`
- 依赖仅 4 个 androidx/material 库，无第三方框架

## 2. 系统架构

```
┌────────────────────────────────────────────────────────┐
│ MainActivity（单 Activity）                             │
│   EditText 行输入 + ScrollView/TextView 输出面板         │
│   单线程 Executor 串行化所有 PTY I/O                     │
└───────────────┬────────────────────────────────────────┘
                │ TerminalSession（读线程轮询 + 回调）
                ▼
┌────────────────────────────────────────────────────────┐
│ Pty（JNI 封装，Long handle）                            │
│   nativeOpen/Read/Write/Resize/Wait/Close              │
└───────────────┬────────────────────────────────────────┘
                ▼
┌────────────────────────────────────────────────────────┐
│ libpty.so（pty.c）                                      │
│   /dev/ptmx → grantpt/unlockpt → fork                   │
│   子进程: setsid + TIOCSCTTY + dup2 + execve(dash -i)   │
│   会话注册表 + 全局互斥锁（防 use-after-free）           │
└───────────────┬────────────────────────────────────────┘
                ▼
┌────────────────────────────────────────────────────────┐
│ files/usr 前缀（Rootfs.kt 首启搭建）                     │
│   bin/{dash,sh} ← assets 释放（按 ABI）                 │
│   etc/{passwd,profile,apt…} · var/lib/dpkg · tmp …      │
│   [进行中] dpkg/tcc/压缩库 ← assets/prefix 释放          │
└────────────────────────────────────────────────────────┘
```

关键设计点：

1. **targetSdk 锁 28** 是权衡而非疏忽——绕过 Android 10 起对应用数据目录 `execve()` 的封禁。
2. dash 交互模式只读 `$ENV` 不读 `/etc/profile`，因此 `Rootfs.environment()` 里必须注入 `ENV=$USR/etc/profile`。
3. pty.c 用「会话注册表 + 全局锁」保证 `close()` 与在途 read/write 并发安全；`EIO`（slave 关闭=子进程退出）翻译为 0 让 Java 层正确收割退出码。

## 3. 项目结构

```
terminal/
├── app/src/main/
│   ├── AndroidManifest.xml            # INTERNET；exported Activity
│   ├── jni/
│   │   ├── pty.c                      # PTY 原生源（~350 行）
│   │   ├── Android.mk / Application.mk
│   ├── jniLibs/{arm64-v8a,armeabi-v7a}/libpty.so
│   ├── assets/
│   │   ├── bin/dash-{arm64-v8a,armeabi-v7a} + SHA256SUMS
│   │   ├── licenses/dash-COPYING
│   │   └── prefix/                    # ★ build-ext.sh 产物（见 §5）
│   │       ├── prefix-<abi>.tar.gz
│   │       └── SHA256SUMS
│   ├── kotlin/com/terminal/
│   │   ├── MainActivity.kt            # UI + 调度
│   │   ├── TerminalSession.kt         # 读泵 + 生命周期
│   │   ├── Pty.kt                     # JNI 声明
│   │   └── Rootfs.kt                  # 前缀初始化（★待改造，见 §6.3）
│   ├── res/…                          # Material3 深色主题
│   └── obj/ libs/                     # ndk-build 产物（已 gitignore）
├── third_party/
│   ├── dash/                          # 上游 tarball + bionic 补丁
│   ├── tcc/                           # tinycc-mob-20260922.tar.gz + TCC_COMMIT（pin 3dc99db）
│   ├── dpkg/                          # dpkg-1.22.6.tar.xz（snapshot.debian.org）
│   ├── zlib/bzip2/xz/zstd/libmd/      # 依赖库 tarball
│   └── SHA256SUMS
├── tools/
│   ├── build-dash.sh                  # dash 交叉编译（已可用）
│   └── build-ext.sh                   # ★ dpkg+tcc 扩展构建（进行中）
├── build-ext/                         # 构建工作区（gitignore）
│   ├── src/                           # 解包后的源码树
│   ├── out/<abi>/stage|final|dpkg-stage/
│   └── ref/                           # Termux 参考脚本
├── docs/TECHNICAL.md                  # 本文档
├── gradle/libs.versions.toml          # AGP 8.13 / Kotlin 2.1
└── README.md
```

## 4. 构建体系

| 目标 | 命令 | 说明 |
|---|---|---|
| APK | `./gradlew :app:assembleDebug` | 产物 `app/build/outputs/apk/debug/app-debug.apk` |
| libpty.so | 在 `app/src/main/jni` 下执行 `ndk-build NDK_PROJECT_PATH=…`（见 fix_all 历史）或依赖 jniLibs 已有产物 | |
| dash | `tools/build-dash.sh` | 需 NDK；产出进 `assets/bin/` |
| dpkg/tcc 扩展 | `tools/build-ext.sh [all\|arm64\|arm]` | **进行中**，见 §5 |

## 5. dpkg + tcc 扩展：当前状态（未完成，已冻结）

### 5.1 方案

参照 Termux `packages/{tcc,dpkg}/build.sh`：

- **tcc 双阶段**：先用 NDK clang 编一个能在本机跑的 `tcc.host`，再配出目标为 Android 的交叉 tcc；`libtcc1.a` 用 NDK clang 直接编译对象、llvm-ar 打包（本机没有可运行的目标 tcc，无法复刻 Termux 完整流程，做了等价改造）。
- **路径烧录**：tcc/dpkg 在 configure 期硬编码路径，统一对准设备路径 `/data/data/com.terminal/files/usr`。
- **产物打包**：所有二进制/库/头文件/crt 汇入 `out/<abi>/final/`，压缩为单 tar 放进 `assets/prefix/`，运行期由 Rootfs 解包。
- **dpkg 依赖**：zlib 1.3.1、bzip2 1.0.8（动态）、xz 5.6.3(liblzma)、zstd 1.5.6（静态）、**libmd 1.1.0**（dpkg 1.22 硬依赖 md5，Termux 同样显式依赖）。

### 5.2 组件矩阵（截至冻结时点）

| 组件 | 版本 | 状态 |
|---|---|---|
| zlib | 1.3.1 | ✅ libz.a |
| bzip2 | 1.0.8 | ✅ libbz2.so.1.0 + bzip2 |
| xz/liblzma | 5.6.3 | ✅ .a + .so（soname 无版本，已补别名 liblzma.so.5）|
| zstd | 1.5.6 | ✅ 仅 libzstd.a（dpkg 以静态链接消费）|
| libmd | 1.1.0 | ✅ libmd.a |
| tcc | mob@3dc99db (2026-09-22) | ✅ 交叉 tcc 编译成功并 strip |
| libtcc1.a | 同上 | 🔧 刚修复 armflush 的 `__arm64_clear_cache`（clang 无此符号，改写为 `__builtin___clear_cache` 等价实现）——**修复后未跑完验证** |
| dpkg | 1.22.6 | 🔧 configure 已带上 `-lmd/-I/-L`，**编译未验证** |

### 5.3 已解决的关键坑（供后续参考）

1. **下载**：`gh.xmly.dev` 加速对 git 协议不透明 → repo.or.cz 直连 clone；GitHub release/xz 的 URL 组合 404 → 换 tarball 扩展名或 `--http1.1`；dpkg 老版本在 deb.debian.org 已下架 → 用 `snapshot.debian.org/archive/debian/<时间戳>/pool/...`。
2. **POSIX sh**：`"VAR=x" cmd` 不是赋值前缀而是命令名（dash 报 not found）→ 去掉引号。
3. **zlib**：`make shared` 会去链不存在的 libz.so 报 `inflateInit_` 未定义 → 静态为主，shared 失败可容忍。
4. **xz**：libtool 在 Android 上产出无版本号 `liblzma.so`，不能按 `liblzma.so.5.6.3` 硬拷。
5. **zstd**：没有 `libzstd.so` / `libzstd.so-libzstd.a` 目标，只有 `libzstd.a`。
6. **tcc configure**：`--cross-prefix` 会拼 `<prefix>clang`，NDK 里是 `<triple>-clang` → 传 `--cross-prefix=$BIN/${TRIPLE}- --cc=clang`；Makefile 会生成 `aarch64-linux-android24-ar` 这种不存在的工具 → `make AR=$BIN/llvm-ar`。
7. **tcc 宿主工具**：`c2str.exe` 若用 Android clang 编译则无法在本机运行 → 用宿主 gcc 编译并预生成 `tccdefs_.h`。
8. **tcc 链接**：bionic 内置 pthread/dl → `LIBS="-lm"` 覆盖掉 `-lpthread -ldl`。
9. **libtcc1.a**：`armflush.c` 依赖 tcc 自身提供的 `__arm64_clear_cache` → 用 clang 内建 `__builtin___clear_cache` 写了等价替身（armflush-clang.c）。

### 5.4 冻结时的最后状态

最后一次 `./tools/build-ext.sh arm64` 被**手动取消**，未产出结论。此前最后一次完整运行停在：dpkg configure 报 `md5 digest functions not found`（已通过 `CPPFLAGS/LDFLAGS/LIBS=-lmd` 修复，待验证）。

## 6. 下一步操作（接手指南）

### 6.1 跑通 arm64

```sh
cd /home/Project/Android/terminal
./tools/build-ext.sh arm64 2>&1 | tee /tmp/ext.log
```

检查两个悬而未决点：

1. `build-ext/out/arm64-v8a/stage/lib/tcc/libtcc1.a` 是否生成（日志里不再出现 `WARN: libtcc1.a missing`）；
2. dpkg configure 是否越过 `md5 digest functions not found`。

### 6.2 预期还会撞的问题（按可能性排序）

- **dpkg 编译期 glibc-ism**：若报 `error.h`/`obstack.h`/`gettext` 等，去 Termux 仓库 `packages/dpkg/*.patch` 拉补丁移植（走 `https://gh.xmly.dev/https://raw.githubusercontent.com/termux/termux-packages/master/packages/dpkg/<patch>`）。dpkg 1.22.6 的 `--disable-nls` 已加，通常剩下的是 minor。
- **收集阶段符号链接**：`final/lib` 里 `cp -rf` 会解引用软链，若 `liblzma.so.5` 等别名变成实体文件可接受（多占几 KB），如需保留真链改 `cp -a`。
- **dpkg 安装布局**：`make install DESTDIR=…/dpkg-stage` 后实际路径是 `dpkg-stage/data/data/com.terminal/files/usr/...`，collect 段的 `find` 已按 `*/bin/*`、`*share/dpkg`、`*etc/dpkg` 通配，若空则微调。

### 6.3 运行期集成（APK 侧改造）

1. **解包方案**：设备上没有 tar 二进制，二选一：
   - **推荐**：加 `implementation("org.apache.commons:commons-compress:1.26.2")`，在 `Rootfs.ensure()` 里用 `TarArchiveInputStream + GzipCompressorInputStream` 解 `assets/prefix/prefix-<abi>.tar.gz`；按 ABI 缓存已释放版本号（如写 `usr/.prefix-version`）。
   - 备选：后续编译静态 busybox/tar 进 `bin/`。
2. **Rootfs.kt 改造点**：
   - `ensure()` 增加 `extractPrefix(context)`：校验 SHA256 → 解包到 `usr/` → 逐文件 `setExecutable(true, false)`（assets 解包不保留权限位，**必须显式 chmod**）；
   - `environment()` 的 PATH 无需改动（前缀已在 `$USR/bin`）；
   - `aptConf()` 里 `Dir::Bin::Dpkg` 指向 `/system/bin/dpkg` 的占位改成 `$USR/bin/dpkg`；
   - `etc/dpkg/dpkg.cfg` 占位内容替换为真实配置（`admindir $USR/var/lib/dpkg`）。
3. **版本升级策略**：assets 里 tar 包带 `SHA256SUMS`，`usr/.prefix-version` 记录上次释放的 hash；hash 变化则整体删除 `usr/{bin,lib,include,share,etc/dpkg}` 后重放（保留 `home/` 与 `var/lib/dpkg/` 用户数据）。
4. **构建 + 验证**：
   ```sh
   ./gradlew :app:assembleDebug
   # 设备上验证：
   tcc -v ; tcc -run /tmp/hello.c
   dpkg --version ; dpkg -i /path/to/pkg.deb   # .deb 的 data.tar 由 liblzma/bz2/zstd 支撑
   ```

### 6.4 收尾项

- 双 ABI 全量：`./tools/build-ext.sh all`，确认 `assets/prefix/` 出两个 tar；
- `git add third_party/ tools/build-ext.sh docs/ && git commit`（tarball 共 ~13MB，与 dash 先例一致）；
- 视需要把 `.gitignore` 加上 `build-ext/`。

## 7. 已完成的主体修复（历史，供追溯）

提交 `151d56d`：修复 `fix_all.sh` 造成的全项目字符串转义损坏（编译失败根因）；pty.c 会话注册表 + 全局锁消除 use-after-free；子进程每条 close 路径都被收割；EINTR 重试 / EIO→0；Kotlin 双启动竞态、死会话丢输入、`ENV=/etc/profile` 注入；清理一次性脚本与 .gitignore。

## 8. 参考

- Termux 构建脚本：`build-ext/ref/{tcc,dpkg}-build.sh`（自 termux-packages master 拉取）
- tinycc 上游：https://repo.or.cz/tinycc.git（mob 分支，pin `3dc99dbc82f8e07308c5d398136803e62f9676df`）
- dpkg 上游：snapshot.debian.org（1.22.6）
- gh 加速：`https://gh.xmly.dev/https://github.com/...`
