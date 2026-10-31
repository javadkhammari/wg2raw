#!/usr/bin/env bash
# =============================================================================
#  wg2raw — WireGuard over udp2raw (faketcp), menu-driven installer & manager
#
#  Server = the public/upstream machine (udp2raw listens on a TCP port)
#  Client = the machine behind the restrictive network
#           (udp2raw connects out, WireGuard -> 127.0.0.1)
#
#  Usage:
#    sudo ./wg2raw.sh                 open the menu
#    sudo wg2raw                      same, after the first install
#    sudo wg2raw <command>            run one action directly (see: wg2raw help)
#
#  Requires: Debian/Ubuntu with systemd, root.
# =============================================================================
set -euo pipefail
trap 'echo "[-] ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR

WG2RAW_VERSION="2.0.0"

# ---------------------------------------------------------------- paths -----
STATE_DIR="/etc/wg2raw"
STATE_FILE="${STATE_DIR}/wg2raw.conf"     # saved settings
ENV_FILE="${STATE_DIR}/udp2raw.env"       # udp2raw password (mode 600)
CLIENT_KEY_FILE="${STATE_DIR}/client.key" # server only: client's private key (for the code)

WG_DIR="/etc/wireguard"
CFG_WG="${WG_DIR}/wg0.conf"
PRIV_FILE="${WG_DIR}/wg0.key"
PUB_FILE="${WG_DIR}/wg0.pub"

UNIT_UDP2RAW="/etc/systemd/system/udp2raw.service"
UNIT_OFFLOAD="/etc/systemd/system/wg2raw-offload.service"
OVR_DIR="/etc/systemd/system/wg-quick@wg0.service.d"
SYSCTL_FILE="/etc/sysctl.d/99-wg2raw.conf"

UDP2RAW_BIN="/usr/local/bin/udp2raw"
UDP2RAW_RELEASE="${UDP2RAW_RELEASE:-20230206.0}"
UDP2RAW_URL="https://github.com/wangyu-/udp2raw/releases/download/${UDP2RAW_RELEASE}/udp2raw_binaries.tar.gz"

SELF_INSTALL_PATH="/usr/local/bin/wg2raw"
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"

CODE_PREFIX="wg2raw:"

# ------------------------------------------------------------- settings -----
# Defaults. load_state() overrides them with what is saved on disk.
ROLE=""
SERVER_ADDR=""
EXT_PORT="443"
WG_PORT="51820"
TUN_NET="10.77.77.0/30"
LOCAL_TUN_IP=""
PEER_TUN_IP=""
PEER_PUB=""
MTU="1280"
KEEPALIVE="10"
FIXGRO="y"
OFFLOAD="n"
NAT="n"
NIC=""

STATE_KEYS=(ROLE SERVER_ADDR EXT_PORT WG_PORT TUN_NET LOCAL_TUN_IP PEER_TUN_IP PEER_PUB
            MTU KEEPALIVE FIXGRO OFFLOAD NAT NIC)

SERVER_TUN_IP_DEFAULT="10.77.77.1/30"
CLIENT_TUN_IP_DEFAULT="10.77.77.2/30"

# =============================================================================
#  UI helpers
# =============================================================================
if [[ -t 1 ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[34m'; C_C=$'\e[36m'
  C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_0=$'\e[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_C=""; C_BOLD=""; C_DIM=""; C_0=""
fi

ok(){   echo "${C_G}[+]${C_0} $*"; }
info(){ echo "${C_B}[*]${C_0} $*"; }
warn(){ echo "${C_Y}[!]${C_0} $*" >&2; }
die(){  echo "${C_R}[-]${C_0} $*" >&2; exit 1; }

title(){ echo; echo "${C_BOLD}${C_C}== $* ==${C_0}"; echo; }

pause(){ echo; read -r -p "  Press Enter to continue..." _ || true; }

# ask VAR "Question" [default] [validator_fn]
# Asks again until the value is non-empty and passes the validator.
ask(){
  local __var="$1" __msg="$2" __def="${3:-}" __chk="${4:-}" __val
  while true; do
    if [[ -n "$__def" ]]; then
      read -r -p "  ${__msg} [${__def}]: " __val || die "Input closed."
      __val="${__val:-$__def}"
    else
      read -r -p "  ${__msg}: " __val || die "Input closed."
    fi
    __val="${__val#"${__val%%[![:space:]]*}"}"   # trim leading spaces
    __val="${__val%"${__val##*[![:space:]]}"}"   # trim trailing spaces
    if [[ -z "$__val" ]]; then warn "A value is required."; continue; fi
    if [[ -n "$__chk" ]] && ! "$__chk" "$__val"; then warn "Invalid value: ${__val}"; continue; fi
    printf -v "$__var" '%s' "$__val"
    return 0
  done
}

# ask_yn VAR "Question" [y|n]
ask_yn(){
  local __var="$1" __msg="$2" __def="${3:-n}" __val
  while true; do
    read -r -p "  ${__msg} (y/n) [${__def}]: " __val || die "Input closed."
    __val="${__val:-$__def}"
    case "$__val" in
      y|Y|yes) printf -v "$__var" 'y'; return 0 ;;
      n|N|no)  printf -v "$__var" 'n'; return 0 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

# Print "  label   value" aligned
kv(){ printf "  %-18s %s\n" "$1" "$2"; }

# =============================================================================
#  Validators
# =============================================================================
is_port(){ [[ "${1:-}" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
is_mtu(){ [[ "${1:-}" =~ ^[0-9]+$ ]] && ((10#$1 >= 900 && 10#$1 <= 1500)); }
is_keepalive(){ [[ "${1:-}" =~ ^[0-9]+$ ]] && ((10#$1 >= 0 && 10#$1 <= 60)); }
# systemd ExecStart is not a shell: keep the password to safe characters.
is_safe_pass(){ [[ "${1:-}" =~ ^[A-Za-z0-9._-]{6,64}$ ]]; }
is_host(){ [[ "${1:-}" =~ ^[A-Za-z0-9.-]+$ ]]; }
is_ipv4_cidr(){ [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; }
is_wg_key(){ [[ "${1:-}" =~ ^[A-Za-z0-9+/]{43}=$ ]]; }
is_yn(){ [[ "${1:-}" == "y" || "${1:-}" == "n" ]]; }

# =============================================================================
#  System helpers
# =============================================================================
have(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)."; }

ensure_packages(){
  local missing=()
  have wg       || missing+=(wireguard-tools)
  have ip       || missing+=(iproute2)
  have ss       || missing+=(iproute2)
  have iptables || missing+=(iptables)
  have curl     || missing+=(curl ca-certificates)
  have ethtool  || missing+=(ethtool)
  have ping     || missing+=(iputils-ping)

  if ((${#missing[@]})); then
    if have apt-get; then
      info "Installing missing packages: ${missing[*]}"
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null 2>&1 || warn "apt-get update failed (continuing)."
      apt-get install -y "${missing[@]}" >/dev/null 2>&1 || warn "Some packages failed to install."
    else
      warn "apt-get not found. Please install: ${missing[*]}"
    fi
  fi

  local t
  for t in wg wg-quick ip ss iptables systemctl; do
    have "$t" || die "Required tool is missing: $t"
  done
}

default_nic(){
  ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

detect_public_ip(){
  local ip=""
  if have curl; then ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"; fi
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then echo "$ip"; fi
}

tcp_port_in_use(){ ss -lnt 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]$1\$"; }
udp_port_in_use(){ ss -lnu 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]$1\$"; }

random_pass(){ tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24 || true; }

svc_active(){ systemctl is-active --quiet "$1" 2>/dev/null; }

# =============================================================================
#  State (saved settings)
# =============================================================================
load_state(){
  [[ -f "$STATE_FILE" ]] || return 1
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

save_state(){
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  local k
  ( umask 077
    { echo "# wg2raw settings - generated. Change them with: wg2raw settings"
      for k in "${STATE_KEYS[@]}"; do printf '%s=%q\n' "$k" "${!k}"; done
    } > "$STATE_FILE" )
}

load_pass(){
  local UDP2RAW_KEY=""
  # shellcheck disable=SC1090
  if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi
  echo "${UDP2RAW_KEY}"
}

save_pass(){
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  ( umask 077; printf 'UDP2RAW_KEY=%s\n' "$1" > "$ENV_FILE" )
}

# =============================================================================
#  udp2raw binary
# =============================================================================
udp2raw_ok(){ [[ -x "$UDP2RAW_BIN" ]] && "$UDP2RAW_BIN" --help >/dev/null 2>&1; }

udp2raw_asset_for_arch(){
  case "$(uname -m)" in
    x86_64|amd64)          echo "udp2raw_amd64" ;;
    i?86)                  echo "udp2raw_x86" ;;
    armv6*|armv7*|aarch64) echo "udp2raw_arm" ;;   # 32-bit ARM build; runs on most aarch64 kernels
    *) echo "" ;;
  esac
}

# Install from the official .tar.gz or from a ready binary
udp2raw_install_from_file(){
  local src="$1" asset tmp
  [[ -f "$src" ]] || die "File not found: $src"
  asset="$(udp2raw_asset_for_arch)"
  tmp="$(mktemp -d)"
  if tar tzf "$src" >/dev/null 2>&1; then
    [[ -n "$asset" ]] || die "Unsupported CPU architecture: $(uname -m)"
    tar xzf "$src" -C "$tmp" "$asset" || die "Could not find ${asset} inside the archive."
    install -m 755 "$tmp/$asset" "$UDP2RAW_BIN"
  else
    install -m 755 "$src" "$UDP2RAW_BIN"
  fi
  rm -rf "$tmp"
  udp2raw_ok || die "The installed udp2raw binary does not run on this machine."
  ok "udp2raw installed at ${UDP2RAW_BIN}"
}

udp2raw_download(){
  have curl || die "curl is missing."
  local tmp; tmp="$(mktemp -d)"
  info "Downloading udp2raw ${UDP2RAW_RELEASE} from GitHub..."
  if ! curl -fL --max-time 120 --retry 2 -o "$tmp/udp2raw.tgz" "$UDP2RAW_URL"; then
    rm -rf "$tmp"
    die "Download failed. Download this file on another machine, copy it here and use option 2:
    ${UDP2RAW_URL}"
  fi
  udp2raw_install_from_file "$tmp/udp2raw.tgz"
  rm -rf "$tmp"
}

cmd_install_udp2raw(){
  need_root
  title "Install / update udp2raw"
  if udp2raw_ok; then ok "udp2raw is already installed at ${UDP2RAW_BIN}"; echo; fi
  echo "  1) Download from GitHub (release ${UDP2RAW_RELEASE})"
  echo "  2) Use a local file (udp2raw_binaries.tar.gz or the binary itself)"
  echo "  0) Back"
  echo
  local c path
  read -r -p "  Choose: " c || return 0
  case "$c" in
    1) udp2raw_download ;;
    2) ask path "Path to file"; udp2raw_install_from_file "$path" ;;
    *) return 0 ;;
  esac
}

ensure_udp2raw(){
  if udp2raw_ok; then return 0; fi
  warn "udp2raw was not found at ${UDP2RAW_BIN}."
  cmd_install_udp2raw
  udp2raw_ok || die "udp2raw is required."
}

# =============================================================================
#  Config writers — every file is generated from the saved settings
# =============================================================================
gen_keys_if_missing(){
  if [[ -s "$PRIV_FILE" && -s "$PUB_FILE" ]]; then return 0; fi
  info "Generating WireGuard keys..."
  ( umask 077; mkdir -p "$WG_DIR"; wg genkey | tee "$PRIV_FILE" | wg pubkey > "$PUB_FILE" )
}

write_wg_conf(){
  local priv; priv="$(cat "$PRIV_FILE")"
  local mss="FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
  mkdir -p "$WG_DIR"
  ( umask 077
    {
      echo "# Generated by wg2raw - do not edit by hand, use: wg2raw settings"
      echo "[Interface]"
      echo "Address = ${LOCAL_TUN_IP}"
      if [[ "$ROLE" == "server" ]]; then echo "ListenPort = ${WG_PORT}"; fi
      echo "PrivateKey = ${priv}"
      echo "MTU = ${MTU}"
      echo "PostUp = iptables -t mangle -A ${mss}"
      echo "PostDown = iptables -t mangle -D ${mss}"
      if [[ "$ROLE" == "server" && "$NAT" == "y" && -n "$NIC" ]]; then
        echo "PostUp = iptables -t nat -A POSTROUTING -s ${TUN_NET} -o ${NIC} -j MASQUERADE"
        echo "PostDown = iptables -t nat -D POSTROUTING -s ${TUN_NET} -o ${NIC} -j MASQUERADE"
      fi
      echo
      echo "[Peer]"
      echo "PublicKey = ${PEER_PUB}"
      if [[ "$ROLE" == "client" ]]; then echo "Endpoint = 127.0.0.1:${WG_PORT}"; fi
      echo "AllowedIPs = ${TUN_NET}"
      echo "PersistentKeepalive = ${KEEPALIVE}"
    } > "$CFG_WG" )
  chmod 600 "$CFG_WG"
}

# The iptables DROP rule stops the kernel from answering udp2raw's fake TCP
# packets with RST (which makes the tunnel flap). The service adds it when it
# starts and removes it when it stops.
write_udp2raw_unit(){
  local ipt; ipt="$(command -v iptables)"
  local fix=""; if [[ "$FIXGRO" == "y" ]]; then fix=" --fix-gro"; fi
  local exec rule
  if [[ "$ROLE" == "server" ]]; then
    exec="${UDP2RAW_BIN} -s -l0.0.0.0:${EXT_PORT} -r127.0.0.1:${WG_PORT} -k \${UDP2RAW_KEY} --raw-mode faketcp${fix}"
    rule="INPUT -p tcp --dport ${EXT_PORT} -j DROP"
  else
    exec="${UDP2RAW_BIN} -c -l127.0.0.1:${WG_PORT} -r${SERVER_ADDR}:${EXT_PORT} -k \${UDP2RAW_KEY} --raw-mode faketcp${fix}"
    rule="INPUT -s ${SERVER_ADDR} -p tcp --sport ${EXT_PORT} -j DROP"
  fi
  cat > "$UNIT_UDP2RAW" <<EOF
# Generated by wg2raw
[Unit]
Description=udp2raw faketcp tunnel (wg2raw ${ROLE})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStartPre=/bin/sh -c '${ipt} -C ${rule} 2>/dev/null || ${ipt} -I ${rule}'
ExecStart=${exec}
ExecStopPost=-/bin/sh -c '${ipt} -D ${rule}'
Restart=always
RestartSec=2
StartLimitIntervalSec=0
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  mkdir -p "$OVR_DIR"
  cat > "${OVR_DIR}/override.conf" <<'EOF'
# Generated by wg2raw
[Unit]
After=udp2raw.service network-online.target
Wants=udp2raw.service network-online.target
EOF
}

write_offload_unit(){
  local eth; eth="$(command -v ethtool || true)"
  if [[ "$OFFLOAD" == "y" && -n "$NIC" && -n "$eth" ]]; then
    cat > "$UNIT_OFFLOAD" <<EOF
# Generated by wg2raw
[Unit]
Description=wg2raw: disable GRO/GSO/TSO on ${NIC}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${eth} -K ${NIC} gro off gso off tso off

[Install]
WantedBy=multi-user.target
EOF
  elif [[ -f "$UNIT_OFFLOAD" ]]; then
    # Turned off: remove the unit and switch offloads back on
    systemctl disable --now wg2raw-offload.service >/dev/null 2>&1 || true
    rm -f "$UNIT_OFFLOAD"
    if [[ -n "$NIC" && -n "$eth" ]]; then "$eth" -K "$NIC" gro on gso on tso on >/dev/null 2>&1 || true; fi
  fi
}

write_sysctl(){
  echo "net.ipv4.ip_forward=1" > "$SYSCTL_FILE"
  sysctl -q -p "$SYSCTL_FILE" >/dev/null 2>&1 || sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
}

stop_services(){
  systemctl stop wg-quick@wg0 >/dev/null 2>&1 || true
  systemctl stop udp2raw.service >/dev/null 2>&1 || true
  local s
  for s in udp2raw-server udp2raw-client; do   # leftovers from older scripts
    systemctl disable --now "$s.service" >/dev/null 2>&1 || true
  done
  pkill -x udp2raw >/dev/null 2>&1 || true
  ip link del wg0 >/dev/null 2>&1 || true
}

start_services(){
  systemctl daemon-reload
  if [[ -f "$UNIT_OFFLOAD" ]]; then
    systemctl enable wg2raw-offload.service >/dev/null 2>&1 || true
    systemctl restart wg2raw-offload.service || warn "Offload tuning failed (non-fatal)."
  fi
  systemctl enable udp2raw.service >/dev/null 2>&1 || true
  systemctl restart udp2raw.service
  systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
  systemctl restart wg-quick@wg0
}

verify_services(){
  sleep 2   # let udp2raw crash now if it is going to
  local s bad=0
  for s in udp2raw.service wg-quick@wg0; do
    if svc_active "$s"; then
      ok "Service running: $s"
    else
      warn "Service NOT running: $s"
      journalctl -u "$s" -n 20 --no-pager 2>/dev/null || true
      bad=1
    fi
  done
  if ip link show wg0 >/dev/null 2>&1; then ok "Interface wg0 is up"; else warn "Interface wg0 not found"; bad=1; fi
  ((bad == 0)) || die "Tunnel did not start. See the logs above (or: wg2raw logs)."
}

# Write every file from the saved settings and (re)start the tunnel
apply_config(){
  stop_services
  write_wg_conf
  write_udp2raw_unit
  write_offload_unit
  write_sysctl
  start_services
  verify_services
}

self_install(){
  [[ -f "$SELF" && "$SELF" != "$SELF_INSTALL_PATH" ]] || return 0
  install -m 755 "$SELF" "$SELF_INSTALL_PATH"
  ok "Command installed: run 'sudo wg2raw' any time to open this menu."
}

# =============================================================================
#  Connection code (server -> client). One line. Contains secrets!
# =============================================================================
make_client_code(){
  [[ -s "$CLIENT_KEY_FILE" ]] || die "Client key not found. Run the server install again."
  local payload
  payload="$(printf '%s\n' \
    "V=1" \
    "SERVER_ADDR=${SERVER_ADDR}" \
    "EXT_PORT=${EXT_PORT}" \
    "PASS=$(load_pass)" \
    "SERVER_PUB=$(cat "$PUB_FILE")" \
    "CLIENT_PRIV=$(cat "$CLIENT_KEY_FILE")" \
    "SERVER_TUN_IP=${LOCAL_TUN_IP}" \
    "CLIENT_TUN_IP=${PEER_TUN_IP}" \
    "TUN_NET=${TUN_NET}" \
    "MTU=${MTU}" \
    "KEEPALIVE=${KEEPALIVE}" \
    "FIXGRO=${FIXGRO}" | base64 -w0)"
  echo "${CODE_PREFIX}${payload}"
}

# Parse + validate a code into C_* variables. The content is never executed.
C_SERVER_ADDR=""; C_EXT_PORT=""; C_PASS=""; C_SERVER_PUB=""; C_CLIENT_PRIV=""
C_SERVER_TUN_IP=""; C_CLIENT_TUN_IP=""; C_TUN_NET=""; C_MTU=""; C_KEEPALIVE=""; C_FIXGRO=""
parse_client_code(){
  local code="$1" raw line k v
  code="${code//[[:space:]]/}"
  [[ "$code" == "$CODE_PREFIX"* ]] || die "This is not a wg2raw connection code (it must start with '${CODE_PREFIX}')."
  raw="$(printf '%s' "${code#"$CODE_PREFIX"}" | base64 -d 2>/dev/null)" || die "The code is damaged (copy the whole line)."
  [[ "$raw" == V=1$'\n'* ]] || die "The code is damaged or from another version (copy the whole line)."
  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in
      SERVER_ADDR)   C_SERVER_ADDR="$v" ;;
      EXT_PORT)      C_EXT_PORT="$v" ;;
      PASS)          C_PASS="$v" ;;
      SERVER_PUB)    C_SERVER_PUB="$v" ;;
      CLIENT_PRIV)   C_CLIENT_PRIV="$v" ;;
      SERVER_TUN_IP) C_SERVER_TUN_IP="$v" ;;
      CLIENT_TUN_IP) C_CLIENT_TUN_IP="$v" ;;
      TUN_NET)       C_TUN_NET="$v" ;;
      MTU)           C_MTU="$v" ;;
      KEEPALIVE)     C_KEEPALIVE="$v" ;;
      FIXGRO)        C_FIXGRO="$v" ;;
    esac
  done <<< "$raw"
  is_host "$C_SERVER_ADDR"        || die "Code: invalid server address."
  is_port "$C_EXT_PORT"           || die "Code: invalid port."
  is_safe_pass "$C_PASS"          || die "Code: invalid password."
  is_wg_key "$C_SERVER_PUB"       || die "Code: invalid server public key."
  is_wg_key "$C_CLIENT_PRIV"      || die "Code: invalid client private key."
  is_ipv4_cidr "$C_SERVER_TUN_IP" || die "Code: invalid server tunnel IP."
  is_ipv4_cidr "$C_CLIENT_TUN_IP" || die "Code: invalid client tunnel IP."
  is_ipv4_cidr "$C_TUN_NET"       || die "Code: invalid tunnel network."
  is_mtu "$C_MTU"                 || die "Code: invalid MTU."
  is_keepalive "$C_KEEPALIVE"     || die "Code: invalid keepalive."
  is_yn "$C_FIXGRO"               || die "Code: invalid fix-gro value."
}

print_code_box(){
  echo
  echo "${C_BOLD}${C_Y}  ┌─ CLIENT CONNECTION CODE ──────────────────────────────────────────┐${C_0}"
  echo "${C_Y}  │${C_0} Copy the whole line below. On the CLIENT machine run:"
  echo "${C_Y}  │${C_0}     sudo ./wg2raw.sh  ->  2) Install CLIENT  ->  paste it"
  echo "${C_Y}  │${C_0} ${C_R}It contains the tunnel password and a private key. Keep it secret.${C_0}"
  echo "${C_BOLD}${C_Y}  └───────────────────────────────────────────────────────────────────┘${C_0}"
  echo
  echo "$1"
  echo
}

# =============================================================================
#  Commands
# =============================================================================
cmd_install_server(){
  need_root
  title "Install / reconfigure SERVER (upstream side)"
  ensure_packages
  ensure_udp2raw
  load_state || true
  if [[ -n "$ROLE" && "$ROLE" != "server" ]]; then
    warn "This machine is currently configured as: ${ROLE}"
    local sw; ask_yn sw "Reconfigure it as SERVER?" "n"
    [[ "$sw" == "y" ]] || return 0
  fi
  if [[ "$ROLE" != "server" ]]; then
    LOCAL_TUN_IP="$SERVER_TUN_IP_DEFAULT"; PEER_TUN_IP="$CLIENT_TUN_IP_DEFAULT"; SERVER_ADDR=""
  fi
  ROLE="server"

  local pass; pass="$(load_pass)"; [[ -n "$pass" ]] || pass="$(random_pass)"
  if [[ -z "$SERVER_ADDR" ]]; then SERVER_ADDR="$(detect_public_ip)"; fi

  echo "  ${C_DIM}Press Enter to accept the value in [brackets].${C_0}"
  echo
  ask SERVER_ADDR "Public IP or domain of THIS server" "$SERVER_ADDR" is_host
  ask EXT_PORT    "udp2raw TCP port (clients connect here)" "$EXT_PORT" is_port
  ask pass        "Tunnel password (A-Z a-z 0-9 . _ -, 6+ chars)" "$pass" is_safe_pass

  local adv; ask_yn adv "Change advanced settings (tunnel IPs, MTU, NAT...)?" "n"
  if [[ "$adv" == "y" ]]; then
    ask TUN_NET      "Tunnel network" "$TUN_NET" is_ipv4_cidr
    ask LOCAL_TUN_IP "Server tunnel IP" "$LOCAL_TUN_IP" is_ipv4_cidr
    ask PEER_TUN_IP  "Client tunnel IP" "$PEER_TUN_IP" is_ipv4_cidr
    ask WG_PORT      "WireGuard local UDP port" "$WG_PORT" is_port
    ask MTU          "WireGuard MTU (900-1500)" "$MTU" is_mtu
    ask KEEPALIVE    "PersistentKeepalive seconds (0-60)" "$KEEPALIVE" is_keepalive
    ask_yn FIXGRO    "Use udp2raw --fix-gro" "$FIXGRO"
    ask_yn OFFLOAD   "Disable GRO/GSO/TSO on the network card (only for 'huge packet' warnings)" "$OFFLOAD"
    ask_yn NAT       "Enable NAT (tunnel traffic can reach the internet through this server)" "$NAT"
  fi
  NIC="$(default_nic)"

  title "Summary"
  kv "Role:" "SERVER"
  kv "Public address:" "${SERVER_ADDR}:${EXT_PORT}/tcp"
  kv "Tunnel:" "${LOCAL_TUN_IP} <-> ${PEER_TUN_IP}"
  kv "MTU / keepalive:" "${MTU} / ${KEEPALIVE}s"
  kv "fix-gro / offload:" "${FIXGRO} / ${OFFLOAD}"
  kv "NAT:" "${NAT}${NIC:+ (via ${NIC})}"
  echo
  local go; ask_yn go "Apply now?" "y"
  [[ "$go" == "y" ]] || { warn "Cancelled."; return 0; }

  stop_services
  if tcp_port_in_use "$EXT_PORT"; then
    ss -lntp 2>/dev/null | grep -E "[:.]${EXT_PORT}[[:space:]]" || true
    die "TCP port ${EXT_PORT} is used by another program. Choose another port (e.g. 8443)."
  fi

  gen_keys_if_missing
  # The client's keys are made here, so the client only needs one code.
  if [[ ! -s "$CLIENT_KEY_FILE" ]]; then
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    ( umask 077; wg genkey > "$CLIENT_KEY_FILE" )
  fi
  PEER_PUB="$(wg pubkey < "$CLIENT_KEY_FILE")"

  save_pass "$pass"
  save_state
  apply_config
  self_install

  ok "Server is ready."
  print_code_box "$(make_client_code)"
  info "Show this code again any time with: sudo wg2raw code"
}

cmd_install_client(){
  need_root
  title "Install / reconfigure CLIENT (local side)"
  ensure_packages
  ensure_udp2raw
  load_state || true
  if [[ "$ROLE" == "server" ]]; then
    warn "This machine is currently configured as: server"
    local sw; ask_yn sw "Reconfigure it as CLIENT?" "n"
    [[ "$sw" == "y" ]] || return 0
  fi

  local code="${1:-}"
  if [[ -z "$code" ]]; then
    echo "  Paste the connection code printed by the server"
    echo "  ${C_DIM}(on the server: sudo wg2raw code)${C_0}"
    echo
    read -r -p "  Code: " code || die "Input closed."
  fi
  parse_client_code "$code"
  ok "Code is valid."

  ROLE="client"
  SERVER_ADDR="$C_SERVER_ADDR"; EXT_PORT="$C_EXT_PORT"
  LOCAL_TUN_IP="$C_CLIENT_TUN_IP"; PEER_TUN_IP="$C_SERVER_TUN_IP"; TUN_NET="$C_TUN_NET"
  PEER_PUB="$C_SERVER_PUB"; MTU="$C_MTU"; KEEPALIVE="$C_KEEPALIVE"; FIXGRO="$C_FIXGRO"
  NAT="n"; NIC="$(default_nic)"

  local adv; ask_yn adv "Change local settings (local UDP port, offload)?" "n"
  if [[ "$adv" == "y" ]]; then
    ask WG_PORT    "Local UDP port between WireGuard and udp2raw" "$WG_PORT" is_port
    ask_yn OFFLOAD "Disable GRO/GSO/TSO on the network card (only for 'huge packet' warnings)" "$OFFLOAD"
  fi

  title "Summary"
  kv "Role:" "CLIENT"
  kv "Server:" "${SERVER_ADDR}:${EXT_PORT}/tcp"
  kv "Tunnel:" "${LOCAL_TUN_IP} <-> ${PEER_TUN_IP}"
  kv "MTU / keepalive:" "${MTU} / ${KEEPALIVE}s"
  kv "fix-gro / offload:" "${FIXGRO} / ${OFFLOAD}"
  echo
  local go; ask_yn go "Apply now?" "y"
  [[ "$go" == "y" ]] || { warn "Cancelled."; return 0; }

  stop_services
  if udp_port_in_use "$WG_PORT"; then
    ss -lnup 2>/dev/null | grep -E "[:.]${WG_PORT}[[:space:]]" || true
    die "UDP port ${WG_PORT} is used by another program. Choose another one in 'local settings'."
  fi

  ( umask 077; mkdir -p "$WG_DIR"
    printf '%s\n' "$C_CLIENT_PRIV" > "$PRIV_FILE"
    wg pubkey < "$PRIV_FILE" > "$PUB_FILE" )
  rm -f "$CLIENT_KEY_FILE"

  save_pass "$C_PASS"
  save_state
  apply_config
  self_install

  info "Waiting for the WireGuard handshake..."
  local i
  for ((i = 0; i < 15; i++)); do
    if [[ "$(handshake_age)" != "never" ]]; then
      ok "Handshake OK - the tunnel is connected."
      ping_peer
      return 0
    fi
    sleep 1
  done
  warn "No handshake yet. Check that the server is running and TCP ${EXT_PORT} is reachable from here."
  warn "Then run: sudo wg2raw status"
}

# Seconds since the last handshake, or "never"
handshake_age(){
  local ts
  ts="$(wg show wg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')"
  if [[ "$ts" =~ ^[0-9]+$ && "$ts" != "0" ]]; then echo $(( $(date +%s) - ts )); else echo "never"; fi
}

ping_peer(){
  local ip="${PEER_TUN_IP%/*}" out avg
  [[ -n "$ip" ]] || return 0
  if ! have ping; then kv "Peer ping:" "ping is not installed"; return 0; fi
  if out="$(ping -c 3 -W 2 -q "$ip" 2>/dev/null)"; then
    avg="$(awk -F'/' '/rtt|round-trip/{print $5}' <<< "$out")"
    kv "Peer ping:" "${C_G}${ip} OK${C_0} (avg ${avg:-?} ms)"
  else
    kv "Peer ping:" "${C_R}${ip} no reply${C_0}"
  fi
}

human_bytes(){ if have numfmt; then numfmt --to=iec --suffix=B "$1"; else echo "${1}B"; fi; }

svc_badge(){ if svc_active "$1"; then echo "${C_G}● running${C_0}"; else echo "${C_R}○ stopped${C_0}"; fi; }

cmd_status(){
  need_root
  title "Status"
  if ! load_state; then warn "wg2raw is not installed on this machine yet."; return 0; fi

  kv "Role:" "${ROLE^^}"
  if [[ "$ROLE" == "server" ]]; then kv "Listening on:" "${SERVER_ADDR}:${EXT_PORT}/tcp"
  else kv "Server:" "${SERVER_ADDR}:${EXT_PORT}/tcp"; fi
  kv "Tunnel:" "${LOCAL_TUN_IP} <-> ${PEER_TUN_IP}"
  kv "MTU / keepalive:" "${MTU} / ${KEEPALIVE}s"
  echo
  kv "udp2raw:" "$(svc_badge udp2raw.service)"
  kv "WireGuard (wg0):" "$(svc_badge wg-quick@wg0)"

  local age; age="$(handshake_age)"
  if [[ "$age" == "never" ]]; then kv "Last handshake:" "${C_R}never${C_0}"
  elif ((age > 180)); then kv "Last handshake:" "${C_Y}${age}s ago (stale)${C_0}"
  else kv "Last handshake:" "${C_G}${age}s ago${C_0}"; fi

  local rx="" tx=""
  read -r _ rx tx < <(wg show wg0 transfer 2>/dev/null | head -1) || true
  if [[ -n "$rx" ]]; then kv "Traffic:" "rx $(human_bytes "$rx") / tx $(human_bytes "$tx")"; fi

  ping_peer

  local huge
  huge="$(journalctl -u udp2raw.service --since '10 min ago' --no-pager 2>/dev/null | grep -ci 'huge packet' || true)"
  if [[ "${huge:-0}" -gt 0 ]]; then
    kv "Huge packets:" "${C_Y}${huge} warnings in the last 10 min${C_0}"
    echo
    warn "Tip: lower the MTU to 1200 in Settings, or turn on 'Disable NIC offloads' there."
  else
    kv "Huge packets:" "none in the last 10 min"
  fi
}

cmd_code(){
  need_root
  load_state || die "Not installed."
  [[ "$ROLE" == "server" ]] || die "The connection code is only available on the SERVER."
  print_code_box "$(make_client_code)"
}

cmd_logs(){
  local what="${1:-}"
  if [[ -z "$what" ]]; then
    title "Logs"
    echo "  1) udp2raw    (last 100 lines)"
    echo "  2) WireGuard  (last 100 lines + wg show)"
    echo "  3) udp2raw live  (Ctrl+C to stop)"
    echo "  0) Back"
    echo
    read -r -p "  Choose: " what || return 0
  fi
  case "$what" in
    1|udp2raw) journalctl -u udp2raw.service -n 100 --no-pager ;;
    2|wg)      journalctl -u wg-quick@wg0 -n 100 --no-pager; echo; wg show 2>/dev/null || true ;;
    3|follow)  journalctl -u udp2raw.service -f -n 20 || true ;;
    *) return 0 ;;
  esac
}

cmd_restart(){
  need_root
  load_state || die "Not installed."
  info "Restarting tunnel..."
  systemctl restart udp2raw.service
  systemctl restart wg-quick@wg0
  verify_services
}

cmd_settings(){
  need_root
  load_state || die "Not installed."
  local c
  while true; do
    title "Settings  (${ROLE^^})"
    echo "  1) MTU                   ${C_DIM}[${MTU}]${C_0}"
    echo "  2) Keepalive             ${C_DIM}[${KEEPALIVE}s]${C_0}"
    echo "  3) udp2raw --fix-gro     ${C_DIM}[${FIXGRO}]${C_0}"
    echo "  4) Disable NIC offloads  ${C_DIM}[${OFFLOAD}]${C_0}"
    if [[ "$ROLE" == "server" ]]; then echo "  5) NAT to internet       ${C_DIM}[${NAT}]${C_0}"; fi
    echo
    echo "  9) Save & apply"
    echo "  0) Back without saving"
    echo
    read -r -p "  Choose: " c || return 0
    case "$c" in
      1) ask MTU "WireGuard MTU (900-1500; try 1200 for 'huge packet' warnings)" "$MTU" is_mtu ;;
      2) ask KEEPALIVE "PersistentKeepalive seconds (0-60)" "$KEEPALIVE" is_keepalive ;;
      3) ask_yn FIXGRO "Use --fix-gro" "$FIXGRO" ;;
      4) ask_yn OFFLOAD "Disable GRO/GSO/TSO" "$OFFLOAD" ;;
      5) if [[ "$ROLE" == "server" ]]; then ask_yn NAT "Enable NAT" "$NAT"; fi ;;
      9)
        NIC="$(default_nic)"
        save_state
        apply_config
        ok "Settings applied."
        if [[ "$ROLE" == "server" ]]; then
          info "If you changed MTU / keepalive / fix-gro, import the new code on the client too (wg2raw code)."
        fi
        return 0 ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

cmd_uninstall(){
  need_root
  title "Uninstall"
  local go; ask_yn go "Remove the wg2raw tunnel from this machine?" "n"
  [[ "$go" == "y" ]] || return 0

  load_state || true
  stop_services
  systemctl disable udp2raw.service wg-quick@wg0 wg2raw-offload.service >/dev/null 2>&1 || true
  if [[ "$OFFLOAD" == "y" && -n "$NIC" ]] && have ethtool; then
    ethtool -K "$NIC" gro on gso on tso on >/dev/null 2>&1 || true
  fi
  rm -f "$UNIT_UDP2RAW" "$UNIT_OFFLOAD" "$SYSCTL_FILE" "$CFG_WG"
  rm -rf "$OVR_DIR" /etc/udp2raw
  systemctl daemon-reload
  ok "Services and configs removed."

  local a
  ask_yn a "Also delete WireGuard keys and saved settings?" "y"
  if [[ "$a" == "y" ]]; then rm -f "$PRIV_FILE" "$PUB_FILE"; rm -rf "$STATE_DIR"; ok "Keys and settings deleted."; fi
  ask_yn a "Also delete the udp2raw binary?" "n"
  if [[ "$a" == "y" ]]; then rm -f "$UDP2RAW_BIN"; ok "udp2raw binary deleted."; fi
  ask_yn a "Also delete the 'wg2raw' command?" "n"
  if [[ "$a" == "y" ]]; then rm -f "$SELF_INSTALL_PATH"; ok "wg2raw command deleted."; fi
  ok "Uninstall finished."
}

cmd_help(){
  cat <<EOF
wg2raw ${WG2RAW_VERSION} - WireGuard over udp2raw (faketcp)

Usage: sudo wg2raw [command]

  (no command)            open the interactive menu
  install-server          set up this machine as the SERVER (upstream side)
  install-client [code]   set up this machine as the CLIENT (local side)
  code                    show the client connection code (server only)
  status                  services, handshake, traffic, ping
  logs [udp2raw|wg|follow]
  restart                 restart udp2raw + WireGuard
  settings                change MTU, keepalive, fix-gro, offload, NAT
  install-udp2raw         download / install the udp2raw binary
  uninstall               remove everything
  help                    this help
EOF
}

# =============================================================================
#  Menu
# =============================================================================
# Each menu action runs in a child process, so an error inside an action
# prints its message and returns to the menu instead of closing the program.
run_action(){
  if [[ -f "$SELF" ]]; then
    bash "$SELF" "$@" || warn "Action finished with an error."
  else
    dispatch "$@"
  fi
  pause
}

draw_header(){
  if [[ -t 1 ]]; then clear; fi
  echo "${C_BOLD}${C_C}"
  echo "  ╦ ╦╔═╗╔═╗╦═╗╔═╗╦ ╦"
  echo "  ║║║║ ╦╔═╝╠╦╝╠═╣║║║"
  echo "  ╚╩╝╚═╝╚═╝╩╚═╩ ╩╚╩╝   v${WG2RAW_VERSION}"
  echo "${C_0}  ${C_DIM}WireGuard over udp2raw (faketcp)${C_0}"
  echo
  ROLE=""
  if load_state; then
    printf "  Role: %-7s  udp2raw: %s   wg0: %s\n" "${ROLE^^}" "$(svc_badge udp2raw.service)" "$(svc_badge wg-quick@wg0)"
  else
    echo "  ${C_Y}Not installed yet${C_0} - start with 1 (server) or 2 (client)."
  fi
  echo "  ───────────────────────────────────────────────"
}

menu(){
  trap ':' INT   # Ctrl+C stops the running action (e.g. live logs), not the menu
  local c
  while true; do
    draw_header
    echo "   1) Install / reconfigure SERVER  (upstream side)"
    echo "   2) Install / reconfigure CLIENT  (local side)"
    echo
    echo "   3) Status"
    echo "   4) Show client connection code   ${C_DIM}(server)${C_0}"
    echo "   5) Logs"
    echo "   6) Restart tunnel"
    echo "   7) Settings (MTU, keepalive, NAT...)"
    echo
    echo "   8) Install / update udp2raw binary"
    echo "   9) Uninstall"
    echo "   0) Exit"
    echo
    read -r -p "  Choose: " c || exit 0
    case "$c" in
      1) run_action install-server ;;
      2) run_action install-client ;;
      3) run_action status ;;
      4) run_action code ;;
      5) run_action logs ;;
      6) run_action restart ;;
      7) run_action settings ;;
      8) run_action install-udp2raw ;;
      9) run_action uninstall ;;
      0|q|exit) exit 0 ;;
      *) ;;
    esac
  done
}

dispatch(){
  local cmd="${1:-menu}"
  shift || true
  case "$cmd" in
    menu)                  need_root; menu ;;
    install-server|server) cmd_install_server ;;
    install-client|client) cmd_install_client "${1:-}" ;;
    code)                  cmd_code ;;
    status)                cmd_status ;;
    logs)                  cmd_logs "${1:-}" ;;
    restart)               cmd_restart ;;
    settings)              cmd_settings ;;
    install-udp2raw)       cmd_install_udp2raw ;;
    uninstall)             cmd_uninstall ;;
    help|-h|--help)        cmd_help ;;
    version|-v|--version)  echo "wg2raw ${WG2RAW_VERSION}" ;;
    *) cmd_help; die "Unknown command: $cmd" ;;
  esac
}

# Tests can source this file without running anything
if [[ "${WG2RAW_NO_MAIN:-0}" != "1" ]]; then
  dispatch "$@"
fi
