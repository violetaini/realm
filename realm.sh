#!/bin/bash

# ==========================================
# Realm 一键转发脚本 v3.2.8 (violetaini fork)
# 更新日志:
# 1. 修复 Alpine Linux (musl) 下 IP/域名正则校验失败的问题
# 2. 新增 Alpine Linux / OpenRC 支持
# 3. Alpine 自动选择 musl 版 Realm 二进制
# 4. 面板服务控制兼容 systemd 与 OpenRC
# 5. 构建产物改为 GitHub Actions 自动生成
# 6. 修复终端异常断开时 read 读到 EOF 导致 CPU 100% 空转死循环的严重缺陷
# 7. 根据物理内存智能动态适配 Realm 零拷贝管道容量 (-p 16/32/64)，防止小内存 OOM
# 8. 彻底移除 Web 可视化面板功能，消除 HTTP 端口暴露与扫描攻击面，保持纯净 CLI
# ==========================================

# --- 基础配置 ---
sh_ver="3.2.8"

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 路径定义
REALM_DIR="/root/realm"
REALM_BIN="${REALM_DIR}/realm"
CONFIG_DIR="/root/.realm"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
REALM_SYSTEMD_SERVICE_FILE="/etc/systemd/system/realm.service"
REALM_OPENRC_SERVICE_FILE="/etc/init.d/realm"

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

is_alpine() {
    [ -f /etc/alpine-release ]
}

detect_init_system() {
    if [ -n "${REALM_INIT_SYSTEM:-}" ]; then
        echo "$REALM_INIT_SYSTEM"
        return
    fi
    if is_alpine; then
        echo "openrc"
        return
    fi
    if command_exists systemctl; then
        echo "systemd"
        return
    fi
    if command_exists rc-service; then
        echo "openrc"
        return
    fi
    echo "unknown"
}

detect_package_manager() {
    if [ -n "${REALM_PACKAGE_MANAGER:-}" ]; then
        echo "$REALM_PACKAGE_MANAGER"
        return
    fi
    if command_exists apk; then
        echo "apk"
    elif command_exists apt-get; then
        echo "apt"
    elif command_exists yum; then
        echo "yum"
    else
        echo "unknown"
    fi
}

is_musl_system() {
    is_alpine || { command_exists ldd && ldd --version 2>&1 | grep -qi musl; }
}

select_realm_filename() {
    local arch=${1:-$(uname -m)}
    local libc=${REALM_LIBC:-gnu}
    if [ -z "${REALM_LIBC:-}" ] && is_musl_system; then
        libc="musl"
    fi

    case "$arch" in
        x86_64) echo "realm-x86_64-unknown-linux-${libc}.tar.gz" ;;
        aarch64|arm64) echo "realm-aarch64-unknown-linux-${libc}.tar.gz" ;;
        *) return 1 ;;
    esac
}

service_action() {
    local service_name=$1
    local action=$2
    local manager
    manager=$(detect_init_system)

    case "$manager" in
        systemd)
            case "$action" in
                enable) systemctl enable "$service_name" ;;
                disable) systemctl disable "$service_name" ;;
                daemon-reload) systemctl daemon-reload ;;
                is-active) systemctl is-active --quiet "$service_name" ;;
                *) systemctl "$action" "$service_name" ;;
            esac
            ;;
        openrc)
            case "$action" in
                enable) rc-update add "$service_name" default ;;
                disable) rc-update del "$service_name" default >/dev/null 2>&1 || true ;;
                daemon-reload) return 0 ;;
                is-active) rc-service "$service_name" status >/dev/null 2>&1 ;;
                *) rc-service "$service_name" "$action" ;;
            esac
            ;;
        *)
            echo -e "${RED}错误: 不支持的服务管理器，请安装 systemd 或 OpenRC。${PLAIN}"
            return 1
            ;;
    esac
}

service_start() { service_action "$1" start; }
service_stop() { service_action "$1" stop; }
service_restart() { service_action "$1" restart; }
service_enable() { service_action "$1" enable; }
service_disable() { service_action "$1" disable; }
service_daemon_reload() { service_action "" daemon-reload; }
service_is_active() { service_action "$1" is-active >/dev/null 2>&1; }

# --- 状态检测函数 ---

get_status() {
    if service_is_active realm; then
        echo -e "${GREEN}运行中${PLAIN}"
    else
        echo -e "${RED}未运行${PLAIN}"
    fi
}

# --- 核心校验函数 ---

validate_port() {
    local port
    # 使用 [:cntrl:] 字符类清理控制字符，xargs 去除前后空白
    port=$(printf '%s' "$1" | tr -d '[:cntrl:]' | xargs 2>/dev/null)
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        echo -e "${RED}错误: 端口必须是 1-65535 之间的数字。${PLAIN}"
        return 1
    fi
}

validate_ip() {
    local ip
    # 使用 [:cntrl:] 字符类清理控制字符，xargs 去除前后空白
    ip=$(printf '%s' "$1" | tr -d '[:cntrl:]' | xargs 2>/dev/null)
    if [[ -z "$ip" ]]; then
        echo -e "${RED}错误: 地址不能为空。${PLAIN}"
        return 1
    fi
    if [[ "$ip" =~ ^[][a-zA-Z0-9.:-]+$ ]]; then
        return 0
    else
        echo -e "${RED}错误: 无效的 IP 或域名格式。${PLAIN}"
        return 1
    fi
}

check_port_available() {
    local port
    # 使用 [:cntrl:] 字符类清理控制字符，xargs 去除前后空白
    port=$(printf '%s' "$1" | tr -d '[:cntrl:]' | xargs 2>/dev/null)
    if command -v ss >/dev/null; then
        if ss -tulpn | grep ":${port} " | grep -qv "realm"; then
            echo -e "${RED}错误: 本机端口 ${port} 已被其他程序占用。${PLAIN}"
            return 1
        fi
    fi
    return 0
}

check_rule_exists() {
    local port
    # 使用 [:cntrl:] 字符类清理控制字符，xargs 去除前后空白
    port=$(printf '%s' "$1" | tr -d '[:cntrl:]' | xargs 2>/dev/null)
    if [ -f "$CONFIG_FILE" ]; then
        if grep -qE "listen = \"(\\[::]:${port}|0\\.0\\.0\\.0:${port})\"" "$CONFIG_FILE"; then
            echo -e "${RED}错误: 端口 ${port} 的规则已存在。${PLAIN}"
            return 0
        fi
    fi
    return 1
}

# --- 基础功能 ---

init_env() {
    mkdir -p "$REALM_DIR"
    mkdir -p "$CONFIG_DIR"
    [ ! -f "$CONFIG_FILE" ] && write_config_header
    # 彻底禁用并清理历史遗留面板服务与文件，防范 HTTP 端口扫描风险
    if service_is_active realm-panel 2>/dev/null; then
        service_stop realm-panel 2>/dev/null || true
        service_disable realm-panel 2>/dev/null || true
        rm -f /etc/systemd/system/realm-panel.service /etc/init.d/realm-panel 2>/dev/null || true
        service_daemon_reload 2>/dev/null || true
    fi
    rm -rf "${REALM_DIR}/web" 2>/dev/null || true
}

write_config_header() {
    cat <<EOF > "$CONFIG_FILE"
[network]
no_tcp = false
use_udp = true

EOF
}

add_package() {
    local package=$1
    local existing
    for existing in "${packages[@]}"; do
        [ "$existing" = "$package" ] && return
    done
    packages+=("$package")
}

require_command_package() {
    local command_name=$1
    local package_name=$2
    command_exists "$command_name" || add_package "$package_name"
}

check_dependencies() {
    local manager
    local package_manager
    local packages=()
    manager=$(detect_init_system)
    package_manager=$(detect_package_manager)

    case "$package_manager" in
        apt)
            require_command_package wget wget
            require_command_package tar tar
            require_command_package sed sed
            require_command_package grep grep
            require_command_package curl curl
            require_command_package ss iproute2
            if [ "$manager" = "systemd" ]; then
                require_command_package systemctl systemd
            else
                require_command_package rc-service openrc
                require_command_package rc-update openrc
            fi
            ;;
        yum)
            require_command_package wget wget
            require_command_package tar tar
            require_command_package sed sed
            require_command_package grep grep
            require_command_package curl curl
            require_command_package ss iproute
            if [ "$manager" = "systemd" ]; then
                require_command_package systemctl systemd
            else
                require_command_package rc-service openrc
                require_command_package rc-update openrc
            fi
            ;;
        apk)
            require_command_package bash bash
            require_command_package wget wget
            require_command_package tar tar
            require_command_package sed sed
            require_command_package grep grep
            require_command_package curl curl
            require_command_package ss iproute2
            require_command_package update-ca-certificates ca-certificates
            require_command_package rc-service openrc
            require_command_package rc-update openrc
            ;;
        *)
            echo -e "${RED}请手动安装依赖: wget tar sed grep curl ss。${PLAIN}"
            exit 1
            ;;
    esac

    if [ ${#packages[@]} -gt 0 ]; then
        echo -e "${YELLOW}安装依赖: ${packages[*]} ...${PLAIN}"
        case "$package_manager" in
            apt) apt-get update -y >/dev/null 2>&1 && apt-get install -y "${packages[@]}" ;;
            yum) yum install -y "${packages[@]}" ;;
            apk) apk add --no-cache "${packages[@]}" ;;
        esac
    fi
}

set_service_file_permissions() {
    local file_path=$1
    local mode=$2
    chown root:root "$file_path" 2>/dev/null || true
    chmod "$mode" "$file_path"
}

get_total_mem_mb() {
    local mem_kb
    mem_kb=$(grep -i MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
    if [ -n "$mem_kb" ] && [ "$mem_kb" -gt 0 ] 2>/dev/null; then
        echo $((mem_kb / 1024))
    else
        echo 1024
    fi
}

get_recommended_pipe_page() {
    local mem_mb
    mem_mb=$(get_total_mem_mb)
    if [ "$mem_mb" -lt 768 ]; then
        # 小内存机 (<= 512M 或 < 768M): 保持默认 16 页 (64KB)，保守防 OOM
        echo 16
    elif [ "$mem_mb" -lt 3500 ]; then
        # 中等内存 (1G ~ 3G): 使用 32 页 (128KB)，兼顾高吞吐与内存开销
        echo 32
    else
        # 大内存机 (>= 4G): 使用 64 页 (256KB)，极致零拷贝吞吐
        echo 64
    fi
}

write_realm_service() {
    local pipe_page
    pipe_page=$(get_recommended_pipe_page)
    local mem_mb
    mem_mb=$(get_total_mem_mb)
    echo -e "检测到系统内存: ${mem_mb}MB，自动适配管道容量: -p ${pipe_page} ($((pipe_page * 4))KB)"

    local pipe_arg=""
    if [ "$pipe_page" -ne 16 ]; then
        pipe_arg=" -p ${pipe_page}"
    fi

    case "$(detect_init_system)" in
        systemd)
            cat <<EOF > "$REALM_SYSTEMD_SERVICE_FILE"
[Unit]
Description=Realm Forwarding Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
WorkingDirectory=${REALM_DIR}
ExecStart=${REALM_BIN} -c ${CONFIG_FILE}${pipe_arg}

[Install]
WantedBy=multi-user.target
EOF
            set_service_file_permissions "$REALM_SYSTEMD_SERVICE_FILE" 0644
            ;;
        openrc)
            cat <<EOF > "$REALM_OPENRC_SERVICE_FILE"
#!/sbin/openrc-run
name="Realm Forwarding Service"
description="Realm Forwarding Service"
supervisor="supervise-daemon"
command="${REALM_BIN}"
command_args="-c ${CONFIG_FILE}${pipe_arg}"
directory="${REALM_DIR}"
command_user="root"
respawn_delay=5
respawn_max=0

depend() {
    need net
    after firewall
}
EOF
            set_service_file_permissions "$REALM_OPENRC_SERVICE_FILE" 0755
            ;;
        *)
            echo -e "${RED}无法创建服务文件: 不支持的服务管理器。${PLAIN}"
            return 1
            ;;
    esac
}



install_realm() {
    echo -e "${GREEN}> 部署 Realm...${PLAIN}"
    check_dependencies; init_env
    local version
    version=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [ -z "$version" ] && version="v2.6.0"

    local arch
    arch=$(uname -m)
    local filename
    if ! filename=$(select_realm_filename "$arch"); then
        echo -e "${RED}不支持架构: $arch${PLAIN}"
        return 1
    fi

    wget -O "/tmp/realm.tar.gz" "https://github.com/zhboner/realm/releases/download/${version}/${filename}" || { echo -e "${RED}下载失败${PLAIN}"; return 1; }
    tar -xvf /tmp/realm.tar.gz -C "$REALM_DIR" && rm -f /tmp/realm.tar.gz
    chmod +x "$REALM_BIN"

    write_realm_service || return 1
    service_daemon_reload
    service_enable realm
    service_restart realm
    echo -e "${GREEN}安装完成${PLAIN}"
}

uninstall_realm() {
    read -r -p "确定卸载 Realm? [y/N]: " confirm || return
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    service_stop realm
    service_disable realm
    rm -f "$REALM_SYSTEMD_SERVICE_FILE" "$REALM_OPENRC_SERVICE_FILE"
    service_daemon_reload
    rm -rf "$REALM_DIR"
    read -r -p "删除配置? [y/N]: " del_conf || return
    [[ "$del_conf" == "y" || "$del_conf" == "Y" ]] && rm -rf "$CONFIG_DIR"
    echo -e "${GREEN}已卸载${PLAIN}"
}

# --- 转发管理 (已添加重试限制) ---

add_forward() {
    echo -e "${YELLOW}>>> 添加转发 (连续错误2次自动返回)${PLAIN}"
    
    # 1. 本机端口
    local attempt=0
    while true; do
        read -r -e -p "本机端口: " lp || return
        # 依次校验：格式、占用、重复
        if ! validate_port "$lp"; then
            ((attempt++)); [ $attempt -ge 2 ] && { echo -e "${RED}错误过多，返回主菜单${PLAIN}"; return; }
            continue
        fi
        if ! check_port_available "$lp"; then
            ((attempt++)); [ $attempt -ge 2 ] && { echo -e "${RED}错误过多，返回主菜单${PLAIN}"; return; }
            continue
        fi
        if check_rule_exists "$lp"; then
            ((attempt++)); [ $attempt -ge 2 ] && { echo -e "${RED}错误过多，返回主菜单${PLAIN}"; return; }
            continue
        fi
        break
    done

    # 2. 落地IP
    attempt=0
    while true; do
        read -r -e -p "落地IP/域名: " rip || return
        if ! validate_ip "$rip"; then
             ((attempt++)); [ $attempt -ge 2 ] && { echo -e "${RED}错误过多，返回主菜单${PLAIN}"; return; }
             continue
        fi
        break
    done

    # 3. 落地端口
    attempt=0
    while true; do
        read -r -e -p "落地端口: " rp || return
        if ! validate_port "$rp"; then
            ((attempt++)); [ $attempt -ge 2 ] && { echo -e "${RED}错误过多，返回主菜单${PLAIN}"; return; }
            continue
        fi
        break
    done

    cat <<EOF >> "$CONFIG_FILE"

[[endpoints]]
listen = "[::]:$lp"
remote = "$rip:$rp"
EOF
    restart_service
}

add_range_forward() {
    echo -e "${YELLOW}>>> 端口段转发 (连续错误2次自动返回)${PLAIN}"
    local attempt=0
    
    while true; do read -r -e -p "落地IP: " rip || return; validate_ip "$rip" && break; ((attempt++)); [ $attempt -ge 2 ] && return; done
    attempt=0; while true; do read -r -e -p "起始端口: " sp || return; validate_port "$sp" && break; ((attempt++)); [ $attempt -ge 2 ] && return; done
    attempt=0; while true; do read -r -e -p "结束端口: " ep || return; validate_port "$ep" && break; ((attempt++)); [ $attempt -ge 2 ] && return; done
    attempt=0; while true; do read -r -e -p "落地基准端口: " rbp || return; validate_port "$rbp" && break; ((attempt++)); [ $attempt -ge 2 ] && return; done

    [ "$sp" -ge "$ep" ] && { echo -e "${RED}起始必须小于结束${PLAIN}"; return; }

    echo "生成中..."
    local rp=$rbp
    for ((p=sp; p<=ep; p++)); do
        if ! grep -Fq "listen = \"[::]:$p\"" "$CONFIG_FILE"; then
            cat <<EOF >> "$CONFIG_FILE"

[[endpoints]]
listen = "[::]:$p"
remote = "$rip:$rp"
EOF
        fi
        ((rp++))
    done
    restart_service
}

delete_forward() {
    [ ! -f "$CONFIG_FILE" ] && return
    local listens=()
    local remotes=()
    while IFS= read -r line; do
        [ -n "$line" ] && listens+=("$line")
    done < <(grep -E '^\s*listen\s*=' "$CONFIG_FILE" | awk -F'"' '{print $2}')
    while IFS= read -r line; do
        [ -n "$line" ] && remotes+=("$line")
    done < <(grep -E '^\s*remote\s*=' "$CONFIG_FILE" | awk -F'"' '{print $2}')

    [ ${#listens[@]} -eq 0 ] && { echo "无规则"; return; }
    if [ ${#listens[@]} -ne ${#remotes[@]} ]; then
        echo -e "${RED}配置文件格式异常: listen 与 remote 数量不匹配，请手动检查${PLAIN}"
        return 1
    fi

    echo "==============="
    for ((i=0; i<${#listens[@]}; i++)); do
        echo -e "${GREEN}$((i+1)).${PLAIN} ${listens[i]} -> ${remotes[i]}"
    done
    echo "==============="
    read -r -p "删除序号(0取消): " c || return
    [[ "$c" == "0" || -z "$c" ]] && return
    if ! [[ "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 1 ] || [ "$c" -gt "${#listens[@]}" ]; then
        echo -e "${RED}无效序号${PLAIN}"; return
    fi
    
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"; write_config_header
    local del_idx=$((c-1))
    for ((i=0; i<${#listens[@]}; i++)); do
        if [ $i -ne $del_idx ]; then
            cat <<EOF >> "$CONFIG_FILE"

[[endpoints]]
listen = "${listens[i]}"
remote = "${remotes[i]}"
EOF
        fi
    done
    restart_service
}

# --- 服务控制 ---
start_service() {
    service_start realm && echo "已启动" || echo -e "${RED}启动失败${PLAIN}"
}

stop_service() {
    service_stop realm && echo "已停止" || echo -e "${RED}停止失败${PLAIN}"
}

restart_service() {
    service_daemon_reload
    service_restart realm
    sleep 1
    service_is_active realm && echo -e "${GREEN}重启成功${PLAIN}" || echo -e "${RED}重启失败${PLAIN}"
}

# --- 脚本更新 ---
Update_Shell() {
    local url="https://raw.githubusercontent.com/violetaini/realm/main/realm.sh"
    local new_ver
    new_ver=$(wget -qO- "$url" | grep 'sh_ver="' | awk -F "=" '{print $NF}' | tr -d '"' | head -1)
    [[ -z "$new_ver" ]] && { echo -e "${RED}检测失败${PLAIN}"; return; }
    [[ "$new_ver" == "$sh_ver" ]] && { echo "已是最新"; return; }
    read -r -p "更新到 $new_ver? [y/N]: " yn || return
    [[ "$yn" =~ ^[Yy]$ ]] && wget -N "$url" -O realm.sh && chmod +x realm.sh && echo "已更新" && exit 0
}

# --- 主菜单 ---
show_menu() {
    clear
    echo "################################################"
    echo "#        Realm 一键转发脚本 (v${sh_ver})         #"
    echo "################################################"
    echo -e " Realm 状态: $(get_status)"
    echo "------------------------------------------------"
    echo "  1. 安装 / 重置 Realm"
    echo "  2. 卸载 Realm"
    echo "------------------------------------------------"
    echo "  3. 添加转发规则"
    echo "  4. 添加端口段转发"
    echo "  5. 删除转发规则"
    echo "  6. 查看当前配置"
    echo "------------------------------------------------"
    echo "  7. 启动服务"
    echo "  8. 停止服务"
    echo "  9. 重启服务"
    echo "------------------------------------------------"
    echo "  10. 更新脚本"
    echo "  0. 退出脚本"
    echo "################################################"
}

main() {
    check_dependencies; init_env
    while true; do
        show_menu
        read -r -p "选择 [0-10]: " opt || exit 0
        case $opt in
            1) install_realm ;;
            2) uninstall_realm ;;
            3) add_forward ;;
            4) add_range_forward ;;
            5) delete_forward ;;
            6) cat "$CONFIG_FILE" ;;
            7) start_service ;;
            8) stop_service ;;
            9) restart_service ;;
            10) Update_Shell ;;
            0) exit 0 ;;
            *) echo "无效" ;;
        esac
        [ "$opt" != "0" ] && read -r -p "按回车返回..." || exit 0
    done
}

if [ "${REALM_TESTING:-0}" != "1" ]; then
    main
fi
