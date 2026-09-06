# VPS 脚本目录

| 脚本 | 简短说明 | 详细文档 |
| --- | --- | --- |
| MTool | 安装或覆盖安装，备份旧配置并保留数据；默认端口 `9808`，开放 IPv4 监听并显示公网地址。 | [mtool/README.md](mtool/README.md) |
| Vertex | 检测已有容器并询问是否沿用目录、端口等配置；默认端口 `3000`，使用定制镜像并显示公网地址。 | [vertex/README.md](vertex/README.md) |

## MTool 执行命令

在已安装 Docker 和 Compose 的 Linux VPS 上，以 root 执行：

```bash
(set -e; f=$(mktemp); trap 'rm -f "$f"' EXIT; curl -fsSL --fail-early --connect-timeout 10 --max-time 120 'https://raw.githubusercontent.com/xchenya/scripts/main/mtool/install.sh' -o "$f"; bash -n "$f"; bash "$f")
```

## Vertex 执行命令

在已安装 Docker、Compose 和 Python 3 的 Linux VPS 上，以 root 执行：

```bash
(set -e; f=$(mktemp); trap 'rm -f "$f"' EXIT; curl -fsSL --fail-early --connect-timeout 10 --max-time 120 'https://raw.githubusercontent.com/xchenya/scripts/main/vertex/vertex-install.sh' -o "$f"; bash -n "$f"; bash "$f")
```
