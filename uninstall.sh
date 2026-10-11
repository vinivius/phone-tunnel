#!/usr/bin/env bash
# Remove everything install.sh put in place (laptop + phone).   ./uninstall.sh
set -uo pipefail
cd "$(dirname "$0")"
[[ $EUID -eq 0 ]] || exec sudo --preserve-env=SSH_AUTH_SOCK "$0" "$@"

[[ -x /usr/local/sbin/phone-tunnel ]] && /usr/local/sbin/phone-tunnel off
if [[ -f /etc/phone-tunnel/config && -n "${SUDO_USER:-}" ]]; then
  # shellcheck source=/dev/null
  source /etc/phone-tunnel/config
  TMPPUB="$(mktemp)"; cp /etc/phone-tunnel/id_ed25519.pub "$TMPPUB"; chmod 644 "$TMPPUB"   # /etc/phone-tunnel is root-only
  sudo -u "$SUDO_USER" -H env ${SSH_AUTH_SOCK:+SSH_AUTH_SOCK="$SSH_AUTH_SOCK"} PHONE_PORT="$PHONE_PORT" PHONE_USER="$PHONE_USER" ./setup-phone.sh --remove "$TMPPUB" \
    || echo "could not clean up the phone (not connected?); run ./setup-phone.sh --remove later"
  rm -f "$TMPPUB"
fi
rm -f /etc/NetworkManager/dispatcher.d/90-phone-tunnel /etc/systemd/system/phone-tunnel.service \
      /usr/local/sbin/phone-tunnel /usr/local/bin/tun2socks
rm -rf /etc/phone-tunnel /run/phone-tunnel
systemctl daemon-reload
id phonetun >/dev/null 2>&1 && userdel phonetun
echo "phone-tunnel removed"
