#!/usr/bin/env bash
#
# Snell management script for githubh01/snell.sh
#
# This script is self-contained by design:
# - no remote shell execution
# - no self-update from another repository
# - no telemetry or phone-home behavior
# - Snell binaries are downloaded only from https://dl.nssurge.com/snell/

set -Eeuo pipefail

SCRIPT_VERSION="1.1.2"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

INSTALL_DIR="/usr/local/bin"
SHORTCUT_PRIMARY="/usr/local/bin/snell-menu"
SHORTCUT_ALIAS="/usr/local/bin/sat"
SNELL_BIN="${INSTALL_DIR}/snell-server"
SNELL_DIR="/etc/snell"
USERS_DIR="${SNELL_DIR}/users"
MAIN_CONF="${USERS_DIR}/snell-main.conf"
SERVICE_FILE="/etc/systemd/system/snell.service"
SERVICE_USER="snell"
SERVICE_GROUP="snell"

ANYTLS_DIR="/etc/AnyTLS"
ANYTLS_BIN="${ANYTLS_DIR}/anytls-server"
ANYTLS_CONFIG="${ANYTLS_DIR}/config.yaml"
ANYTLS_CLIENT_FILE="${ANYTLS_DIR}/anytls.txt"
ANYTLS_SERVICE_NAME="anytls.service"
ANYTLS_SERVICE_FILE="/etc/systemd/system/${ANYTLS_SERVICE_NAME}"
ANYTLS_TZ="Asia/Shanghai"
ANYTLS_ALIAS="AnyTLS"
ANYTLS_DOWNLOADED_VERSION=""
ANYTLS_CERT_DIR="${ANYTLS_DIR}/certs"
ANYTLS_SING_BOX_BIN="${ANYTLS_DIR}/sing-box"
ANYTLS_SING_BOX_CONFIG="${ANYTLS_DIR}/sing-box-anytls.json"
ANYTLS_DOMAIN_FILE="${ANYTLS_DIR}/domain"
SING_BOX_DOWNLOADED_VERSION=""

info() { echo -e "${CYAN}$*${RESET}"; }
ok() { echo -e "${GREEN}$*${RESET}"; }
warn() { echo -e "${YELLOW}$*${RESET}"; }
err() { echo -e "${RED}$*${RESET}" >&2; }
die() { err "$*"; exit 1; }

require_root() {
    [ "$(id -u)" = "0" ] || die "Please run this script as root."
}

has_command() {
    command -v "$1" >/dev/null 2>&1
}

install_menu_shortcut() {
    local script_path

    [ "$(id -u)" = "0" ] || return 0
    script_path="$(readlink -f "$0" 2>/dev/null || true)"
    [ -n "${script_path}" ] || return 0
    [ -f "${script_path}" ] || return 0
    [ "${script_path}" = "${SHORTCUT_PRIMARY}" ] && return 0

    mkdir -p "${INSTALL_DIR}"
    if install -m 0755 "${script_path}" "${SHORTCUT_PRIMARY}" 2>/dev/null; then
        ln -sf "${SHORTCUT_PRIMARY}" "${SHORTCUT_ALIAS}" 2>/dev/null || true
    fi
}

wait_for_apt() {
    local waited=0
    local max_wait="${APT_LOCK_MAX_WAIT:-900}"

    while apt_is_busy; do
        warn "Waiting for another apt/dpkg process..."
        if [ $((waited % 30)) -eq 0 ]; then
            apt_lock_details
        fi
        if [ "${waited}" -ge "${max_wait}" ]; then
            apt_lock_details
            die "Timed out waiting for apt/dpkg lock after ${max_wait}s. Check the process above, or reboot if it is stale."
        fi
        sleep 2
        waited=$((waited + 2))
    done
}

apt_is_busy() {
    if has_command fuser; then
        fuser /var/lib/dpkg/lock >/dev/null 2>&1 && return 0
        fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && return 0
        fuser /var/cache/apt/archives/lock >/dev/null 2>&1 && return 0
    fi

    ps -eo comm= 2>/dev/null | grep -Eq '^(apt|apt-get|dpkg|unattended-upgr)$'
}

apt_lock_details() {
    echo "Current apt/dpkg holders:" >&2

    if has_command fuser; then
        fuser -v /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock 2>/dev/null || true
    fi

    ps -eo pid,ppid,comm,args 2>/dev/null | awk '
        NR == 1 { print; next }
        $3 ~ /^(apt|apt-get|dpkg|unattended-upgr)$/ { print }
    ' >&2 || true
}

run_apt_get() {
    wait_for_apt
    DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

install_packages() {
    local missing=()
    local cmd

    for cmd in curl unzip tar awk sed grep systemctl; do
        if ! has_command "$cmd"; then
            missing+=("$cmd")
        fi
    done

    [ "${#missing[@]}" -eq 0 ] && return 0

    warn "Missing dependencies: ${missing[*]}"

    if has_command apt-get; then
        run_apt_get update
        run_apt_get install -y curl unzip tar gawk sed grep systemd procps
    elif has_command dnf; then
        dnf install -y curl unzip tar gawk sed grep systemd
    elif has_command yum; then
        yum install -y curl unzip tar gawk sed grep systemd
    elif has_command apk; then
        apk add --no-cache curl unzip tar gawk sed grep
    else
        die "Unsupported package manager. Please install curl, unzip, tar, awk, sed, and grep manually."
    fi
}

install_anytls_packages() {
    install_packages

    if has_command apt-get; then
        run_apt_get install -y ca-certificates
    elif has_command dnf; then
        dnf install -y ca-certificates
    elif has_command yum; then
        yum install -y ca-certificates
    elif has_command apk; then
        apk add --no-cache ca-certificates
    fi
}

install_acme_packages() {
    install_anytls_packages

    if has_command certbot; then
        return 0
    fi

    if has_command apt-get; then
        run_apt_get install -y certbot openssl
    elif has_command dnf; then
        dnf install -y certbot openssl
    elif has_command yum; then
        yum install -y epel-release || true
        yum install -y certbot openssl
    elif has_command apk; then
        apk add --no-cache certbot openssl
    else
        die "Unsupported package manager. Please install certbot manually."
    fi
}

ensure_service_user() {
    if ! getent group "${SERVICE_GROUP}" >/dev/null 2>&1; then
        groupadd --system "${SERVICE_GROUP}" 2>/dev/null || groupadd -r "${SERVICE_GROUP}" 2>/dev/null || true
    fi

    if ! getent passwd "${SERVICE_USER}" >/dev/null 2>&1; then
        useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --gid "${SERVICE_GROUP}" "${SERVICE_USER}" 2>/dev/null || \
            useradd -r -M -s /usr/sbin/nologin -g "${SERVICE_GROUP}" "${SERVICE_USER}" 2>/dev/null || true
    fi
}

ensure_dirs() {
    ensure_service_user
    mkdir -p "${INSTALL_DIR}" "${USERS_DIR}"
    chmod 755 "${SNELL_DIR}" "${USERS_DIR}"
    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${SNELL_DIR}" 2>/dev/null || true
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        i386|i686) echo "i386" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7l|armv7) echo "armv7l" ;;
        *) die "Unsupported CPU architecture: $(uname -m)" ;;
    esac
}

choose_snell_major() {
    echo >&2
    info "Choose Snell major version:" >&2
    echo "1. Snell v4" >&2
    echo "2. Snell v5" >&2
    echo "3. Snell v6 Beta" >&2

    while true; do
        read -rp "Select [1-3]: " choice
        case "${choice}" in
            1) echo "v4"; return 0 ;;
            2) echo "v5"; return 0 ;;
            3) echo "v6"; return 0 ;;
            *) err "Please enter 1, 2, or 3." ;;
        esac
    done
}

latest_from_official_docs() {
    local major="$1"
    local fallback="$2"
    local version=""
    local html=""

    html="$(curl -fsSL --connect-timeout 10 https://manual.nssurge.com/others/snell.html 2>/dev/null || true)"
    if [ -z "${html}" ]; then
        html="$(curl -fsSL --connect-timeout 10 https://kb.nssurge.com/surge-knowledge-base/release-notes/snell 2>/dev/null || true)"
    fi

    if [ -n "${html}" ]; then
        version="$(printf '%s\n' "${html}" | grep -Eo "snell-server-v${major}\.[0-9]+\.[0-9]+[a-z0-9]*" | sed 's/snell-server-//' | head -n 1 || true)"
    fi

    if [ -n "${version}" ]; then
        echo "${version}"
    else
        echo "${fallback}"
    fi
}

resolve_snell_version() {
    local selected="$1"

    case "${selected}" in
        v4) latest_from_official_docs 4 "v4.1.1" ;;
        v5) latest_from_official_docs 5 "v5.0.1" ;;
        v6) latest_from_official_docs 6 "v6.0.0b4" ;;
        *) die "Unknown Snell version selection: ${selected}" ;;
    esac
}

download_url() {
    local version="$1"
    local arch="$2"
    local major="${version%%.*}"

    if [ "${major}" = "v6" ] && [ "${arch}" = "armv7l" ]; then
        die "Snell v6 does not support armv7l."
    fi

    echo "https://dl.nssurge.com/snell/snell-server-${version}-linux-${arch}.zip"
}

random_psk() {
    if has_command openssl; then
        openssl rand -base64 24 | tr -d '\n'
    elif [ -r /dev/urandom ]; then
        tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
    else
        date +%s%N | sha256sum | awk '{print $1}'
    fi
}

prompt_port() {
    local default_port="${1:-443}"
    local port
    local prompt

    while true; do
        if [ "${default_port}" = "random" ]; then
            prompt="Listen port [Enter = random available port]: "
        else
            prompt="Listen port [default ${default_port}]: "
        fi
        read -rp "${prompt}" port
        if [ -z "${port}" ] && [ "${default_port}" = "random" ]; then
            port="$(random_available_port)"
        fi
        port="${port:-${default_port}}"
        if [[ "${port}" =~ ^[0-9]+$ ]] && [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ]; then
            echo "${port}"
            return 0
        fi
        err "Port must be a number between 1 and 65535."
    done
}

prompt_dns() {
    local dns
    read -rp "DNS servers [default 1.1.1.1,8.8.8.8]: " dns
    echo "${dns:-1.1.1.1,8.8.8.8}"
}

write_config() {
    local path="$1"
    local port="$2"
    local psk="$3"
    local dns="$4"

    cat > "${path}" <<EOF
[snell-server]
listen = ::0:${port}
psk = ${psk}
ipv6 = true
dns = ${dns}
EOF

    chmod 640 "${path}"
    chown "${SERVICE_USER}:${SERVICE_GROUP}" "${path}" 2>/dev/null || true
}

write_service() {
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Snell Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
LimitNOFILE=32768
ExecStart=${SNELL_BIN} -c ${MAIN_CONF}
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${SNELL_DIR}
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF
}

install_binary() {
    local selected="$1"
    local version
    local arch
    local url
    local tmpdir

    arch="$(detect_arch)"
    version="$(resolve_snell_version "${selected}")"
    url="$(download_url "${version}" "${arch}")"
    tmpdir="$(mktemp -d)"

    info "Downloading Snell ${version} (${arch})..."
    warn "Source: ${url}"

    curl -fL --proto '=https' --tlsv1.2 "${url}" -o "${tmpdir}/snell.zip"
    unzip -o "${tmpdir}/snell.zip" -d "${tmpdir}" >/dev/null

    if [ ! -f "${tmpdir}/snell-server" ]; then
        rm -rf "${tmpdir}"
        die "snell-server was not found in the downloaded archive."
    fi

    install -m 0755 "${tmpdir}/snell-server" "${SNELL_BIN}"
    rm -rf "${tmpdir}"
    ok "Installed: ${SNELL_BIN}"
}

install_snell() {
    local selected
    local port
    local dns
    local psk
    local overwrite

    require_root
    install_packages
    ensure_dirs

    selected="$(choose_snell_major)"
    install_binary "${selected}"

    if [ -f "${MAIN_CONF}" ]; then
        warn "Existing main config detected: ${MAIN_CONF}"
        read -rp "Overwrite main config? [y/N]: " overwrite
        if [[ ! "${overwrite}" =~ ^[Yy]$ ]]; then
            write_service
            systemctl daemon-reload
            systemctl enable --now snell
            ok "Service started with the existing config."
            show_config
            return 0
        fi
    fi

    port="$(prompt_port random)"
    dns="$(prompt_dns)"
    psk="$(random_psk)"
    write_config "${MAIN_CONF}" "${port}" "${psk}" "${dns}"
    write_service

    systemctl daemon-reload
    systemctl enable --now snell

    ok "Snell installation completed."
    show_config
}

uninstall_snell() {
    local confirm
    local remove_conf

    require_root
    warn "This will stop and uninstall Snell. Config files can be kept."
    read -rp "Confirm uninstall? [y/N]: " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || return 0

    systemctl disable --now snell 2>/dev/null || true
    rm -f "${SERVICE_FILE}" "${SNELL_BIN}"
    systemctl daemon-reload 2>/dev/null || true

    read -rp "Remove config directory ${SNELL_DIR}? [y/N]: " remove_conf
    if [[ "${remove_conf}" =~ ^[Yy]$ ]]; then
        rm -rf "${SNELL_DIR}"
    fi

    ok "Uninstall completed."
}

restart_snell() {
    require_root

    [ -f "${SERVICE_FILE}" ] || die "Service file not found. Please install Snell first."

    systemctl daemon-reload
    systemctl restart snell
    systemctl --no-pager --full status snell || true
}

update_snell() {
    local selected

    require_root
    install_packages

    selected="$(choose_snell_major)"
    install_binary "${selected}"
    systemctl restart snell 2>/dev/null || true
    ok "Snell binary update completed."
}

extract_value() {
    local key="$1"
    local file="$2"

    grep -E "^[[:space:]]*${key}[[:space:]]*=" "${file}" | head -n 1 | awk -F= '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}'
}

detect_public_ip() {
    curl -fsSL --connect-timeout 5 https://api.ipify.org 2>/dev/null || true
}

snell_installed_major() {
    local output

    if [ -x "${SNELL_BIN}" ]; then
        output="$("${SNELL_BIN}" --v 2>&1 || true)"
    elif has_command snell-server; then
        output="$(snell-server --v 2>&1 || true)"
    else
        output=""
    fi

    if echo "${output}" | grep -qi 'v6'; then
        echo "v6"
    elif echo "${output}" | grep -qi 'v5'; then
        echo "v5"
    elif echo "${output}" | grep -qi 'v4'; then
        echo "v4"
    else
        echo "unknown"
    fi
}

print_one_config() {
    local file="$1"
    local label="$2"
    local port
    local psk
    local dns
    local ip
    local major

    port="$(extract_value listen "${file}" | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p')"
    psk="$(extract_value psk "${file}")"
    dns="$(extract_value dns "${file}")"
    ip="$(detect_public_ip)"
    ip="${ip:-YOUR_SERVER_IP}"
    major="$(snell_installed_major)"

    echo
    ok "${label}"
    echo "Config file: ${file}"
    echo "Port: ${port}"
    echo "PSK: ${psk}"
    echo "DNS: ${dns}"
    echo "Detected Snell server: ${major}"
    echo "Surge examples:"
    case "${major}" in
        v4)
            echo "Snell = snell, ${ip}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true"
            ;;
        v5)
            echo "Snell = snell, ${ip}, ${port}, psk = ${psk}, version = 5, reuse = true, tfo = true"
            echo "Snell = snell, ${ip}, ${port}, psk = ${psk}, version = 6, reuse = true, tfo = true"
            ;;
        v6)
            echo "Snell = snell, ${ip}, ${port}, psk = ${psk}, version = 6, reuse = true, tfo = true"
            ;;
        *)
            warn "Could not detect Snell server major version. Showing v5 and v6 examples by default."
            echo "Snell = snell, ${ip}, ${port}, psk = ${psk}, version = 5, reuse = true, tfo = true"
            echo "Snell = snell, ${ip}, ${port}, psk = ${psk}, version = 6, reuse = true, tfo = true"
            ;;
    esac
}

show_config() {
    local file

    if [ ! -d "${USERS_DIR}" ]; then
        warn "Config directory not found: ${USERS_DIR}"
        return 0
    fi

    if [ -f "${MAIN_CONF}" ]; then
        print_one_config "${MAIN_CONF}" "Main user config"
    fi

    for file in "${USERS_DIR}"/snell-*.conf; do
        [ -f "${file}" ] || continue
        [ "${file}" = "${MAIN_CONF}" ] && continue
        print_one_config "${file}" "Additional user config"
    done
}

service_status() {
    systemctl --no-pager --full status snell || true
}

start_snell() {
    require_root
    systemctl start snell
    service_status
}

stop_snell() {
    require_root
    systemctl stop snell
    service_status
}

snell_logs() {
    journalctl -u snell --no-pager -n 80 || true
}

snell_main_port() {
    [ -f "${MAIN_CONF}" ] || return 0
    extract_value listen "${MAIN_CONF}" | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p'
}

snell_main_psk() {
    [ -f "${MAIN_CONF}" ] || return 0
    extract_value psk "${MAIN_CONF}"
}

snell_main_dns() {
    [ -f "${MAIN_CONF}" ] || return 0
    extract_value dns "${MAIN_CONF}"
}

change_snell_port() {
    local port
    local psk
    local dns

    require_root
    [ -f "${MAIN_CONF}" ] || die "Main Snell config not found. Please install Snell first."

    port="$(prompt_port "$(snell_main_port)")"
    psk="$(snell_main_psk)"
    dns="$(snell_main_dns)"
    dns="${dns:-1.1.1.1,8.8.8.8}"

    write_config "${MAIN_CONF}" "${port}" "${psk}" "${dns}"
    systemctl restart snell 2>/dev/null || true
    show_config
}

change_snell_psk() {
    local port
    local psk
    local dns

    require_root
    [ -f "${MAIN_CONF}" ] || die "Main Snell config not found. Please install Snell first."

    port="$(snell_main_port)"
    dns="$(snell_main_dns)"
    dns="${dns:-1.1.1.1,8.8.8.8}"
    read -rp "New PSK [press Enter to generate]: " psk
    psk="${psk:-$(random_psk)}"

    write_config "${MAIN_CONF}" "${port}" "${psk}" "${dns}"
    systemctl restart snell 2>/dev/null || true
    show_config
}

snell_menu() {
    local choice

    while true; do
        clear
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN}        Snell Manager${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        echo "1. Install / reinstall Snell"
        echo "2. Update Snell binary"
        echo "3. Show config"
        echo "4. Change main port"
        echo "5. Change main PSK"
        echo "6. Restart service"
        echo "7. Start service"
        echo "8. Stop service"
        echo "9. Show service status"
        echo "10. Show logs"
        echo "11. User config management"
        echo "12. Uninstall Snell"
        echo "0. Back"
        echo -e "${CYAN}============================================${RESET}"
        read -rp "Select [0-12]: " choice
        case "${choice}" in
            1) install_snell ;;
            2) update_snell ;;
            3) show_config ;;
            4) change_snell_port ;;
            5) change_snell_psk ;;
            6) restart_snell ;;
            7) start_snell ;;
            8) stop_snell ;;
            9) service_status ;;
            10) snell_logs ;;
            11) user_menu ;;
            12) uninstall_snell ;;
            0) return 0 ;;
            *) err "Invalid option." ;;
        esac
        echo
        read -rp "Press Enter to return to the Snell menu..." _
    done
}

show_bbr_status() {
    local cc
    local qdisc
    local module_state="not loaded"

    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"

    if lsmod 2>/dev/null | awk '{print $1}' | grep -qx 'tcp_bbr'; then
        module_state="loaded"
    elif modinfo tcp_bbr >/dev/null 2>&1; then
        module_state="available"
    fi

    echo
    info "BBR status"
    echo "tcp_bbr module: ${module_state}"
    echo "tcp_congestion_control: ${cc:-unknown}"
    echo "default_qdisc: ${qdisc:-unknown}"
}

enable_bbr() {
    local confirm
    local conf="/etc/sysctl.conf"
    local current_cc
    local current_qdisc

    require_root

    show_bbr_status
    echo
    current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    if [ "${current_cc}" = "bbr" ] && [ "${current_qdisc}" = "fq" ]; then
        ok "BBR is already active. No runtime change is needed."
        read -rp "Ensure BBR is persisted in ${conf}? [y/N]: " confirm
        [[ "${confirm}" =~ ^[Yy]$ ]] || return 0
    else
        warn "This will enable BBR by updating ${conf} and running sysctl -p."
        read -rp "Enable BBR now? [y/N]: " confirm
        [[ "${confirm}" =~ ^[Yy]$ ]] || return 0
    fi

    if ! modprobe tcp_bbr 2>/dev/null; then
        warn "Could not load tcp_bbr with modprobe. The kernel may not support BBR, or it may already be built in."
    fi

    cp -a "${conf}" "${conf}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

    sed -i '/^[[:space:]]*net.core.default_qdisc[[:space:]]*=/d' "${conf}"
    sed -i '/^[[:space:]]*net.ipv4.tcp_congestion_control[[:space:]]*=/d' "${conf}"

    {
        echo ""
        echo "# Enable BBR congestion control"
        echo "net.core.default_qdisc = fq"
        echo "net.ipv4.tcp_congestion_control = bbr"
    } >> "${conf}"

    sysctl -p "${conf}" >/dev/null || warn "sysctl -p failed. Please check kernel support and ${conf}."

    show_bbr_status

    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" = "bbr" ]; then
        ok "BBR is enabled."
    else
        warn "BBR is not active yet. A reboot or newer kernel may be required."
    fi
}

anytls_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) die "AnyTLS supports only amd64 and arm64 on this script. Current architecture: $(uname -m)" ;;
    esac
}

sing_box_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv7) echo "armv7" ;;
        *) die "sing-box architecture is unsupported by this script: $(uname -m)" ;;
    esac
}

sing_box_latest_version() {
    local version

    version="$(curl -fsSL --connect-timeout 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)"
    [ -n "${version}" ] || die "Could not get latest sing-box version from GitHub."
    echo "${version}"
}

install_sing_box_binary() {
    local version
    local version_num
    local arch
    local url
    local name
    local tmpdir

    install_anytls_packages
    mkdir -p "${ANYTLS_DIR}"

    version="$(sing_box_latest_version)"
    version_num="${version#v}"
    arch="$(sing_box_arch)"
    name="sing-box-${version_num}-linux-${arch}"
    url="https://github.com/SagerNet/sing-box/releases/download/${version}/${name}.tar.gz"
    tmpdir="$(mktemp -d)"

    info "Downloading sing-box ${version} (${arch})..."
    warn "Source: ${url}"

    curl -fL --proto '=https' --tlsv1.2 "${url}" -o "${tmpdir}/sing-box.tar.gz"
    tar xzf "${tmpdir}/sing-box.tar.gz" -C "${tmpdir}"

    [ -f "${tmpdir}/${name}/sing-box" ] || {
        rm -rf "${tmpdir}"
        die "sing-box binary was not found in the downloaded archive."
    }

    install -m 0755 "${tmpdir}/${name}/sing-box" "${ANYTLS_SING_BOX_BIN}"
    rm -rf "${tmpdir}"
    SING_BOX_DOWNLOADED_VERSION="${version}"
}

anytls_random_port() {
    random_available_port
}

valid_port() {
    local port="${1:-}"
    [[ "${port}" =~ ^[0-9]+$ ]] && [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ]
}

is_port_used() {
    local port="$1"

    if has_command ss; then
        ss -tuln | awk '{print $5}' | grep -Eq "[:.]${port}([[:space:]]|$)"
    elif has_command lsof; then
        lsof -i :"${port}" -sTCP:LISTEN >/dev/null 2>&1
    elif has_command netstat; then
        netstat -tuln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
    else
        return 1
    fi
}

random_available_port() {
    local port

    while true; do
        if has_command shuf; then
            port="$(shuf -i 2000-65000 -n 1)"
        else
            port="$(awk 'BEGIN{srand(); print int(2000 + rand() * 63000)}')"
        fi
        if ! is_port_used "${port}"; then
            echo "${port}"
            return 0
        fi
    done
}

anytls_prompt_port() {
    local input

    while true; do
        echo "Press Enter for a random available port, or enter a custom port [1-65535]." >&2
        read -rp "AnyTLS port: " input
        if [ -z "${input:-}" ]; then
            input="$(anytls_random_port)"
        fi
        if ! valid_port "${input}"; then
            err "Invalid port: ${input}"
            continue
        fi
        if is_port_used "${input}"; then
            err "Port ${input} is already in use."
            continue
        fi
        echo "${input}"
        return 0
    done
}

anytls_password() {
    if has_command uuidgen; then
        uuidgen
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        random_psk
    fi
}

urlencode() {
    local s="$1"
    local i
    local c

    for (( i=0; i<${#s}; i++ )); do
        c="${s:$i:1}"
        case "${c}" in
            [a-zA-Z0-9.~_-]) printf '%s' "${c}" ;;
            *) printf '%%%02X' "'${c}" ;;
        esac
    done
}

anytls_public_ip() {
    local ip

    ip="$(curl -fsSL --connect-timeout 5 -4 https://api.ipify.org 2>/dev/null || true)"
    if [ -n "${ip}" ]; then
        echo "${ip}"
        return 0
    fi

    curl -fsSL --connect-timeout 5 https://api.ipify.org 2>/dev/null || true
}

anytls_latest_version() {
    local version

    version="$(curl -fsSL --connect-timeout 10 https://api.github.com/repos/anytls/anytls-go/releases/latest 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)"
    [ -n "${version}" ] || die "Could not get the latest AnyTLS version from GitHub."
    echo "${version}"
}

anytls_installed_version() {
    if [ -f "${ANYTLS_SERVICE_FILE}" ]; then
        grep '^X-AT-Version=' "${ANYTLS_SERVICE_FILE}" | sed -E 's/^X-AT-Version=//' || true
    fi
}

anytls_is_installed() {
    [ -x "${ANYTLS_BIN}" ] || [ -f "${ANYTLS_SERVICE_FILE}" ]
}

anytls_is_active() {
    systemctl is-active "${ANYTLS_SERVICE_NAME}" >/dev/null 2>&1
}

anytls_config_port() {
    [ -f "${ANYTLS_CONFIG}" ] || return 0
    sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${ANYTLS_CONFIG}" | head -n 1
}

anytls_config_password() {
    [ -f "${ANYTLS_CONFIG}" ] || return 0
    sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${ANYTLS_CONFIG}" | head -n 1
}

anytls_config_domain() {
    [ -f "${ANYTLS_CONFIG}" ] || return 0
    sed -nE 's/^[[:space:]]*domain:[[:space:]]*(.*)$/\1/p' "${ANYTLS_CONFIG}" | head -n 1
}

anytls_config_cert_path() {
    [ -f "${ANYTLS_CONFIG}" ] || return 0
    sed -nE 's/^[[:space:]]*certificate_path:[[:space:]]*(.*)$/\1/p' "${ANYTLS_CONFIG}" | head -n 1
}

anytls_config_key_path() {
    [ -f "${ANYTLS_CONFIG}" ] || return 0
    sed -nE 's/^[[:space:]]*key_path:[[:space:]]*(.*)$/\1/p' "${ANYTLS_CONFIG}" | head -n 1
}

anytls_config_mode() {
    [ -f "${ANYTLS_CONFIG}" ] || return 0
    sed -nE 's/^[[:space:]]*mode:[[:space:]]*(.*)$/\1/p' "${ANYTLS_CONFIG}" | head -n 1
}

anytls_write_config() {
    local port="$1"
    local password="$2"
    local domain="${3:-}"
    local cert_path="${4:-}"
    local key_path="${5:-}"
    local mode="${6:-anytls-go}"

    mkdir -p "${ANYTLS_DIR}"
    cat > "${ANYTLS_CONFIG}" <<EOF
mode: ${mode}
listen: :${port}
auth:
  type: password
  password: ${password}
EOF
    if [ -n "${domain}" ]; then
        cat >> "${ANYTLS_CONFIG}" <<EOF
domain: ${domain}
certificate_path: ${cert_path}
key_path: ${key_path}
EOF
        echo "${domain}" > "${ANYTLS_DOMAIN_FILE}"
    fi
    chmod 600 "${ANYTLS_CONFIG}"
}

anytls_write_service() {
    local version="$1"
    local port="$2"
    local password="$3"

    if [ -z "${version}" ]; then
        version="$(anytls_installed_version)"
        version="${version:-unknown}"
    fi

    cat > "${ANYTLS_SERVICE_FILE}" <<EOF
[Unit]
Description=AnyTLS Server Service
Documentation=https://github.com/anytls/anytls-go
After=network-online.target
Wants=network-online.target
X-AT-Version=${version}

[Service]
Type=simple
User=root
Environment=TZ=${ANYTLS_TZ}
ExecStart=${ANYTLS_BIN} -l 0.0.0.0:${port} -p ${password}
Restart=on-failure
RestartSec=10s
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

anytls_write_sing_box_config() {
    local port="$1"
    local password="$2"
    local domain="$3"
    local cert_path="$4"
    local key_path="$5"

    mkdir -p "${ANYTLS_DIR}"
    cat > "${ANYTLS_SING_BOX_CONFIG}" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": ${port},
      "users": [
        {
          "name": "main",
          "password": "${password}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${domain}",
        "certificate_path": "${cert_path}",
        "key_path": "${key_path}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
    chmod 600 "${ANYTLS_SING_BOX_CONFIG}"
}

anytls_write_sing_box_service() {
    local version="$1"

    version="${version:-$(anytls_installed_version)}"
    version="${version#sing-box }"
    version="${version:-unknown}"

    cat > "${ANYTLS_SERVICE_FILE}" <<EOF
[Unit]
Description=AnyTLS Server Service via sing-box
Documentation=https://sing-box.sagernet.org/configuration/inbound/anytls/
After=network-online.target
Wants=network-online.target
X-AT-Version=sing-box ${version}

[Service]
Type=simple
User=root
Environment=TZ=${ANYTLS_TZ}
ExecStart=${ANYTLS_SING_BOX_BIN} run -c ${ANYTLS_SING_BOX_CONFIG}
Restart=on-failure
RestartSec=10s
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

certbot_issue_standalone() {
    local domain="$1"
    local email="$2"
    local staging="${3:-false}"
    local staging_arg=""
    local account_args=()

    install_acme_packages

    if is_port_used 80; then
        die "Port 80 is in use. Stop the service using port 80, then run certificate issuance again."
    fi

    if [ "${staging}" = "true" ]; then
        staging_arg="--test-cert"
    fi

    if [ -n "${email}" ]; then
        account_args=(--email "${email}")
    else
        account_args=(--register-unsafely-without-email)
    fi

    certbot certonly --standalone --non-interactive --agree-tos \
        --preferred-challenges http \
        "${account_args[@]}" \
        -d "${domain}" \
        ${staging_arg}
}

copy_letsencrypt_cert_for_anytls() {
    local domain="$1"
    local src_dir="/etc/letsencrypt/live/${domain}"
    local cert_path="${ANYTLS_CERT_DIR}/${domain}.fullchain.pem"
    local key_path="${ANYTLS_CERT_DIR}/${domain}.privkey.pem"

    [ -f "${src_dir}/fullchain.pem" ] || die "Certificate not found: ${src_dir}/fullchain.pem"
    [ -f "${src_dir}/privkey.pem" ] || die "Private key not found: ${src_dir}/privkey.pem"

    mkdir -p "${ANYTLS_CERT_DIR}"
    cp -L "${src_dir}/fullchain.pem" "${cert_path}"
    cp -L "${src_dir}/privkey.pem" "${key_path}"
    chmod 600 "${cert_path}" "${key_path}"

    echo "${cert_path}|${key_path}"
}

install_cert_renew_hook() {
    local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
    local hook_file="${hook_dir}/anytls-sing-box.sh"

    mkdir -p "${hook_dir}"
    cat > "${hook_file}" <<EOF
#!/usr/bin/env sh
set -eu
DOMAIN="\$(cat "${ANYTLS_DOMAIN_FILE}" 2>/dev/null || true)"
[ -n "\${DOMAIN}" ] || exit 0
[ -f "/etc/letsencrypt/live/\${DOMAIN}/fullchain.pem" ] || exit 0
mkdir -p "${ANYTLS_CERT_DIR}"
cp -L "/etc/letsencrypt/live/\${DOMAIN}/fullchain.pem" "${ANYTLS_CERT_DIR}/\${DOMAIN}.fullchain.pem"
cp -L "/etc/letsencrypt/live/\${DOMAIN}/privkey.pem" "${ANYTLS_CERT_DIR}/\${DOMAIN}.privkey.pem"
chmod 600 "${ANYTLS_CERT_DIR}/\${DOMAIN}.fullchain.pem" "${ANYTLS_CERT_DIR}/\${DOMAIN}.privkey.pem"
systemctl restart "${ANYTLS_SERVICE_NAME}" 2>/dev/null || true
EOF
    chmod +x "${hook_file}"
}

anytls_download_binary() {
    local version
    local arch
    local url
    local tmpdir

    install_anytls_packages
    mkdir -p "${ANYTLS_DIR}"

    arch="$(anytls_arch)"
    version="$(anytls_latest_version)"
    url="https://github.com/anytls/anytls-go/releases/download/${version}/anytls_${version#v}_linux_${arch}.zip"
    tmpdir="$(mktemp -d)"

    info "Downloading AnyTLS ${version} (${arch})..."
    warn "Source: ${url}"

    curl -fL --proto '=https' --tlsv1.2 "${url}" -o "${tmpdir}/anytls.zip"
    unzip -o "${tmpdir}/anytls.zip" -d "${tmpdir}" >/dev/null

    [ -f "${tmpdir}/anytls-server" ] || {
        rm -rf "${tmpdir}"
        die "anytls-server was not found in the downloaded archive."
    }

    install -m 0755 "${tmpdir}/anytls-server" "${ANYTLS_BIN}"
    rm -rf "${tmpdir}"
    ANYTLS_DOWNLOADED_VERSION="${version}"
}

anytls_restart() {
    systemctl daemon-reload
    systemctl enable "${ANYTLS_SERVICE_NAME}" >/dev/null
    systemctl restart "${ANYTLS_SERVICE_NAME}"
    systemctl --no-pager --full status "${ANYTLS_SERVICE_NAME}" | sed -n '1,8p' || true
}

anytls_client_export() {
    local port
    local password
    local ip
    local domain
    local mode
    local query
    local insecure_text
    local alias_enc
    local link
    local link_enc

    [ -f "${ANYTLS_CONFIG}" ] || die "AnyTLS config not found: ${ANYTLS_CONFIG}"

    port="$(anytls_config_port)"
    password="$(anytls_config_password)"
    domain="$(anytls_config_domain)"
    mode="$(anytls_config_mode)"
    ip="$(anytls_public_ip)"
    ip="${ip:-YOUR_SERVER_IP}"
    query="?allowInsecure=1&insecure=1"
    insecure_text="true"
    if [ "${mode}" = "sing-box-tls" ] && [ -n "${domain}" ]; then
        query="?sni=${domain}&allowInsecure=0&insecure=0"
        insecure_text="false"
    fi
    alias_enc="$(urlencode "${ANYTLS_ALIAS}")"
    link="anytls://${password}@${ip}:${port}${query}#${alias_enc}"
    link_enc="$(urlencode "${link}")"

    mkdir -p "${ANYTLS_DIR}"
    cat > "${ANYTLS_CLIENT_FILE}" <<EOF
AnyTLS client parameters
Address: ${ip}
Domain: ${domain:-none}
SNI: ${domain:-none}
Port: ${port}
Password: ${password}
Transport: tls
Allow insecure / skip certificate verification: ${insecure_text}
Mode: ${mode:-anytls-go}
URL: ${link}
QR: https://api.qrserver.com/v1/create-qr-code/?size=400x400&data=${link_enc}
EOF

    echo
    ok "AnyTLS client parameters"
    cat "${ANYTLS_CLIENT_FILE}"
}

anytls_install() {
    local version
    local port
    local password

    require_root

    anytls_download_binary
    version="${ANYTLS_DOWNLOADED_VERSION}"
    port="$(anytls_prompt_port)"
    password="$(anytls_password)"

    anytls_write_service "${version}" "${port}" "${password}"
    anytls_write_config "${port}" "${password}"
    anytls_restart

    if anytls_is_active; then
        ok "AnyTLS is installed and running."
        anytls_client_export
    else
        warn "AnyTLS did not become active. Check: journalctl -u ${ANYTLS_SERVICE_NAME} -e"
    fi
}

anytls_update() {
    local version
    local port
    local password
    local mode
    local domain
    local cert_path
    local key_path

    require_root
    anytls_is_installed || die "AnyTLS is not installed."

    port="$(anytls_config_port)"
    password="$(anytls_config_password)"
    mode="$(anytls_config_mode)"
    domain="$(anytls_config_domain)"
    cert_path="$(anytls_config_cert_path)"
    key_path="$(anytls_config_key_path)"
    port="${port:-$(anytls_random_port)}"
    password="${password:-$(anytls_password)}"

    if [ "${mode}" = "sing-box-tls" ]; then
        [ -n "${domain}" ] || die "AnyTLS TLS domain is missing."
        [ -f "${cert_path}" ] || die "Certificate file is missing: ${cert_path}"
        [ -f "${key_path}" ] || die "Key file is missing: ${key_path}"
        install_sing_box_binary
        version="${SING_BOX_DOWNLOADED_VERSION}"
        anytls_write_sing_box_config "${port}" "${password}" "${domain}" "${cert_path}" "${key_path}"
        anytls_write_sing_box_service "${version}"
        anytls_write_config "${port}" "${password}" "${domain}" "${cert_path}" "${key_path}" "sing-box-tls"
        anytls_restart
        anytls_client_export
        return 0
    fi

    anytls_download_binary
    version="${ANYTLS_DOWNLOADED_VERSION}"

    anytls_write_service "${version}" "${port}" "${password}"
    anytls_write_config "${port}" "${password}"
    anytls_restart
    anytls_client_export
}

anytls_install_with_acme_cert() {
    local domain
    local email
    local staging_choice
    local staging="false"
    local cert_pair
    local cert_path
    local key_path
    local version
    local port
    local password

    require_root

    echo
    warn "This mode uses certbot standalone HTTP-01. Your domain must point to this VPS and port 80 must be reachable."
    read -rp "Domain for AnyTLS certificate: " domain
    [ -n "${domain}" ] || die "Domain is required."
    read -rp "Email for Let's Encrypt notices [Enter = no email]: " email
    read -rp "Use Let's Encrypt staging/test certificate? [y/N]: " staging_choice
    if [[ "${staging_choice}" =~ ^[Yy]$ ]]; then
        staging="true"
    fi

    certbot_issue_standalone "${domain}" "${email}" "${staging}"
    cert_pair="$(copy_letsencrypt_cert_for_anytls "${domain}")"
    cert_path="${cert_pair%%|*}"
    key_path="${cert_pair#*|}"
    install_cert_renew_hook

    install_sing_box_binary
    version="${SING_BOX_DOWNLOADED_VERSION}"
    port="$(anytls_prompt_port)"
    password="$(anytls_password)"

    anytls_write_sing_box_config "${port}" "${password}" "${domain}" "${cert_path}" "${key_path}"
    anytls_write_sing_box_service "${version}"
    anytls_write_config "${port}" "${password}" "${domain}" "${cert_path}" "${key_path}" "sing-box-tls"
    anytls_restart

    if anytls_is_active; then
        ok "Secure AnyTLS via sing-box is installed and running."
        anytls_client_export
    else
        warn "AnyTLS did not become active. Check: journalctl -u ${ANYTLS_SERVICE_NAME} -e"
    fi
}

anytls_apply_existing_cert() {
    local domain
    local port
    local password
    local cert_pair
    local cert_path
    local key_path
    local version

    require_root

    read -rp "Existing Let's Encrypt domain to apply: " domain
    [ -n "${domain}" ] || die "Domain is required."

    cert_pair="$(copy_letsencrypt_cert_for_anytls "${domain}")"
    cert_path="${cert_pair%%|*}"
    key_path="${cert_pair#*|}"
    install_cert_renew_hook

    install_sing_box_binary
    version="${SING_BOX_DOWNLOADED_VERSION}"
    port="$(anytls_config_port)"
    password="$(anytls_config_password)"
    port="${port:-$(anytls_prompt_port)}"
    password="${password:-$(anytls_password)}"

    anytls_write_sing_box_config "${port}" "${password}" "${domain}" "${cert_path}" "${key_path}"
    anytls_write_sing_box_service "${version}"
    anytls_write_config "${port}" "${password}" "${domain}" "${cert_path}" "${key_path}" "sing-box-tls"
    anytls_restart
    anytls_client_export
}

renew_anytls_certificate() {
    require_root
    install_acme_packages
    certbot renew
    if anytls_is_installed; then
        systemctl restart "${ANYTLS_SERVICE_NAME}" 2>/dev/null || true
    fi
    anytls_client_export
}

anytls_uninstall() {
    local confirm

    require_root
    anytls_is_installed || die "AnyTLS is not installed."

    read -rp "Uninstall AnyTLS and delete ${ANYTLS_DIR}? [y/N]: " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || return 0

    systemctl disable --now "${ANYTLS_SERVICE_NAME}" 2>/dev/null || true
    rm -f "${ANYTLS_SERVICE_FILE}"
    rm -rf "${ANYTLS_DIR}"
    systemctl daemon-reload 2>/dev/null || true
    ok "AnyTLS uninstalled."
}

anytls_change_port() {
    local port
    local password
    local mode
    local domain
    local cert_path
    local key_path

    require_root
    anytls_is_installed || die "AnyTLS is not installed."

    port="$(anytls_prompt_port)"
    password="$(anytls_config_password)"
    password="${password:-$(anytls_password)}"
    mode="$(anytls_config_mode)"
    domain="$(anytls_config_domain)"
    cert_path="$(anytls_config_cert_path)"
    key_path="$(anytls_config_key_path)"

    if [ "${mode}" = "sing-box-tls" ]; then
        anytls_write_sing_box_config "${port}" "${password}" "${domain}" "${cert_path}" "${key_path}"
        anytls_write_sing_box_service ""
        anytls_write_config "${port}" "${password}" "${domain}" "${cert_path}" "${key_path}" "sing-box-tls"
    else
        anytls_write_service "" "${port}" "${password}"
        anytls_write_config "${port}" "${password}"
    fi
    anytls_restart
    anytls_client_export
}

anytls_change_password() {
    local port
    local password
    local mode
    local domain
    local cert_path
    local key_path

    require_root
    anytls_is_installed || die "AnyTLS is not installed."

    port="$(anytls_config_port)"
    port="${port:-$(anytls_random_port)}"
    password="$(anytls_password)"
    mode="$(anytls_config_mode)"
    domain="$(anytls_config_domain)"
    cert_path="$(anytls_config_cert_path)"
    key_path="$(anytls_config_key_path)"

    if [ "${mode}" = "sing-box-tls" ]; then
        anytls_write_sing_box_config "${port}" "${password}" "${domain}" "${cert_path}" "${key_path}"
        anytls_write_sing_box_service ""
        anytls_write_config "${port}" "${password}" "${domain}" "${cert_path}" "${key_path}" "sing-box-tls"
    else
        anytls_write_service "" "${port}" "${password}"
        anytls_write_config "${port}" "${password}"
    fi
    anytls_restart
    anytls_client_export
}

anytls_status() {
    if anytls_is_installed; then
        echo
        ok "AnyTLS installed"
        echo "Version: $(anytls_installed_version)"
        echo "Mode: $(anytls_config_mode)"
        echo "Domain: $(anytls_config_domain)"
        echo "Port: $(anytls_config_port)"
        if anytls_is_active; then
            echo "Status: running"
        else
            echo "Status: stopped"
        fi
        systemctl --no-pager --full status "${ANYTLS_SERVICE_NAME}" | sed -n '1,8p' || true
    else
        warn "AnyTLS is not installed."
    fi
}

anytls_start() {
    require_root
    anytls_is_installed || die "AnyTLS is not installed."
    systemctl start "${ANYTLS_SERVICE_NAME}"
    anytls_status
}

anytls_stop() {
    require_root
    anytls_is_installed || die "AnyTLS is not installed."
    systemctl stop "${ANYTLS_SERVICE_NAME}"
    anytls_status
}

anytls_logs() {
    journalctl -u "${ANYTLS_SERVICE_NAME}" --no-pager -n 80 || true
}

anytls_menu() {
    local choice

    while true; do
        clear
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN}        AnyTLS Manager${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        echo "1. Install / reinstall AnyTLS"
        echo "2. Update AnyTLS"
        echo "3. Show client config"
        echo "4. Change port"
        echo "5. Change password"
        echo "6. Show service status"
        echo "7. One-click certificate + secure AnyTLS"
        echo "8. Apply existing Let's Encrypt cert to AnyTLS"
        echo "9. Renew certificate"
        echo "10. Start service"
        echo "11. Stop service"
        echo "12. Show logs"
        echo "13. Uninstall AnyTLS"
        echo "0. Back"
        echo -e "${CYAN}============================================${RESET}"
        read -rp "Select [0-13]: " choice
        case "${choice}" in
            1) anytls_install ;;
            2) anytls_update ;;
            3) anytls_client_export ;;
            4) anytls_change_port ;;
            5) anytls_change_password ;;
            6) anytls_status ;;
            7) anytls_install_with_acme_cert ;;
            8) anytls_apply_existing_cert ;;
            9) renew_anytls_certificate ;;
            10) anytls_start ;;
            11) anytls_stop ;;
            12) anytls_logs ;;
            13) anytls_uninstall ;;
            0) return 0 ;;
            *) err "Invalid option." ;;
        esac
        echo
        read -rp "Press Enter to return to the AnyTLS menu..." _
    done
}

deploy_snell_and_anytls() {
    require_root
    info "Step 1/2: Snell installation"
    install_snell
    echo
    info "Step 2/2: AnyTLS installation"
    anytls_install
}

deploy_bbr_snell_anytls() {
    require_root
    info "Step 1/3: Enable BBR"
    enable_bbr
    echo
    info "Step 2/3: Snell installation"
    install_snell
    echo
    info "Step 3/3: Certificate + Secure AnyTLS installation"
    anytls_install_with_acme_cert
}

restart_proxy_services() {
    require_root

    info "Restarting Snell and AnyTLS services only. BBR will not be restarted or changed."

    if [ -f "${SERVICE_FILE}" ]; then
        systemctl restart snell
        ok "Snell service restarted."
    else
        warn "Snell service file not found; skipped."
    fi

    if [ -f "${ANYTLS_SERVICE_FILE}" ]; then
        systemctl restart "${ANYTLS_SERVICE_NAME}"
        ok "AnyTLS service restarted."
    else
        warn "AnyTLS service file not found; skipped."
    fi

    echo
    show_bbr_status
}

add_user() {
    local port
    local dns
    local psk
    local file

    require_root
    ensure_dirs

    port="$(prompt_port random)"
    file="${USERS_DIR}/snell-${port}.conf"
    [ ! -f "${file}" ] || die "Config already exists for port ${port}: ${file}"

    dns="$(prompt_dns)"
    psk="$(random_psk)"
    write_config "${file}" "${port}" "${psk}" "${dns}"
    ok "Created config: ${file}"
    warn "The default snell.service loads only ${MAIN_CONF}. Create a separate service if you need multiple live ports."
}

remove_user() {
    local port
    local file
    local confirm

    require_root

    read -rp "Additional user port to remove: " port
    [[ "${port}" =~ ^[0-9]+$ ]] || die "Invalid port."
    file="${USERS_DIR}/snell-${port}.conf"

    [ -f "${file}" ] || die "Config not found: ${file}"

    read -rp "Remove ${file}? [y/N]: " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || return 0
    rm -f "${file}"
    ok "Removed: ${file}"
}

user_menu() {
    local choice

    while true; do
        echo
        info "User config management"
        echo "1. Show configs"
        echo "2. Add additional user config"
        echo "3. Remove additional user config"
        echo "0. Back"
        read -rp "Select [0-3]: " choice
        case "${choice}" in
            1) show_config ;;
            2) add_user ;;
            3) remove_user ;;
            0) return 0 ;;
            *) err "Invalid option." ;;
        esac
    done
}

security_note() {
    cat <<'EOF'

Security notes:
- This script does not execute remote scripts from third-party repositories.
- This script does not auto-update itself.
- This script does not upload server information, config, ports, or PSKs.
- Snell binaries are downloaded only from https://dl.nssurge.com/snell/.
- AnyTLS binaries are downloaded only from https://github.com/anytls/anytls-go/releases.
- Secure AnyTLS with real certificates uses system certbot and official sing-box releases.
- BBR is enabled locally through sysctl and modprobe only; no remote BBR script is used.
- Features from third-party scripts were reimplemented locally instead of being pasted as remote-execution code.
- Do not publish /etc/snell/users/*.conf because those files contain PSKs.
- Do not publish /etc/AnyTLS/config.yaml because it contains the AnyTLS password.
EOF
}

show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}        Snell + AnyTLS Manager v${SCRIPT_VERSION}${RESET}"
    echo -e "${CYAN}        githubh01/snell.sh${RESET}"
    echo -e "${CYAN}        Shortcuts: snell-menu / sat${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo "1. Snell management"
    echo "2. AnyTLS management"
    echo "3. Enable BBR only"
    echo "4. Deploy Snell + AnyTLS (do not change BBR)"
    echo "5. Enable BBR, then deploy Snell + certificate AnyTLS"
    echo "6. Restart Snell + AnyTLS services"
    echo "7. Certificate + Secure AnyTLS"
    echo "8. Show Snell config"
    echo "9. Show AnyTLS config"
    echo "10. Show Snell status"
    echo "11. Show AnyTLS status"
    echo "12. Security notes"
    echo "0. Exit"
    echo -e "${CYAN}============================================${RESET}"
}

main() {
    local choice

    install_menu_shortcut

    while true; do
        show_menu
        read -rp "Select [0-12]: " choice
        case "${choice}" in
            1) snell_menu ;;
            2) anytls_menu ;;
            3) enable_bbr ;;
            4) deploy_snell_and_anytls ;;
            5) deploy_bbr_snell_anytls ;;
            6) restart_proxy_services ;;
            7) anytls_install_with_acme_cert ;;
            8) show_config ;;
            9) anytls_client_export ;;
            10) service_status ;;
            11) anytls_status ;;
            12) security_note ;;
            0) ok "Bye."; exit 0 ;;
            *) err "Invalid option." ;;
        esac
        echo
        read -rp "Press Enter to return to the menu..." _
    done
}

main "$@"
