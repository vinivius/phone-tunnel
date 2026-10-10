#!/usr/bin/env bash
# Install phone-tunnel so it starts automatically when you join your phone's hotspot.
# Run while connected to the phone's hotspot, from a normal terminal:   ./install.sh
# (it re-runs itself with sudo, keeping SSH_AUTH_SOCK so your ssh-agent key still works)
# Your normal user must already be able to:  ssh -p 8022 <phone-ip>   (see README)
set -euo pipefail
cd "$(dirname "$0")"

[[ $EUID -eq 0 ]] || exec sudo --preserve-env=SSH_AUTH_SOCK "$0" "$@"
REAL_USER="${SUDO_USER:?run ./install.sh as your normal user, not as root}"
# your ssh key may live only in an agent (e.g. GNOME Keyring); plain sudo drops SSH_AUTH_SOCK
if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
  uid="$(id -u "$REAL_USER")"
  for s in "/run/user/$uid/keyring/ssh" "/run/user/$uid/gcr/ssh" "/run/user/$uid/openssh_agent"; do
    [[ -S "$s" ]] && { SSH_AUTH_SOCK="$s"; break; }
  done
fi
as_user() { sudo -u "$REAL_USER" -H env ${SSH_AUTH_SOCK:+SSH_AUTH_SOCK="$SSH_AUTH_SOCK"} "$@"; }

CONF_DIR=/etc/phone-tunnel
PHONE_PORT="${PHONE_PORT:-8022}"
SS_PORT="${SS_PORT:-8388}"
RUN_AS=phonetun
DNS="${DNS:-1.1.1.1 8.8.8.8}"

confirm() { local a; read -rp "$1 [y/N] " a; [[ "$a" == [yY] ]]; }

# --- 0. Dependencies: tell the user what's missing, ask, then install --------------------------
declare -A PKG=([nmcli]=network-manager [iw]=iw [nft]=nftables [ip]=iproute2 [resolvectl]=systemd-resolved
                [ssh]=openssh-client [ssh-keygen]=openssh-client [ssh-keyscan]=openssh-client
                [runuser]=util-linux [curl]=curl [unzip]=unzip [sha256sum]=coreutils)
missing=()
for c in "${!PKG[@]}"; do command -v "$c" >/dev/null || missing+=("${PKG[$c]}"); done
((${#missing[@]})) && mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort -u)

T2S_VERSION=v2.7.0
declare -A T2S_SHA256=(   # from the GitHub release asset digests
  [amd64]=a612baa287a3b6de6221f74fd02b442a50888508227ecf51e1288a5ccbb77381
  [arm64]=3931476c9cfa8fa236d23aeaf36767df0eb27cc11ecaab699faba57744450f49
)
case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) arch="" ;; esac
T2S_SRC="$(command -v tun2socks || echo ./bin/tun2socks)"
need_t2s=0; [[ -x "$T2S_SRC" ]] || need_t2s=1
((need_t2s)) && [[ -z "$arch" ]] && { echo "no pinned tun2socks for $(uname -m); put one in ./bin/tun2socks"; exit 1; }

if ((${#missing[@]} || need_t2s)); then
  echo "These are needed and not installed yet on this laptop:"
  ((${#missing[@]})) && echo "  - apt packages: ${missing[*]}"
  ((need_t2s)) && echo "  - tun2socks $T2S_VERSION ($arch) from github.com/xjasonlyu/tun2socks/releases," \
                       "checked against a pinned SHA-256, installed to /usr/local/bin/tun2socks"
  if ((${#missing[@]})) && ! command -v apt-get >/dev/null; then
    echo "No apt-get here: install those packages with your package manager, then re-run."; exit 1
  fi
  confirm "Install them now?" || { echo "Aborted. Nothing was changed."; exit 1; }
  ((${#missing[@]})) && apt-get install -y "${missing[@]}"
  if ((need_t2s)); then
    zip="tun2socks-linux-$arch.zip"
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    curl -fsSL -o "$tmp/$zip" "https://github.com/xjasonlyu/tun2socks/releases/download/$T2S_VERSION/$zip"
    echo "${T2S_SHA256[$arch]}  $tmp/$zip" | sha256sum -c --quiet - || { echo "tun2socks checksum MISMATCH, aborting"; exit 1; }
    unzip -q -o "$tmp/$zip" -d "$tmp"
    install -m 755 "$tmp/tun2socks-linux-$arch" /usr/local/bin/tun2socks   # keep it, so a re-run won't download again
    T2S_SRC=/usr/local/bin/tun2socks
    echo "tun2socks $T2S_VERSION downloaded, verified (sha256 ok), installed to /usr/local/bin/tun2socks"
  fi
fi

# --- 1. Identify the hotspot we're connected to right now ------------------------------------
IFACE="$(ip -4 route show default | awk '/^default via/ {print $5; exit}')"
PHONE="$(ip -4 route show default dev "$IFACE" | awk '/^default via/ {print $3; exit}')"
LINK="$(iw dev "$IFACE" link)" || { echo "$IFACE is not a Wi-Fi link"; exit 1; }
SSID="$(sed -n 's/^\tSSID: //p' <<<"$LINK")"
BSSID="$(awk '/^Connected to/ {print $3}' <<<"$LINK")"
NM_UUID="$(nmcli -t -f UUID,DEVICE connection show --active | awk -F: -v d="$IFACE" '$2==d {print $1; exit}')"
KEYMGMT="$(nmcli -g 802-11-wireless-security.key-mgmt connection show "$NM_UUID")"
PHONE_USER="$(as_user ssh -p "$PHONE_PORT" -o ConnectTimeout=10 -o BatchMode=yes "$PHONE" whoami)" \
  || { echo "your user can't ssh to $PHONE:$PHONE_PORT without a password; set that up first (README)"; exit 1; }
PHONE_HAS_GOST=0
as_user ssh -p "$PHONE_PORT" -o BatchMode=yes "$PHONE" 'command -v gost' >/dev/null 2>&1 && PHONE_HAS_GOST=1

cat <<EOF

  Trusted hotspot
    interface   $IFACE
    SSID        $SSID
    BSSID       $BSSID
    NM profile  $NM_UUID  (security: ${KEYMGMT:-none})
    phone       $PHONE_USER@$PHONE:$PHONE_PORT   (Shadowsocks port $SS_PORT)
EOF
[[ "$KEYMGMT" == sae ]] || echo "  WARNING: hotspot is not WPA3-SAE; the profile-UUID check is weaker. Switch the hotspot to WPA3 if you can."

# --- 2. Pin the phone's SSH host key ----------------------------------------------------------
SCAN="$(ssh-keyscan -t ed25519 -p "$PHONE_PORT" "$PHONE" 2>/dev/null | awk '$2=="ssh-ed25519"')"
[[ -n "$SCAN" ]] || { echo "could not read the phone's ed25519 host key"; exit 1; }
FP_SCAN="$(ssh-keygen -lf - <<<"$SCAN" | awk '{print $2}')"
# ask the phone itself (over your already-trusted ssh session) for its fingerprint
FP_PHONE="$(as_user ssh -p "$PHONE_PORT" -o BatchMode=yes "$PHONE" \
  'ssh-keygen -lf $PREFIX/etc/ssh/ssh_host_ed25519_key.pub' | awk '{print $2}')"
echo "    host key    $FP_SCAN"
[[ "$FP_SCAN" == "$FP_PHONE" ]] || { echo "host key mismatch (scan $FP_SCAN vs phone $FP_PHONE): aborting"; exit 1; }
echo "                (matches what the phone reports for itself)"

echo
echo "  This will install / change, on this laptop:"
id "$RUN_AS" >/dev/null 2>&1 || echo "    - new system user '$RUN_AS' (no login, no home) to run tun2socks unprivileged"
echo "    - /etc/phone-tunnel/   new SSH key for the tunnel, pinned phone host key, config"
echo "    - /usr/local/bin/tun2socks, /usr/local/sbin/phone-tunnel"
echo "    - /etc/systemd/system/phone-tunnel.service"
echo "    - /etc/NetworkManager/dispatcher.d/90-phone-tunnel  (auto start/stop on this hotspot)"
echo "  and on the phone (Termux):"
((PHONE_HAS_GOST)) || echo "    - pkg install gost"
echo "    - ~/bin/phone-tunnel-ctl"
echo "    - one restricted line in ~/.ssh/authorized_keys (tunnel key, can only run phone-tunnel-ctl)"
echo "  Then the tunnel starts right away, with its kill switch on."
echo
confirm "Proceed?" || { echo "Aborted. Nothing else was changed."; exit 1; }

# --- 3. Files, user, key ----------------------------------------------------------------------
id "$RUN_AS" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$RUN_AS"
install -d -m 700 "$CONF_DIR"
[[ -f "$CONF_DIR/id_ed25519" ]] || ssh-keygen -q -t ed25519 -N '' -C phone-tunnel -f "$CONF_DIR/id_ed25519"
echo "phone-tunnel ${SCAN#* }" >"$CONF_DIR/known_hosts"; chmod 600 "$CONF_DIR/known_hosts"
cat >"$CONF_DIR/config" <<EOF
# generated by install.sh
PHONE_USER=$PHONE_USER
PHONE_PORT=$PHONE_PORT
SS_PORT=$SS_PORT
IFACE=$IFACE
SSID='$SSID'
BSSID=$BSSID
NM_UUID=$NM_UUID
RUN_AS=$RUN_AS
DNS="$DNS"
TUN2SOCKS=/usr/local/bin/tun2socks
EOF
chmod 600 "$CONF_DIR/config"

[[ "$(realpath "$T2S_SRC")" == /usr/local/bin/tun2socks ]] || install -m 755 "$T2S_SRC" /usr/local/bin/tun2socks
install -m 755 phone-tunnel /usr/local/sbin/phone-tunnel
install -m 644 system/phone-tunnel.service /etc/systemd/system/phone-tunnel.service
install -m 755 system/90-phone-tunnel /etc/NetworkManager/dispatcher.d/90-phone-tunnel
systemctl daemon-reload

# --- 4. Phone side (as your user, over your normal ssh) ---------------------------------------
TMPPUB="$(mktemp)"; cp "$CONF_DIR/id_ed25519.pub" "$TMPPUB"; chmod 644 "$TMPPUB"
as_user env PHONE="$PHONE" PHONE_PORT="$PHONE_PORT" PHONE_USER="$PHONE_USER" ./setup-phone.sh --yes "$TMPPUB"
rm -f "$TMPPUB"

# --- 5. Check the restricted key works, and that it really is restricted ----------------------
KS=(ssh -i "$CONF_DIR/id_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes
    -o UserKnownHostsFile="$CONF_DIR/known_hosts" -o HostKeyAlias=phone-tunnel -p "$PHONE_PORT" "$PHONE_USER@$PHONE")
rc=0; "${KS[@]}" status >/dev/null 2>&1 || rc=$?   # 0 running / 1 stopped; 255 = ssh failure
[[ $rc -le 1 ]] || { echo "tunnel key can't log in to the phone"; exit 1; }
[[ "$("${KS[@]}" id 2>&1)" == denied ]] && echo "verified: tunnel key can only run phone-tunnel-ctl" \
  || { echo "WARNING: tunnel key is NOT restricted on the phone"; exit 1; }

echo
echo "Installed. Starting now (and from now on, every time you join '$SSID')..."
/usr/local/sbin/phone-tunnel on
sleep 4
/usr/local/sbin/phone-tunnel status
