# TCC：独立源码与构建、真实设备结果

## 项目布局

新增外部项目均为 `/home/Project/Android/` 下的独立目录，未嵌套到 APK 工程：

- `tinycc/`：Git 拉取的 TinyCC 原始源码，固定 `3dc99dbc82f8e07308c5d398136803e62f9676df`。
- `tcc-android/`：独立 Git 构建/打包/HTTP 设备测试工程；NDK 源码构建，没有导入 Termux 二进制。
- `termux-packages/`：独立 Git 参考配方，固定本轮检出的 `2c884d93d5468b7e932280a90ca66b4ff598b0ef`；只参考源码规则，不复制补丁集合。
- `openjdk-17/`：独立 Git 上游 `jdk-17.0.20-ga`，固定 `8cbbca61432426a3441aa08838d930ef954ea1ba`。
- `openjdk17-android/`：独立 Git 的无 GUI Android JDK 构建调查工程，尚无可用 Android JDK 产物。

所有新源码拉取均使用 `git` 与 `https://gh.xmly.dev/<原始GitURL>`，未使用新的源码归档下载。原来已经校验的其他依赖归档保持不变。

## 故障与修复

旧签名包 `tcc 20260922-1` 可以安装，但构建参数只给了 NDK 编译器，漏掉 `--targetos=Android`，导致 TCC 自己的目标配置仍选普通 Linux CRT。还漏装了内建 `stddef.h`/`stdarg.h` 等，libtcc1 搜索路径与实际布局不一致，也缺少 `-run` 的 `runmain.o`。

上游 TinyCC configure 已内置 Android 支持：使用 `--targetos=Android` 正确选择 Android CRT、`__ANDROID__` 和 PIE；将完整 `include/*.h`/`tcclib.h` 放到 `lib/tcc/include`；由宿主可执行 TCC 生成完整 ARM64 运行库；让 `{B}` 搜索路径包含 support/CRT/header。没有伪造 `crt1.o` 到 Android CRT 的链接，没有扩张文件权限或关闭签名。

compiler 内嵌静态 `libtcc.a`，但**不是全静态目标可执行文件**：仍是 `/system/bin/linker64` 加载的 Bionic PIE，依赖系统 libc/libm/libdl，compiler LOAD 对齐 0x4000。仅 arm64/API 24，32 位扩展继续暂停。

## 构建与产物

```sh
# 在 terminal 工程中仅重建/stage TCC，不清理 APT/gpgv/BusyBox/nano 输出：
sh tools/build-tcc.sh arm64
# 独立工程的规范新版本打包入口：
python3 ../tcc-android/package.py
# HTTP-only 设备回归（token-file 必须是用户自行准备的 mode 600 文件）：
python3 ../tcc-android/device-test.py http://192.168.31.23:35565 /private/path/token-file
```

`build-ext.sh` 也委托同一独立构建入口，不再保留出错的重复 TCC 配置；其完整 arm64 构建仍会清理原 DEST，因此 TCC-only 场景必须使用局部入口。

新包：`tcc-android/out/packages/tcc_20260922-2_arm64.deb`，2522560 字节，SHA256 `0be112b7b68a3a4d0f162162d205a600c3a33fb632ebf612da0b02af1511d5cb`。重复打包得到相同哈希；原包 20260922-1 的固定字节没有改写。包含 Installed-Size、md5sums、TinyCC/NDK license notice 和源码/构建清单。

注意：旧 `remote-repo-client/build-packages.sh` 仍是 nano 9.2-1/tcc 20260922-1 的原版本构建入口，不能拿修正后的 stage 去覆盖 20260922-1。当前仓库服务工作树仍有 `bad tree object HEAD`，本轮没有掩盖它或在该工作树推送变更；新包直接由独立工程的 package.py 产生，交给现有签名发布入口导入。

## 2026-10-01 实际设备验证范围

通过 Debug HTTP API，以真实 App UID 10229 上传新包并核对 SHA256，再 **只提取到另建 usr/tmp 子目录**。使用 `tcc -B<候选目录>/lib/tcc` 验证：
- 完整 stddef/stdint/stdarg/stdio/string 头文件链；
- 可变参数函数正确性与 size_t=8；
- `-c` 生成对象文件；
- Android CRT/PIE 链接并执行，输出 `TCC_CANDIDATE_HELLO_OK`；
- `tcc -run` 同样输出，最终 `TCC_CANDIDATE_DEVICE_OK`，任务退出码 0，无 stderr。

候选测试目录已删除；真实数据库中的签名版仍为 `20260922-1`。没有把未经仓库签名发布的新包冒充成 signed-by 安装成功。新版本须由用户在实际仓库主机用现有私钥签名发布，再通过原 signed-by 源 `apt-get update`、`apt-get install tcc` 完成默认前缀的真实升级/不带 -B 回归。未修改仓库信任配置，不接触或导出私钥。

## OpenJDK 17 后续

已执行上游 headless cross-configure 基线尝试；当前错误是旧 config.sub 不识别 `aarch64-linux-android`。尚未开始完整 JDK 编译，更不能宣称 Java 在 App UID 可用。

`--enable-headless-only` 只去除 headful/X11 支持，并不移除 java.desktop 的全部字体/打印/音频依赖。计划明确分离 Android/Bionic 移植与模块构建，最后用 jlink 生成不含 java.desktop 的 java/javac 命令行镜像。任何后续兼容库也独立 Git 拉取/建项，不混入 App。

资料来源（搜索后核对实际 Git 源码，而非 AI 摘要）：
- https://github.com/TinyCC/tinycc/blob/3dc99dbc82f8e07308c5d398136803e62f9676df/configure
- https://github.com/TinyCC/tinycc/blob/3dc99dbc82f8e07308c5d398136803e62f9676df/Makefile
- https://github.com/termux/termux-packages/blob/2c884d93d5468b7e932280a90ca66b4ff598b0ef/packages/tcc/build.sh
- https://github.com/openjdk/jdk17u/blob/jdk-17.0.20-ga/doc/building.md