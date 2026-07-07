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

SCRIPT_VERSION="1.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

INSTALL_DIR="/usr/local/bin"
SNELL_BIN="${INSTALL_DIR}/snell-server"
SNELL_DIR="/etc/snell"
USERS_DIR="${SNELL_DIR}/users"
MAIN_CONF="${USERS_DIR}/snell-main.conf"
SERVICE_FILE="/etc/systemd/system/snell.service"
SERVICE_USER="snell"
SERVICE_GROUP="snell"

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

wait_for_apt() {
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        warn "Waiting for another apt/dpkg process..."
        sleep 2
    done
}

install_packages() {
    local missing=()
    local cmd

    for cmd in curl unzip awk sed grep systemctl; do
        if ! has_command "$cmd"; then
            missing+=("$cmd")
        fi
    done

    [ "${#missing[@]}" -eq 0 ] && return 0

    warn "Missing dependencies: ${missing[*]}"

    if has_command apt-get; then
        wait_for_apt
        apt-get update
        apt-get install -y curl unzip gawk sed grep systemd
    elif has_command dnf; then
        dnf install -y curl unzip gawk sed grep systemd
    elif has_command yum; then
        yum install -y curl unzip gawk sed grep systemd
    elif has_command apk; then
        apk add --no-cache curl unzip gawk sed grep
    else
        die "Unsupported package manager. Please install curl, unzip, awk, sed, and grep manually."
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
    echo
    info "Choose Snell major version:"
    echo "1. Snell v4"
    echo "2. Snell v5"
    echo "3. Snell v6 Beta"

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

    while true; do
        read -rp "Listen port [default ${default_port}]: " port
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

    port="$(prompt_port 443)"
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

print_one_config() {
    local file="$1"
    local label="$2"
    local port
    local psk
    local dns
    local ip

    port="$(extract_value listen "${file}" | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p')"
    psk="$(extract_value psk "${file}")"
    dns="$(extract_value dns "${file}")"
    ip="$(detect_public_ip)"
    ip="${ip:-YOUR_SERVER_IP}"

    echo
    ok "${label}"
    echo "Config file: ${file}"
    echo "Port: ${port}"
    echo "PSK: ${psk}"
    echo "DNS: ${dns}"
    echo "Surge examples:"
    echo "Snell = snell, ${ip}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true"
    echo "Snell = snell, ${ip}, ${port}, psk = ${psk}, version = 5, reuse = true, tfo = true"
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

    require_root

    show_bbr_status
    echo
    warn "This will enable BBR by updating ${conf} and running sysctl -p."
    read -rp "Enable BBR now? [y/N]: " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || return 0

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

add_user() {
    local port
    local dns
    local psk
    local file

    require_root
    ensure_dirs

    port="$(prompt_port 8443)"
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
- BBR is enabled locally through sysctl and modprobe only; no remote BBR script is used.
- Do not publish /etc/snell/users/*.conf because those files contain PSKs.
EOF
}

show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}        Snell Manager v${SCRIPT_VERSION}${RESET}"
    echo -e "${CYAN}        githubh01/snell.sh${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo "1. Install Snell"
    echo "2. Uninstall Snell"
    echo "3. Show config"
    echo "4. Restart service"
    echo "5. Update Snell binary"
    echo "6. Show service status"
    echo "7. User config management"
    echo "8. Enable BBR"
    echo "9. Security notes"
    echo "0. Exit"
    echo -e "${CYAN}============================================${RESET}"
}

main() {
    local choice

    while true; do
        show_menu
        read -rp "Select [0-9]: " choice
        case "${choice}" in
            1) install_snell ;;
            2) uninstall_snell ;;
            3) show_config ;;
            4) restart_snell ;;
            5) update_snell ;;
            6) service_status ;;
            7) user_menu ;;
            8) enable_bbr ;;
            9) security_note ;;
            0) ok "Bye."; exit 0 ;;
            *) err "Invalid option." ;;
        esac
        echo
        read -rp "Press Enter to return to the menu..." _
    done
}

main "$@"
