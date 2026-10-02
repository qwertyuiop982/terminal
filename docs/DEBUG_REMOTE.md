# Debug 远程管理

启动 Debug App 会自动启动前台 `DebugRemoteService`，监听 `0.0.0.0:35565`。手机 Wi-Fi 地址为 `192.168.31.23` 时，浏览器入口是 `http://192.168.31.23:35565/`；本机可用 `http://127.0.0.1:35565/`。`192.168.*` 是局域网地址，互联网访问需要另外提供可到达的路由。切换网络不需要重启监听器，App 连接信息显示当前地址。

App 顶部“调试服务 :35565 · 连接信息”提供地址、访问令牌、复制和停止入口。通知中也能停止服务。令牌由 `SecureRandom` 生成，保存在 App 私有 `no_backup/debug-remote-token`，不会内置 APK、出现在 URL、自动注入网页或作为公钥使用。网页保存令牌到当前浏览器会话；所有 `/api/` 请求必须带 `Authorization: Bearer <token>`，不允许跨站来源调用。

网页支持命令执行和结果轮询、目录浏览、文本编辑、新建/删除、上传/下载、重命名，以及内部↔外部存储复制和移动。命令使用 App UID、`/data/data/com.terminal/files/usr/bin/sh -c`、私有 PATH/环境；返回 stdout、stderr、退出码、超时、取消和截断标志。默认超时 30 秒，上限 300 秒，最多同时四个命令；stdout/stderr 各保留最多 2 MiB，同时持续读管道以免输出阻塞。完成的最近 12 个任务留在内存，服务停止会取消自己的任务。

文件管理允许 App 的 `/data/data/com.terminal/files` 和它有权访问的 `/storage/emulated/0`。外部存储需要 Debug 的读写存储权限；Android 限制的其他 App 私有目录不在支持范围。文件和目录跨存储复制校验内容；跨存储移动在完整复制及校验后删除源。同文件系统移动用改名。删除树不跟随符号链接；不能替换或删除存储根。目标已有文件时复制/移动返回 409，不进行目录合并或静默覆盖。编辑可传旧文件 SHA256 防止覆盖同时修改；一次上传最多 16 MiB，编辑读取最多 8 MiB，下载和存储间复制使用流式传输。

## HTTP API

| 方法与路径 | 参数或正文 | 结果 |
| --- | --- | --- |
| `GET /api/status` | 无 | UID、前缀、地址、允许的存储根、外部权限 |
| `POST /api/exec` | `command`, 可选 `cwd`, `stdin`, `timeoutMs` | 202 与任务 `id` |
| `GET /api/jobs/<id>` | 无 | 实时 stdout/stderr、退出码和状态 |
| `POST /api/jobs/<id>/cancel` | `{}` | 取消任务 |
| `GET /api/files` | query `path`, 可选 `offset`, `limit` | 文件清单、UID/GID/模式、大小 |
| `GET /api/files/read` | query `path` | UTF-8、base64、SHA256 |
| `GET /api/file` | query `path` | 原始文件下载 |
| `POST /api/upload` | query `path`, 可选 `overwrite=true`, `sha256`；原始文件正文 | 原子写入 |
| `POST /api/files/write` | `path`, `text` 或 `base64`, 可选 `overwrite`, `sha256` | 原子写入及 SHA256 |
| `POST /api/files/mkdir` | `path` | 新建目录 |
| `POST /api/files/delete` | `path`, 可选 `recursive` | 删除文件或目录 |
| `POST /api/files/copy` | `source`, `destination` | 复制至新的完整目标路径 |
| `POST /api/files/move` | `source`, `destination` | 移动至新的完整目标路径 |
| `GET /api/permissions` | 无 | 遍历 App 私有目录的归属/可访问性报告 |
| `POST /api/permissions/repair` | `{}` | 只补 App 自有目录的 owner rwx，不改其他 UID 或跟随符号链接 |

脚本客户端示例（令牌由 App 的连接信息获取）：

```sh
curl -H "Authorization: Bearer $TERMINAL_DEBUG_TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{"command":"apt --version","timeoutMs":5000}' \
  http://192.168.31.23:35565/api/exec
```

## 变体与验证

服务、HTTP/命令/文件实现、网页和额外权限只在 `app/src/debug/`；Release 只有空的 `DebugFeatures.attach`，没有监听器、服务声明、网页或访问令牌代码。保持同一个 `com.terminal` applicationId，以匹配 NDK 私有前缀，不能用 applicationIdSuffix 创建不同目录却运行固定前缀程序。

`tools/test-debug-remote.py <base-url> <token-file>` 在新建临时目录中检查鉴权、跨站拒绝、UID/路径、命令输出/退出码/超时/取消、编辑冲突、上传/下载、目录删除以及内部↔外部复制/移动，最后删除测试文件。2026-10-01 已在真实 Debug App UID 下通过；手机 Wi-Fi 暂时无 IPv4 时使用本机 HTTP，首次启动时 LAN 页面曾以 192.168.31.23 返回 200。Release 编译和合并 manifest 检查确认远程实现及存储权限不进入 Release。
## 最新设备验收（2026-10-01）
覆盖安装成功，APK SHA256：`957b35f54ad2e94f4b6404069e4b78acd9cc7aeab0da71bc2ad1d73d9819cf1e`。通过 `http://192.168.31.23:35565` 运行两项 Python HTTP 回归，鉴权、Origin、命令超时取消、文件操作、双向跨存储复制移动及隔离 dpkg 安装/升级/purge 全部通过，未改动实际 dpkg 数据库。另通过 curl POST exec 和 GET jobs 验证命令控制，diff/cmp 私有路径与运行正常、APT 2.8.1 返回正常；网页 `/`（3850 字节）及 `/remote.js`（7098 字节）均可读取。此为同设备经 LAN 地址测试，尚非另一台设备或公网端到端验证；网页交互尚未重新人工浏览验收。

## 经远控真实安装 tcc（2026-10-01）
所有设备操作均通过 `http://192.168.31.23:35565` 的 Bearer HTTP API，以 App UID 10229 执行，未使用 ADB/run-as 安装。

8080 仓库重新启动后，严格模式 `apt-get update` 返回 0；独立 signed-by keyring 对 InRelease 得到 GOODSIG/VALIDSIG `B8342A1AF9D10071761AFB1A3A675C6C2B3B0870`。
随后 `apt-get -y --no-remove install tcc` 成功下载 2477362 字节并安装 `tcc 20260922-1`，退出码 0；`dpkg-query` 为 `install ok installed`，`dpkg --audit` 无输出。缓存 deb SHA256 为 `ed7f15694948ce42a982bad455afc9b3a66f4240fc0505572a9fbc409be4718d`。未绕过仓库签名或包哈希校验。
安装前数据库备份保留在 `usr/var/backups/tcc-network.6ePUGfrJ/dpkg-before`。安装后 status/status-old 均属 App UID，mode 0644、独立 inode、link count 1；目录权限 API 无问题。

**安装成功不代表编译环境完整可用**：
- `tcc -v` 正常：0.9.28rc AArch64。
- 无头文件 C 函数 `tcc -c` 成功生成 1118 字节目标文件。
- 普通 stdio 测试的可执行文件编译失败：仍查找 `crt1.o`/`crti.o`，包实际提供的是 NDK `crtbegin_dynamic.o`/`crtend_android.o` 等 Android CRT。
- `tcc -run` stdio 测试失败：缺少 `stddef.h`。构建入口配置了 `lib/tcc/include`，但当前 staging 仅复制 tcclib.h 与 NDK 系统头，没有完整放入 TCC 自带标准头。

这些是 tcc 包的目标平台/头文件布局问题，不能以放宽文件权限解决。需要修复 Android CRT 默认选择、标准头及 libtcc1 搜索路径，再以新版本重新构建/签名发布；不可覆盖已发布 20260922-1 的固定内容或哈希。当前没有改写已发布包，也没有宣称完整 C 编译运行验收通过。临时编译测试文件已删除，tcc 保留安装。

## 2026-10-01：TCC 独立构建与 OpenJDK 17 调查
- 已搜索并以实际 Git 源码核对 TCC Android 配置；独立 TinyCC 源码 + tcc-android 构建工程解决 CRT/标准头/libtcc1/runmain.o 问题。TCC-only 入口与 build-ext 的 TCC 段统一；32 位扩展仍暂停。
- 新候选 tcc 20260922-2 已构建、重打包哈希相同，并通过 HTTP API/App UID 的隔离 `.o`、PIE 链接执行、可变参数和 `-run` 回归；没有改变旧包 20260922-1 的哈希。详细证据与独立项目列表见 [TCC_ANDROID.md](TCC_ANDROID.md)。
- 新包在 `/sdcard/Download/Operit/tcc_20260922-2_arm64.deb`，SHA256 `0be112b7b68a3a4d0f162162d205a600c3a33fb632ebf612da0b02af1511d5cb`；真实数据库仍装着旧签名版。下一步必须在实际仓库主机用现有私钥发布新版本，再通过 signed-by APT 真实升级并测试不带 -B 的默认路径。
- OpenJDK 上游 17.0.20 和构建调查工程已独立 Git 创建/拉取，做了实际无 GUI cross-configure 基线；当前 config.sub 拒绝 Android triplet，尚未编译/运行 Java。计划 headless + 不含 java.desktop 的 jlink 命令行镜像；不能把当前 Ubuntu boot JDK 当 Android 产物。
- 没有新建 APK、清除 App 数据、扩充仓库全局信任或接触私钥。remote-repo-client 的 bad tree object HEAD 仍未修复，不宣称推送/仓库新版本发布成功。
