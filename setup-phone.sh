#!/usr/bin/env bash
# Prepare the phone (Termux) over your existing, normal SSH access:
#   - install gost
#   - install ~/bin/phone-tunnel-ctl (the only thing the tunnel key may run)
#   - authorize the tunnel's public key, locked down with restrict,command=...
# Usage: setup-phone.sh [--yes] PUBKEY_FILE   (install.sh calls this for you; asks before installing gost unless --yes)
#        setup-phone.sh --remove PUBKEY_FILE  (remove this computer's key)
#        setup-phone.sh --remove              (remove all tunnel keys + phone-tunnel-ctl)
# Each computer gets its own restricted key line; re-running replaces only that computer's line.
# Env: PHONE (default: gateway), PHONE_PORT (8022), PHONE_USER (default: your ssh config / local user)
set -euo pipefail
cd "$(dirname "$0")"

PHONE="${PHONE:-$(ip -4 route show default | awk '/^default via/ {print $3; exit}')}"
PHONE_PORT="${PHONE_PORT:-8022}"
TARGET="${PHONE_USER:+$PHONE_USER@}$PHONE"
SSH=(ssh -p "$PHONE_PORT" -o ConnectTimeout=10 "$TARGET")
TAG=phone-tunnel-key
YES=0; [[ "${1:-}" == --yes ]] && { YES=1; shift; }

read_pub() {
  read -r ktype kdata _ <"$1"
  [[ "$ktype" == ssh-ed25519 && "$kdata" =~ ^[A-Za-z0-9+/=]+$ ]] || { echo "not an ed25519 public key: $1"; exit 1; }
}

if [[ "${1:-}" == "--remove" ]]; then
  if [[ -n "${2:-}" ]]; then
    read_pub "$2"
    "${SSH[@]}" "sed -i '\\#$kdata $TAG\$#d' ~/.ssh/authorized_keys"
    echo "phone: this computer's tunnel key removed"
  else
    "${SSH[@]}" "sed -i '/ $TAG\$/d' ~/.ssh/authorized_keys; rm -f ~/bin/phone-tunnel-ctl;
      kill \$(cat \$PREFIX/var/phone-tunnel/gost.pid 2>/dev/null) 2>/dev/null; rm -rf \$PREFIX/var/phone-tunnel"
    echo "phone: all tunnel keys + phone-tunnel-ctl removed"
  fi
  exit 0
fi

PUB="${1:?usage: setup-phone.sh PUBKEY_FILE}"
read_pub "$PUB"

if ! "${SSH[@]}" 'command -v gost' >/dev/null 2>&1; then
  if ((!YES)); then
    read -rp "gost is not installed on the phone. Install it now (pkg install gost)? [y/N] " a
    [[ "$a" == [yY] ]] || { echo "Aborted. Nothing was changed."; exit 1; }
  fi
  echo "phone: installing gost"
  "${SSH[@]}" 'yes | pkg install -y gost >/dev/null 2>&1; command -v gost >/dev/null' \
    || { echo "could not install gost (try: pkg install gost)"; exit 1; }
fi
echo "phone: installing phone-tunnel-ctl on $TARGET:$PHONE_PORT"
"${SSH[@]}" 'mkdir -p ~/bin && cat > ~/bin/phone-tunnel-ctl && chmod 700 ~/bin/phone-tunnel-ctl' <phone/phone-tunnel-ctl

# restrict = no shell/pty/forwarding/agent; command= = only phone-tunnel-ctl, whatever the client asks
"${SSH[@]}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys &&
  sed -i '\\#$kdata $TAG\$#d' ~/.ssh/authorized_keys &&
  echo \"restrict,command=\\\"\$HOME/bin/phone-tunnel-ctl\\\" $ktype $kdata $TAG\" >> ~/.ssh/authorized_keys &&
  chmod 600 ~/.ssh/authorized_keys"
echo "phone: tunnel key authorized (restricted to phone-tunnel-ctl)"
