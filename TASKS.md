# terminal 工作任务

更新：2026-09-27 23:42。APT 2.8.1、GnuPG gpgv、arm64 libedit dash 和新 APK 均已由 NDK/Gradle 本地编译，滚屏纯 JVM 回归与 lint 通过；**新 APK 未安装**，设备提示 `INSTALL_FAILED_ABORTED: User rejected permissions`。旧版 App UID 的 `apt update` 因 `/tmp` 回退失败，新版的签名仓库验收尚未进行。待办见 [docs/ROADMAP.md](docs/ROADMAP.md)，源码/校验和见 [docs/SOURCES_AND_BUILD.md](docs/SOURCES_AND_BUILD.md)，技术证据见 [docs/TECHNICAL.md](docs/TECHNICAL.md)。

必须保留的判据：21 个指定 BusyBox applets 与 `apt` 最终应内置 APK；nano/tcc 只能按需从同一 GitHub 仓库 `main-repo` 的签名源安装；不能用宿主 apt 测试或 Android shell UID 冒烟替代 App UID 真实验证。APT/gpgv 已在 arm64 APK 中本地编译并打包，但仍缺 App UID 与实际签名仓库验收，因此 debug APK 仍是阶段产物。只构建 arm64 扩展，32 位扩展仍暂停；不得取消 TLS 或仓库签名校验。

两项目统一任务清单在共享工作区的 `../TASKS.md`；该文件不在本 Git 分支中，云端使用本文件与 `docs/ROADMAP.md` 跟踪终端项目，用 `main-repo/TASKS.md` 跟踪仓库项目。
## 2026-10-01 最新阶段（覆盖旧安装阻塞描述）
- [x] Debug APK 已安装，signed-by 更新及 tcc 20260922-1 真实 App UID 安装成功；新 20260922-2 候选修复了编译配置，并通过隔离 HTTP 编译/运行测试。
- [ ] 新 TCC 候选仍须由实际仓库私钥签名发布，再做 signed-by 真实升级；不把候选 -B 测试当生产包升级。
- [x] TinyCC/参考配方/OpenJDK 源码与新增构建工程均独立创建/经 Git 加速地址拉取。
- [ ] OpenJDK 17 无 GUI 移植：已试 configure，当前 Android triplet 识别阻塞，暂无可用 Android JDK。
详见 [TCC 独立构建与验收](docs/TCC_ANDROID.md)。
