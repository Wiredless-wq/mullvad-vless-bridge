#!/usr/bin/env bash
set -euo pipefail

# One-command installer for a host-based Mullvad -> VLESS Reality bridge.
# Target: fresh Debian 12 / Ubuntu 24.04 VPS, run as root.

SCRIPT_VERSION="2026-06-14"
STATE_DIR="${STATE_DIR:-/var/lib/mullvad-vless-bridge}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/install.env}"
LOG_FILE="${LOG_FILE:-/var/log/mullvad-vless-install.log}"
LOCK_DIR="${LOCK_DIR:-/run/mullvad-vless-installer.lock}"
BACKUP_ROOT="${BACKUP_ROOT:-/root/mullvad-vless-installer-backups}"
CURRENT_STEP="init"

XUI_RELEASE_API="${XUI_RELEASE_API:-https://api.github.com/repos/MHSanaei/3x-ui/releases/latest}"
XUI_RELEASE_BASE="${XUI_RELEASE_BASE:-https://github.com/MHSanaei/3x-ui/releases/download}"
XUI_VERSION="${XUI_VERSION:-latest}"
XUI_PANEL_PORT="${XUI_PANEL_PORT:-7921}"
SUB_PORT="${SUB_PORT:-2096}"
VLESS_PORT="${VLESS_PORT:-443}"
GLOBAL_VLESS_PORT="${GLOBAL_VLESS_PORT:-8443}"
SSH_PORT="${SSH_PORT:-22}"
MULLVAD_EXIT_COUNTRY="${MULLVAD_EXIT_COUNTRY:-nl}"
REALITY_DEST="${REALITY_DEST:-www.yandex.ru:443}"
REALITY_SNI="${REALITY_SNI:-www.yandex.ru}"
REALITY_SERVER_NAMES="${REALITY_SERVER_NAMES:-www.yandex.ru,ya.ru,yandex.ru}"
REALITY_FINGERPRINT="${REALITY_FINGERPRINT:-firefox}"
GLOBAL_REALITY_DEST="${GLOBAL_REALITY_DEST:-www.microsoft.com:443}"
GLOBAL_REALITY_SNI="${GLOBAL_REALITY_SNI:-www.microsoft.com}"
GLOBAL_REALITY_SERVER_NAMES="${GLOBAL_REALITY_SERVER_NAMES:-www.microsoft.com}"
GLOBAL_REALITY_FINGERPRINT="${GLOBAL_REALITY_FINGERPRINT:-chrome}"
CLIENT_EMAIL="${CLIENT_EMAIL:-ru}"
GLOBAL_CLIENT_EMAIL="${GLOBAL_CLIENT_EMAIL:-global}"
RU_NODE_NAME="${RU_NODE_NAME:-RU - Mullvad - Reality}"
GLOBAL_NODE_NAME="${GLOBAL_NODE_NAME:-Global - Mullvad - Reality}"
PUBLIC_PORTS="${PUBLIC_PORTS:-22,80,443,8443,2096}"
PRIVACY_HARDENING="${PRIVACY_HARDENING:-1}"
PRIVACY_SCRUB_INTERVAL="${PRIVACY_SCRUB_INTERVAL:-60s}"
XUI_SNIFFING_ENABLED="${XUI_SNIFFING_ENABLED:-0}"

if [ -t 1 ]; then
  RED="$(printf '\033[31m')"
  GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"
  BLUE="$(printf '\033[34m')"
  BOLD="$(printf '\033[1m')"
  RESET="$(printf '\033[0m')"
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  BOLD=""
  RESET=""
fi

log_line() {
  mkdir -p "$(dirname "$LOG_FILE")"
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

title() {
  log_line ""
  log_line "${BOLD}${BLUE}==>${RESET} $*"
}

ok() {
  log_line "${GREEN}✓${RESET} $*"
}

warn() {
  log_line "${YELLOW}!${RESET} $*"
}

fail() {
  log_line "${RED}✗${RESET} $*"
}

die() {
  fail "$*"
  exit 1
}

mullvad_cmd() {
  local seconds="$1"
  shift
  timeout "$seconds" mullvad "$@"
}

generate_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  else
    die "Cannot generate UUID: /proc/sys/kernel/random/uuid and uuidgen are unavailable."
  fi
}

on_error() {
  local exit_code=$?
  local line_no=${1:-unknown}
  fail "Install failed at step '${CURRENT_STEP}' on line ${line_no}. Exit code: ${exit_code}"
  fail "Log: ${LOG_FILE}"
  fail "State: ${STATE_FILE}"
  warn "The installer is designed to be re-run after fixing the issue."
  warn "For a full regeneration, run with RESET_INSTALL=1."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl start x-ui.service >/dev/null 2>&1 || true
  fi
  exit "$exit_code"
}

cleanup_lock() {
  rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
}

trap 'on_error $LINENO' ERR
trap cleanup_lock EXIT

run_step() {
  CURRENT_STEP="$1"
  shift
  title "$CURRENT_STEP"
  "$@"
  ok "$CURRENT_STEP"
}

acquire_lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "Another installer run is active: ${LOCK_DIR}"
  fi
}

init_state() {
  mkdir -p "$STATE_DIR" "$BACKUP_ROOT"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true

  if [ "${RESET_INSTALL:-0}" = "1" ]; then
    warn "RESET_INSTALL=1: existing installer state will be ignored."
    rm -f "$STATE_FILE"
  fi

  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    ok "Loaded previous state from ${STATE_FILE}"
  else
    (
      umask 077
      : > "$STATE_FILE"
    )
    ok "Created installer state at ${STATE_FILE}"
  fi
}

state_set() {
  local key="$1"
  local value="$2"
  mkdir -p "$STATE_DIR"
  touch "$STATE_FILE"
  if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
    sed -i "s#^${key}=.*#${key}=$(printf '%q' "$value")#" "$STATE_FILE"
  else
    printf '%s=%q\n' "$key" "$value" >> "$STATE_FILE"
  fi
  export "$key=$value"
}

backup_file() {
  local path="$1"
  [ -e "$path" ] || return 0
  local backup_dir="${BACKUP_ROOT}/$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$backup_dir"
  cp -a "$path" "$backup_dir/"
  ok "Backup: ${path} -> ${backup_dir}/"
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Run as root."
  fi
}

require_debian_like() {
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *)
      die "Unsupported OS: ${ID:-unknown}. Use Debian 12 or Ubuntu 24.04."
      ;;
  esac
}

detect_public_ipv4() {
  local ip=""
  for url in \
    https://api4.ipify.org \
    https://ipv4.icanhazip.com \
    https://v4.ident.me
  do
    ip="$(curl -4fsS --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if printf '%s' "$ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  die "Could not detect public IPv4."
}

detect_wan_ipv4() {
  local dev="$1"
  ip -4 addr show dev "$dev" scope global | awk '/inet / {split($2, a, "/"); print a[1]; exit}'
}

detect_wan_dev() {
  ip -4 route show default | awk '{print $5; exit}'
}

detect_wan_gw() {
  ip -4 route show default | awk '{print $3; exit}'
}

detect_wan_cidr() {
  local dev="$1"
  ip -4 route show dev "$dev" scope link | awk '$1 != "default" {print $1; exit}'
}

prompt_mullvad_account() {
  local account="${MULLVAD_ACCOUNT:-}"
  if [ -z "$account" ]; then
    read -r -p "Mullvad account number: " account
  fi
  if [ -z "$account" ]; then
    die "Mullvad account is required."
  fi
  printf '%s\n' "$account"
}

repair_mullvad_apt_files() {
  if [ -e /usr/share/keyrings/mullvad-keyring.asc ]; then
    chmod 644 /usr/share/keyrings/mullvad-keyring.asc
  fi
  if [ -e /etc/apt/sources.list.d/mullvad.list ]; then
    chmod 644 /etc/apt/sources.list.d/mullvad.list
  fi
}

install_base_packages() {
  export DEBIAN_FRONTEND=noninteractive
  repair_mullvad_apt_files
  ok "Installing base packages"
  apt-get update
  apt-get install -y \
    curl wget ca-certificates gnupg dnsutils ufw nftables jq sqlite3 \
    certbot openssl uuid-runtime python3 fail2ban unattended-upgrades
}

install_mullvad() {
  if ! command -v mullvad >/dev/null 2>&1; then
    ok "Installing Mullvad repository and package"
    curl -fsSLo /usr/share/keyrings/mullvad-keyring.asc \
      https://repository.mullvad.net/deb/mullvad-keyring.asc
    echo "deb [signed-by=/usr/share/keyrings/mullvad-keyring.asc arch=$(dpkg --print-architecture)] https://repository.mullvad.net/deb/stable stable main" \
      > /etc/apt/sources.list.d/mullvad.list
    chmod 644 /usr/share/keyrings/mullvad-keyring.asc /etc/apt/sources.list.d/mullvad.list
    apt-get update
    apt-get install -y mullvad-vpn
  else
    ok "Mullvad is already installed"
  fi

  # The desktop package enables early boot blocking. On a remote VPS it can
  # cut SSH before the public-service bypass and routing policy are in place.
  systemctl disable --now mullvad-early-boot-blocking.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/mullvad-daemon.service.wants/mullvad-early-boot-blocking.service
  systemctl daemon-reload
}

configure_firewall() {
  ok "Configuring UFW ports: ${SSH_PORT}, 80, ${VLESS_PORT}, ${GLOBAL_VLESS_PORT}, ${SUB_PORT}"
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${SSH_PORT}/tcp" comment 'SSH'
  ufw allow 80/tcp comment 'ACME HTTP-01'
  ufw allow "${VLESS_PORT}/tcp" comment 'VLESS Reality'
  ufw allow "${GLOBAL_VLESS_PORT}/tcp" comment 'VLESS Reality global fallback'
  ufw allow "${SUB_PORT}/tcp" comment '3x-ui subscription'
  ufw --force enable
}

write_bypass_files() {
  backup_file /usr/local/sbin/mullvad-vps-bypass.sh
  backup_file /usr/local/sbin/mullvad-connect-wait.sh
  backup_file /etc/systemd/system/mullvad-vps-bypass.service
  backup_file /etc/systemd/system/mullvad-connect.service

  cat > /usr/local/sbin/mullvad-vps-bypass.sh <<'SCRIPT'
#!/bin/sh
set -eu

WAN_DEV="${WAN_DEV:-eth0}"
VPS_IP="${VPS_IP:?set VPS_IP}"
WAN_GW="${WAN_GW:?set WAN_GW}"
WAN_CIDR="${WAN_CIDR:?set WAN_CIDR}"
WAN_TABLE="${WAN_TABLE:-100}"
PUBLIC_PORTS="${PUBLIC_PORTS:-22,80,443,8443,2096}"

nft delete table inet vps_bypass 2>/dev/null || true
nft add table inet vps_bypass

nft 'add chain inet vps_bypass prerouting { type filter hook prerouting priority -150; policy accept; }'
nft 'add chain inet vps_bypass output { type route hook output priority -150; policy accept; }'

nft "add rule inet vps_bypass prerouting iifname ${WAN_DEV} tcp dport { ${PUBLIC_PORTS} } counter ct mark set 0x00000f41 meta mark set 0x6d6f6c65"
nft 'add rule inet vps_bypass output ct mark 0x00000f41 counter meta mark set 0x6d6f6c65'

ip route replace default via "${WAN_GW}" dev "${WAN_DEV}" src "${VPS_IP}" table "${WAN_TABLE}"
ip route replace "${WAN_CIDR}" dev "${WAN_DEV}" src "${VPS_IP}" table "${WAN_TABLE}"

if ! ip rule show | grep -q "from ${VPS_IP} lookup ${WAN_TABLE}"; then
  ip rule add pref 100 from "${VPS_IP}/32" table "${WAN_TABLE}"
fi
SCRIPT
  chmod 755 /usr/local/sbin/mullvad-vps-bypass.sh

  cat > /usr/local/sbin/mullvad-connect-wait.sh <<'SCRIPT'
#!/bin/sh
set -eu

mullvad connect || true

i=0
while [ "$i" -lt 60 ]; do
  if mullvad status | grep -qi '^Connected'; then
    mullvad status -v
    exit 0
  fi
  i=$((i + 1))
  sleep 2
done

mullvad status -v || true
echo "Mullvad did not connect in time." >&2
exit 1
SCRIPT
  chmod 755 /usr/local/sbin/mullvad-connect-wait.sh

  cat > /etc/systemd/system/mullvad-vps-bypass.service <<EOF
[Unit]
Description=Bypass public VPS services around Mullvad lockdown
Before=mullvad-daemon.service mullvad-connect.service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment="WAN_DEV=${WAN_DEV}"
Environment="VPS_IP=${VPS_IP}"
Environment="WAN_GW=${WAN_GW}"
Environment="WAN_CIDR=${WAN_CIDR}"
Environment="PUBLIC_PORTS=${PUBLIC_PORTS}"
ExecStart=/usr/local/sbin/mullvad-vps-bypass.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/mullvad-connect.service <<'EOF'
[Unit]
Description=Connect Mullvad after VPS bypass is installed
After=mullvad-daemon.service mullvad-vps-bypass.service network-online.target
Requires=mullvad-daemon.service mullvad-vps-bypass.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mullvad-connect-wait.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now mullvad-vps-bypass.service
}

configure_mullvad() {
  local account="$1"
  local account_info=""
  systemctl enable mullvad-daemon.service >/dev/null 2>&1 || true
  timeout 30 systemctl start mullvad-daemon.service
  systemctl restart mullvad-vps-bypass.service
  mullvad_cmd 20 lockdown-mode set off >/dev/null 2>&1 || true
  mullvad_cmd 20 disconnect >/dev/null 2>&1 || true
  mullvad_cmd 20 auto-connect set off >/dev/null 2>&1 || true

  account_info="$(mullvad_cmd 20 account get 2>/dev/null || true)"
  if printf '%s\n' "$account_info" | grep -q '^Mullvad account:'; then
    ok "Mullvad account is already logged in"
  else
    mullvad_cmd 60 account login "$account"
  fi
  account_info="$(mullvad_cmd 20 account get 2>/dev/null || true)"
  printf '%s\n' "$account_info" | grep -q '^Mullvad account:' || die "Mullvad account login failed."

  mullvad_cmd 20 auto-connect set off
  mullvad_cmd 20 lan set block
  mullvad_cmd 20 tunnel set quantum-resistant on
  mullvad_cmd 20 relay set location "$MULLVAD_EXIT_COUNTRY"
  mullvad_cmd 20 relay set multihop on
  mullvad_cmd 20 relay set entry location de
  mullvad_cmd 20 tunnel set daita on
  mullvad_cmd 20 lockdown-mode set off
}

configure_mullvad_dns_policy() {
  backup_file /etc/resolvconf.conf
  backup_file /etc/resolv.conf
  backup_file /usr/local/sbin/mullvad-dns-guard.sh
  backup_file /etc/systemd/system/mullvad-dns-guard.service

  if command -v resolvconf >/dev/null 2>&1; then
    cat > /etc/resolvconf.conf <<'EOF'
# Mullvad VLESS bridge DNS policy.
# Keep DNS on Mullvad only. Cloudflare/provider DNS must not appear in
# /etc/resolv.conf because Xray may resolve client-requested domains here.
resolv_conf=/etc/resolv.conf
name_servers=10.64.0.1
name_server_blacklist="1.1.1.1 1.0.0.1 2606:4700:4700::1111 2606:4700:4700::1001"
interface_order="wg0-mullvad* wg* tun* vpn* lo*"
dnsmasq_resolv=/var/run/dnsmasq/resolv.conf
pdnsd_conf=/etc/pdnsd.conf
    unbound_conf=/etc/unbound/unbound.conf.d/resolvconf_resolvers.conf
EOF
    resolvconf -u
  else
    warn "resolvconf is not installed; writing /etc/resolv.conf directly."
  fi

  if ! grep -q '^nameserver 10[.]64[.]0[.]1$' /etc/resolv.conf; then
    warn "Writing /etc/resolv.conf directly for Mullvad DNS."
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<'EOF'
nameserver 10.64.0.1
EOF
  fi

  if ! grep -q '^nameserver 10[.]64[.]0[.]1$' /etc/resolv.conf; then
    die "Mullvad DNS 10.64.0.1 is missing from /etc/resolv.conf"
  fi
  if grep -Eq 'nameserver[[:space:]]+(1[.]1[.]1[.]1|1[.]0[.]0[.]1|2606:4700:4700::1111|2606:4700:4700::1001)' /etc/resolv.conf; then
    die "Cloudflare DNS is still present in /etc/resolv.conf"
  fi

  cat > /usr/local/sbin/mullvad-dns-guard.sh <<'SCRIPT'
#!/bin/sh
set -eu

nft delete table ip mullvad_dns_guard 2>/dev/null || true
nft add table ip mullvad_dns_guard
nft 'add chain ip mullvad_dns_guard output { type nat hook output priority -101; policy accept; }'
nft 'add rule ip mullvad_dns_guard output udp dport 53 counter dnat to 10.64.0.1'
nft 'add rule ip mullvad_dns_guard output tcp dport 53 counter dnat to 10.64.0.1'
SCRIPT
  chmod 755 /usr/local/sbin/mullvad-dns-guard.sh

  cat > /etc/systemd/system/mullvad-dns-guard.service <<'EOF'
[Unit]
Description=Force local and proxied plain DNS to Mullvad DNS
After=mullvad-daemon.service mullvad-vps-bypass.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mullvad-dns-guard.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now mullvad-dns-guard.service
}

install_xui() {
  rm -f /etc/systemd/system/x-ui.service.d/after-mullvad.conf
  rmdir /etc/systemd/system/x-ui.service.d 2>/dev/null || true
  systemctl daemon-reload

  if ! command -v x-ui >/dev/null 2>&1 || [ ! -x /usr/local/x-ui/x-ui ] || [ ! -f /etc/systemd/system/x-ui.service ]; then
    ok "Installing 3x-ui"
    systemctl disable --now x-ui.service >/dev/null 2>&1 || true
    rm -f /usr/bin/x-ui /etc/systemd/system/x-ui.service
    rm -rf /usr/local/x-ui /etc/x-ui
    systemctl daemon-reload

    local deb_arch xui_arch version archive_url tmp_dir
    deb_arch="$(dpkg --print-architecture)"
    case "$deb_arch" in
      amd64) xui_arch="amd64" ;;
      i386) xui_arch="386" ;;
      arm64) xui_arch="arm64" ;;
      armhf) xui_arch="armv7" ;;
      armel) xui_arch="armv5" ;;
      s390x) xui_arch="s390x" ;;
      *) die "Unsupported architecture for 3x-ui: ${deb_arch}" ;;
    esac

    if [ "$XUI_VERSION" = "latest" ]; then
      version="$(curl -fsSL "$XUI_RELEASE_API" | jq -r '.tag_name')"
    else
      version="$XUI_VERSION"
    fi
    [ -n "$version" ] && [ "$version" != "null" ] || die "Could not detect latest 3x-ui version."

    archive_url="${XUI_RELEASE_BASE}/${version}/x-ui-linux-${xui_arch}.tar.gz"
    tmp_dir="$(mktemp -d)"
    curl -fL --retry 3 --retry-delay 2 -o "${tmp_dir}/x-ui.tar.gz" "$archive_url"
    tar -xzf "${tmp_dir}/x-ui.tar.gz" -C "$tmp_dir"
    mv "${tmp_dir}/x-ui" /usr/local/x-ui
    cp /usr/local/x-ui/x-ui.service.debian /etc/systemd/system/x-ui.service
    ln -sf /usr/local/x-ui/x-ui.sh /usr/bin/x-ui
    chmod +x /usr/local/x-ui/x-ui /usr/local/x-ui/x-ui.sh /usr/bin/x-ui
    chmod +x /usr/local/x-ui/bin/xray-linux-* /usr/local/x-ui/bin/mtg-* 2>/dev/null || true
    rm -rf "$tmp_dir"
    systemctl daemon-reload
  else
    ok "3x-ui is already installed"
  fi
  systemctl enable --now x-ui.service
  local i=0
  while [ "$i" -lt 30 ] && [ ! -f /etc/x-ui/x-ui.db ]; do
    i=$((i + 1))
    sleep 1
  done
  [ -f /etc/x-ui/x-ui.db ] || die "3x-ui DB was not created at /etc/x-ui/x-ui.db"
  x-ui setting -listenIP 127.0.0.1 -port "$XUI_PANEL_PORT" >/dev/null 2>&1 || true
}

issue_subscription_cert() {
  local domain="$1"
  local cert_dir="/etc/letsencrypt/live/${domain}"

  if [ ! -s "${cert_dir}/fullchain.pem" ] || [ ! -s "${cert_dir}/privkey.pem" ]; then
    systemctl stop x-ui.service 2>/dev/null || true
    if ! certbot certonly --standalone \
      --non-interactive \
      --agree-tos \
      --register-unsafely-without-email \
      -d "$domain"; then
      systemctl start x-ui.service 2>/dev/null || true
      die "Failed to issue Let's Encrypt certificate for ${domain}."
    fi
    systemctl start x-ui.service
  fi
}

generate_reality_keys() {
  /usr/local/x-ui/bin/xray-linux-amd64 x25519 \
    | awk '
      /PrivateKey:/ {priv=$2}
      /Private key:/ {priv=$3}
      /Password \(PublicKey\):/ {pub=$3}
      /Public key:/ {pub=$3}
      END {
        if (priv == "" || pub == "") exit 1
        print priv "\n" pub
      }'
}

configure_xui_db() {
  local domain="$1"
  local private_key="$2"
  local public_key="$3"
  local client_uuid="$4"
  local short_id="$5"
  local sub_id="$6"
  local xui_panel_port="$7"
  local sub_port="$8"
  local vless_port="$9"
  local global_vless_port="${10}"
  local reality_dest="${11}"
  local reality_sni="${12}"
  local reality_server_names="${13}"
  local reality_fingerprint="${14}"
  local global_reality_dest="${15}"
  local global_reality_sni="${16}"
  local global_reality_server_names="${17}"
  local global_reality_fingerprint="${18}"
  local client_email="${19}"
  local global_client_email="${20}"
  local ru_node_name="${21}"
  local global_node_name="${22}"
  local now="${23}"

  backup_file /etc/x-ui/x-ui.db
  export XUI_SNIFFING_ENABLED

  python3 - "$domain" "$private_key" "$public_key" "$client_uuid" "$short_id" "$sub_id" "$xui_panel_port" "$sub_port" "$vless_port" "$global_vless_port" "$reality_dest" "$reality_sni" "$reality_server_names" "$reality_fingerprint" "$GLOBAL_REALITY_PRIVATE_KEY" "$GLOBAL_REALITY_PUBLIC_KEY" "$GLOBAL_CLIENT_UUID" "$GLOBAL_SHORT_ID" "$global_reality_dest" "$global_reality_sni" "$global_reality_server_names" "$global_reality_fingerprint" "$client_email" "$global_client_email" "$ru_node_name" "$global_node_name" "$now" <<'PY'
import json
import os
import sqlite3
import sys

(
    domain,
    private_key,
    public_key,
    client_uuid,
    short_id,
    sub_id,
    xui_panel_port,
    sub_port,
    vless_port,
    global_vless_port,
    reality_dest,
    reality_sni,
    reality_server_names,
    reality_fingerprint,
    global_private_key,
    global_public_key,
    global_client_uuid,
    global_short_id,
    global_reality_dest,
    global_reality_sni,
    global_reality_server_names,
    global_reality_fingerprint,
    client_email,
    global_client_email,
    ru_node_name,
    global_node_name,
    now,
) = sys.argv[1:]
now = int(now)
db = "/etc/x-ui/x-ui.db"
con = sqlite3.connect(db)
xui_sniffing_enabled = os.environ.get("XUI_SNIFFING_ENABLED", "0") == "1"

def setting(key, value):
    row = con.execute("select id from settings where key=?", (key,)).fetchone()
    if row:
        con.execute("update settings set value=? where key=?", (value, key))
    else:
        con.execute("insert into settings (key,value) values (?,?)", (key, value))

setting("webListen", "127.0.0.1")
setting("webPort", xui_panel_port)
setting("subEnable", "true")
setting("subListen", "0.0.0.0")
setting("subPort", sub_port)
setting("subPath", "/sub/")
setting("subDomain", domain)
setting("subCertFile", f"/etc/letsencrypt/live/{domain}/fullchain.pem")
sniffing = {
    "enabled": xui_sniffing_enabled,
    "destOverride": ["http", "tls", "quic"] if xui_sniffing_enabled else [],
    "metadataOnly": False,
    "routeOnly": False,
}

setting("subKeyFile", f"/etc/letsencrypt/live/{domain}/privkey.pem")

def server_names(value, fallback):
    items = [item.strip() for item in value.split(",") if item.strip()]
    return items or [fallback]

def add_node(port, remark, tag, email, uuid_value, private, public, short, dest, sni, names, fingerprint):
    client = {
        "id": uuid_value,
        "flow": "xtls-rprx-vision",
        "email": email,
        "limitIp": 0,
        "totalGB": 0,
        "expiryTime": 0,
        "enable": True,
        "tgId": "",
        "subId": sub_id,
    }
    settings = {"clients": [client], "decryption": "none", "fallbacks": []}
    stream = {
        "network": "tcp",
        "security": "reality",
        "externalProxy": [],
        "realitySettings": {
            "show": False,
            "xver": 0,
            "dest": dest,
            "serverNames": server_names(names, sni),
            "privateKey": private,
            "shortIds": [short],
            "settings": {
                "publicKey": public,
                "fingerprint": fingerprint,
                "serverName": "",
                "spiderX": "/",
            },
        },
        "tcpSettings": {
            "acceptProxyProtocol": False,
            "header": {"type": "none"},
        },
    }
    con.execute("delete from inbounds where port=?", (int(port),))
    con.execute(
        """insert into inbounds
        (user_id,up,down,total,remark,enable,expiry_time,traffic_reset,last_traffic_reset_time,listen,port,protocol,settings,stream_settings,tag,sniffing)
        values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (
            1, 0, 0, 0, remark, 1, 0, "never", 0, "", int(port), "vless",
            json.dumps(settings, separators=(",", ":")),
            json.dumps(stream, separators=(",", ":")),
            tag,
            json.dumps(sniffing, separators=(",", ":")),
        ),
    )
    inbound_id = con.execute("select id from inbounds where port=?", (int(port),)).fetchone()[0]
    con.execute("delete from clients where email=?", (email,))
    con.execute(
        """insert into clients
        (email,sub_id,uuid,flow,limit_ip,total_gb,expiry_time,enable,group_name,reset,created_at,updated_at)
        values (?,?,?,?,?,?,?,?,?,?,?,?)""",
        (email, sub_id, uuid_value, "xtls-rprx-vision", 0, 0, 0, 1, "", 0, now, now),
    )
    client_id = con.execute("select id from clients where email=?", (email,)).fetchone()[0]
    con.execute("delete from client_traffics where email=?", (email,))
    con.execute(
        """insert into client_traffics
        (inbound_id,enable,email,up,down,expiry_time,total,reset,last_online)
        values (?,?,?,?,?,?,?,?,?)""",
        (inbound_id, 1, email, 0, 0, 0, 0, 0, 0),
    )
    con.execute(
        "insert or replace into client_inbounds (client_id,inbound_id,flow_override,created_at) values (?,?,?,?)",
        (client_id, inbound_id, "xtls-rprx-vision", now),
    )

add_node(
    vless_port, ru_node_name, "inbound-443", client_email,
    client_uuid, private_key, public_key, short_id,
    reality_dest, reality_sni, reality_server_names, reality_fingerprint,
)
add_node(
    global_vless_port, global_node_name, "inbound-8443", global_client_email,
    global_client_uuid, global_private_key, global_public_key, global_short_id,
    global_reality_dest, global_reality_sni, global_reality_server_names, global_reality_fingerprint,
)

for sql in [
    "update inbounds set up=0, down=0, last_traffic_reset_time=0",
    "update client_traffics set up=0, down=0, last_online=0",
    "update client_global_traffics set up=0, down=0, updated_at=0",
    "update node_client_traffics set up=0, down=0",
    "update outbound_traffics set up=0, down=0",
    "delete from inbound_client_ips",
    "delete from history_of_seeders",
]:
    try:
        con.execute(sql)
    except sqlite3.OperationalError:
        pass

con.commit()
PY
}

configure_privacy_hardening() {
  [ "$PRIVACY_HARDENING" = "1" ] || {
    warn "PRIVACY_HARDENING=0: persistent service logs and panel metadata scrubber will not be configured."
    return 0
  }

  backup_file /etc/fstab
  backup_file /etc/ssh/sshd_config

  mkdir -p /etc/systemd/journald.conf.d /etc/ssh/sshd_config.d /usr/local/sbin /run/x-ui

  cat > /usr/local/sbin/mullvad-vless-privacy-scrub.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

DB="/etc/x-ui/x-ui.db"
[ -f "$DB" ] || exit 0

python3 - <<'PY'
import sqlite3

db = "/etc/x-ui/x-ui.db"
con = sqlite3.connect(db, timeout=5)
for sql in [
    "update inbounds set up=0, down=0, last_traffic_reset_time=0",
    "update client_traffics set up=0, down=0, last_online=0",
    "update client_global_traffics set up=0, down=0, updated_at=0",
    "update node_client_traffics set up=0, down=0",
    "update outbound_traffics set up=0, down=0",
    "delete from inbound_client_ips",
    "delete from history_of_seeders",
]:
    try:
        con.execute(sql)
    except sqlite3.OperationalError:
        pass
con.commit()
con.close()
PY

rm -f /etc/x-ui/system_metrics.gob /run/x-ui/system_metrics.gob 2>/dev/null || true
SCRIPT
  chmod 700 /usr/local/sbin/mullvad-vless-privacy-scrub.sh

  cat > /etc/systemd/system/mullvad-vless-privacy-scrub.service <<'EOF'
[Unit]
Description=Scrub Mullvad VLESS bridge runtime metadata
Documentation=man:systemd.service(5)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mullvad-vless-privacy-scrub.sh
PrivateTmp=true
NoNewPrivileges=true
EOF

  cat > /etc/systemd/system/mullvad-vless-privacy-scrub.timer <<EOF
[Unit]
Description=Run Mullvad VLESS privacy scrubber frequently

[Timer]
OnBootSec=30s
OnUnitActiveSec=${PRIVACY_SCRUB_INTERVAL}
AccuracySec=10s
Unit=mullvad-vless-privacy-scrub.service

[Install]
WantedBy=timers.target
EOF

  cat > /etc/systemd/journald.conf.d/99-mullvad-vless-volatile.conf <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=32M
SystemMaxUse=0
MaxRetentionSec=1h
ForwardToSyslog=no
EOF

  # OpenSSH uses the first value it reads, so this file must sort before
  # cloud-init's 50-cloud-init.conf. Password login is disabled only when
  # root already has an authorized key; fresh password-only VPS installs must
  # not lock the operator out.
  if [ -s /root/.ssh/authorized_keys ]; then
    cat > /etc/ssh/sshd_config.d/00-mullvad-vless-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3
EOF
  else
    warn "No /root/.ssh/authorized_keys found; keeping SSH password login enabled."
    cat > /etc/ssh/sshd_config.d/00-mullvad-vless-hardening.conf <<'EOF'
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3
EOF
  fi
  sshd -t

  cat > /etc/fail2ban/jail.d/sshd-mullvad-vless.conf <<'EOF'
[sshd]
enabled = true
mode = aggressive
port = ssh
backend = systemd
maxretry = 4
findtime = 10m
bantime = 1h
EOF

  for dir in /var/log/x-ui /var/log/mullvad-vpn; do
    mkdir -p "$dir"
    find "$dir" -maxdepth 1 -type f -delete 2>/dev/null || true
  done

  if ! grep -qE '^[[:space:]]*tmpfs[[:space:]]+/var/log/x-ui[[:space:]]+tmpfs' /etc/fstab; then
    printf '%s\n' 'tmpfs /var/log/x-ui tmpfs rw,nosuid,nodev,noexec,relatime,size=16M,mode=0750 0 0' >> /etc/fstab
  fi
  if ! grep -qE '^[[:space:]]*tmpfs[[:space:]]+/var/log/mullvad-vpn[[:space:]]+tmpfs' /etc/fstab; then
    printf '%s\n' 'tmpfs /var/log/mullvad-vpn tmpfs rw,nosuid,nodev,noexec,relatime,size=16M,mode=0755 0 0' >> /etc/fstab
  fi
  mount /var/log/x-ui 2>/dev/null || true
  mount /var/log/mullvad-vpn 2>/dev/null || true

  systemctl daemon-reload
  systemctl enable --now fail2ban.service >/dev/null 2>&1 || warn "fail2ban did not start; check journalctl -u fail2ban"
  systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 || true
  systemctl enable --now mullvad-vless-privacy-scrub.timer
  systemctl restart systemd-journald
  journalctl --rotate >/dev/null 2>&1 || true
  journalctl --vacuum-time=1s >/dev/null 2>&1 || true
  rm -rf /var/log/journal/* 2>/dev/null || true
  systemctl restart ssh
  /usr/local/sbin/mullvad-vless-privacy-scrub.sh
}

connect_and_lockdown_mullvad() {
  systemctl enable --now mullvad-connect.service
  systemctl is-active --quiet mullvad-connect.service || die "mullvad-connect.service did not complete successfully."
  mullvad_cmd 20 status -v
  mullvad_cmd 20 status | grep -qi '^Connected' || die "Mullvad did not connect; refusing to enable lockdown."
  mullvad_cmd 20 lockdown-mode set on
}

verify_installation() {
  systemctl is-active --quiet x-ui.service
  systemctl is-active --quiet mullvad-daemon.service
  systemctl is-active --quiet mullvad-connect.service
  systemctl is-active --quiet mullvad-vps-bypass.service
  if [ "$PRIVACY_HARDENING" = "1" ]; then
    systemctl is-active --quiet mullvad-vless-privacy-scrub.timer
    systemctl is-active --quiet mullvad-dns-guard.service
    if [ -s /root/.ssh/authorized_keys ]; then
      sshd -T | grep -q '^passwordauthentication no$'
    fi
    grep -q '^nameserver 10[.]64[.]0[.]1$' /etc/resolv.conf
    ! grep -Eq 'nameserver[[:space:]]+(1[.]1[.]1[.]1|1[.]0[.]0[.]1|2606:4700:4700::1111|2606:4700:4700::1001)' /etc/resolv.conf
  fi

  ss -tlnp | grep -q ":${VLESS_PORT} "
  ss -tlnp | grep -q ":${GLOBAL_VLESS_PORT} "
  ss -tlnp | grep -q ":${SUB_PORT} "

  mullvad status | grep -qi '^Connected'
}

print_result() {
  local domain="$1"
  local sub_id="$2"
  cat <<EOF

DONE.

Subscription URL:
https://${domain}:${SUB_PORT}/sub/${sub_id}

Panel access via SSH tunnel:
ssh -L ${XUI_PANEL_PORT}:127.0.0.1:${XUI_PANEL_PORT} root@${VPS_IP}

Then open:
http://127.0.0.1:${XUI_PANEL_PORT}/

Checks:
mullvad status -v
curl -s https://${domain}:${SUB_PORT}/sub/${sub_id} | base64 -d
ss -tlnp | grep -E ':(${SSH_PORT}|${VLESS_PORT}|${GLOBAL_VLESS_PORT}|${SUB_PORT})'

Expected client exit:
Mullvad, not VPS.

Nodes:
- ${RU_NODE_NAME}
- ${GLOBAL_NODE_NAME}
EOF
}

main() {
  need_root
  acquire_lock
  init_state

  title "Mullvad VLESS bridge installer ${SCRIPT_VERSION}"
  ok "Log file: ${LOG_FILE}"
  ok "State file: ${STATE_FILE}"

  run_step "Check OS" require_debian_like

  MULLVAD_ACCOUNT="$(prompt_mullvad_account)"

  WAN_DEV="${WAN_DEV:-$(detect_wan_dev)}"
  state_set WAN_DEV "$WAN_DEV"
  VPS_IP="${VPS_IP:-$(detect_wan_ipv4 "$WAN_DEV")}"
  [ -n "$VPS_IP" ] || VPS_IP="$(detect_public_ipv4)"
  state_set VPS_IP "$VPS_IP"
  WAN_GW="${WAN_GW:-$(detect_wan_gw)}"
  state_set WAN_GW "$WAN_GW"
  WAN_CIDR="${WAN_CIDR:-$(detect_wan_cidr "$WAN_DEV")}"
  state_set WAN_CIDR "$WAN_CIDR"
  DOMAIN="${DOMAIN:-$(printf '%s' "$VPS_IP" | tr '.' '-').sslip.io}"
  state_set DOMAIN "$DOMAIN"
  SUB_ID="${SUB_ID:-happ-$(openssl rand -hex 8)}"
  state_set SUB_ID "$SUB_ID"
  CLIENT_UUID="${CLIENT_UUID:-$(generate_uuid)}"
  state_set CLIENT_UUID "$CLIENT_UUID"
  SHORT_ID="${SHORT_ID:-$(openssl rand -hex 4)}"
  state_set SHORT_ID "$SHORT_ID"

  export VPS_IP WAN_DEV WAN_GW WAN_CIDR PUBLIC_PORTS

  ok "Public IPv4: ${VPS_IP}"
  ok "WAN: ${WAN_DEV} via ${WAN_GW} (${WAN_CIDR})"
  ok "Domain: ${DOMAIN}"
  ok "Subscription token: ${SUB_ID}"

  run_step "Install base packages" install_base_packages
  run_step "Configure firewall" configure_firewall
  run_step "Install Mullvad" install_mullvad
  run_step "Install VPS bypass" write_bypass_files
  run_step "Configure Mullvad profile" configure_mullvad "$MULLVAD_ACCOUNT"
  run_step "Install 3x-ui / Xray" install_xui
  run_step "Issue subscription certificate" issue_subscription_cert "$DOMAIN"

  if [ -z "${REALITY_PRIVATE_KEY:-}" ] || [ -z "${REALITY_PUBLIC_KEY:-}" ]; then
    keys="$(generate_reality_keys)"
    state_set REALITY_PRIVATE_KEY "$(printf '%s\n' "$keys" | sed -n '1p')"
    state_set REALITY_PUBLIC_KEY "$(printf '%s\n' "$keys" | sed -n '2p')"
  fi
  if [ -z "${GLOBAL_REALITY_PRIVATE_KEY:-}" ] || [ -z "${GLOBAL_REALITY_PUBLIC_KEY:-}" ]; then
    keys="$(generate_reality_keys)"
    state_set GLOBAL_REALITY_PRIVATE_KEY "$(printf '%s\n' "$keys" | sed -n '1p')"
    state_set GLOBAL_REALITY_PUBLIC_KEY "$(printf '%s\n' "$keys" | sed -n '2p')"
  fi
  GLOBAL_CLIENT_UUID="${GLOBAL_CLIENT_UUID:-$(generate_uuid)}"
  state_set GLOBAL_CLIENT_UUID "$GLOBAL_CLIENT_UUID"
  GLOBAL_SHORT_ID="${GLOBAL_SHORT_ID:-$(openssl rand -hex 4)}"
  state_set GLOBAL_SHORT_ID "$GLOBAL_SHORT_ID"

  run_step "Configure VLESS Reality nodes" configure_xui_db \
    "$DOMAIN" \
    "$REALITY_PRIVATE_KEY" \
    "$REALITY_PUBLIC_KEY" \
    "$CLIENT_UUID" \
    "$SHORT_ID" \
    "$SUB_ID" \
    "$XUI_PANEL_PORT" \
    "$SUB_PORT" \
    "$VLESS_PORT" \
    "$GLOBAL_VLESS_PORT" \
    "$REALITY_DEST" \
    "$REALITY_SNI" \
    "$REALITY_SERVER_NAMES" \
    "$REALITY_FINGERPRINT" \
    "$GLOBAL_REALITY_DEST" \
    "$GLOBAL_REALITY_SNI" \
    "$GLOBAL_REALITY_SERVER_NAMES" \
    "$GLOBAL_REALITY_FINGERPRINT" \
    "$CLIENT_EMAIL" \
    "$GLOBAL_CLIENT_EMAIL" \
    "$RU_NODE_NAME" \
    "$GLOBAL_NODE_NAME" \
    "$(date +%s)"

  run_step "Configure privacy hardening" configure_privacy_hardening
  run_step "Restart x-ui" systemctl restart x-ui.service
  sleep 3
  run_step "Connect Mullvad and enable lockdown" connect_and_lockdown_mullvad
  run_step "Force Mullvad DNS only" configure_mullvad_dns_policy
  run_step "Verify installation" verify_installation
  print_result "$DOMAIN" "$SUB_ID"
}

main "$@"
