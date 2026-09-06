# BitManager Web 安装脚本

使用 `kuanghom/btmanager-web:latest` 部署 BitManager Web。支持自定义安装目录、宿主机端口、监听地址和管理员账号密码；注册功能固定关闭。

## 执行命令

在已安装 Docker Engine 和 Docker Compose 插件的 Linux VPS 上，以 root 在交互式 Bash / SSH 终端执行。还需 `curl`、`openssl`、`ss`、GNU `realpath` 和 `flock`；缺少依赖时会提示，不自动安装 Docker。仅支持连接本机 Docker Engine。

简短版：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xchenya/scripts/main/bitmanager/bitmanager-install.sh)
```

完整版（下载成功并通过语法检查后执行）：

```bash
(set -e; f=$(mktemp); trap 'rm -f "$f"' EXIT; curl -fsSL --fail-early --connect-timeout 10 --max-time 120 'https://raw.githubusercontent.com/xchenya/scripts/main/bitmanager/bitmanager-install.sh' -o "$f"; bash -n "$f"; bash "$f")
```

两种命令调用同一脚本。简短版边下载边执行；完整版增加下载失败拦截、语法检查、超时和临时文件清理。语法检查不是安全审计。需要固定脚本版本时，可将 URL 中的 `main` 替换为审核过的完整提交 SHA。

## 默认配置

| 项目 | 默认值 |
| --- | --- |
| 安装目录 | `/opt/bitmanager`，可自定义 |
| 数据目录 | `安装目录/data`，默认 `/opt/bitmanager/data` |
| 容器数据路径 | `/opt/bitmanager/proxy/data` |
| 宿主机 Web 端口 | `8088`，可自定义 |
| 容器端口 | 固定 `80` |
| 监听地址 | `0.0.0.0`，可选 `127.0.0.1` |
| 镜像 | 固定 `kuanghom/btmanager-web:latest`，不沿用旧镜像 |
| 容器名及服务名 | `bitmanager-web` |
| 重启策略 | `unless-stopped` |
| `ALLOW_REGISTER` | 字符串 `false`，关闭注册 |
| `ADMIN_USERNAME` | 交互输入，默认 `admin` |
| `ADMIN_PASSWORD` | 隐藏输入，至少 12 个字符；留空生成随机密码 |
| Compose 文件 | `安装目录/bitmanager-compose.yml` |

空白管理员变量会在安装时填入，不会原样以空字符串部署。生成的随机密码在写入配置后显示一次；手动输入的密码不回显。账号密码通过环境变量传给镜像，脚本不直接改写账号数据库，也不承诺通过覆盖安装重置已有账号；旧数据中的账号是否受环境变量影响，以镜像实际行为为准。

默认地址为 `http://公网IP:8088`。安装完成后会查询并显示公网 IPv4、配置位置和管理命令。公网 IP 查询失败不影响安装；公网访问仍需放行安全组和防火墙端口，NAT VPS 需对应端口映射。`127.0.0.1` 仅本机可直接访问。公网长期使用时应通过 HTTPS 反向代理保护登录凭据。

## 已有部署与覆盖安装

检测到已有 `bitmanager-web` 容器时，会先显示原挂载，再按本次输入生成配置。数据固定使用 `安装目录/data`：例如原数据在 `/srv/bitmanager/data`，应输入安装目录 `/srv/bitmanager`，不要再填一层 `data`。选择新目录不会自动复制旧数据。

脚本使用你提供的 bind 挂载形式。旧部署若使用 Docker 数据卷、不同的数据目录结构或额外挂载，需要先自行迁移或调整配置；不会自动转换数据卷、复用全部旧容器参数。端口、管理员环境变量和监听地址采用本次输入，注册始终关闭。

确认部署后的顺序：

1. 校验候选配置、拉取镜像。失败时不会停止旧容器或覆盖原配置；首次安装也不会创建安装目录。
2. 在安装目录加锁，并确认同名容器未被其他操作替换。
3. 将已有 Compose 文件、`.env` 和旧容器检查信息备份到 `.backups/时间-随机字符/`。
4. 写入 `bitmanager-compose.yml`，重建 `bitmanager-web`。只处理这个服务，不删除其他 Compose 服务；不清空数据目录，也不执行 `rm -v` 或 `down -v`。
5. 等待容器运行且 HTTP 有响应后，输出访问地址和管理命令。

旧 `docker-compose.yml` 等其他名称的配置文件会保留，以后请使用新的 `bitmanager-compose.yml` 管理服务。重建期间会短暂中断；重建失败时保留配置、备份和持久化数据，不自动回滚镜像。

配置备份不包含完整数据库和应用数据，新镜像启动也可能修改数据；需要可回退时，请另行备份整个数据目录。只有持久化的数据会被保留，旧容器可写层不是数据备份。

## 常用命令

```bash
docker logs --tail 100 bitmanager-web
docker restart bitmanager-web

# 自定义安装目录时替换这里的路径
cd /opt/bitmanager
docker compose --env-file /dev/null -f bitmanager-compose.yml ps
docker compose --env-file /dev/null -f bitmanager-compose.yml up -d
```

Compose 文件权限为 `600`，备份目录权限为 `700`。文件和容器检查信息可能包含密码，不要提交到公开仓库。Docker 日志采用 `local` 驱动并限制单文件大小与保留数量。

本目录 `SHA256SUMS` 对应 `bitmanager-install.sh`；从同一站点同时下载的脚本和摘要不能单独防御托管账号失陷。

## 验证范围

发布前使用模拟 Docker/curl 验证默认与自定义端口、管理员变量特殊字符、随机密码、旧配置备份、数据保留、取消、端口冲突、拉取及重建失败等流程。未运行真实镜像；HTTP 响应不代表登录和全部功能已验收，安装后请在浏览器验证。
