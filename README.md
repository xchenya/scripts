# VPS 脚本目录

| 脚本 | 简短说明 | 详细文档 |
| --- | --- | --- |
| MTool | 安装或覆盖安装 MTool，备份旧配置并保留持久化数据目录。 | [mtool/README.md](mtool/README.md) |

## MTool 执行命令

在已安装 Docker 和 Compose 的 Linux VPS 上，以 root 执行：

```bash
(set -e; f=$(mktemp); trap 'rm -f "$f"' EXIT; curl -fsSL --fail-early --connect-timeout 10 --max-time 120 'https://raw.githubusercontent.com/xchenya/scripts/main/mtool/install.sh' -o "$f"; bash -n "$f"; bash "$f")
```
