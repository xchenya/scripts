# MTool 安装与覆盖安装

使用 Docker Compose 部署 MTool，支持在已有目录覆盖并重建已有容器。

## 一键安装 MTool

在已经安装 Docker Engine 与 Docker Compose 插件的 Linux VPS 上，以 root 在交互式 SSH 终端执行：

```bash
(set -e; f=$(mktemp); trap 'rm -f "$f"' EXIT; curl -fsSL --fail-early --connect-timeout 10 --max-time 120 'https://raw.githubusercontent.com/xchenya/scripts/main/mtool/install.sh' -o "$f"; bash -n "$f"; bash "$f")
```

脚本下载完成且语法检查通过后，才开始交互安装。普通用户可先运行 `sudo -i` 进入 root 终端。

以上命令以仓库默认分支为 `main` 为前提。它读取该分支的当前版本；需要固定版本时，用审核过的完整提交 SHA 替换链接中的 `main`。

## 环境要求

- Linux、本机 Docker Engine、Docker Compose 插件（使用 `docker compose`）。
- `curl`、`openssl`、`ss`（通常由 iproute2 提供）、GNU `realpath`（通常由 coreutils 提供）及 `flock`（通常由 util-linux 提供）。
- 媒体目录已经存在；使用外接磁盘时应先确认挂载。
- 安装目录可以已存在，已有 `mtool` 容器也可以重建。端口由当前 `mtool` 使用时可以复用，被其他容器或服务占用时需换端口。
- 网络能够访问 GitHub Raw 与 Docker Hub，镜像必须支持目标 CPU 架构。

缺少依赖时脚本会停止并提示；不自动安装 Docker。镜像沿用 `kuanghom/mtoolweb:3.0.1`，版本标签并非不可变的镜像摘要。

## 默认值与选项

| 项目 | 默认值 |
| --- | --- |
| 安装目录 | `/opt/mtool`，支持备份配置后覆盖 |
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

## 覆盖安装的行为

1. 接受已有安装目录，并显示已有容器的挂载路径。要继续使用原数据，请填写原安装目录和媒体目录。
2. 按本次输入生成候选配置，校验后拉取镜像。校验或拉取失败时，旧配置与旧容器保持原状。
3. 将旧 Compose 文件、`.env` 和已有容器的 inspect 信息备份到 `安装目录/.backups/日期时间-随机后缀/`。
4. 原子替换 `docker-compose.yml`。已有容器属于 Compose 的 `mtool` 服务时，沿用其项目名并重建该服务；其他来源的同名容器先正常停止，再移除容器本身并创建新容器。
5. 保留 `data`、`logs`、`output` 和媒体目录中的原文件，不执行 `down -v`、卷删除或数据目录清理；随后检查 Web 响应。

覆盖会采用本次填写的账号、密码、端口和权限。密码留空会生成新密码。旧配置中的额外挂载、自定义环境变量和网络设置不会自动迁移，可从备份中参考恢复。容器可写层内没有持久化的内容不属于保留的数据目录。

备份只包含配置和容器信息，不是数据库或媒体快照。重建阶段失败时，数据目录与备份会保留，但服务可能暂时不可用；脚本不自动回滚容器或数据库。

## 通过 SSH 隧道访问

在自己的电脑执行以下命令，将 SSH 端口、用户名、VPS 地址及 Web 端口替换为实际值：

```bash
ssh -N -L 9808:127.0.0.1:9808 -p 你的SSH端口 用户名@你的VPS地址
```

保持该终端运行，在浏览器打开 `http://127.0.0.1:9808`。

## 安装后的维护

默认安装路径下（新配置中已写入 Compose 项目名）：

```bash
cd /opt/mtool
docker compose --env-file /dev/null -f docker-compose.yml ps
docker compose --env-file /dev/null -f docker-compose.yml logs --tail 100
```

安装或覆盖失败时，可以解决原因后重新运行脚本；如果新配置已经写入，也可在原安装目录使用它继续：

```bash
docker compose --env-file /dev/null -f docker-compose.yml pull
docker compose --env-file /dev/null -f docker-compose.yml up -d
```

重新启动容器不会自动升级到新的版本标签。更换镜像版本前应备份数据、查看上游变更并确认架构兼容性。

## 密码与文件

实际用户名、密码仅在 VPS 安装时输入并写入该 VPS 的 `docker-compose.yml`，文件权限为 `600`，新建安装目录权限为 `700`；已有目录的权限保持原状。权限保护不是加密，拥有 root 或 Docker 管理权限的用户仍可以读取凭据。

`.backups/` 和每次备份目录仅允许 root 访问，备份中可能包含旧密码。恢复时应查看原项目名和挂载路径，将需要的配置恢复到原安装目录后启动；不要直接在备份子目录运行带相对路径的 Compose 文件。

只公开安装脚本和说明，不要提交实际部署生成的 Compose 配置、密码、备份、媒体文件、日志或输出文件。

本目录的 `SHA256SUMS` 对应 `install.sh`。与脚本同时从同一站点下载的校验文件不能单独防御托管账号失陷；更严格的校验应使用提前保存的摘要或审核过的固定提交。

## 验证范围

脚本在发布前使用模拟 Docker/curl 验证首次安装与覆盖流程，包括旧配置备份、数据保留、当前容器端口复用、其他服务端口冲突、拉取失败及重建失败处理。该检查不启动实际容器。实际镜像启动、认证、媒体处理和 ISO 挂载尚需在目标 VPS 上验证。脚本中的 Web 检查仅确认容器运行且 HTTP 有响应，不等于全部功能验收。


## 旧链接兼容

仓库根目录的 `mtool-install.sh` 保留为旧命令入口，完整实现和文档位于本目录。新增其他工具时，分别创建独立文件夹并在根 README 增加目录项和执行命令。
