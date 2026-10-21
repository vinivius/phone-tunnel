#!/usr/bin/env bash
# phone-tunnel (portable): macOS + Linux client, built on sing-box. Same phone side as the
# Linux installer: sing-box (Shadowsocks AEAD, TCP+UDP) in Termux, started over a restricted SSH key.
#
#   ./phone-tunnel.sh setup    one-time: tunnel key, pinned phone host key, phone side (no sudo)
#   ./phone-tunnel.sh proxy    Docker mode: SOCKS5 + HTTP proxy on 127.0.0.1:1080 (no install)
#   ./phone-tunnel.sh tun      native mode: whole device (TCP+UDP+DNS, IPv4+IPv6) via a TUN (sudo)
#
# Runs in the foreground; Ctrl-C stops it and stops the server on the phone.
# Env: PHONE (default: your default gateway), PROXY_PORT (1080), PT_DOCKER_NET (docker --network),
#      SS_PORT at setup (8389; give each computer its own port to use the phone at the same time)
set -euo pipefail   # bash 3.2 compatible (macOS): no associative arrays, no mapfile

HERE="$(cd "$(dirname "$0")" && pwd)"
CONF="${PT_CONF:-$HOME/.config/phone-tunnel}"
PROXY_PORT="${PROXY_PORT:-1080}"
CIPHER=chacha20-ietf-poly1305

SB_VERSION=1.14.3
SB_IMAGE="ghcr.io/sagernet/sing-box:v$SB_VERSION@sha256:80c639ba467885b28511fb7c980565c2d30a8752f778e7bc8abdbc91fbfd95ec"
sb_sha256() {   # pinned from the GitHub release asset digests
  case "$1" in
    darwin-amd64) echo 6d002b74d03b478547349cc10af89e007868596e5aa931816d45da9f544715a9 ;;
    darwin-arm64) echo 0360ce634a04c26a6b4fd957517987bb4f6c8950f63435ce3c5af2fcae5860c5 ;;
    linux-amd64)  echo e2bdf179c15a3652955dc44867e33ca0965c9c9b91b34267dcc5a5d639a5feee ;;
    linux-arm64)  echo 29dae24d76bea3bc62d07dd3e60cfc12003de7debbd6b768df9be9c68360174e ;;
  esac
}

die() { echo "phone-tunnel: $*" >&2; exit 1; }
confirm() { local a; read -rp "$1 [y/N] " a; [[ "$a" == [yY] ]]; }

gateway() {
  if [[ "$(uname)" == Darwin ]]; then route -n get default 2>/dev/null | awk '/gateway:/ {print $2; exit}'
  else ip -4 route show default | awk '/^default via/ {print $3; exit}'; fi
}
PHONE="${PHONE:-$(gateway)}"
[[ -n "$PHONE" ]] || die "no default gateway; connect to the phone's hotspot (or set PHONE=)"

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }

phone_ssh() {  # dedicated key + pinned host key; the phone only lets this key run phone-tunnel-ctl
  # shellcheck source=/dev/null
  source "$CONF/config"
  ssh -i "$CONF/id_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes \
      -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$CONF/known_hosts" \
      -o HostKeyAlias=phone-tunnel -o ConnectTimeout=10 \
      -p "$PHONE_PORT" "$PHONE_USER@$PHONE" "$@"
}

# ---------------------------------------------------------------------------------------------
cmd_setup() {
  # 8389: the Linux installer uses 8388, so both can use the phone at the same time
  local port=8022 ss_port="${SS_PORT:-8389}" user scan fp_scan fp_phone
  command -v ssh >/dev/null && command -v ssh-keyscan >/dev/null || die "needs the OpenSSH client"
  user="$(ssh -n -p "$port" -o ConnectTimeout=10 -o BatchMode=yes "$PHONE" whoami)" \
    || die "can't ssh to $PHONE:$port with your normal key; set that up first (README)"

  scan="$(ssh-keyscan -t ed25519 -p "$port" "$PHONE" 2>/dev/null | awk '$2=="ssh-ed25519"')"
  [[ -n "$scan" ]] || die "could not read the phone's ed25519 host key"
  fp_scan="$(ssh-keygen -lf - <<<"$scan" | awk '{print $2}')"
  fp_phone="$(ssh -n -p "$port" -o BatchMode=yes "$PHONE" \
    'ssh-keygen -lf $PREFIX/etc/ssh/ssh_host_ed25519_key.pub' | awk '{print $2}')"
  [[ "$fp_scan" == "$fp_phone" ]] || die "host key mismatch (scan $fp_scan vs phone $fp_phone), aborting"

  cat <<EOF

  phone       $user@$PHONE:$port
  host key    $fp_scan  (matches what the phone reports for itself)

  This will create, on this computer:
    - $CONF/  (new SSH key for the tunnel, pinned phone host key, config)
  and on the phone (Termux):
    - sing-box, if not installed (asks first)
    - ~/bin/phone-tunnel-ctl
    - one restricted line in ~/.ssh/authorized_keys (tunnel key, can only run phone-tunnel-ctl)

EOF
  confirm "Proceed?" || die "aborted, nothing changed"

  mkdir -p "$CONF"; chmod 700 "$CONF"
  [[ -f "$CONF/id_ed25519" ]] || ssh-keygen -q -t ed25519 -N '' -C phone-tunnel -f "$CONF/id_ed25519"
  echo "phone-tunnel ${scan#* }" >"$CONF/known_hosts"
  printf 'PHONE_USER=%s\nPHONE_PORT=%s\nSS_PORT=%s\n' "$user" "$port" "$ss_port" >"$CONF/config"
  chmod 600 "$CONF/known_hosts" "$CONF/config"

  PHONE="$PHONE" PHONE_PORT="$port" PHONE_USER="$user" "$HERE/../setup-phone.sh" "$CONF/id_ed25519.pub"
  [[ "$(phone_ssh id 2>&1)" == denied ]] || die "tunnel key is NOT restricted on the phone"
  echo "setup done: tunnel key works and can only run phone-tunnel-ctl"
}

# ---------------------------------------------------------------------------------------------
# sing-box config. $1 = proxy|tun, $2 = Shadowsocks key, $3 = listen address (proxy mode)
gen_config() {
  local mode="$1" key="$2" listen="${3:-127.0.0.1}" inbound route
  # shellcheck source=/dev/null
  source "$CONF/config"
  if [[ "$mode" == proxy ]]; then
    inbound="{ \"type\": \"mixed\", \"tag\": \"in\", \"listen\": \"$listen\", \"listen_port\": $PROXY_PORT }"
    route='"final": "phone"'
  else
    # strict_route: no traffic may bypass the TUN; IPv6 is captured too, so nothing leaks around it
    inbound='{ "type": "tun", "tag": "in", "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
               "auto_route": true, "strict_route": true }'
    route='"auto_detect_interface": true,
      "rules": [
        { "action": "sniff" },
        { "protocol": "dns", "action": "hijack-dns" },
        { "ip_is_private": true, "outbound": "direct" }
      ],
      "final": "phone"'
  fi
  cat <<EOF
{
  "log": { "level": "warn" },
  "dns": {
    "servers": [ { "type": "udp", "tag": "remote", "server": "1.1.1.1", "detour": "phone" } ],
    "final": "remote"
  },
  "inbounds": [ $inbound ],
  "outbounds": [
    { "type": "shadowsocks", "tag": "phone", "server": "$PHONE", "server_port": $SS_PORT,
      "method": "$CIPHER", "password": "$key" },
    { "type": "direct", "tag": "direct" }
  ],
  "route": { $route }
}
EOF
}

# start the Shadowsocks server on the phone with a fresh per-session key; echo the key
start_phone() {
  local key; key="$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')"
  # shellcheck source=/dev/null
  source "$CONF/config"
  printf '%s\n' "$key" | phone_ssh start "$SS_PORT" watchdog >&2 || die "phone refused start (host key / tunnel key / sshd?)"
  echo "$key"
}

# temp dir for the config (it contains the session key)
RUNDIR="" HB_PID=""
# check in with the phone every 60 s (its watchdog stops the server after 3 min of silence)
heartbeat() { while sleep 60; do phone_ssh status "$SS_PORT" >/dev/null 2>&1; done & HB_PID=$!; }
cleanup() {
  set +e
  [[ -n "$HB_PID" ]] && kill "$HB_PID" 2>/dev/null
  [[ -n "$RUNDIR" ]] && rm -rf "$RUNDIR"
  docker rm -f phone-tunnel-proxy >/dev/null 2>&1   # proxy mode: never leave the container behind
  phone_ssh stop "$SS_PORT" >/dev/null 2>&1 && echo "phone side stopped"
}

cmd_proxy() {
  [[ -f "$CONF/config" ]] || die "run './phone-tunnel.sh setup' first"
  command -v docker >/dev/null || die "Docker is not installed"
  local key net="${PT_DOCKER_NET:-}" listen=0.0.0.0 publish=(-p "127.0.0.1:$PROXY_PORT:$PROXY_PORT")
  [[ "$net" == host ]] && { listen=127.0.0.1; publish=(); }
  key="$(start_phone)"
  RUNDIR="$(mktemp -d)"; trap cleanup EXIT; trap 'exit 0' INT TERM
  gen_config proxy "$key" "$listen" >"$RUNDIR/config.json"; chmod 644 "$RUNDIR/config.json"
  heartbeat
  echo "proxy: SOCKS5 + HTTP on 127.0.0.1:$PROXY_PORT (set it as your system proxy). Ctrl-C to stop."
  docker run --rm --name phone-tunnel-proxy ${net:+--network "$net"} ${publish[@]+"${publish[@]}"} \
    -v "$RUNDIR:/etc/sing-box:ro" "$SB_IMAGE" run -c /etc/sing-box/config.json
}

# native sing-box: PATH, then $CONF/bin; otherwise offer the pinned, checksummed download
singbox_bin() {
  local os arch plat tgz tmp sum
  if command -v sing-box >/dev/null; then command -v sing-box; return; fi
  [[ -x "$CONF/bin/sing-box" ]] && { echo "$CONF/bin/sing-box"; return; }
  case "$(uname)" in Darwin) os=darwin ;; Linux) os=linux ;; *) die "unsupported OS" ;; esac
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) die "unsupported CPU" ;; esac
  plat="$os-$arch"; tgz="sing-box-$SB_VERSION-$plat.tar.gz"
  {
    echo "sing-box is needed and not installed:"
    echo "  - sing-box $SB_VERSION ($plat) from github.com/SagerNet/sing-box/releases,"
    echo "    checked against a pinned SHA-256, saved to $CONF/bin/sing-box"
  } >&2
  confirm "Download it now?" >&2 || die "aborted, nothing changed"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/$tgz" "https://github.com/SagerNet/sing-box/releases/download/v$SB_VERSION/$tgz"
  sum="$(sha256 "$tmp/$tgz")"
  [[ "$sum" == "$(sb_sha256 "$plat")" ]] || { rm -rf "$tmp"; die "sing-box checksum MISMATCH, aborting"; }
  tar -xzf "$tmp/$tgz" -C "$tmp"
  mkdir -p "$CONF/bin"; cp "$tmp/sing-box-$SB_VERSION-$plat/sing-box" "$CONF/bin/sing-box"; chmod 755 "$CONF/bin/sing-box"
  rm -rf "$tmp"
  echo "sing-box $SB_VERSION verified (sha256 ok)" >&2
  echo "$CONF/bin/sing-box"
}

cmd_tun() {
  [[ -f "$CONF/config" ]] || die "run './phone-tunnel.sh setup' first"
  local sb key
  sb="$(singbox_bin)"
  sudo -v || die "TUN mode needs sudo"
  key="$(start_phone)"
  RUNDIR="$(mktemp -d)"; trap cleanup EXIT; trap 'exit 0' INT TERM
  gen_config tun "$key" >"$RUNDIR/config.json"; chmod 600 "$RUNDIR/config.json"
  "$sb" check -c "$RUNDIR/config.json" || die "generated config failed sing-box check"
  heartbeat
  echo "tun: whole device now goes through the phone (TCP+UDP+DNS). Ctrl-C to stop."
  sudo "$sb" run -c "$RUNDIR/config.json"
}

case "${1:-}" in
  setup) cmd_setup ;;
  proxy) cmd_proxy ;;
  tun)   cmd_tun ;;
  config) gen_config "${2:-tun}" "${3:-0123456789abcdef0123456789abcdef0123456789abcdef}" ;;  # debug: print a config
  *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
