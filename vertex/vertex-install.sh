#!/usr/bin/env bash
# Vertex 安装器：首次安装、已有容器配置复用及覆盖安装。
# 数据默认挂载 /opt/vertex:/vertex，Web 默认 0.0.0.0:3000:3000。
set +x
set -Eeuo pipefail
umask 077
VERTEX_STAGE=''
cleanup() {
    if [[ -n "$VERTEX_STAGE" ]]; then
        if [[ -f "$VERTEX_STAGE/import-plan.json" ]]; then vertex_restore cleanup "$VERTEX_STAGE/import-plan.json" || true; fi
        rm -rf -- "$VERTEX_STAGE"
    fi
}
trap cleanup EXIT
trap 'printf "安装未完成（第 %s 行）。请检查上方错误，持久化数据不会自动删除。\n" "$LINENO" >&2' ERR
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

ask() {
    local target=$1 prompt=$2 fallback=$3 ask_reply
    printf '%s [默认：%s]：' "$prompt" "$fallback" >&3
    IFS= read -r ask_reply <&3 || die '输入已中断。'
    [[ ! "$ask_reply" =~ [[:cntrl:]] ]] || die '输入不能包含控制字符。'
    printf -v "$target" '%s' "${ask_reply:-$fallback}"
}

# Python 仅使用标准库；以 JSON 安全解析 Docker 状态并生成 Compose 文件（JSON 是 YAML 的子集）。
# 密码等环境变量始终在权限受限的文件中处理，不通过 source/eval 或命令行传递。
vertex_config() {
    python3 - "$@" <<'PY'
import ipaddress, json, os, re, subprocess, sys
from pathlib import Path

def load(path):
    return json.loads(Path(path).read_text())

def old_container(path):
    value = load(path)
    return value[0] if value else {}

def environment(old):
    result = {}
    for item in old.get('Config', {}).get('Env') or []:
        key, sep, value = item.partition('=')
        if sep: result[key] = value
    return result

def web_target(old):
    value = environment(old).get('PORT', '3000')
    if not re.fullmatch(r'[0-9]{1,5}', value) or not 1 <= int(value) <= 65535:
        raise ValueError('旧 PORT 环境变量不是有效端口，不能自动复用。')
    return int(value)

def port_bindings(old):
    configured = old.get('HostConfig', {}).get('PortBindings') or {}
    active = old.get('NetworkSettings', {}).get('Ports') or {}
    result = []
    for key in sorted(set(configured) | set(active)):
        target, protocol = key.split('/', 1)
        bindings = active.get(key) or configured.get(key) or []
        for item in bindings:
            published = str(item.get('HostPort') or '')
            if not published.isdigit() or not 1 <= int(published) <= 65535:
                raise ValueError('旧容器存在尚未分配的随机端口，不能自动复用，请选择重新设置。')
            port = {'target': int(target), 'published': published, 'protocol': protocol}
            if item.get('HostIp'): port['host_ip'] = item['HostIp']
            if port not in result: result.append(port)
    return result

def data_mount(old):
    return next((m for m in old.get('Mounts', []) if m.get('Destination') == '/vertex'), None)

def original_meta(old):
    mount = data_mount(old)
    hint = '/opt/vertex'
    if mount and mount.get('Type') == 'bind' and mount.get('Source') != '/':
        hint = mount['Source']
    labels = old.get('Config', {}).get('Labels') or {}
    return {
        'id': old.get('Id', ''), 'status': old.get('State', {}).get('Status', '不存在'),
        'project': labels.get('com.docker.compose.project', ''),
        'service': labels.get('com.docker.compose.service', ''),
        'install_hint': hint, 'tz': environment(old).get('TZ', 'Asia/Shanghai'),
        'data_type': mount.get('Type', '') if mount else '',
    }

def quoted_values(value):
    # Compose 会处理 $ 插值；$$ 才能保留原环境值、路径和命令中的美元符号。
    if isinstance(value, str): return value.replace('$', '$$')
    if isinstance(value, list): return [quoted_values(x) for x in value]
    if isinstance(value, dict): return {key: quoted_values(x) for key, x in value.items()}
    return value

def display_binding(port):
    host = port.get('host_ip') or '0.0.0.0'
    if ':' in host: host = '[' + host + ']'
    return f"{host}:{port['published']} -> {port['target']}/{port['protocol']}"

try:
    mode = sys.argv[1]
    if mode == 'get':
        print(load(sys.argv[2]).get(sys.argv[3], ''))
    elif mode == 'summary':
        old = old_container(sys.argv[2]); meta = original_meta(old)
        Path(sys.argv[3]).write_text(json.dumps(meta, ensure_ascii=False))
        if old:
            mount = data_mount(old)
            print('检测到已有 vertex 容器，状态：' + meta['status'])
            print('原镜像：' + old.get('Config', {}).get('Image', '未知'))
            if mount:
                print('数据位置：' + (mount.get('Name') if mount.get('Type') == 'volume' else mount.get('Source', '')) + ' -> /vertex (' + mount.get('Type', '') + ')')
            else:
                print('数据位置：未发现 /vertex 持久化挂载，不能自动复用其数据。')
            try:
                for port in port_bindings(old): print('原端口：' + display_binding(port))
            except ValueError as error:
                print('原端口无法自动复用：' + str(error))
            print('原时区：' + meta['tz'])
            print('原网络模式：' + old.get('HostConfig', {}).get('NetworkMode', 'default'))
    elif mode == 'generate':
        snapshot, reuse, directory, port, bind, timezone, output, metadata = sys.argv[2:]
        old = old_container(snapshot); meta = original_meta(old); reuse = reuse == 'true'
        directory = os.path.realpath(directory)
        if not directory.startswith('/') or directory == '/' or any(ord(c) < 32 for c in directory):
            raise ValueError('安装目录必须是有效的绝对路径，不能使用根目录。')
        if os.path.exists(directory) and not os.path.isdir(directory):
            raise ValueError('安装路径已存在，但不是目录。')
        project = meta['project'] if re.fullmatch(r'[a-z0-9][a-z0-9_-]*', meta['project']) else 'vertex'
        service = {
            'image': 'kuanghom/vertex:latest', 'container_name': 'vertex',
            'command': ['/bin/sh', '-c', 'bash /app/vertex/docker/start.sh'],
            'restart': 'unless-stopped', 'environment': {'TZ': timezone},
        }
        config = {'name': project, 'services': {'vertex': service}}
        if reuse:
            mount = data_mount(old)
            if not mount or mount.get('Type') not in ('bind', 'volume'):
                raise ValueError('无法复用 /vertex 数据位置。请先备份容器内数据，再选择重新设置；旧容器未修改。')
            service['environment'] = environment(old)
            service['environment'].setdefault('TZ', 'Asia/Shanghai')
            ports = port_bindings(old)
            service['volumes'] = []
            for index, item in enumerate(old.get('Mounts', [])):
                kind = item['Type']
                if kind == 'tmpfs': continue
                if kind not in ('bind', 'volume'):
                    raise ValueError('发现暂不支持自动复用的挂载类型：' + kind)
                volume = {'type': kind, 'target': item['Destination'], 'read_only': not item.get('RW', True)}
                if kind == 'bind':
                    volume['source'] = item['Source']
                    volume['bind'] = {'create_host_path': False}
                    if item.get('Propagation'): volume['bind']['propagation'] = item['Propagation']
                else:
                    name = item.get('Name')
                    if not name: raise ValueError('无法识别原 Docker 数据卷名称。')
                    alias = 'existing_volume_' + str(index)
                    config.setdefault('volumes', {})[alias] = {'external': True, 'name': name}
                    volume['source'] = alias
                service['volumes'].append(volume)
            host = old.get('HostConfig', {})
            if host.get('Tmpfs'):
                service['tmpfs'] = [path + (':' + options if options else '') for path, options in host['Tmpfs'].items()]
            restart = host.get('RestartPolicy') or {}
            service['restart'] = restart.get('Name') or 'no'
            if service['restart'] == 'on-failure' and restart.get('MaximumRetryCount'):
                service['restart'] += ':' + str(restart['MaximumRetryCount'])
            mode_name = host.get('NetworkMode') or 'default'
            if mode_name.startswith('container:') or mode_name == 'none':
                raise ValueError('此网络模式不能自动生成 Web 访问配置，请选择重新设置：' + mode_name)
            if mode_name in ('host', 'bridge', 'default'):
                service['network_mode'] = 'bridge' if mode_name == 'default' else mode_name
            else:
                for index, (name, endpoint) in enumerate((old.get('NetworkSettings', {}).get('Networks') or {}).items()):
                    alias = 'existing_network_' + str(index)
                    config.setdefault('networks', {})[alias] = {'external': True, 'name': name}
                    settings = {}
                    aliases = [a for a in endpoint.get('Aliases') or [] if a not in (old.get('Id'), old.get('Id', '')[:12])]
                    if aliases: settings['aliases'] = aliases
                    ipam = endpoint.get('IPAMConfig') or {}
                    for source, target in [('IPv4Address', 'ipv4_address'), ('IPv6Address', 'ipv6_address')]:
                        if ipam.get(source): settings[target] = ipam[source]
                    service.setdefault('networks', {})[alias] = settings
                if not service.get('networks'): raise ValueError('无法识别旧容器网络，不能自动复用。')
            labels = {k: v for k, v in (old.get('Config', {}).get('Labels') or {}).items() if not k.startswith('com.docker.compose.')}
            if labels: service['labels'] = labels
            target_port = web_target(old)
            if mode_name == 'host':
                ports = []
                web_ports = [{'target': target_port, 'published': str(target_port), 'protocol': 'tcp', 'host_ip': '0.0.0.0'}]
            else:
                web_ports = [p for p in ports if p['target'] == target_port and p['protocol'] == 'tcp']
            if ports: service['ports'] = ports
            if mount['Type'] == 'bind':
                data_description = mount['Source']
                password_path = os.path.join(mount['Source'], 'data', 'password')
            else:
                data_description = 'Docker 卷 ' + mount['Name']
                password_path = '容器内 /vertex/data/password'
        else:
            if not re.fullmatch(r'[0-9]{1,5}', port) or not 1 <= int(port) <= 65535:
                raise ValueError('端口必须为 1～65535 的整数。')
            if bind not in ('0.0.0.0', '127.0.0.1'): raise ValueError('监听地址请选择 0.0.0.0 或 127.0.0.1。')
            ports = [{'target': 3000, 'published': str(int(port)), 'protocol': 'tcp', 'host_ip': bind}]
            service['ports'] = ports
            service['volumes'] = [{'type': 'bind', 'source': directory, 'target': '/vertex', 'bind': {'create_host_path': False}}]
            web_ports = ports
            data_description = directory
            password_path = os.path.join(directory, 'data', 'password')
        if not web_ports: raise ValueError('没有识别到 Vertex Web 端口映射，请选择重新设置。')
        service['logging'] = {'driver': 'local', 'options': {'max-size': '10m', 'max-file': '3'}}
        Path(output).write_text(json.dumps(quoted_values(config), ensure_ascii=False, indent=2) + '\n')
        details = {'project': project, 'install_path': directory, 'data': data_description, 'password_path': password_path, 'web_ports': web_ports, 'ports': ports, 'timezone': service['environment'].get('TZ', '')}
        restore_error = ''
        if reuse and (mount['Type'] != 'bind' or not mount.get('RW', True)):
            restore_error = '直链导入需要可写的 /vertex 宿主机目录挂载；Docker 数据卷或只读挂载仍可不导入备份正常安装。'
        if reuse and any(m.get('Destination', '').startswith('/vertex/data/') or m.get('Destination') == '/vertex/data' for m in old.get('Mounts', [])):
            restore_error = '存在覆盖 /vertex/data 的额外挂载，不能直接导入，请先整理挂载结构。'
        details.update(restore_path=os.path.join(directory, 'data'), restore_error=restore_error,
                       restore_uid=service['environment'].get('PUID', ''), restore_gid=service['environment'].get('PGID', ''))
        Path(metadata).write_text(json.dumps(details, ensure_ascii=False))
        print('管理目录：' + directory)
        print('数据位置：' + data_description)
        for item in web_ports: print('Web 映射：' + display_binding(item))
        print('时区：' + details['timezone'])
        print('镜像：kuanghom/vertex:latest；启动命令：bash /app/vertex/docker/start.sh')
    elif mode == 'preflight':
        old = old_container(sys.argv[2]); details = load(sys.argv[3])
        wanted = details['ports'] or details['web_ports']
        previous = port_bindings(old) if old.get('State', {}).get('Running') else []
        if old.get('State', {}).get('Running') and old.get('HostConfig', {}).get('NetworkMode') == 'host':
            previous.append({'published': str(web_target(old)), 'protocol': 'tcp'})
        ids = subprocess.check_output(['docker', 'ps', '-q', '--no-trunc'], text=True).split()
        others = json.loads(subprocess.check_output(['docker', 'inspect', *ids], text=True)) if ids else []
        for desired in wanted:
            port = desired['published']; protocol = desired['protocol']
            for other in others:
                if other.get('Id') == old.get('Id'): continue
                if any(p['published'] == port and p['protocol'] == protocol for p in port_bindings(other)):
                    raise ValueError(f'端口 {port}/{protocol} 被其他容器占用，请重新设置。')
            if any(p['published'] == port and p['protocol'] == protocol for p in previous): continue
            flag = '-ltn' if protocol == 'tcp' else '-lun'
            if subprocess.check_output(['ss', '-H', flag, 'sport = :' + port], text=True).strip():
                raise ValueError(f'端口 {port}/{protocol} 被其他服务占用，请重新设置。')
    elif mode == 'probe':
        for p in load(sys.argv[2])['web_ports']:
            host = p.get('host_ip') or '0.0.0.0'
            if host == '0.0.0.0': host = '127.0.0.1'
            if host == '::': host = '::1'
            if ':' in host: host = '[' + host + ']'
            print('http://' + host + ':' + p['published'] + '/')
    elif mode == 'public':
        for p in load(sys.argv[2])['web_ports']:
            address = p.get('host_ip') or '0.0.0.0'
            parsed = ipaddress.ip_address(address)
            if parsed.version == 4 and not parsed.is_loopback: sys.exit(0)
        sys.exit(1)
    elif mode == 'valid-ip':
        address = ipaddress.ip_address(sys.argv[2])
        sys.exit(0 if address.version == 4 and address.is_global else 1)
    elif mode == 'result':
        details = load(sys.argv[2]); public_ip = sys.argv[3]
        print('\n========== Vertex 已启动，Web 已响应 ==========')
        for p in details['web_ports']:
            host = p.get('host_ip') or '0.0.0.0'
            if host == '0.0.0.0':
                print('本机地址：http://127.0.0.1:' + p['published'])
                if public_ip: print('公网参考地址：http://' + public_ip + ':' + p['published'])
            elif host == '::': print('IPv6 监听：[::]:' + p['published'] + '（使用 VPS 实际 IPv6 地址访问）')
            else:
                value = '[' + host + ']' if ':' in host else host
                print('访问地址：http://' + value + ':' + p['published'])
        print('数据位置：' + details['data'])
        print('首次安装初始密码位置：' + details['password_path'])
        print('默认使用 HTTP；公网访问还需安全组/防火墙放行，NAT VPS 需端口映射。')
    else:
        raise ValueError('未知配置操作。')
except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
    print('错误：' + str(error), file=sys.stderr)
    sys.exit(1)
PY
}

# 备份只解压普通文件/目录，不执行备份中的脚本，不使用 extractall。
vertex_restore() {
    python3 - "$@" <<'PY'
import json, os, re, shutil, stat, sys, tarfile, tempfile, zipfile
from pathlib import Path
from urllib.parse import urlsplit

MAX_BYTES = 4 * 1024**3
MAX_FILES = 100000

class RestoreError(ValueError): pass

def read_json(path): return json.loads(Path(path).read_text())
def write_json(path, value): Path(path).write_text(json.dumps(value, ensure_ascii=False))
def target_for(meta):
    if meta.get('restore_error'): raise RestoreError(meta['restore_error'])
    target = Path(meta['restore_path'])
    if target.is_symlink() or os.path.ismount(target):
        raise RestoreError('导入目标 data 不能是符号链接或独立挂载点，请先整理数据挂载。')
    if target.exists() and not target.is_dir(): raise RestoreError('导入目标 data 已存在且不是目录。')
    return target

def safe_name(name):
    if not name or name.startswith('/') or '\\' in name or re.match(r'^[A-Za-z]:', name) or any(ord(c)<32 for c in name):
        raise RestoreError('备份包含不安全的文件路径。')
    parts = [p for p in name.split('/') if p not in ('', '.')]
    if '..' in parts: raise RestoreError('备份包含越界路径。')
    return Path(*parts) if parts else None

try:
    mode = sys.argv[1]
    if mode == 'url':
        url = Path(sys.argv[2]).read_text()
        parts = urlsplit(url)
        if parts.scheme not in ('http', 'https') or not parts.hostname or any(ord(c)<=32 for c in url) or parts.fragment:
            raise RestoreError('请输入有效的 HTTP/HTTPS 文件直链，不支持空白字符或 URL 片段。')
        _ = parts.port
        escaped = url.replace('\\', '\\\\').replace('"', '\\"')
        Path(sys.argv[3]).write_text('url = "' + escaped + '"\n')
        print('=https' if parts.scheme == 'https' else '=http,https')
    elif mode == 'target':
        target = target_for(read_json(sys.argv[2]))
        print('备份将替换的数据目录：' + str(target))
    elif mode == 'extract':
        archive, output, password_file, result_file = map(Path, sys.argv[2:])
        if output.exists(): shutil.rmtree(output)
        output.mkdir(mode=0o700)
        password = password_file.read_bytes() or None
        total = 0; count = 0; seen = set()
        def unpack(name, size, is_dir, permissions, opener):
            global total, count
            count += 1; total += size
            if count > MAX_FILES or total > MAX_BYTES or size < 0: raise RestoreError('备份解压后超过 4 GiB 或 100000 个条目的限制。')
            relative = safe_name(name)
            if relative is None:
                if not is_dir: raise RestoreError('备份文件路径无效。')
                return
            if relative in seen: raise RestoreError('备份包含重复路径，无法确定恢复内容。')
            seen.add(relative)
            destination = output / relative
            if is_dir:
                destination.mkdir(mode=0o700, parents=True, exist_ok=True)
                return
            destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with opener() as source, destination.open('xb') as sink:
                copied = 0
                while True:
                    chunk = source.read(1024*1024)
                    if not chunk: break
                    copied += len(chunk)
                    if copied > size: raise RestoreError('备份文件大小与声明不一致。')
                    sink.write(chunk)
                if copied != size: raise RestoreError('备份文件内容不完整。')
            destination.chmod(0o600 | (permissions & 0o111))
        if zipfile.is_zipfile(archive):
            with zipfile.ZipFile(archive) as package:
                for member in package.infolist():
                    permissions = member.external_attr >> 16
                    kind = stat.S_IFMT(permissions)
                    if kind not in (0, stat.S_IFREG, stat.S_IFDIR): raise RestoreError('备份包含链接或特殊文件，不能导入。')
                    unpack(member.filename, member.file_size, member.is_dir(), permissions, lambda m=member: package.open(m, pwd=password))
        else:
            with tarfile.open(archive, 'r:*') as package:
                for member in package:
                    if not (member.isfile() or member.isdir()): raise RestoreError('备份包含链接或特殊文件，不能导入。')
                    unpack(member.name, member.size, member.isdir(), member.mode, lambda m=member: package.extractfile(m))
        candidates = list(output.rglob('setting.json'))
        if len(candidates) != 1 or not candidates[0].is_file():
            raise RestoreError('备份必须包含唯一的 setting.json，不能缺失或混入多份 Vertex 备份。')
        settings = json.loads(candidates[0].read_text(encoding='utf-8-sig'))
        if not isinstance(settings, dict): raise RestoreError('setting.json 必须是有效的 JSON 对象。')
        write_json(result_file, {'source':str(candidates[0].parent)})
        print('备份检查通过：已定位 setting.json 及同目录数据。')
    elif mode == 'prepare':
        metadata, extracted, backup, plan_file = sys.argv[2:]
        meta = read_json(metadata); target = target_for(meta); source = Path(read_json(extracted)['source'])
        backup = Path(backup)
        if target.exists() and target.stat().st_dev != backup.stat().st_dev:
            raise RestoreError('data 与备份目录不在同一文件系统，不能进行目录替换。')
        previous = target.stat() if target.exists() else None
        owners = []
        for key, fallback in [('restore_uid', previous.st_uid if previous else 0), ('restore_gid', previous.st_gid if previous else 0)]:
            value = meta.get(key, '') or str(fallback)
            if not re.fullmatch(r'[0-9]{1,10}', value) or int(value) >= 2**32-1: raise RestoreError('PUID/PGID 无效，无法设置恢复文件所有者。')
            owners.append(int(value))
        staging = Path(tempfile.mkdtemp(prefix='.vertex-import-', dir=target.parent))
        try:
            shutil.copytree(source, staging, dirs_exist_ok=True)
            settings_path = staging/'setting.json'
            settings = json.loads(settings_path.read_text(encoding='utf-8-sig'))
            settings['port'] = meta['web_ports'][0]['target']
            settings_path.write_text(json.dumps(settings, ensure_ascii=False, indent=2)+'\n')
            for current, folders, files in os.walk(staging):
                os.chown(current, *owners); os.chmod(current, 0o700)
                for name in files:
                    p = Path(current)/name
                    os.chown(p, *owners); p.chmod(0o600 | (p.stat().st_mode & 0o111))
            write_json(plan_file, {'target':str(target), 'staging':str(staging), 'saved':str(backup/'data-before-import'),
                                  'previous_inode':previous.st_ino if previous else None, 'applied':False})
        except BaseException:
            shutil.rmtree(staging)
            raise
    elif mode == 'apply':
        plan_file = sys.argv[2]; plan = read_json(plan_file)
        target = Path(plan['target']); staging = Path(plan['staging']); saved = Path(plan['saved'])
        if target.is_symlink() or os.path.ismount(target): raise RestoreError('恢复目标在安装期间发生变化。')
        inode = target.stat().st_ino if target.exists() else None
        if inode != plan['previous_inode'] or saved.exists(): raise RestoreError('恢复目标或备份位置在安装期间发生变化。')
        moved = False; installed = False
        try:
            if target.exists(): target.rename(saved); moved = True
            staging.rename(target); installed = True
            plan['applied'] = True; write_json(plan_file, plan)
        except BaseException:
            if installed: target.rename(staging)
            if moved: saved.rename(target)
            raise
        print('备份已导入：' + str(target))
        if moved: print('原 data 目录已保留：' + str(saved))
    elif mode == 'original-restored':
        plan = read_json(sys.argv[2]); target = Path(plan['target'])
        inode = target.stat().st_ino if target.exists() else None
        sys.exit(0 if not target.is_symlink() and inode == plan['previous_inode'] else 1)
    elif mode == 'cleanup':
        plan = read_json(sys.argv[2]); staging = Path(plan['staging'])
        if staging.is_dir(): shutil.rmtree(staging)
    else:
        raise RestoreError('未知备份操作。')
except RestoreError as error:
    print('备份处理失败：' + str(error), file=sys.stderr); sys.exit(1)
except RuntimeError as error:
    if 'password' in str(error).lower() or 'encrypted' in str(error).lower():
        print('ZIP 需要密码或密码错误。', file=sys.stderr); sys.exit(3)
    print('备份解压失败。', file=sys.stderr); sys.exit(1)
except (ValueError, OSError, EOFError, zipfile.BadZipFile, tarfile.TarError, NotImplementedError):
    # 不回显异常中的 URL、文件内容或凭据。
    print('备份处理失败：文件损坏、结构/路径不安全、格式不支持，或数据目录/磁盘条件不满足要求。', file=sys.stderr)
    sys.exit(1)
PY
}

read_secret() {
    local target=$1 prompt=$2 secret_reply
    printf '%s：' "$prompt" >&3
    IFS= read -r -s secret_reply <&3 || die '输入已中断。'
    printf '\n' >&3
    [[ ! "$secret_reply" =~ [[:cntrl:]] ]] || die '输入不能包含控制字符。'
    printf -v "$target" '%s' "$secret_reply"
}

get_public_ipv4() {
    local endpoint address
    for endpoint in 'https://api.ipify.org' 'https://checkip.amazonaws.com'; do
        if address=$(curl -4 -fsS --noproxy '*' --connect-timeout 2 --max-time 3 --max-filesize 64 "$endpoint" 2>/dev/null); then
            address=${address//$'\r'/}
            if vertex_config valid-ip "$address" 2>/dev/null; then printf '%s\n' "$address"; return 0; fi
        fi
    done
    return 1
}

main() {
    [[ $(uname -s) == Linux ]] || die '本脚本适用于 Linux VPS。'
    (( EUID == 0 )) || die '请以 root 执行。'
    local dependency
    for dependency in docker python3 curl ss flock; do
        command -v "$dependency" >/dev/null 2>&1 || die "缺少依赖：$dependency，请先安装。"
    done
    docker compose version >/dev/null 2>&1 || die '需要 Docker Compose 插件（docker compose）。'
    docker info >/dev/null 2>&1 || die '无法连接 Docker 服务。'
    local docker_endpoint
    if [[ -n "${DOCKER_CONTEXT:-}" || -z "${DOCKER_HOST:-}" ]]; then
        docker_endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}')
    else
        docker_endpoint=$DOCKER_HOST
    fi
    [[ "$docker_endpoint" == unix://* ]] || die '请连接本机 Docker Engine；此脚本在当前 VPS 创建数据目录，不能用于远程 Docker。'
    { exec 3<>/dev/tty; } 2>/dev/null || die '请在交互式 SSH 终端执行。'
    VERTEX_STAGE=$(mktemp -d)
    local snapshot="$VERTEX_STAGE/existing.json" old_meta="$VERTEX_STAGE/existing-meta.json"
    local candidate="$VERTEX_STAGE/vertex-compose.yml" metadata="$VERTEX_STAGE/metadata.json"
    local old_id='' old_project='' old_service='' reuse=false answer install_path web_port=3000 bind_address=0.0.0.0 timezone=Asia/Shanghai
    printf '\n[1/5] 检测已有 Vertex 容器\n' >&3
    if old_id=$(docker container inspect --format '{{.Id}}' vertex 2>/dev/null); then
        docker inspect "$old_id" > "$snapshot"
    else
        old_id=''; printf '[]\n' > "$snapshot"
    fi
    vertex_config summary "$snapshot" "$old_meta" >&3
    if [[ -n "$old_id" ]]; then
        old_project=$(vertex_config get "$old_meta" project)
        old_service=$(vertex_config get "$old_meta" service)
        printf '沿用时保留数据卷、所有端口映射、时区/环境变量、重启策略及现有网络；镜像和启动命令使用本脚本配置。\n' >&3
        ask answer '是否沿用原容器的目录、端口等配置（y/n）' 'y'
        case "${answer,,}" in
            y|yes)
                reuse=true
                install_path=$(vertex_config get "$old_meta" install_hint)
                if [[ $(vertex_config get "$old_meta" data_type) == volume ]]; then
                    ask install_path 'Compose 管理目录（数据仍保存在原 Docker 卷中）' '/opt/vertex'
                    [[ "$install_path" == /* ]] || die '目录必须以 / 开头，不能使用 ~。'
                fi
                ;;
            n|no) printf '将重新设置目录和端口。若继续使用原数据，请填写原数据目录；选择新目录不会自动复制旧数据。\n' >&3 ;;
            *) die '请输入 y 或 n。' ;;
        esac
    fi
    printf '\n[2/5] 确定部署配置\n' >&3
    if [[ "$reuse" == false ]]; then
        ask install_path 'Vertex 安装及数据目录（绝对路径）' '/opt/vertex'
        [[ "$install_path" == /* ]] || die '目录必须以 / 开头，不能使用 ~。'
        ask web_port '宿主机 Web 端口（容器默认 3000）' '3000'
        ask bind_address '监听地址（0.0.0.0 / 127.0.0.1）' '0.0.0.0'
        ask timezone '时区' 'Asia/Shanghai'
    fi
    vertex_config generate "$snapshot" "$reuse" "$install_path" "$web_port" "$bind_address" "$timezone" "$candidate" "$metadata" >&3
    install_path=$(vertex_config get "$metadata" install_path)
    local project_name compose_file backup_path='' current_id file
    project_name=$(vertex_config get "$metadata" project)
    compose_file="$install_path/vertex-compose.yml"
    vertex_config preflight "$snapshot" "$metadata"
    local restore_url='' restore_password='' restore_enabled=false restore_protocol='' restore_status
    local import_plan="$VERTEX_STAGE/import-plan.json"
    read_secret restore_url '备份下载直链（可选，回车跳过，输入隐藏）'
    if [[ -n "$restore_url" ]]; then
        restore_enabled=true
        vertex_restore target "$metadata" >&3
        printf '%s' "$restore_url" > "$VERTEX_STAGE/backup-url"
        restore_protocol=$(vertex_restore url "$VERTEX_STAGE/backup-url" "$VERTEX_STAGE/curl.conf")
        unset restore_url
        read_secret restore_password 'ZIP 解压密码（无密码或 tar 备份直接回车）'
        printf '%s' "$restore_password" > "$VERTEX_STAGE/zip-password"
        unset restore_password
        printf '将导入备份中的 setting.json 同目录数据；原 data 会先保留，账号密码使用备份内容，容器端口保持本次配置。\n' >&3
    fi
    ask answer '开始部署？回车继续，输入 n 取消' 'y' 
    case "${answer,,}" in y|yes) ;; n|no) printf '已取消，旧容器未修改。\n'; return 0 ;; *) die '请输入 y 或 n。' ;; esac
    local -a preparation=(docker compose --project-name "$project_name" --env-file /dev/null -f "$candidate")
    local -a compose=(docker compose --project-name "$project_name" --env-file /dev/null -f "$compose_file")
    printf '\n[3/5] 校验配置并拉取镜像\n'
    "${preparation[@]}" config --quiet
    if [[ "$restore_enabled" == true ]]; then
        printf '下载并检查 Vertex 备份（直链不会写入部署配置）...\n'
        if ! curl -q -fsSL --proto '=http,https' --proto-redir "$restore_protocol" --connect-timeout 10 --max-time 1200 \
            --max-filesize 1073741824 --config "$VERTEX_STAGE/curl.conf" -o "$VERTEX_STAGE/backup.archive" 2>"$VERTEX_STAGE/download-error"; then
            die '备份下载失败或超过 1 GiB，旧容器和数据未修改。请检查直链有效期和网络后重试。'
        fi
        while true; do
            if vertex_restore extract "$VERTEX_STAGE/backup.archive" "$VERTEX_STAGE/extracted" "$VERTEX_STAGE/zip-password" "$VERTEX_STAGE/extracted.json"; then break; else restore_status=$?; fi
            [[ "$restore_status" == 3 ]] || die '备份检查未通过，旧容器和数据未修改；不会自动改为全新安装。'
            read_secret restore_password '请重新输入 ZIP 密码（留空终止安装）'
            [[ -n "$restore_password" ]] || die '已终止备份导入，旧容器和数据未修改。'
            printf '%s' "$restore_password" > "$VERTEX_STAGE/zip-password"
            unset restore_password
        done
    fi
    "${preparation[@]}" pull
    mkdir -p -- "$install_path"
    exec 9> "$install_path/.vertex-install.lock"
    flock -n 9 || die '此目录已有 Vertex 安装进程运行，请稍后重试。'
    current_id=$(docker container inspect --format '{{.Id}}' vertex 2>/dev/null || true)
    [[ "$current_id" == "$old_id" ]] || die '安装期间 vertex 容器发生变化，请重新运行以读取当前配置。'
    printf '\n[4/5] 备份配置并重建容器\n'
    if [[ "$restore_enabled" == true || -n "$old_id" || -e "$compose_file" || -e "$install_path/docker-compose.yml" ]]; then
        mkdir -p -- "$install_path/.backups"
        chmod 700 -- "$install_path/.backups"
        backup_path=$(mktemp -d "$install_path/.backups/vertex-$(date +%Y%m%d-%H%M%S)-XXXXXX")
        for file in vertex-compose.yml docker-compose.yml docker-compose.yaml compose.yml compose.yaml .env; do
            if [[ -f "$install_path/$file" ]]; then cp -L -- "$install_path/$file" "$backup_path/$file"; chmod 600 -- "$backup_path/$file"; fi
        done
        if [[ -n "$old_id" ]]; then cp -- "$snapshot" "$backup_path/container-inspect.json"; fi
        printf '旧配置备份：%s\n' "$backup_path"
    fi
    if [[ "$restore_enabled" == true ]]; then
        vertex_restore prepare "$metadata" "$VERTEX_STAGE/extracted.json" "$backup_path" "$import_plan"
        local was_running=false
        if [[ -n "$old_id" ]]; then
            was_running=$(docker inspect --format '{{.State.Running}}' "$old_id")
            docker stop "$old_id" >/dev/null
        fi
        if ! vertex_restore apply "$import_plan"; then
            if [[ "$was_running" == true ]] && vertex_restore original-restored "$import_plan"; then
                docker start "$old_id" >/dev/null || true
            fi
            die "备份目录替换失败，请检查原数据及备份：$backup_path"
        fi
    fi
    local pending
    pending=$(mktemp "$install_path/.vertex-compose.XXXXXX")
    cp -- "$candidate" "$pending"
    chmod 600 -- "$pending"
    mv -T -- "$pending" "$compose_file"
    if [[ -n "$old_id" && ( "$old_project" != "$project_name" || "$old_service" != vertex ) ]]; then
        docker stop "$old_id" >/dev/null
        docker rm "$old_id" >/dev/null
    fi
    if ! "${compose[@]}" up -d --force-recreate vertex; then
        printf 'Vertex 重建失败，持久化数据未删除。配置：%s\n备份：%s\n' "$compose_file" "${backup_path:-无旧配置}" >&2
        return 1
    fi
    printf '\n[5/5] 等待 Web 响应\n'
    local attempt probe http_code running public_ip='' urls
    urls=$(vertex_config probe "$metadata")
    for ((attempt=0; attempt<40; attempt++)); do
        running=$(docker inspect --format '{{.State.Running}}' vertex 2>/dev/null || true)
        while IFS= read -r probe; do
            http_code=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 2 "$probe" || true)
            if [[ "$running" == true && ( "$http_code" =~ ^[23][0-9][0-9]$ || "$http_code" == 401 || "$http_code" == 403 ) ]]; then
                if vertex_config public "$metadata"; then
                    if ! public_ip=$(get_public_ipv4); then printf '公网 IPv4 自动识别失败，可在 VPS 控制台查看；安装不受影响。\n'; fi
                fi
                vertex_config result "$metadata" "$public_ip"
                printf '配置文件：%s\n' "$compose_file"
                if [[ -n "$backup_path" ]]; then printf '旧配置备份：%s\n' "$backup_path"; fi
                printf '\n查看日志：docker logs --tail 100 vertex\n重启服务：docker restart vertex\n'
                printf '查看状态：cd %q && docker compose --env-file /dev/null -f vertex-compose.yml ps\n' "$install_path"
                if [[ "$restore_enabled" == true ]]; then
                    printf '已导入备份，请使用备份中的账号密码登录；下载器地址和任务配置请在网页中核对。\n'
                else
                    printf '首次安装可查看初始密码：docker exec vertex cat /vertex/data/password\n'
                fi
                printf '请在浏览器验证登录及任务运行。\n' 
                return 0
            fi
        done <<< "$urls"
        sleep 2
    done
    printf '容器已提交启动，但 Web 未在等待期内响应。请检查：docker logs --tail 100 vertex\n' >&2
    return 1
}

main "$@"
