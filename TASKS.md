# terminal 工作任务

更新：2026-09-27。当前可执行的顺序、已完成标记、APT/gpgv 编译阻塞及 App UID 验收项见 [docs/ROADMAP.md](docs/ROADMAP.md)。原始源码的 GitHub 固定提交、`gh.xmly.dev` 加速地址、校验和与 NDK 构建约束见 [docs/SOURCES_AND_BUILD.md](docs/SOURCES_AND_BUILD.md)；当前技术证据见 [docs/TECHNICAL.md](docs/TECHNICAL.md)。

必须保留的判据：21 个指定 BusyBox applets 与 `apt` 最终应内置 APK；nano/tcc 只能按需从同一 GitHub 仓库 `main-repo` 的签名源安装；不能用宿主 apt 测试或 Android shell UID 冒烟替代 App UID 真实验证。APT/gpgv 与目标仓库部署尚未完成，因此目前的 debug APK 是阶段产物。只构建 arm64 扩展，32 位扩展仍暂停；不得取消 TLS 或仓库签名校验。

两项目统一任务清单在共享工作区的 `../TASKS.md`；该文件不在本 Git 分支中，云端使用本文件与 `docs/ROADMAP.md` 跟踪终端项目，用 `main-repo/TASKS.md` 跟踪仓库项目。