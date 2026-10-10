#!/usr/bin/env bash
# Route ALL local traffic (TCP + UDP + DNS) out through the phone.
#   phone:  gost SOCKS5 server (UDP ASSOCIATE) inside Termux, started over SSH
#   laptop: tun2socks on tun0 + default route via tun0
# Connections are opened by the phone itself (from inside Termux).
#
# Usage: USER_=u0_a123 ./phone-tunnel.sh   # foreground; Ctrl-C tears everything down
set -euo pipefail

PHONE="${PHONE:-$(ip -4 route show default | awk '/default/ {print $3; exit}')}"
PORT="${PORT:-8022}"
USER_="${USER_:?set USER_ to your Termux username (run whoami in Termux)}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
TUN=tun0
DNS_SERVERS=(1.1.1.1 8.8.8.8)
IFACE="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
TUN2SOCKS="$(command -v tun2socks || echo "$(dirname "$0")/bin/tun2socks")"

[[ -x "$TUN2SOCKS" ]] || { echo "tun2socks not found (expected in PATH or $TUN2SOCKS)"; exit 1; }

SSH=(ssh -p "$PORT" -o ConnectTimeout=10 -o ServerAliveInterval=15 "$USER_@$PHONE")
PASS="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"   # per-session SOCKS auth

echo "Phone: $USER_@$PHONE:$PORT  socks :$SOCKS_PORT  (iface $IFACE)"
sudo -v

v6_prev="$(sysctl -n "net.ipv6.conf.$IFACE.disable_ipv6")"
T2S_PID=""
cleanup() {
  set +e
  [[ -n "$T2S_PID" ]] && kill "$T2S_PID" 2>/dev/null
  sudo ip link del "$TUN" 2>/dev/null
  sudo resolvectl default-route "$IFACE" true 2>/dev/null
  sudo sysctl -q "net.ipv6.conf.$IFACE.disable_ipv6=$v6_prev"
  "${SSH[@]}" 'kill $(cat $PREFIX/tmp/gost.pid) 2>/dev/null; termux-wake-unlock' 2>/dev/null
  echo "Tunnel down, routing/IPv6 restored."
}
trap cleanup EXIT INT TERM

# 1. Phone: start gost (IPv4 only, password-protected), keep Termux awake
# (no pkill -f here: the pattern would match this very shell's command line and kill it)
"${SSH[@]}" "kill \$(cat \$PREFIX/tmp/gost.pid 2>/dev/null) 2>/dev/null; termux-wake-lock;
  nohup gost -L 'socks5://p:$PASS@0.0.0.0:$SOCKS_PORT' >\$PREFIX/tmp/gost.log 2>&1 </dev/null &
  echo \$! >\$PREFIX/tmp/gost.pid"
sleep 1
timeout 5 bash -c "</dev/tcp/$PHONE/$SOCKS_PORT" || { echo "gost not listening on phone"; exit 1; }

# 2. Laptop: tun device + tun2socks
sudo ip tuntap add mode tun dev "$TUN" user "$USER"
# needs an address, or systemd-resolved won't give tun0 a DNS scope and all lookups fail
sudo ip addr add 198.18.0.1/15 dev "$TUN"
sudo ip link set "$TUN" up
"$TUN2SOCKS" --device "$TUN" --interface "$IFACE" --loglevel warn \
  --proxy "socks5://p:$PASS@$PHONE:$SOCKS_PORT" &
T2S_PID=$!
sleep 1

# 3. Routing: default via tun0 wins (lower metric); the hotspot /24 link route stays
#    more specific, so traffic to the phone itself (incl. the SOCKS connection) goes direct.
sudo ip route add default dev "$TUN" metric 50
sudo sysctl -q "net.ipv6.conf.$IFACE.disable_ipv6=1"     # no IPv6 leak around the tunnel
sudo resolvectl dns "$TUN" "${DNS_SERVERS[@]}"
sudo resolvectl domain "$TUN" '~.'                          # all DNS via tun0
sudo resolvectl default-route "$IFACE" false 2>/dev/null || true

echo "Tunnel up (TCP+UDP). Ctrl-C to stop."
wait "$T2S_PID"
