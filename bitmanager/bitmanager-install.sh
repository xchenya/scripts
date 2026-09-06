#!/usr/bin/env bash
# BitManager Web 安装 / 覆盖安装：Linux + 本机 Docker Engine + Docker Compose 插件。
# 默认 /opt/bitmanager/data 挂载到 /opt/bitmanager/proxy/data，0.0.0.0:8088 -> 80。
# 固定 kuanghom/btmanager-web:latest，关闭注册；交互设置管理员环境变量。
# 配置备份不包含完整应用数据；不清空数据，不自动修改应用数据库。
set +x
set -Eeuo pipefail
umask 077

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
trap 'printf "安装未完成（第 %s 行）。已生成的配置保留，请检查错误后处理；不会自动删除数据。\n" "$LINENO" >&2' ERR
BITMANAGER_STAGE=''
cleanup() {
    if [[ -n "$BITMANAGER_STAGE" ]]; then
        rm -rf -- "$BITMANAGER_STAGE"
    fi
}
trap cleanup EXIT

# 同时保护 YAML 字面值和 Compose 的 $ 插值；不使用 eval/source。
yaml_value() {
    local value=$1
    value=${value//\$/\$\$}
    value=${value//\'/\'\'}
    printf "'%s'" "$value"
}

ask() {
    local target=$1 prompt=$2 fallback=$3 ask_reply
    printf '%s [默认：%s]：' "$prompt" "$fallback" >&3
    IFS= read -r ask_reply <&3 || die '输入已中断。'
    [[ ! "$ask_reply" =~ [[:cntrl:]] ]] || die '输入不能包含控制字符。'
    printf -v "$target" '%s' "${ask_reply:-$fallback}"
}

valid_public_ipv4() {
    local value=$1 octet first second
    local -a octets=()
    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$value"
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
    first=$((10#${octets[0]}))
    second=$((10#${octets[1]}))
    # 查询结果不能是本机、私网、共享地址或组播等常见非公网地址。
    (( first > 0 && first < 224 && first != 10 && first != 127 )) || return 1
    (( first != 169 || second != 254 )) || return 1
    (( first != 172 || second < 16 || second > 31 )) || return 1
    (( first != 192 || second != 168 )) || return 1
    (( first != 100 || second < 64 || second > 127 )) || return 1
    return 0
}

get_public_ipv4() {
    local endpoint candidate
    # 只查询公网 IPv4，不使用环境代理；每个查询最多 3 秒，失败尝试备用服务。
    for endpoint in 'https://api.ipify.org' 'https://checkip.amazonaws.com'; do
        if candidate=$(curl -4 -fsS --noproxy '*' --connect-timeout 2 --max-time 3 --max-filesize 64 \
            "$endpoint" 2>/dev/null); then
            candidate=${candidate//$'\r'/}
            if valid_public_ipv4 "$candidate"; then
                printf '%s\n' "$candidate"
                return 0
            fi
        fi
    done
    return 1
}

show_result() {
    local bind_address=$1 web_port=$2 login_name=$3 compose_file=$4 install_path=$5 backup_path=$6 public_ip
    printf '\n========== BitManager Web 已启动，Web 已响应 ==========\n'
    printf '监听地址：%s:%s\n本机地址：http://127.0.0.1:%s\n' "$bind_address" "$web_port" "$web_port"
    if [[ "$bind_address" == 0.0.0.0 ]]; then
        if public_ip=$(get_public_ipv4); then
            printf '公网地址：http://%s:%s\n' "$public_ip" "$web_port"
        else
            printf '公网地址：自动识别失败，请在 VPS 控制台查看公网 IPv4；安装不受影响。\n'
        fi
        printf '公网入口尚未从外部验证；请放行 TCP %s，NAT VPS 还需对应的端口映射。\n' "$web_port"
    else
        printf '当前仅本机监听，远程访问请使用 SSH 隧道或本机反向代理。\n'
    fi
    printf '管理员环境变量账号：%s\n管理员环境变量密码：使用本次设置或生成的密码\n配置文件：%s\n' "$login_name" "$compose_file"
    if [[ -n "$backup_path" ]]; then
        printf '旧配置备份：%s\n' "$backup_path"
    fi
    printf '\n查看日志：docker logs --tail 100 bitmanager-web\n重启服务：docker restart bitmanager-web\n'
    printf '查看状态：cd %q && docker compose --env-file /dev/null -f bitmanager-compose.yml ps\n' "$install_path"
    printf '请在浏览器验证登录。已有账号是否受管理员环境变量影响由镜像决定，脚本不直接修改账号数据库。\n'
}

main() {
    [[ $(uname -s) == Linux ]] || die '本脚本适用于 Linux VPS。'
    (( EUID == 0 )) || die '请以 root 运行，例如 sudo bash bitmanager-install.sh。'
    printf '\n[1/5] 检查运行环境\n'
    local dependency
    for dependency in docker curl openssl ss realpath flock; do
        command -v "$dependency" >/dev/null 2>&1 || die "缺少依赖：$dependency。请先安装。"
    done
    docker compose version >/dev/null 2>&1 || die '需要 Docker Compose 插件（docker compose）。'
    docker info >/dev/null 2>&1 || die '无法连接 Docker，请检查服务和访问权限。'
    local docker_endpoint
    if [[ -n "${DOCKER_CONTEXT:-}" || -z "${DOCKER_HOST:-}" ]]; then
        docker_endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}')
    else
        docker_endpoint=$DOCKER_HOST
    fi
    [[ "$docker_endpoint" == unix://* ]] || die '请连接本机 Docker Engine；不能使用远程 Docker 创建本机数据挂载。'
    local existing_id project_name=bitmanager-web existing_project='' existing_service=''
    existing_id=$(docker container inspect --format '{{.Id}}' bitmanager-web 2>/dev/null || true)
    if [[ -n "$existing_id" ]]; then
        existing_project=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$existing_id")
        existing_service=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$existing_id")
        if [[ "$existing_project" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
            project_name=$existing_project
        fi
    fi
    { exec 3<>/dev/tty; } 2>/dev/null || die '需要交互终端；请在 SSH 终端中运行。'
    printf '\n[2/5] 设置部署参数\n' >&3

    local install_path web_port bind_address login_name login_password
    local confirm existing_listeners port_owners='' owner owns_port=false
    local running_ids container_port published_port
    local -a running_containers=()
    local existing_directory=false backup_path=''
    local generated=false
    if [[ -n "$existing_id" ]]; then
        printf '检测到已有 bitmanager-web 容器，将按本次输入重建。原挂载如下，请沿用需要保留的数据路径：\n' >&3
        docker inspect --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' "$existing_id" >&3
        printf '本脚本使用“安装目录/data”作为数据目录；例如原数据在 /srv/bitmanager/data，请填写安装目录 /srv/bitmanager。选择新目录不会自动迁移旧数据。\n' >&3
    fi
    ask install_path 'BitManager Web 安装目录（已有目录会备份配置后覆盖）' '/opt/bitmanager'
    [[ "$install_path" == /* ]] || die '路径必须以 / 开头，不能使用 ~。'
    install_path=$(realpath -m -- "$install_path")
    [[ "$install_path" != / ]] || die '不能将根目录作为安装目录。'
    if [[ -e "$install_path" ]]; then
        [[ -d "$install_path" ]] || die '安装路径已存在，但不是目录。'
        existing_directory=true
        printf '检测到已有安装目录：将备份旧配置并覆盖，保留 data 目录中的文件。\n' >&3
    fi
    ask web_port '宿主机 Web 端口（容器端口固定为 80）' '8088'
    [[ "$web_port" =~ ^[0-9]{1,5}$ ]] || die '端口必须为 1～65535 的整数。'
    web_port=$((10#$web_port))
    (( web_port >= 1 && web_port <= 65535 )) || die '端口必须为 1～65535。'
    existing_listeners=$(ss -H -ltn "sport = :$web_port")
    # 按实际 HostPort 检查；publish 过滤器可能按容器端口匹配，不能用于判断宿主机端口冲突。
    running_ids=$(docker ps --no-trunc -q)
    if [[ -n "$running_ids" ]]; then
        mapfile -t running_containers <<< "$running_ids"
        port_owners=$(docker inspect --format '{{range $port, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{println $.Id $port .HostPort}}{{end}}{{end}}' "${running_containers[@]}")
    fi
    while read -r owner container_port published_port; do
        [[ "$container_port" == */tcp && "$published_port" == "$web_port" ]] || continue
        [[ "$owner" == "$existing_id" ]] || die "TCP 端口 $web_port 被其他容器占用，请换一个端口。"
        owns_port=true
    done <<< "$port_owners"
    if [[ -n "$existing_listeners" && "$owns_port" != true ]]; then
        die "TCP 端口 $web_port 被其他服务占用，请换一个端口。"
    fi
    if [[ "$owns_port" == true ]]; then
        printf '端口 %s 由当前 bitmanager-web 使用，重建时会继续使用该端口。\n' "$web_port" >&3
    fi

    printf '\n0.0.0.0：监听宿主机所有 IPv4 网卡，可使用公网 IP 访问；请配置云安全组和 HTTPS。\n127.0.0.1：仅本机监听，通过 SSH 隧道或本机反向代理访问。\n' >&3
    ask bind_address '监听地址（0.0.0.0 / 127.0.0.1）' '0.0.0.0'
    [[ "$bind_address" == 127.0.0.1 || "$bind_address" == 0.0.0.0 ]] || die '请填写 127.0.0.1 或 0.0.0.0。'
    ask login_name '管理员用户名' 'admin'
    printf '设置登录密码（隐藏输入，回车生成随机密码）：' >&3
    IFS= read -r -s login_password <&3 || die '输入已中断。'
    printf '\n' >&3
    [[ ! "$login_password" =~ [[:cntrl:]] ]] || die '密码不能包含控制字符。'
    if [[ -z "$login_password" ]]; then
        login_password=$(openssl rand -base64 24)
        generated=true
    fi
    (( ${#login_password} >= 12 )) || die '请使用至少 12 个字符的密码。'

    printf '\n安装目录：%s\n数据目录：%s/data\n监听地址：%s:%s → 容器 80\n管理员用户名：%s\n镜像：kuanghom/btmanager-web:latest\n开放注册：false\n' \
        "$install_path" "$install_path" "$bind_address" "$web_port" "$login_name" >&3
    if [[ "$existing_directory" == true || -n "$existing_id" ]]; then
        printf '覆盖方式：先校验配置并拉取镜像，再备份配置和重建容器；保留持久化文件。\n管理员环境变量及其他配置以本次输入为准，额外挂载和自定义参数不自动迁移；不直接重置应用内已有账号。\n' >&3
    fi
    ask confirm '开始安装 / 覆盖？回车继续，输入 n 取消' 'y'
    case "${confirm,,}" in
        y|yes) ;;
        n|no) printf '已取消。\n'; return 0 ;;
        *) die '请输入 y 或 n。' ;;
    esac

    local compose_file="$install_path/bitmanager-compose.yml"
    BITMANAGER_STAGE=$(mktemp -d)
    local candidate_file="$BITMANAGER_STAGE/bitmanager-compose.yml"
    cat > "$candidate_file" <<EOF
name: $(yaml_value "$project_name")
services:
  bitmanager-web:
    image: kuanghom/btmanager-web:latest
    container_name: bitmanager-web
    ports:
      - "$bind_address:$web_port:80"
    environment:
      ALLOW_REGISTER: "false"
      ADMIN_USERNAME: $(yaml_value "$login_name")
      ADMIN_PASSWORD: $(yaml_value "$login_password")
    volumes:
      - type: bind
        source: $(yaml_value "$install_path/data")
        target: /opt/bitmanager/proxy/data
        bind:
          create_host_path: false
    logging:
      driver: local
      options:
        max-size: "10m"
        max-file: "3"
    restart: unless-stopped
EOF
    chmod 600 -- "$candidate_file"
    local -a candidate=(docker compose --project-name "$project_name" --env-file /dev/null -f "$candidate_file")
    local -a compose=(docker compose --project-name "$project_name" --env-file /dev/null -f "$compose_file")
    printf '\n[3/5] 校验配置并拉取镜像\n'
    "${candidate[@]}" config --quiet
    # 下载失败不会覆盖旧配置，也不会停止旧容器。
    "${candidate[@]}" pull

    mkdir -p -- "$install_path"
    exec 9> "$install_path/.bitmanager-install.lock"
    flock -n 9 || die '此目录已有安装进程在运行，请等它结束后重试。'
    local current_id name
    current_id=$(docker container inspect --format '{{.Id}}' bitmanager-web 2>/dev/null || true)
    [[ "$current_id" == "$existing_id" ]] || die '安装期间 bitmanager-web 容器发生了变化，请重新运行以读取当前状态。'
    printf '\n[4/5] 备份配置并重建容器\n'
    if [[ "$existing_directory" == true || -n "$existing_id" || -e "$compose_file" || -L "$compose_file" ]]; then
        mkdir -p -- "$install_path/.backups"
        chmod 700 -- "$install_path/.backups"
        backup_path=$(mktemp -d "$install_path/.backups/$(date +%Y%m%d-%H%M%S)-XXXXXX")
        for name in bitmanager-compose.yml docker-compose.yml docker-compose.yaml compose.yml compose.yaml .env; do
            if [[ -f "$install_path/$name" ]]; then
                cp -L -- "$install_path/$name" "$backup_path/$name"
                chmod 600 -- "$backup_path/$name"
            fi
        done
        if [[ -n "$existing_id" ]]; then
            docker inspect "$existing_id" > "$backup_path/container-inspect.json"
        fi
        printf '\n旧配置备份：%s\n' "$backup_path" >&3
    fi
    mkdir -p -m 755 -- "$install_path/data"
    local pending_file
    pending_file=$(mktemp "$install_path/.bitmanager-compose.XXXXXX")
    cp -- "$candidate_file" "$pending_file"
    chmod 600 -- "$pending_file"
    mv -T -- "$pending_file" "$compose_file"
    if [[ "$generated" == true ]]; then
        printf '\n随机密码：%s\n请现在保存；密码同时保存在权限为 600 的 Compose 文件中。\n' "$login_password" >&3
    else
        printf '\n使用你设置的密码；不会在输出中显示。\n' >&3
    fi
    unset login_password

    if [[ -n "$existing_id" && ( "$existing_project" != "$project_name" || "$existing_service" != bitmanager-web ) ]]; then
        # 非本项目 bitmanager-web 服务的旧容器不能由 Compose 接管；先正常停止，再移除容器本身。
        # 不使用 rm -v / down -v，不删除任何挂载卷或宿主机数据目录。
        docker stop "$existing_id" >/dev/null
        docker rm "$existing_id" >/dev/null
    fi
    if ! "${compose[@]}" up -d --force-recreate bitmanager-web; then
        printf '容器重建失败，持久化数据未删除。旧配置备份：%s\n' "${backup_path:-无旧配置}" >&2
        printf '请检查 Docker 错误；需要恢复时使用备份配置和其中记录的原挂载路径。\n' >&2
        return 1
    fi
    printf '\n[5/5] 等待 Web 服务响应\n'
    local attempt http_code running
    for ((attempt=0; attempt<40; attempt++)); do
        http_code=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 2 \
            "http://127.0.0.1:$web_port/" || true)
        running=$(docker inspect --format '{{.State.Running}}' bitmanager-web 2>/dev/null || true)
        if [[ "$running" == true && ( "$http_code" =~ ^[23][0-9][0-9]$ || "$http_code" == 401 || "$http_code" == 403 ) ]]; then
            printf '\nHTTP 响应：%s\n' "$http_code"
            show_result "$bind_address" "$web_port" "$login_name" "$compose_file" "$install_path" "$backup_path"
            return 0
        fi
        sleep 2
    done
    printf '\nWeb 未在等待期内就绪，不能确认安装成功。请检查：\n'
    printf '  docker logs --tail 100 bitmanager-web\n'
    printf '配置已保留：%s\n' "$compose_file"
    return 1
}

main "$@"
