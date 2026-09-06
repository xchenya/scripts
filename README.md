# scripts

个人 VPS 运维脚本。目前提供 MTool 首次安装脚本。

## 一键安装 MTool

在已经安装 Docker Engine 与 Docker Compose 插件的 Linux VPS 上，以 root 在交互式 SSH 终端执行：

```bash
(set -e; f=$(mktemp); trap 'rm -f "$f"' EXIT; curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 'https://raw.githubusercontent.com/xchenya/scripts/main/mtool-install.sh' -o "$f"; bash -n "$f"; bash "$f")
```

脚本下载完成且语法检查通过后，才开始交互安装。普通用户可先运行 `sudo -i` 进入 root 终端。

以上命令以仓库默认分支为 `main` 为前提。它读取该分支的当前版本；需要固定版本时，用审核过的完整提交 SHA 替换链接中的 `main`。

## 环境要求

- Linux、本机 Docker Engine、Docker Compose 插件（使用 `docker compose`）。
- `curl`、`openssl`、`ss`（通常由 iproute2 提供）、GNU `realpath`（通常由 coreutils 提供）。
- 媒体目录已经存在；使用外接磁盘时应先确认挂载。
- 安装目录尚不存在，系统没有名为 `mtool` 的容器，选择的 TCP 端口未被占用。
- 网络能够访问 GitHub Raw 与 Docker Hub，镜像必须支持目标 CPU 架构。

缺少依赖时脚本会停止并提示；不自动安装 Docker。镜像沿用 `kuanghom/mtoolweb:3.0.1`，版本标签并非不可变的镜像摘要。

## 默认值与选项

| 项目 | 默认值 |
| --- | --- |
| 安装目录 | `/opt/mtool`，仅首次安装，不覆盖已有目录 |
| 媒体目录 | `/home/qbqb/Downloads` |
| 宿主机 Web 端口 | `9808` |
| 容器内部端口 | 固定 `9808` |
| 监听地址 | `127.0.0.1` |
| 用户名 | `admin` |
| 密码 | 隐藏输入；回车生成随机密码，手动密码至少 12 个字符 |
| 媒体挂载 | 只读；可在交互时启用写入及删除开关 |
| 特权模式 | 关闭；ISO loop 挂载可按需启用兼容模式 |

安装脚本默认只监听本机。需要直接通过 VPS 公网 IP 访问时，在监听地址选项填写 `0.0.0.0`，并自行配置访问限制与 HTTPS。密码登录不要长期通过公网明文 HTTP 使用。

ISO 特权模式扩大容器对宿主机设备的访问权限，媒体只读挂载不能完全隔离这种权限。ISO 处理能否成功仍取决于镜像、内核及运行环境。

## 通过 SSH 隧道访问

在自己的电脑执行以下命令，将 SSH 端口、用户名、VPS 地址及 Web 端口替换为实际值：

```bash
ssh -N -L 9808:127.0.0.1:9808 -p 你的SSH端口 用户名@你的VPS地址
```

保持该终端运行，在浏览器打开 `http://127.0.0.1:9808`。

## 安装后的维护

默认安装路径下：

```bash
cd /opt/mtool
docker compose --project-name mtool --env-file /dev/null -f docker-compose.yml ps
docker compose --project-name mtool --env-file /dev/null -f docker-compose.yml logs --tail 100
```

首次安装在拉取或启动阶段失败后，配置和数据会保留。解决原因后，在同一目录继续：

```bash
docker compose --project-name mtool --env-file /dev/null -f docker-compose.yml pull
docker compose --project-name mtool --env-file /dev/null -f docker-compose.yml up -d
```

重新启动容器不会自动升级到新的版本标签。更换镜像版本前应备份数据、查看上游变更并确认架构兼容性。

## 密码与文件

实际用户名、密码仅在 VPS 安装时输入并写入该 VPS 的 `docker-compose.yml`，文件权限为 `600`，安装目录权限为 `700`。权限保护不是加密，拥有 root 或 Docker 管理权限的用户仍可以读取凭据。

只公开安装脚本和说明，不要提交实际部署生成的 Compose 配置、密码、媒体文件、日志或输出文件。

`SHA256SUMS` 用于核对脚本内容。与脚本同时从同一站点下载的校验文件不能单独防御托管账号失陷；更严格的校验应使用提前保存的摘要或审核过的固定提交。

## 验证范围

脚本已完成 Bash 语法、特殊字符转义及使用模拟 Docker/curl 的安装流程检查，覆盖端口映射、配置权限、旧目录保护与非法端口拒绝。实际镜像启动、认证、媒体处理和 ISO 挂载尚需在目标 VPS 上验证。脚本中的 Web 检查仅确认容器运行且 HTTP 有响应，不等于全部功能验收。

