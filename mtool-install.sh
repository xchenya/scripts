#!/usr/bin/env bash
# MTool 首次安装脚本：Linux + 本机 Docker Engine + Docker Compose 插件。
# 以 root 执行。安装目录必须尚不存在；不会覆盖或升级已有部署。
# 容器内部端口固定为 9808，镜像沿用用户提供的 3.0.1。
# 默认仅本机访问、媒体只读、关闭特权。ISO 挂载可按需启用特权。
# 安装后使用：cd /opt/mtool && docker compose -f docker-compose.yml up -d
# 密码写入权限为 600 的 Compose 文件；这是访问权限保护，不是加密。
set +x
set -Eeuo pipefail
umask 077

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
trap 'printf "安装未完成（第 %s 行）。已生成的配置保留，请检查错误后处理；不会自动删除数据。\n" "$LINENO" >&2' ERR

# 同时保护 YAML 字面值和 Compose 的 $ 插值；不使用 eval/source。
yaml_value() {
    local value=$1
    value=${value//\$/\$\$}
    value=${value//\'/\'\'}
    printf "'%s'" "$value"
}

ask() {
    local target=$1 prompt=$2 fallback=$3 answer
    printf '%s [默认：%s]：' "$prompt" "$fallback" >&3
    IFS= read -r answer <&3 || die '输入已中断。'
    [[ ! "$answer" =~ [[:cntrl:]] ]] || die '输入不能包含控制字符。'
    printf -v "$target" '%s' "${answer:-$fallback}"
}

main() {
    [[ $(uname -s) == Linux ]] || die '本脚本适用于 Linux VPS。'
    (( EUID == 0 )) || die '请以 root 运行，例如 sudo bash mtool-install.sh。'
    local dependency
    for dependency in docker curl openssl ss realpath; do
        command -v "$dependency" >/dev/null 2>&1 || die "缺少依赖：$dependency。请先安装。"
    done
    docker compose version >/dev/null 2>&1 || die '需要 Docker Compose 插件（docker compose）。'
    docker info >/dev/null 2>&1 || die '无法连接 Docker，请检查服务和访问权限。'
    if docker container inspect mtool >/dev/null 2>&1; then
        die '已存在名为 mtool 的容器。本脚本仅用于首次安装，不会替换旧容器。'
    fi
    { exec 3<>/dev/tty; } 2>/dev/null || die '需要交互终端；请在 SSH 终端中运行。'

    local install_path media_path web_port bind_address login_name login_password
    local iso_choice write_choice confirm existing_listeners
    local privileged=false media_read_only=true delete_enabled=false generated=false
    ask install_path 'MTool 安装目录（需为新目录，使用绝对路径）' '/opt/mtool'
    ask media_path '媒体目录（必须已存在，使用绝对路径）' '/home/qbqb/Downloads'
    [[ "$install_path" == /* && "$media_path" == /* ]] || die '路径必须以 / 开头，不能使用 ~。'
    install_path=$(realpath -m -- "$install_path")
    [[ "$install_path" != / ]] || die '不能将根目录作为安装目录。'
    [[ ! -e "$install_path" && ! -L "$install_path" ]] || die '安装目录已存在，请选择新目录，避免覆盖旧数据。'
    [[ -d "$media_path" ]] || die '媒体目录不存在，请检查磁盘挂载和路径。'
    media_path=$(realpath -e -- "$media_path")
    [[ "$media_path" != / ]] || die '不能将宿主机根目录作为媒体目录。'
    [[ "$install_path" != "$media_path"/* ]] || die '安装目录不能位于媒体目录中，以免从媒体浏览器暴露配置和密码。'

    ask web_port '宿主机 Web 端口（容器端口固定为 9808）' '9808'
    [[ "$web_port" =~ ^[0-9]{1,5}$ ]] || die '端口必须为 1～65535 的整数。'
    web_port=$((10#$web_port))
    (( web_port >= 1 && web_port <= 65535 )) || die '端口必须为 1～65535。'
    existing_listeners=$(ss -H -ltn "sport = :$web_port")
    [[ -z "$existing_listeners" ]] || die "TCP 端口 $web_port 已被占用。"

    printf '\n127.0.0.1：通过 SSH 隧道或本机 HTTPS 反代访问。\n0.0.0.0：开放宿主机所有 IPv4 网卡，请配置云安全组和 HTTPS。\n' >&3
    ask bind_address '监听地址（127.0.0.1 / 0.0.0.0）' '127.0.0.1'
    [[ "$bind_address" == 127.0.0.1 || "$bind_address" == 0.0.0.0 ]] || die '请填写 127.0.0.1 或 0.0.0.0。'
    ask login_name '登录用户名' 'admin'
    printf '设置登录密码（隐藏输入，回车生成随机密码）：' >&3
    IFS= read -r -s login_password <&3 || die '输入已中断。'
    printf '\n' >&3
    [[ ! "$login_password" =~ [[:cntrl:]] ]] || die '密码不能包含控制字符。'
    if [[ -z "$login_password" ]]; then
        login_password=$(openssl rand -base64 24)
        generated=true
    fi
    (( ${#login_password} >= 12 )) || die '请使用至少 12 个字符的密码。'

    printf '\nISO 在容器内进行 loop 挂载可能需要特权模式；特权容器能够访问宿主机设备，媒体只读不能完全隔离此权限。\n' >&3
    ask iso_choice '是否启用 ISO 特权挂载兼容模式（y/n）' 'n'
    case "${iso_choice,,}" in
        y|yes) privileged=true ;;
        n|no) ;;
        *) die '请输入 y 或 n。' ;;
    esac
    ask write_choice '是否允许写入媒体并启用文件删除开关（y/n）' 'n'
    case "${write_choice,,}" in
        y|yes) media_read_only=false; delete_enabled=true ;;
        n|no) ;;
        *) die '请输入 y 或 n。' ;;
    esac

    printf '\n安装目录：%s\n媒体目录：%s\n监听地址：%s:%s → 容器 9808\n登录账号：%s\n特权模式：%s\n媒体只读：%s\n' \
        "$install_path" "$media_path" "$bind_address" "$web_port" "$login_name" "$privileged" "$media_read_only" >&3
    ask confirm '开始安装？回车继续，输入 n 取消' 'y'
    case "${confirm,,}" in
        y|yes) ;;
        n|no) printf '已取消。\n'; return 0 ;;
        *) die '请输入 y 或 n。' ;;
    esac

    mkdir -p -- "$(dirname -- "$install_path")"
    # 不带 -p，确保并发运行或新出现的目录不会被覆盖。
    mkdir -m 700 -- "$install_path"
    mkdir -m 755 -- "$install_path/data" "$install_path/logs" "$install_path/output"
    local compose_file="$install_path/docker-compose.yml"
    cat > "$compose_file" <<EOF
services:
  mtool:
    image: kuanghom/mtoolweb:3.0.1
    container_name: mtool
    privileged: $privileged
    ports:
      - "$bind_address:$web_port:9808"
    environment:
      SERVER_PORT: "9808"
      BDINFO_BROWSER_DELETE_ENABLED: "$delete_enabled"
      MTOOL_AUTH_USERNAME: $(yaml_value "$login_name")
      MTOOL_AUTH_PASSWORD: $(yaml_value "$login_password")
    volumes:
      - type: bind
        source: $(yaml_value "$media_path")
        target: /media
        read_only: $media_read_only
        bind:
          create_host_path: false
      - type: bind
        source: $(yaml_value "$install_path/data")
        target: /data/mtool/data
      - type: bind
        source: $(yaml_value "$install_path/logs")
        target: /data/mtool/logs
      - type: bind
        source: $(yaml_value "$install_path/output")
        target: /data/mtool/output
    logging:
      driver: local
      options:
        max-size: "10m"
        max-file: "3"
    restart: unless-stopped
EOF
    chmod 600 -- "$compose_file"
    local -a compose=(docker compose --project-name mtool --env-file /dev/null -f "$compose_file")
    "${compose[@]}" config --quiet
    if [[ "$generated" == true ]]; then
        printf '\n随机密码：%s\n请现在保存；密码同时保存在权限为 600 的 Compose 文件中。\n' "$login_password" >&3
    else
        printf '\n使用你设置的密码；不会在输出中显示。\n' >&3
    fi
    unset login_password

    # 由 Docker 检查目标架构；镜像拉取失败时不尝试用模拟架构强行启动。
    "${compose[@]}" pull
    "${compose[@]}" up -d
    printf '\n等待 Web 服务响应……\n'
    local attempt http_code running
    for ((attempt=0; attempt<40; attempt++)); do
        http_code=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 2 \
            "http://127.0.0.1:$web_port/" || true)
        running=$(docker inspect --format '{{.State.Running}}' mtool 2>/dev/null || true)
        if [[ "$running" == true && ( "$http_code" =~ ^[23][0-9][0-9]$ || "$http_code" == 401 || "$http_code" == 403 ) ]]; then
            printf '\n容器正在运行，Web 已响应（HTTP %s）。请在浏览器中验证登录和媒体处理。\n' "$http_code"
            printf '本机地址：http://127.0.0.1:%s\n账号：%s\n配置：%s\n' "$web_port" "$login_name" "$compose_file"
            if [[ "$bind_address" == 0.0.0.0 ]]; then
                printf '远程地址：http://你的VPS公网IP:%s（公网连通性尚未验证）。\n' "$web_port"
            else
                printf '远程访问：在电脑建立 SSH 隧道，或配置本机 HTTPS 反向代理。\n'
            fi
            return 0
        fi
        sleep 2
    done
    printf '\nWeb 未在等待期内就绪，不能确认安装成功。请检查：\n'
    printf '  docker logs --tail 100 mtool\n'
    printf '配置已保留：%s\n' "$compose_file"
    return 1
}

main "$@"
