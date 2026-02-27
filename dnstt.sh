#!/usr/bin/env bash
set -euo pipefail

APP="dnstt"
BIN_DIR="/usr/local/bin"
CFG_DIR="/etc/dnstt"
DATA_DIR="/var/lib/dnstt"
LOG_DIR="/var/log/dnstt"
PORTS_FILE="$CFG_DIR/ports.list"
RESOLVERS_FILE="$CFG_DIR/resolvers.list"

SYSTEMD_DIR="/etc/systemd/system"
SVC_FR="dnstt-fr.service"
SVC_IR="dnstt-ir.service"
SVC_SOCKS="dnstt-socks.service"

DEFAULT_UDP_PORT="5300"      # dnstt-server listens here (non-privileged)
DEFAULT_PUBLIC_DNS_PORT="53" # public DNS port redirected to 5300
DEFAULT_SOCKS_PORT="8000"    # microsocks on FR
DEFAULT_LOCAL_PORT="1080"    # local port on IR (V2Ray outbound uses this)
DEFAULT_MTU="1232"           # per dnstt docs; can be lowered if needed

# ------------------ helpers ------------------
need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Please run as root (sudo)."
    exit 1
  fi
}

os_detect() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "${ID:-linux}"
  else
    echo "linux"
  fi
}

pkg_install() {
  local pkgs=("$@")
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${pkgs[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${pkgs[@]}"
  else
    echo "ERROR: Unsupported package manager."
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "$BIN_DIR" "$CFG_DIR" "$DATA_DIR" "$LOG_DIR"
  touch "$PORTS_FILE" "$RESOLVERS_FILE"
  chmod 600 "$CFG_DIR"/* 2>/dev/null || true
}

log() { echo "[$APP] $*"; }

prompt() {
  local var="$1"; shift
  local text="$1"; shift
  local def="${1:-}"
  local val=""
  if [[ -n "$def" ]]; then
    read -r -p "$text [$def]: " val
    val="${val:-$def}"
  else
    read -r -p "$text: " val
  fi
  printf -v "$var" "%s" "$val"
}

confirm() {
  local text="$1"
  read -r -p "$text [y/N]: " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# ------------------ dnstt build/install ------------------
install_build_deps() {
  log "Installing dependencies..."
  pkg_install curl ca-certificates git iptables iproute2 jq lsof netcat-openbsd
  # Go build deps
  if ! command -v go >/dev/null 2>&1; then
    pkg_install golang || pkg_install golang-go
  fi
}

build_dnstt_from_source() {
  # Official source: https://www.bamsoftware.com/software/dnstt/ :contentReference[oaicite:1]{index=1}
  log "Building dnstt from source (bamsoftware git)..."
  cd /tmp
  rm -rf /tmp/dnstt || true
  git clone https://www.bamsoftware.com/git/dnstt.git
  cd /tmp/dnstt/dnstt-server
  go build -o "$BIN_DIR/dnstt-server"
  cd /tmp/dnstt/dnstt-client
  go build -o "$BIN_DIR/dnstt-client"
  chmod +x "$BIN_DIR/dnstt-server" "$BIN_DIR/dnstt-client"
  log "dnstt-server and dnstt-client installed to $BIN_DIR"
}

install_microsocks() {
  if command -v microsocks >/dev/null 2>&1; then
    log "microsocks already installed."
    return
  fi
  log "Installing microsocks (SOCKS5 server on FR)..."
  # Try package first
  if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y microsocks || true
  fi
  if ! command -v microsocks >/dev/null 2>&1; then
    # Build from source (small)
    pkg_install build-essential
    cd /tmp
    rm -rf /tmp/microsocks || true
    git clone https://github.com/rofl0r/microsocks.git
    cd /tmp/microsocks
    make
    install -m 755 microsocks "$BIN_DIR/microsocks"
  fi
  if ! command -v microsocks >/dev/null 2>&1; then
    echo "ERROR: microsocks installation failed."
    exit 1
  fi
  log "microsocks installed."
}

# ------------------ DNS port redirect (FR) ------------------
apply_dns_redirect_rules() {
  # Redirect UDP/53 -> UDP/5300 (or chosen port) on FR
  local listen_port="$1"  # e.g. 5300
  log "Applying iptables rules for UDP/53 -> UDP/$listen_port redirect..."
  iptables -I INPUT -p udp --dport "$listen_port" -j ACCEPT 2>/dev/null || true
  iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports "$listen_port" 2>/dev/null || true
}

remove_dns_redirect_rules() {
  local listen_port="$1"
  log "Removing iptables rules for DNS redirect..."
  # Best-effort delete (may fail if not present)
  iptables -D INPUT -p udp --dport "$listen_port" -j ACCEPT 2>/dev/null || true
  iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports "$listen_port" 2>/dev/null || true
}

# ------------------ systemd ------------------
systemd_reload() {
  systemctl daemon-reload
}

write_service_fr() {
  local tunnel_domain="$1"
  local mtu="$2"
  local udp_listen_port="$3"
  local socks_port="$4"

  cat > "$SYSTEMD_DIR/$SVC_SOCKS" <<EOF
[Unit]
Description=DNSTT SOCKS5 backend (microsocks)
After=network.target

[Service]
Type=simple
ExecStart=$BIN_DIR/microsocks -i 127.0.0.1 -p ${socks_port}
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

  cat > "$SYSTEMD_DIR/$SVC_FR" <<EOF
[Unit]
Description=DNSTT Server (authoritative zone: ${tunnel_domain})
After=network.target ${SVC_SOCKS}

[Service]
Type=simple
WorkingDirectory=$CFG_DIR
ExecStart=$BIN_DIR/dnstt-server -udp :${udp_listen_port} -mtu ${mtu} -privkey-file ${CFG_DIR}/server.key ${tunnel_domain} 127.0.0.1:${socks_port}
Restart=always
RestartSec=1
StandardOutput=append:${LOG_DIR}/dnstt-fr.log
StandardError=append:${LOG_DIR}/dnstt-fr.log

[Install]
WantedBy=multi-user.target
EOF
}

write_service_ir() {
  local tunnel_domain="$1"
  local mode="$2"          # doh|dot|udp
  local resolver="$3"      # URL or host:port
  local mtu="$4"
  local local_port="$5"

  local mode_arg=""
  if [[ "$mode" == "doh" ]]; then
    mode_arg="-doh $resolver"
  elif [[ "$mode" == "dot" ]]; then
    mode_arg="-dot $resolver"
  else
    mode_arg="-udp $resolver"
  fi

  cat > "$SYSTEMD_DIR/$SVC_IR" <<EOF
[Unit]
Description=DNSTT Client -> local proxy port 127.0.0.1:${local_port}
After=network.target

[Service]
Type=simple
WorkingDirectory=$CFG_DIR
ExecStart=$BIN_DIR/dnstt-client ${mode_arg} -mtu ${mtu} -pubkey-file ${CFG_DIR}/server.pub ${tunnel_domain} 127.0.0.1:${local_port}
Restart=always
RestartSec=1
StandardOutput=append:${LOG_DIR}/dnstt-ir.log
StandardError=append:${LOG_DIR}/dnstt-ir.log

[Install]
WantedBy=multi-user.target
EOF
}

# ------------------ token encode/decode ------------------
make_token() {
  local tunnel_domain="$1"
  local pubkey_b64
  pubkey_b64="$(base64 -w0 < "$CFG_DIR/server.pub")"
  # token fields are JSON for easy parsing
  jq -nc --arg domain "$tunnel_domain" --arg pub "$pubkey_b64" '{tunnel_domain:$domain,server_pub_b64:$pub}' | base64 -w0
}

read_token() {
  local token="$1"
  echo "$token" | base64 -d 2>/dev/null
}

# ------------------ menu actions ------------------
action_install() {
  need_root
  ensure_dirs
  install_build_deps
  build_dnstt_from_source
  log "Install complete."
}

action_setup_fr() {
  need_root
  ensure_dirs
  install_build_deps
  build_dnstt_from_source
  install_microsocks

  local tunnel_domain mtu udp_listen_port socks_port
  prompt tunnel_domain "Enter tunnel domain (e.g. t.example.com)"
  prompt mtu "MTU (lower if unstable)" "$DEFAULT_MTU"
  prompt udp_listen_port "dnstt-server listen UDP port (non-privileged)" "$DEFAULT_UDP_PORT"
  prompt socks_port "SOCKS5 backend port (microsocks on 127.0.0.1)" "$DEFAULT_SOCKS_PORT"

  log "Generating server keys..."
  "$BIN_DIR/dnstt-server" -gen-key -privkey-file "$CFG_DIR/server.key" -pubkey-file "$CFG_DIR/server.pub" >/dev/null

  chmod 600 "$CFG_DIR/server.key" "$CFG_DIR/server.pub"

  write_service_fr "$tunnel_domain" "$mtu" "$udp_listen_port" "$socks_port"
  systemd_reload

  apply_dns_redirect_rules "$udp_listen_port"

  systemctl enable --now "$SVC_SOCKS" "$SVC_FR"

  log "FR setup complete."
  log "TOKEN (copy this to IR setup):"
  make_token "$tunnel_domain"
  echo
  log "DNS records required (set at your registrar/DNS panel):"
  echo "  A    tns.<your-domain>   -> <FR_PUBLIC_IP>"
  echo "  NS   ${tunnel_domain}    -> tns.<your-domain>"
  echo "Note: tns label must NOT be under tunnel domain label. See official dnstt DNS setup guidance."
}

action_setup_ir() {
  need_root
  ensure_dirs
  install_build_deps
  build_dnstt_from_source

  local token_json token tunnel_domain pub_b64
  prompt token "Paste TOKEN from FR"
  token_json="$(read_token "$token")" || { echo "ERROR: Invalid token"; exit 1; }

  tunnel_domain="$(echo "$token_json" | jq -r '.tunnel_domain')"
  pub_b64="$(echo "$token_json" | jq -r '.server_pub_b64')"

  if [[ -z "$tunnel_domain" || -z "$pub_b64" || "$tunnel_domain" == "null" ]]; then
    echo "ERROR: Token missing fields."
    exit 1
  fi

  echo "$pub_b64" | base64 -d > "$CFG_DIR/server.pub"
  chmod 600 "$CFG_DIR/server.pub"

  local mode resolver mtu local_port
  prompt mode "Resolver mode (doh/dot/udp)" "doh"
  if [[ "$mode" == "doh" ]]; then
    prompt resolver "DoH URL (e.g. https://dns.google/dns-query)"
  elif [[ "$mode" == "dot" ]]; then
    prompt resolver "DoT host:port (e.g. 1.1.1.1:853)"
  else
    prompt resolver "UDP resolver ip:port (e.g. 1.1.1.1:53)"
  fi
  prompt mtu "MTU (lower if unstable)" "$DEFAULT_MTU"
  prompt local_port "Local listen port on IR (use as SOCKS/HTTP proxy entry)" "$DEFAULT_LOCAL_PORT"

  # Save resolver list for convenience
  if [[ -n "$resolver" ]]; then
    grep -qxF "$resolver" "$RESOLVERS_FILE" 2>/dev/null || echo "$resolver" >> "$RESOLVERS_FILE"
  fi

  write_service_ir "$tunnel_domain" "$mode" "$resolver" "$mtu" "$local_port"
  systemd_reload
  systemctl enable --now "$SVC_IR"

  log "IR setup complete."
  log "Local proxy endpoint on IR: 127.0.0.1:${local_port}"
  log "Next: set your Xray/V2Ray outbound to SOCKS5 -> 127.0.0.1:${local_port}"
}

action_status() {
  need_root
  echo "---- systemd ----"
  systemctl --no-pager -l status "$SVC_FR" 2>/dev/null || true
  systemctl --no-pager -l status "$SVC_IR" 2>/dev/null || true
  systemctl --no-pager -l status "$SVC_SOCKS" 2>/dev/null || true
  echo
  echo "---- listening ports ----"
  ss -lntup | grep -E '(:53|:5300|:8000|:1080)' || true
  echo
  echo "---- logs ----"
  tail -n 30 "$LOG_DIR/dnstt-fr.log" 2>/dev/null || true
  tail -n 30 "$LOG_DIR/dnstt-ir.log" 2>/dev/null || true
}

action_restart() {
  need_root
  systemctl restart "$SVC_IR" 2>/dev/null || true
  systemctl restart "$SVC_FR" 2>/dev/null || true
  systemctl restart "$SVC_SOCKS" 2>/dev/null || true
  log "Restarted."
}

action_uninstall() {
  need_root
  if ! confirm "This will remove services, configs, and iptables rules. Continue?"; then
    exit 0
  fi

  # Stop services
  systemctl disable --now "$SVC_IR" 2>/dev/null || true
  systemctl disable --now "$SVC_FR" 2>/dev/null || true
  systemctl disable --now "$SVC_SOCKS" 2>/dev/null || true

  # Remove iptables rules (best effort)
  remove_dns_redirect_rules "$DEFAULT_UDP_PORT"

  rm -f "$SYSTEMD_DIR/$SVC_IR" "$SYSTEMD_DIR/$SVC_FR" "$SYSTEMD_DIR/$SVC_SOCKS"
  systemd_reload

  rm -rf "$CFG_DIR" "$DATA_DIR" "$LOG_DIR"
  rm -f "$BIN_DIR/dnstt-server" "$BIN_DIR/dnstt-client" "$BIN_DIR/microsocks"

  rm -f "$BIN_DIR/dnstt-menu" 2>/dev/null || true
  rm -f "$BIN_DIR/dnstt" 2>/dev/null || true

  log "Uninstalled."
}

install_menu_alias() {
  cat > "$BIN_DIR/dnstt" <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/dnstt-menu "$@"
EOF
  chmod +x "$BIN_DIR/dnstt"

  cat > "$BIN_DIR/dnstt-menu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT="/usr/local/bin/dnstt.sh"

if [[ ! -f "$SCRIPT" ]]; then
  echo "ERROR: /usr/local/bin/dnstt.sh not found."
  exit 1
fi

exec bash "$SCRIPT" menu
EOF
  chmod +x "$BIN_DIR/dnstt-menu"
}

action_menu_install_self() {
  need_root
  # copy current script to /usr/local/bin/dnstt.sh
  install -m 755 "$0" "$BIN_DIR/dnstt.sh"
  install_menu_alias
  log "Menu installed. Use: sudo dnstt"
}

menu() {
  need_root
  while true; do
    echo
    echo "=============================="
    echo " DNSTT Emergency Tunnel Manager"
    echo "=============================="
    echo "1) Install/Update (build dnstt)"
    echo "2) Setup FR (EXIT server)"
    echo "3) Setup IR (ENTRY server)"
    echo "4) Status"
    echo "5) Restart"
    echo "6) Uninstall"
    echo "0) Exit"
    echo
    read -r -p "Select: " c
    case "$c" in
      1) action_install ;;
      2) action_setup_fr ;;
      3) action_setup_ir ;;
      4) action_status ;;
      5) action_restart ;;
      6) action_uninstall ;;
      0) exit 0 ;;
      *) echo "Invalid choice" ;;
    esac
  done
}

# ------------------ CLI ------------------
case "${1:-}" in
  install) action_install; action_menu_install_self ;;
  menu) menu ;;
  setup-fr) action_setup_fr ;;
  setup-ir) action_setup_ir ;;
  status) action_status ;;
  restart) action_restart ;;
  uninstall) action_uninstall ;;
  *)
    echo "Usage:"
    echo "  sudo bash dnstt.sh install"
    echo "  sudo dnstt           # menu"
    echo "  sudo dnstt.sh menu"
    echo "  sudo dnstt.sh setup-fr | setup-ir | status | restart | uninstall"
    exit 1
    ;;
esac
