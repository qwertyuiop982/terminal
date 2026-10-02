# 独立签名仓库：任务与部署前检查

更新：2026-09-27。此工作树的 Git 分支是 `main-repo`，与 Android App 的 `main` 分支分别维护；服务部署在另一台 Debian/Termux 主机，不在 APK 中运行 nginx。`[x]` 仅表示已有记录的本地结果，不代表目标机上线。架构及命令用法见 [README.md](README.md) 和 [TECHNICAL.md](TECHNICAL.md)。

## 已完成的本地工作

- [x] `main-repo` 已推送到 `https://github.com/qwertyuiop982/terminal.git`，当前已知提交 `a12fed7`；`packages/` 含由 `../terminal` 的原始源码和 Android NDK 输出的 **arm64 Bionic** nano 9.2 与 tcc 包，以及固定 `SHA256SUMS`。APK 不打包这两项。
- [x] Debian 和 Termux 的 `install.sh <IPv4> <端口>` 默认从 `https://gh.xmly.dev/https://raw.githubusercontent.com/qwertyuiop982/terminal/main-repo/packages/` 下载两包，分别核验 HTTPS 和本分支 SHA256 后导入；用户可用 `REPO_PACKAGES_URL` 指定其它 HTTPS 基址但仍按本分支哈希检查，用 `REPO_BOOTSTRAP=no` 跳过下载。无 `REPO_SIGNING_KEY` 时暂存包、不产生可信发布；有完整私钥指纹时自动签名发布。私钥不在 Git/公开仓库内。
- [x] `sh tests/run.sh` 验证地址、端口、幂等安装、权限、ABI/私有前缀检查、签名快照、by-hash、nginx 配置检查和失败回退（模拟 nginx）；`sh tests/bootstrap.sh` 验证真实包、重复导入、篡改拒绝、临时 Ed25519 签名、**宿主隔离 apt** 使用专用 `signed-by` 对两包执行 `update`/`download`。默认 GitHub 加速 raw URL 的真实 HTTPS 下载已完成本地核验。以前的本地 nginx/隔离 apt 测试不等于目标机部署。
- [x] 已保留之前 `build-packages.sh` 对新包名/新版本的私有路径审计；既有 nano/tcc 包不重写、不改变原哈希。历史 Git 损坏已通过完整重克隆修复，原目录和此前改动备份仍保留。
- [x] 2026-10-02：OpenJDK `17.0.20-android2` 已放入本地 `packages/`，单独校验表为 `packages/SHA256SUMS.openjdk`。它未上传远端，固定 nano/tcc bootstrap 清单不扩张。
- [x] 2026-10-02：原 Termux 私钥不可恢复，已在仓库主机生成新的 RSA 4096 签名密钥 `A823B7EABD7E49BC620CBFC74F4203C9A033BF3C`。OpenJDK 已签名发布，nginx 运行于 `0.0.0.0:8080`，公钥只读服务运行于 `0.0.0.0:9999`；App UID 10229 已原子替换 keyring，更新源到 `192.168.1.7:8080`，并通过签名 `apt update` 与 `apt download openjdk-17`。私钥位于独立 `GNUPGHOME`，未进入 Git。详情见 `LOCAL-REPO-STATUS.md`。

## 尚未达到的验收标准

1. [ ] 确定目标 Debian 与实际 Termux 主机及可用权限、`<IPv4> <端口>`、套件/组件、仓库数据目录、私钥完整指纹、导出公钥的带外校验方法。没有这些数据时不能填造地址或把测试私钥上传到 Git。
2. [ ] 在目标 Debian/Termux 环境分别验证 nginx 获取/安装、`install.sh` 的真实 GitHub HTTPS 下载、固定 SHA256、重复执行、权限、`publish.sh`、`start.sh check/start/reload/status/stop`、失败回退、低端口权限；443 必须配真实 TLS 证书和私钥，不能只写 `listen 443` 当作 HTTPS 已工作。
3. [ ] 使用仓库主机持有的实际签名私钥签名发布，核验两包的 ELF/API 24/Bionic/私有根、索引内 Filename/Size/SHA256、Packages.gz、Release/InRelease/Release.gpg、by-hash；目标客户端使用核验了指纹的独立 keyring、`signed-by` 与真实源执行 `apt update` 和 `apt download nano tcc`，验证 404、路径隔离、GET/HEAD。绝不使用 `trusted=yes`、关闭签名验证或混入 Debian/Termux glibc 包。
4. [ ] 与 Android 终端的 App UID 完成对接后验收 nano/tcc 安装、升级、卸载、`var/lib/dpkg` 和磁盘一致性。仓库控制字段 `X-Android-*` 是发布契约，不是每个上传包兼容性的自动证明；维护脚本需要私有 `$USR/bin/sh`，包路径必须相对 App 的私有 `usr` 根。

## 源码和访问约束

优先固定 GitHub tag/commit 的源码归档或 raw 文档，经 `https://gh.xmly.dev/https://github.com/...` 和 `https://gh.xmly.dev/https://raw.githubusercontent.com/...` 只读下载并复核 SHA256；不请求 GNU/软件包官网的目标二进制，不引用 Termux 预编译包。Android 包只从另一个工作树的 NDK 产物生成，Bionic 动态 PIE 和 API 24 要单独验证。详细源码清单本机见 [terminal/docs/SOURCES_AND_BUILD.md](../terminal/docs/SOURCES_AND_BUILD.md)，云端见 [main 分支的 GitHub raw 文档](https://gh.xmly.dev/https://raw.githubusercontent.com/qwertyuiop982/terminal/main/docs/SOURCES_AND_BUILD.md)。两工作树/服务器真实数据都不可因测试而被清空；构建检查、仓库主机运行和 App UID 运行须分别记录结果。
## Release publication update (2026-10-02)

The product README is now English. The installer downloads pinned Nano 9.2-1, corrected TinyCC 20260922-2, and OpenJDK 17.0.20-android2 from GitHub Release `android-packages-20261002` through `https://gh.xmly.dev/`, with `packages/SHA256SUMS.release` verified before import. Binary `.deb` files are Release assets; the historical build checksum list is retained. Earlier status entries above describe the previous raw-file bootstrap and local deployment.
