# 独立 APT 仓库服务：技术说明

更新：2026-10-02。该项目已从 HTTPS 上游反向代理原型改为独立的静态 APT 仓库服务，`main-repo` 已推送（之前验证的提交为 `a12fed7`）。部署目标是另一台 Debian 或 Termux 主机；Android `terminal` App 不包含 nginx，也不依赖本目录的运行状态。当前尚未部署到实际目标主机，缺少的验收项和注意事项见 [TASKS.md](TASKS.md)。

## 架构

```text
GitHub Release assets/*.deb + 本分支固定 SHA256 + 仓库签名私钥
                    |
                    v
  repository/pool/main/*.deb
  repository/dists/<suite> -> ../../releases/<snapshot>/
                    |
                    v
        nginx root=repository, listen=<IPv4>:<port>
                    |
                    v
  客户端 apt: signed-by 公钥 -> InRelease/Release -> Packages -> .deb
```

安装脚本创建状态目录，从 `gh.xmly.dev` 转发的固定 GitHub Release 下载已由 NDK 构建的 nano/tcc/OpenJDK 17 包，逐个按本地固定 SHA256 核验，再导入仓库池；有签名密钥时立即生成签名快照，无密钥时只暂存包。发布脚本生成索引和签名快照；启动脚本只生成静态 nginx 配置。nginx 不编译包、不代理上游、不访问项目源码或私钥。构建主机使用原始源码与 NDK 产出 `packages/` 下的 `.deb`；目标仓库主机不交叉编译。

## 脚本契约

| 脚本 | 契约 |
| --- | --- |
| `debian/install.sh <ip> <port>` | 校验 IPv4/端口，缺 nginx 时在目标 Debian 上调用 `apt-get install nginx`；创建目录，默认 HTTPS 下载并核验 nano/tcc/OpenJDK 17，设了签名密钥才自动发布 |
| `termux/install.sh <ip> <port>` | 同上；缺 nginx 时在目标 Termux 上调用 `apt install nginx` |
| `build-packages.sh` | 构建主机从终端项目 NDK staged tree 产生相对私有根的 nano/tcc `.deb`；检查 ELF 与源树，输出固定 SHA256 |
| `debian/publish.sh <deb...>` | 按 `REPO_ARCH` 检查包，生成 `Packages`、压缩索引、by-hash、`Release`、`InRelease`、`Release.gpg`，原子切换快照 |
| `termux/publish.sh <deb...>` | 与 Debian 发布入口相同，使用 Termux 环境工具 |
| `debian/start.sh <ip> <port> [start/check/reload]` | 生成并检查 nginx 静态 root；启动或重载失败时恢复旧配置 |
| `termux/start.sh <ip> <port> [start/check/reload]` | 同上 |
| `start.sh status/stop` | 查询或停止状态文件中的 nginx |

公共环境变量：

- `REPO_CLIENT_HOME`：状态目录；默认 Debian root 为 `/var/lib/terminal-repo-client`，非 root 为 `$HOME/.local/share/terminal-repo-client`，Termux 为 `$PREFIX/var/lib/terminal-repo-client`。
- `REPO_SUITE`：套件，默认 `stable`；只接受小写字母、数字和连字符。
- `REPO_ARCH`：APT 架构，默认 `arm64`；包必须是该架构或 `all`；自动下载仅支持 arm64。
- `REPO_BOOTSTRAP=no`：禁用安装时自动下载，供离线测试或手工发布；默认自动下载。
- `REPO_PACKAGES_URL`：可替换自动下载的 HTTPS 基址，不改变本地 `packages/SHA256SUMS.release` 的预期哈希。
- `REPO_NGINX`：可执行 nginx 路径；显式设置但不可执行时不会自动安装替代品。
- `REPO_SIGNING_KEY`：发布使用的完整十六进制 secret-key fingerprint，长度为 40 或 64。
- `GNUPGHOME`：可选的签名密钥目录，不能位于公开仓库下。
- `REPO_TLS_CERT`、`REPO_TLS_KEY`：只有启用 443 时才必须同时提供；证书和私钥必须在仓库根目录外。

## 目录和安全边界

安装后目录为：

```text
<state>/
├── repository/
│   ├── pool/main/*.deb
│   └── dists/<suite> -> ../../releases/<snapshot>/
├── releases/<snapshot>/
│   └── main/binary-<arch>/
│       ├── Packages, Packages.gz
│       └── by-hash/SHA256/<sha256>
├── conf/nginx.conf
├── run/{body,proxy,fastcgi,uwsgi,scgi}/
└── logs/
```

发布使用临时快照目录和临时 symlink，完成签名与自验证后才替换当前 `dists/<suite>`。旧 by-hash 索引保留在新快照中，避免客户端在切换期间拿到不一致的压缩索引。

nginx 只匹配：

- `/pool/main/.../*.deb`；
- 当前套件的 `Release`、`InRelease`、`Release.gpg`；
- 当前架构的 `Packages`、`Packages.gz` 和 by-hash SHA256 路径。

其他路径返回 404；非 GET/HEAD 请求被拒绝；包目录不允许符号链接。路径、地址、端口、套件、架构和证书路径都会在写入 nginx 配置前验证。

## 验证结果

已通过：

- `sh tests/run.sh`：Debian/Termux 参数校验、幂等安装、权限、签名索引、重复发布、旧 by-hash、错误架构/前缀、nginx 配置检查、启动/停止/重载和失败回滚。
- `sh tests/bootstrap.sh`：本地模拟 HTTPS 下载器，真实 NDK arm64 nano/tcc `.deb` 固定哈希核验、重复安装、签名发布与篡改拒绝；宿主隔离 apt 使用专用 `signed-by` 对真实两包完成 `update`/`download`（文件源，无 Android 安装）。
- `sh tests/nginx-smoke.sh <nginx>`：真实 nginx `nginx -t`、HEAD、POST 拒绝、路径穿越拒绝、签名 `apt update` 和隔离 `apt download`。
- 此前记录的 nginx/宿主 apt 集成测试仅在本机构造目录通过；本轮没有目标仓库主机、实际 Termux 主机、公钥分发或 App UID 验收结果，不能据此宣称生产仓库已上线。

## 限制

仓库中的 `.deb` 必须已经针对 Android bionic、目标 API/ABI 和 `REPO_ARCH` 构建；Debian glibc 包不能直接安装到 Android 私有前缀。签名只证明发布文件完整和来自指定密钥，不证明包的 ABI 兼容性。客户端仍需把对应公钥安装为专用 keyring，并使用类似下面的源：

```text
deb [arch=arm64 signed-by=/path/to/repo-keyring.gpg] http://<ip>:<port>/ stable main
```
