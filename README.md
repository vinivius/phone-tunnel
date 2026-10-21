# phone-tunnel

Route **all** of a Linux laptop's internet traffic (**TCP, UDP and DNS**) through an
Android phone running [Termux](https://termux.dev), while the laptop is connected to the
phone's Wi-Fi hotspot. Every connection is opened **by the phone itself**, from inside
Termux. **No root on the phone is required.**

It **starts automatically** when the laptop joins *your* hotspot. It checks that it really
is your hotspot and your phone before sending any traffic, and if the tunnel goes down a
**kill switch** stops traffic from leaking out directly.

> ## ⚠️ For study purposes only
>
> This project is a learning exercise in Linux networking: TUN devices, Shadowsocks AEAD,
> SOCKS-style UDP relaying, nftables, NetworkManager dispatcher hooks, systemd services,
> SSH forced commands and systemd-resolved. It is provided as is, with no warranty.
>
> Many mobile carriers' terms of service restrict or charge separately for hotspot or
> tethering use. **You alone are responsible for making sure that using this on your network
> and plan is allowed.** Don't use it to break any contract, policy or law.

**Tested with:** Ubuntu 24.04 LTS (laptop) + Samsung Galaxy Z Fold 6 (Android 16, Termux, sing-box 1.14.3).

### Two clients, same phone side

| | **Linux installer** (`install.sh`) | **Portable client** (`portable/phone-tunnel.sh`) |
|---|---|---|
| Platforms | Linux (NetworkManager + systemd) | **macOS + Linux** |
| Starts | automatically on your hotspot | by hand (`proxy` or `tun`, Ctrl-C to stop) |
| Covers | whole device: TCP + UDP + DNS | `tun`: whole device (TCP + UDP + DNS, IPv4 + IPv6) · `proxy`: apps using the system proxy |
| Kill switch | ✅ nftables, fail-closed | `tun`: strict routing while running; nothing once stopped · `proxy`: ❌ |
| Install | `./install.sh` (sudo) | nothing for `proxy` (just Docker) · `tun` downloads sing-box (pinned + checksummed) |
| Engine | tun2socks | [sing-box](https://github.com/SagerNet/sing-box) |

Both use the same phone side: sing-box (Shadowsocks AEAD) started over a restricted SSH key with
a pinned host key. Each computer gets its own key and its own port, so several computers can
use the phone at the same time. See [macOS & Linux portable client](#macos--linux-portable-client).

---

## How it works

```
                 laptop                                               phone (Termux, no root)
 ┌────────────────────────────────────────────────┐                 ┌──────────────────────────┐
 │ apps ─► default route ─► phonetun0 ─► tun2socks ────┼── Shadowsocks ──┼─► sing-box ─► mobile data ─► internet
 │                    (198.18.0.1)  (unprivileged)│  AEAD, TCP+UDP  │   (started over SSH)     │
 │ DNS (systemd-resolved) ─► phonetun0                 │    over Wi-Fi   │                          │
 │ nftables kill switch on Wi-Fi: only phone:ssh  │                 │                          │
 │   and phone:shadowsocks may leave              │                 │                          │
 └────────────────────────────────────────────────┘                 └──────────────────────────┘
```

**When you join the hotspot:**

1. **NetworkManager** runs the dispatcher hook `/etc/NetworkManager/dispatcher.d/90-phone-tunnel`.
2. `phone-tunnel nm-hook` checks that it is the **trusted hotspot**. The saved profile's
   UUID, the SSID and the BSSID must all match what was recorded at install time. If any of
   them differs, nothing happens. (Leave `BSSID=` empty in `/etc/phone-tunnel/config` if the
   phone randomizes its hotspot MAC; see Troubleshooting.)
3. It switches on the **kill switch**, an nftables table. From then on the only traffic
   allowed out of the Wi-Fi interface is to the phone's SSH and Shadowsocks ports, plus
   DHCP. Everything else is rejected, including forwarded traffic from Docker and VMs.
   Rejecting rather than silently dropping means apps fail fast instead of hanging.
4. It starts `phone-tunnel.service`, which:
   - connects to the phone with a **dedicated, restricted SSH key**, verifies the phone's
     **pinned host key**, and asks it to start `sing-box` as a **Shadowsocks** server
     (`chacha20-ietf-poly1305`, TCP + UDP). The key is random for each session and is sent
     over SSH's stdin, so it never appears in a command line;
   - creates `phonetun0` and runs `tun2socks` on it **as an unprivileged system user**
     (`phonetun`). Its config, including the key, is in a mode-600 file, not on the
     command line;
   - points the default route and all DNS (systemd-resolved, `~.`) at `phonetun0` and turns
     IPv6 off on the Wi-Fi interface (only IPv4 is tunneled);
   - checks every 15 s that the phone is still answering. If tun2socks or the phone side
     dies, the service exits and systemd restarts it. The kill switch stays on the whole
     time, so nothing leaks while it restarts.
5. **When you disconnect,** the hook stops the service, which puts back routes, DNS and
   IPv6 and stops the server on the phone. It also removes the kill switch, so other Wi-Fi
   networks work normally.

### Why Shadowsocks and not SSH, SOCKS5 or sshuttle?

- SSH can only forward TCP. OpenSSH's `ssh -D` SOCKS proxy has no UDP support, and
  sshuttle only carries TCP and DNS. So none of them can carry QUIC/HTTP3, games, VoIP or
  WireGuard.
- Plain SOCKS5 with UDP ASSOCIATE works, but it is **unencrypted** between laptop and
  phone.
- **Shadowsocks AEAD encrypts and authenticates both TCP and UDP.** sing-box (phone) and
  tun2socks (laptop) both support it natively. TLS-wrapped SOCKS5 wouldn't cover UDP,
  and tun2socks can't speak it anyway.

---

## Security layers

| Layer | Protects against | Can it be spoofed? |
|---|---|---|
| SSID match | joining some other network by accident | yes, trivially; only a first filter |
| BSSID match (optional) | same SSID on a different access point | yes, MACs can be copied; still a filter. Leave it empty if the phone randomizes its hotspot MAC |
| **NetworkManager profile UUID** | a fake access point with your SSID and BSSID | **no, with WPA3-SAE**: SAE authenticates both sides with the password, so only the real hotspot can complete the connection with your saved profile |
| **Pinned SSH host key** (`StrictHostKeyChecking=yes`, dedicated `known_hosts`, `HostKeyAlias`) | a fake "phone" (man-in-the-middle) | **no**: without the phone's private host key, the tunnel refuses to start |
| **Restricted SSH key** (`restrict,command="phone-tunnel-ctl"`) | a stolen laptop key being used to get a shell on the phone | the key can only start, stop or check the Shadowsocks server. No shell, no port forwarding, no agent; all arguments are validated |
| **Shadowsocks AEAD** (per-session random key) | others on the hotspot reading or injecting tunnel traffic | encrypted and authenticated TCP + UDP |
| **Kill switch** (nftables) | leaks while the tunnel is starting, restarting or broken | only the phone's ssh + Shadowsocks ports (and DHCP) may leave the Wi-Fi interface |
| Unprivileged `tun2socks` (`phonetun` user) | a bug in the packet-processing code becoming root | it only gets the `phonetun0` it owns |

The installer **refuses** to continue if the scanned host key doesn't match the
fingerprint the phone reports about itself over your existing SSH session. It also checks
that the tunnel key really is restricted. It warns if the hotspot isn't WPA3.

---

## Requirements

- **Laptop:** Linux with NetworkManager, systemd and systemd-resolved; kernel 5.7 or newer,
  so the unprivileged tun2socks can bind to the Wi-Fi interface. Anything else that's
  missing, including [`tun2socks`](https://github.com/xjasonlyu/tun2socks), is installed by
  `install.sh` (apt-based distros; on others, install the tools listed in `install.sh` yourself).
- **Phone:** Termux (preferably from F-Droid) with `openssh` running. That has to be set up
  by hand, since it's how the installer reaches the phone. The installer adds `sing-box` itself.
- **Hotspot:** set it to **WPA3** if your phone allows; on Samsung that's
  *Mobile Hotspot → Configure → Security → WPA3-Personal*.

## Setup

### 1. Phone (Termux), once

```sh
pkg update && pkg install openssh
sshd                                  # listens on port 8022
```

Add your laptop's normal public key to the phone's `~/.ssh/authorized_keys` (or set a
password with `passwd` and use `ssh-copy-id -p 8022 <phone-ip>`). Then check from the laptop:

```sh
ssh -p 8022 <phone-ip> whoami         # phone-ip = your default gateway on the hotspot (ip route)
```

Recommended: Android Settings → Apps → Termux → Battery → **Unrestricted**, so Android
doesn't kill Termux in the background.

### 2. Laptop

Nothing to download by hand. The installer:
- installs any missing packages with `apt` (`iw`, `nftables`, `iproute2`, `systemd-resolved`,
  `openssh-client`, `curl`, `unzip`…);
- downloads **tun2socks v2.7.0** (amd64 or arm64) from its GitHub release and checks it
  against a **pinned SHA-256**. If the checksum doesn't match, it aborts. To use your own
  build instead, put it in `./bin/tun2socks` or your `$PATH`.

Then, **connected to the phone's hotspot**, in a normal terminal:

```sh
./install.sh
```

The installer will:

1. **Record the trusted hotspot.** It reads the interface, SSID, BSSID, saved profile
   UUID and security type, and gets the phone's Termux username automatically.
2. **Pin the phone's host key.** It cross-checks the scanned key against what the phone
   reports about itself and aborts on mismatch.
3. **Show everything and ask for confirmation.**
4. **Install the laptop side.** It creates the `phonetun` system user, generates the
   dedicated SSH key in `/etc/phone-tunnel/`, and installs `phone-tunnel`, the systemd
   unit and the dispatcher hook.
5. **Set up the phone over your normal SSH.** It installs sing-box and `phone-tunnel-ctl`,
   and authorizes the new key as restricted.
6. **Verify and start.** It checks that the key works and really is restricted, then
   starts the tunnel.

From then on it starts and stops by itself whenever you join or leave the hotspot.

## Usage

| Command | What it does |
|---|---|
| `sudo phone-tunnel status` | service, kill switch, trusted hotspot?, route, phone side |
| `sudo phone-tunnel off` | stop the tunnel **and** remove the kill switch: direct, unprotected (until you reconnect) |
| `sudo phone-tunnel on` | kill switch + tunnel (only works on the trusted hotspot) |
| `journalctl -u phone-tunnel -f` | logs |
| `./speedtest.py` / `./speedtest.py --direct <wifi-iface>` | measure through the tunnel / directly (direct needs `off` first) |
| `./uninstall.sh` | remove everything, on the laptop and the phone |

Settings live in `/etc/phone-tunnel/config` (mode 600). You can set `PHONE=<ip>` there
to pin the phone's address instead of using the gateway.

## Files

| Path in repo | Installed to | Role |
|---|---|---|
| `portable/phone-tunnel.sh` | (run in place) | macOS + Linux client: `setup`, `proxy` (Docker), `tun` (sing-box) |
| `phone-tunnel` | `/usr/local/sbin/phone-tunnel` | the tunnel, kill switch, trust check, on/off/status |
| `system/phone-tunnel.service` | `/etc/systemd/system/` | runs `phone-tunnel run`, restarts on failure, never at boot |
| `system/90-phone-tunnel` | `/etc/NetworkManager/dispatcher.d/` | calls `phone-tunnel nm-hook` on every network event |
| `phone/phone-tunnel-ctl` | phone: `~/bin/phone-tunnel-ctl` | forced command: the only thing the tunnel key can run |
| `install.sh` / `uninstall.sh` | | set everything up / remove it |
| `setup-phone.sh` | | phone part of the install (also `--remove`) |
| `speedtest.py` | | latency, UDP DNS, download/upload: tunnel vs direct |
| *(generated)* | `/etc/phone-tunnel/{config,id_ed25519,known_hosts}` | settings, tunnel key, pinned phone host key |

---

## Test results

Tested on **Ubuntu 24.04 LTS** + **Samsung Galaxy Z Fold 6** (Android 16, Termux, gost 2.12.0 on
the phone at the time, tun2socks 2.7.0). Medians, two alternating rounds:

| Path | Download | Upload | TLS RTT | UDP DNS loss |
|---|---:|---:|---:|---:|
| direct (laptop → hotspot) | 0.14–0.50 Mbit/s | 0.42–0.55 Mbit/s | 45 ms | 0 % |
| **tunnel** (laptop → phone-tunnel) | **34.0–34.4 Mbit/s** | **8.3–10.5 Mbit/s** | 68 ms | 0 % |
| on the phone itself (reference) | 119 Mbit/s | — | — | — |

**Cost on the laptop:** nothing at all when you're not on the hotspot (no daemon, no polling).
On it: ~50 MB of RAM and ~1 % of one CPU core.

Results depend entirely on your carrier and plan. See **[TESTING.md](TESTING.md)** for the
method, raw samples, caveats, and all the functional and security tests (restricted key,
host-key pinning, kill switch, leak tests, hotspot matching, installer checksum checks).

---

## macOS & Linux portable client

`portable/phone-tunnel.sh` runs on **macOS** (it's written for macOS's bash 3.2) and **Linux**.
It needs only the OpenSSH client, which both systems include, plus either Docker or sing-box.

```sh
cd portable
./phone-tunnel.sh setup     # once, while on the hotspot. No sudo. Lists what it will change, asks first.
./phone-tunnel.sh proxy     # Docker mode
./phone-tunnel.sh tun       # whole-device mode (asks for your password)
```

**`setup`** works like the Linux installer's phone step:
- creates a tunnel key in `~/.config/phone-tunnel/`;
- pins the phone's host key, checking the scanned key against what the phone reports about
  itself over your normal SSH, and aborts on mismatch;
- installs sing-box and `phone-tunnel-ctl` on the phone and authorizes the key as restricted;
- checks that the key really is restricted.

It uses Shadowsocks port **8389**; the Linux installer uses 8388. Give each extra computer its
own: `SS_PORT=8390 ./phone-tunnel.sh setup`.

**`proxy`, Docker mode: nothing to install except Docker.**
- Starts the Shadowsocks server on the phone with a fresh per-session key.
- Runs the **official sing-box image**, pinned by digest, with a SOCKS5 + HTTP proxy on
  `127.0.0.1:1080`. It's only reachable from the computer itself, never from the LAN.
- Set it as your **system proxy**:
  - **macOS:** *System Settings → Network → Wi-Fi → Details → Proxies* → SOCKS proxy
    `127.0.0.1:1080`.
  - **Linux:** your desktop's network proxy settings.

  Apps that follow the system proxy (browsers, most apps) go through the phone; apps that
  ignore it don't.
- **UDP:** browsers fall back from QUIC to TCP, so web browsing works. UDP through SOCKS5
  itself only works with `PT_DOCKER_NET=host` (Linux), because Docker's published port
  doesn't carry the SOCKS5 UDP relay.

**`tun`, native mode: the whole device.**
- Runs sing-box natively with a TUN interface and `auto_route` + `strict_route`.
- **All** TCP, UDP and DNS goes through the phone, including IPv6, which is captured rather
  than left to leak.
- The system DNS is intercepted and answered through the tunnel. LAN addresses go direct.
- If sing-box isn't installed, it offers to download **sing-box 1.14.3** for your OS/CPU
  (macOS or Linux, Intel or ARM), checked against a **pinned SHA-256**, into
  `~/.config/phone-tunnel/bin/`.
- Every generated config is checked with `sing-box check` before it runs.

**Both modes:**
- Ctrl-C stops everything, including the server on the phone.
- A heartbeat every 60 s keeps the phone side alive. If the computer vanishes, for example
  by walking out of hotspot range, the server on the phone stops itself after 3 minutes.

**Limits compared with the Linux installer:**
- it doesn't start automatically;
- there's no kill switch once it's stopped;
- in `proxy` mode, apps that ignore the system proxy go direct.

**Don't run another VPN at the same time** (Proton, WireGuard…). Both would try to own the
default route.

## Running a VPN through the tunnel

A UDP VPN such as WireGuard works through the tunnel, and three things matter. The first and third are
built in; the second is up to you.

1. **Bigger UDP socket buffers (automatic).** tun2socks doesn't size its UDP sockets, and the
   default 208 KB buffer overflows under a VPN's packet rate and drops packets. While the tunnel
   is up, `phone-tunnel` raises `net.core.rmem_default` / `wmem_default` to 4 MiB (it never
   lowers them) and restores the old values when it stops.
2. **Lower the VPN's MTU to 1360.** The Wi-Fi link to the phone carries at most 1500 bytes per
   packet, and every relayed packet must fit including the Shadowsocks wrapper:

   ```
   VPN MTU + 32 (WireGuard header+tag) + 55 (Shadowsocks: 32 salt + 7 address + 16 tag) + 28 (IP+UDP) <= 1500
   ```

   That's at most 1385. WireGuard's default 1420 doesn't fit, so every full-size packet is
   split into two IP fragments in both directions, and losing either half loses the packet.
   1360 leaves room for carrier paths below 1500 (e.g. IPv4-over-IPv6 translation on the phone).
   With NetworkManager: `nmcli connection modify <vpn> wireguard.mtu 1360`. The cost on other
   networks is about 4% per packet.

3. **The phone runs sing-box, not gost.** gost 2.12 ends its whole UDP session on any error
   with a single packet and opens a new socket on a new port, which happened several times a
   second under load. Packets already on their way to the old port were lost, and the VPN's
   TCP slowed down. sing-box keeps the session. (`phone-tunnel-ctl` still falls back to gost if
   sing-box isn't installed.)

Shadowsocks can't carry bigger packets: its UDP mode has no fragmentation of its own, and
Android's hotspot doesn't do jumbo frames. Measured results are in [TESTING.md](TESTING.md).

## Troubleshooting / lessons learned

| Symptom | Cause | Fix (already in the scripts) |
|---|---|---|
| gost never starts | `pkill -f 'gost …'` inside `ssh "…"` matches the remote shell's **own** command line and kills it first | track gost with a pidfile |
| tun2socks prints its usage text and exits | it uses GNU-style flags: `-device` is parsed as `-d evice` | use a YAML `--config` file (also keeps the key out of `ps`) |
| Tunnel is up but "no internet" | `phonetun0` had no IP address, so systemd-resolved gave it no DNS scope and nothing resolved | give `phonetun0` an address (`198.18.0.1/15`, a range reserved for testing) |
| Re-running scripts while a tunnel is up picks `phonetun0` as "the phone" | `default dev phonetun0` has no gateway | only consider `default via …` routes |
| Kill switch fails to load | `fwd` is a reserved word in nftables | chains are called `egress` / `forwarding` |
| `sudo: a terminal is required` | the installer was started without a TTY | run it in a normal terminal |
| Slow, but the phone itself is fast | the Wi-Fi link between laptop and phone (signal, band, power saving) is the bottleneck, not the tunnel | check `iw dev <iface> link`, move closer, use 5 GHz |
| Some site fails over IPv6 | IPv6 is deliberately off during the session | expected; apps fall back to IPv4 |
| NetworkManager shows "limited connectivity" | its connectivity check is bound to Wi-Fi and the kill switch rejects it | cosmetic |
| A VPN (WireGuard) through the tunnel is slow and loses packets | tun2socks' UDP socket buffer overflows, and VPN packets bigger than ~1385 bytes get fragmented | buffers: built in; MTU: set the VPN's MTU to 1360 (see "Running a VPN through the tunnel") |
| Auto-start stopped working; `sudo phone-tunnel on` still works | the phone picked a new randomized hotspot MAC, so the BSSID no longer matches | set `BSSID=` (empty) in `/etc/phone-tunnel/config`, or set the hotspot's MAC type to "Phone MAC" and put the new BSSID there |
| No internet as soon as the tunnel turns on; log says `port 8022: Connection refused` | sshd isn't running in Termux (Termux killed or phone rebooted); the kill switch blocks everything while the service retries | run `sshd` in Termux; set Termux's battery use to Unrestricted; Termux:Boot to start sshd after a reboot |

## License

MIT. See [LICENSE](LICENSE). Educational use only, as described above.
