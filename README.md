# 独立 APT 仓库服务

本目录部署在另一台 Debian 或 Termux 主机上，为 Android bionic 兼容的 `.deb` 包提供经过签名的静态 APT 仓库。它与 [Android 终端项目](https://gh.xmly.dev/https://raw.githubusercontent.com/qwertyuiop982/terminal/main/README.md) 分离；不在 App 内运行 nginx，也不代理第三方仓库。`main-repo` 分支保存可选的 nano、tcc 原生安装包；它们不进入 APK。进度、缺少的实际部署参数和注意事项见 [TASKS.md](TASKS.md)；源码/NDK/GitHub 加速地址见 `main` 分支 [构建说明](https://gh.xmly.dev/https://raw.githubusercontent.com/qwertyuiop982/terminal/main/docs/SOURCES_AND_BUILD.md)。

## 使用

在目标主机上准备 `curl`、`sha256sum`、`gpg`、`dpkg-deb`、`dpkg-scanpackages`、`gzip` 和 nginx。Debian 缺少 nginx 时，安装入口会调用目标机的 `apt-get install nginx`；Termux 会调用目标机的 `apt install nginx`。安装入口接受指定监听地址和端口：

```text
sh debian/install.sh <IPv4> <端口>
sh termux/install.sh <IPv4> <端口>
```

默认仓库根目录分别为 `/var/lib/terminal-repo-client/repository`（Debian root）或 `$PREFIX/var/lib/terminal-repo-client/repository`（Termux）。可用 `REPO_CLIENT_HOME`、`REPO_SUITE`、`REPO_ARCH` 覆盖目录、套件和 APT 架构。地址必须是合法 IPv4，端口范围为 `1..65535`。

`install.sh` 默认从 `https://gh.xmly.dev/https://raw.githubusercontent.com/qwertyuiop982/terminal/main-repo/packages/` 下载 nano/tcc 的 `.deb`，对照本分支 `packages/SHA256SUMS` 全部校验成功后才导入 `pool/main`；失败不会签名发布不完整的快照。仅支持 arm64/API 24 和 `com.terminal` 的私有前缀，拒绝仅 CPU 架构相同的 glibc/Termux 包。设 `REPO_BOOTSTRAP=no` 可跳过下载，以便离线测试或自行发布其他兼容包；`REPO_PACKAGES_URL` 可指定另一个 HTTPS 镜像，但仍使用本地固定哈希校验。

在执行 `install.sh` 前设置 `REPO_SIGNING_KEY` 为仓库私钥的完整指纹，安装入口会自动签名发布两包；私钥只能留在目标仓库主机的私有 GnuPG 目录。未设置密钥时只导入待发布的包，不启动 nginx；之后可手动发布（Termux 换用 `termux/publish.sh`）：

```text
REPO_SIGNING_KEY=<完整指纹> sh debian/publish.sh
```

其他经过同样 bionic 前缀/API/ABI 检查的包可作为参数传给 `publish.sh`。构建主机上可在终端项目完成 NDK 构建后运行 `sh build-packages.sh`，它生成可重复的 `.deb` 和 `packages/SHA256SUMS`，不从发行版下载 Android 目标二进制。

`publish.sh` 会拒绝错误架构、危险文件名、重复但内容不同的包和仓库内符号链接；生成 `Packages`、`Packages.gz`、by-hash、`Release`、`InRelease`、`Release.gpg`，最后原子切换 `dists/<suite>` 到新的发布快照。私钥必须留在仓库主机外部公开目录，客户端应单独安装导出的公钥并使用 `signed-by`。

启动和管理：

```text
sh debian/start.sh <IPv4> <端口> check
sh debian/start.sh <IPv4> <端口> start
sh debian/start.sh <IPv4> <端口> reload
sh debian/start.sh status
sh debian/start.sh stop
```

nginx 只允许 GET/HEAD，并只匹配 `pool/main/**/*.deb`、当前套件的发布元数据和 by-hash 路径。端口 `443` 必须同时设置 `REPO_TLS_CERT` 和 `REPO_TLS_KEY`，证书与私钥不能放在公开仓库目录中。配置先执行 `nginx -t`，启动或重载失败时保留上一份配置。

## 目录

```text
<state>/
├── repository/
│   ├── pool/main/*.deb
│   └── dists/<suite> -> ../../releases/<snapshot>/
├── releases/<snapshot>/
│   └── main/binary-<apt-architecture>/Packages[.gz]
├── conf/
├── run/
└── logs/
```

仓库主机不编译包。`publish.sh` 要求包声明 `X-Android-Bionic: yes`、`X-Android-Min-API: 24`（或更低）和 `X-Terminal-Prefix: /data/data/com.terminal/files/usr`；这些字段只是契约，实际 ELF/脚本仍须由包构建方检查。Debian、Termux 和 Android bionic 包不能仅按 CPU 名称混用。客户端需通过可信带外渠道导入仓库公钥、核对完整指纹，并用 `signed-by` 配置实际 `<ip>:<port>` 的源，不能设 `trusted=yes` 或提前预置假地址。

## 验证

```text
sh tests/run.sh
sh tests/bootstrap.sh
sh tests/nginx-smoke.sh /absolute/path/to/nginx [port]
```

`run.sh` 覆盖 Debian/Termux 入口、参数校验、目录权限、签名发布、原子快照、重载回滚和错误包；`bootstrap.sh` 用本地 HTTPS 模拟下载器验证固定哈希、真实 nano/tcc 包导入和签名，并用宿主隔离 apt 的专用 `signed-by` 从文件源更新及下载两包；`nginx-smoke.sh` 需外部提供的 nginx，执行真实 `nginx -t`、HTTP/HEAD/POST/路径穿越检查及隔离的 `apt update`/`apt download`。这些本地测试不代表另一台目标主机或 Android App UID 验收。
