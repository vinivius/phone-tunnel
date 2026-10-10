#!/usr/bin/env bash
# Route all local TCP + DNS traffic through the phone's Termux sshd via sshuttle.
# Connections are opened by the phone itself (from inside Termux).
#
# Usage: USER_=u0_a123 ./phone-tunnel-tcp.sh   # foreground; Ctrl-C to stop and restore everything
#        PHONE=192.168.43.1 PORT=8022 USER_=u0_a123 ./phone-tunnel-tcp.sh
set -euo pipefail

# Default: the hotspot gateway is the phone
PHONE="${PHONE:-$(ip -4 route show default | awk '/default/ {print $3; exit}')}"
PORT="${PORT:-8022}"
USER_="${USER_:?set USER_ to your Termux username (run whoami in Termux)}"
IFACE="$(ip -4 route show default | awk '/default/ {print $5; exit}')"

# Local stuff that must NOT go through the tunnel
EXCLUDES=(
  "$(ip -4 route show dev "$IFACE" scope link | awk '{print $1; exit}')"  # hotspot LAN
  172.16.0.0/12      # docker bridges
  192.168.122.0/24   # libvirt
  10.0.3.0/24        # lxc
  100.64.0.0/10      # tailscale
)

SSH_CMD="ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ConnectTimeout=10"

command -v sshuttle >/dev/null || { echo "Installing sshuttle..."; sudo apt-get install -y sshuttle; }

echo "Phone: $USER_@$PHONE:$PORT  (iface $IFACE)"
$SSH_CMD -p "$PORT" "$USER_@$PHONE" 'command -v python3 >/dev/null || pkg install -y python; termux-wake-lock' \
  || { echo "Can't reach phone sshd"; exit 1; }

# sshuttle only tunnels IPv4 here; disable IPv6 on the hotspot iface so nothing leaks around it
v6_prev="$(sysctl -n "net.ipv6.conf.$IFACE.disable_ipv6")"
cleanup() {
  sudo sysctl -q "net.ipv6.conf.$IFACE.disable_ipv6=$v6_prev"
  $SSH_CMD -p "$PORT" "$USER_@$PHONE" termux-wake-unlock 2>/dev/null || true
  echo "Tunnel down, IPv6 restored."
}
trap cleanup EXIT
sudo sysctl -q "net.ipv6.conf.$IFACE.disable_ipv6=1"

x_args=(); for n in "${EXCLUDES[@]}"; do x_args+=(-x "$n"); done

echo "Tunnel up. Ctrl-C to stop."
sshuttle --dns -r "$USER_@$PHONE:$PORT" -e "$SSH_CMD" "${x_args[@]}" 0/0
