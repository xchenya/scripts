# Vertex 安装脚本

支持首次安装、覆盖安装和可选的备份直链导入。启动时检测名为 `vertex` 的容器，包括正在运行和已停止的容器，先显示其数据位置、端口、时区和网络，再询问是否沿用。

## 执行命令

适用于 Linux VPS、本机 Docker Engine 和 Docker Compose 插件。需要 Bash、Python 3（仅标准库）、curl、ss 和 flock；请在交互式 SSH 终端中以 root 执行。脚本会检查依赖，不会自动安装 Docker。

简短版（在 Bash 终端执行）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xchenya/scripts/main/vertex/vertex-install.sh)
```

完整版（下载成功并通过语法检查后执行）：

```bash
(set -e; f=$(mktemp); trap 'rm -f "$f"' EXIT; curl -fsSL --fail-early --connect-timeout 10 --max-time 120 'https://raw.githubusercontent.com/xchenya/scripts/main/vertex/vertex-install.sh' -o "$f"; bash -n "$f"; bash "$f")
```

完整版先完整下载、检查 Bash 语法，再运行。`main` 会随仓库更新；需要固定版本时，把 URL 中的 `main` 换成审核过的完整提交 SHA。语法检查和同站点提供的 SHA256 校验不能代替代码审核。

简短版通过 Bash 进程替换边下载边执行，省去了下载完成确认、预先语法检查、显式超时和临时文件清理；下载中途失败时，不能保证阻止已下载内容执行。两种命令都使用 HTTPS，并调用同一个安装脚本，安装选项和默认配置完全相同。完整版也不验证代码来源签名，语法检查不等于安全审计。

## 默认配置

| 项目 | 默认值 |
| --- | --- |
| 安装及数据目录 | `/opt/vertex`，挂载到容器 `/vertex` |
| 宿主机端口 | `3000`，可自定义 |
| 容器 Web 端口 | `3000` |
| 监听地址 | `0.0.0.0`，也可选择 `127.0.0.1` |
| 时区 | `Asia/Shanghai`，可自定义 |
| 镜像 | `kuanghom/vertex:latest` |
| 容器名 | `vertex` |
| 重启策略 | `unless-stopped` |
| 启动命令 | `/bin/sh -c 'bash /app/vertex/docker/start.sh'` |
| Compose 文件 | 安装目录内的 `vertex-compose.yml` |

默认使用 **HTTP**，访问形式为 `http://公网IP:3000`。`0.0.0.0` 允许通过 VPS 的 IPv4 地址访问，还需要放行安全组和防火墙端口；NAT VPS 需要相应的外部端口映射。选择 `127.0.0.1` 时仅本机可直接访问。

安装完成后自动查询公网 IPv4，查询失败会尝试备用服务，并且不会导致安装失败。检测出的地址是出口 IP，公网可达性仍以实际访问为准。

默认端口 `3000` 用于首次安装或选择重新设置；选择沿用时保留原端口。

## 已有容器如何处理

检测到 `vertex` 后，首先询问：

```text
是否沿用原容器的目录、端口等配置（y/n） [默认：y]：
```

- **选择沿用**：复用 `/vertex` 的数据位置、所有已发布端口、环境变量（含时区及自定义 `PORT`）、挂载、重启策略和现有网络。普通 bind 挂载沿用原宿主机路径；Docker 数据卷按原名称声明为外部卷，并额外询问保存 Compose 文件的管理目录。不会把 Docker 内部的数据卷目录改成 bind 挂载。
- **选择重新设置**：重新输入安装目录、宿主机端口、监听地址和时区，采用上表的默认值。填写原数据目录可继续使用其中的数据；选择新目录不会自动复制或迁移旧数据，旧目录仍然保留。
- 最后显示部署配置，再询问是否开始。输入 `n` 取消，不会停止旧容器或写入安装配置。

沿用配置的范围如上；无论旧容器使用哪个镜像，始终拉取并使用定制镜像 `kuanghom/vertex:latest`，不会沿用旧镜像。启动命令统一采用本脚本配置，日志采用有大小限制的 Docker `local` 驱动。自定义 entrypoint、额外 capabilities、设备、特权等高级容器参数不会自动复制；使用这些参数的部署应先检查原 Compose 配置。

支持已有容器的普通 Docker 网络、IPv4/IPv6 端口映射，以及 host 网络；host 网络继续使用原 `PORT` 或 `3000`，不生成 Docker 端口映射。无法识别 `/vertex` 持久化挂载、Web 端口或遇到 `none`、共享其他容器的网络模式时，会在修改前报错；此时可以重新运行并选择重新设置。没有持久化挂载时，请先导出容器中的数据。

## 可选：从备份直链导入

设置部署参数后，脚本会询问：

```text
备份下载直链（可选，回车跳过，输入隐藏）：
ZIP 解压密码（无密码或 tar 备份直接回车）：
```

直链留空就按原流程安装，不下载、不导入备份。填写直链后，会在最终确认前显示恢复目标；链接和密码隐藏输入，不写入 Compose 文件、日志或进程命令行。请使用自己的可信备份。

- 支持 HTTP/HTTPS 文件直链，推荐 HTTPS；允许带签名参数的链接。通过文件内容识别格式，不要求 URL 以压缩包后缀结尾。网盘预览页、登录页面不是文件直链。HTTPS 链接不允许重定向降级到 HTTP。
- 支持 ZIP、tar、tar.gz / tgz；ZIP 支持传统 ZipCrypto 密码保护，密码错误可以重新输入，重试时留空退出。Python 标准库不支持 AES 加密 ZIP，需要先转换为支持的格式。
- 备份必须包含唯一的有效 `setting.json`。可以直接放在压缩包根目录，也可以位于 `vertex/data/` 等多层目录中；将其所在目录的全部内容恢复到容器 `/vertex/data`，不会把压缩包外层文件夹多套一层。
- 只恢复这个数据目录，不恢复压缩包中的其他同级目录，也不导入 Docker Compose、镜像或端口映射。备份中的账号密码、下载器和任务配置保留；`setting.json` 的 `port` 会设为本次容器 Web 端口，以匹配安装配置。固定使用 `kuanghom/vertex:latest`，宿主机端口仍按本次输入或沿用配置。
- 导入目前支持可写的宿主机目录挂载到 `/vertex`。Docker 数据卷、只读挂载、覆盖 `/vertex/data` 的额外挂载，以及符号链接或独立挂载点形式的 `data` 暂不支持直链导入；这些部署仍可跳过导入继续原有安装流程。
- 下载上限 1 GiB，解压上限 4 GiB / 100000 个条目；解压暂存和目标磁盘需有足够空间。压缩包内的越界路径、链接、特殊文件和重复路径会被拒绝。不会在安装过程中执行备份中的脚本。

完整下载、解压、结构检查和镜像拉取成功后，才会准备新数据并停止旧容器。原 `data` 目录会移动到本次备份目录的 `data-before-import/`，随后换入导入数据；这个旧目录会保留，不会自动清理。备份数据所有者采用沿用配置中的 `PUID/PGID`；未设置时沿用旧 `data` 所有者，首次安装默认 root。

下载、密码、解压或检查失败会停止安装，旧容器和数据保持原状，不会自动降级为全新安装。目录替换失败时会尝试恢复原目录，并重新启动原先正在运行的容器。导入完成后的容器重建或 Web 检查失败不会自动回退导入数据；可根据输出的备份路径排查和恢复。

导入成功后使用**备份中的账号密码**登录。下载器地址、站点配置和任务可能仍指向旧服务器，请在网页中核对。数据导入功能参考 [Auto-Seedbox-PT 的 Vertex 恢复流程](https://github.com/yimouleng/Auto-Seedbox-PT/blob/8716b2d7f5d495ce61aef308107738f4429b14ac/auto_seedbox_apps.sh)，独立实现了暂存检查和原数据保留；不自动改写备份中的登录密码或下载器连接信息。

## 覆盖安装、备份与失败处理

1. 检查端口占用，允许替换当前 `vertex` 正在使用的端口。
2. 校验候选 Compose 配置，并拉取 `kuanghom/vertex:latest`。这两步失败时，旧容器和原安装配置保持原状。
3. 在安装目录的 `.backups/vertex-时间-随机字符/` 备份已有 Compose 配置、`.env` 和旧容器检查信息。
4. 写入新的 `vertex-compose.yml`，然后重建 `vertex`。重建期间服务会短暂中断；不会执行 `down -v`、删除数据卷或清空数据目录。
5. 等待容器运行且 HTTP 响应后，显示访问地址、数据位置及常用命令。

已有其他名称的 Compose 文件会保留。脚本使用独立的 `vertex-compose.yml`，以后请使用这个文件管理 Vertex，避免再次从旧配置启动同名容器。只操作 `vertex` 服务，不移除原 Compose 项目的其他服务。

未选择直链导入时，备份保存配置和容器元数据，**不是应用数据库及整个数据卷的完整备份**。选择导入时，会额外保留导入前的 `data` 目录；这仍不包含 `/vertex` 下的其他同级目录。新镜像启动可能修改应用数据，升级前如需可回退，应另行备份完整数据。重建失败时不会自动切回旧镜像；脚本会保留备份并输出失败信息，修复原因后可重新运行或恢复配置。

生成的配置权限为 `600`，备份目录权限为 `700`，因为复用的环境变量可能含密码。不要将 VPS 上生成的配置、检查信息、密码或备份提交到此公开仓库。

## 初始密码和管理命令

镜像发布者说明初始密码保存在 `/vertex/data/password`；默认宿主机路径为 `/opt/vertex/data/password`。见 [kuanghom/vertex 镜像说明](https://hub.docker.com/r/kuanghom/vertex)。沿用数据不会重置应用内已有账号密码。

```bash
# 首次安装后查看初始密码
docker exec vertex cat /vertex/data/password

# 查看日志及重启
docker logs --tail 100 vertex
docker restart vertex

# 默认安装目录；自定义安装时替换此路径
cd /opt/vertex
docker compose --env-file /dev/null -f vertex-compose.yml ps
docker compose --env-file /dev/null -f vertex-compose.yml up -d
```

配置以 JSON 语法写入 `.yml` 文件，Docker Compose 可直接读取；这样能正确处理旧环境变量和路径中的引号、反斜杠、美元符号等字符。Python 3 仅用于解析和生成配置。

## 验证范围

发布前使用隔离的模拟 Docker/curl 验证首次安装、已有容器复用、重新设置、取消、端口冲突、镜像拉取失败和容器重建失败等流程。备份导入另使用真实构造的 ZIP、加密 ZIP 和 tar.gz 验证解压、目录定位、密码处理、路径和容量限制，并模拟验证旧数据保留、下载失败、拉取失败及目录替换失败回退。该验证不会运行真实 Vertex 镜像。脚本中的 HTTP 检查不等于完整功能验收；实际登录、任务和目标 VPS 上的镜像运行需要安装后确认。
