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

**Tested with:** Ubuntu 24.04 LTS (laptop) + Samsung Galaxy Z Fold 6 (Android 16, Termux, gost 2.12).

---

## How it works

```
                 laptop                                               phone (Termux, no root)
 ┌────────────────────────────────────────────────┐                 ┌──────────────────────────┐
 │ apps ─► default route ─► tun0 ─► tun2socks ────┼── Shadowsocks ──┼─► gost ─► mobile data ─► internet
 │                    (198.18.0.1)  (unprivileged)│  AEAD, TCP+UDP  │   (started over SSH)     │
 │ DNS (systemd-resolved) ─► tun0                 │    over Wi-Fi   │                          │
 │ nftables kill switch on Wi-Fi: only phone:ssh  │                 │                          │
 │   and phone:shadowsocks may leave              │                 │                          │
 └────────────────────────────────────────────────┘                 └──────────────────────────┘
```

**When you join the hotspot:**

1. **NetworkManager** runs the dispatcher hook `/etc/NetworkManager/dispatcher.d/90-phone-tunnel`.
2. `phone-tunnel nm-hook` checks that it is the **trusted hotspot**. The saved profile's
   UUID, the SSID and the BSSID must all match what was recorded at install time. If any of
   them differs, nothing happens.
3. It switches on the **kill switch**, an nftables table. From then on the only traffic
   allowed out of the Wi-Fi interface is to the phone's SSH and Shadowsocks ports, plus
   DHCP. Everything else is rejected, including forwarded traffic from Docker and VMs.
   Rejecting rather than silently dropping means apps fail fast instead of hanging.
4. It starts `phone-tunnel.service`, which:
   - connects to the phone with a **dedicated, restricted SSH key**, verifies the phone's
     **pinned host key**, and asks it to start `gost` as a **Shadowsocks** server
     (`chacha20-ietf-poly1305`, TCP + UDP). The key is random for each session and is sent
     over SSH's stdin, so it never appears in a command line;
   - creates `tun0` and runs `tun2socks` on it **as an unprivileged system user**
     (`phonetun`). Its config, including the key, is in a mode-600 file, not on the
     command line;
   - points the default route and all DNS (systemd-resolved, `~.`) at `tun0` and turns
     IPv6 off on the Wi-Fi interface (only IPv4 is tunneled);
   - checks every 15 s that the phone is still answering. If tun2socks or the phone side
     dies, the service exits and systemd restarts it. The kill switch stays on the whole
     time, so nothing leaks while it restarts.
5. **When you disconnect,** the hook stops the service, which puts back routes, DNS and
   IPv6 and stops gost on the phone. It also removes the kill switch, so other Wi-Fi
   networks work normally.

### Why Shadowsocks and not SSH, SOCKS5 or sshuttle?

- SSH can only forward TCP. OpenSSH's `ssh -D` SOCKS proxy has no UDP support, and
  sshuttle only carries TCP and DNS. So none of them can carry QUIC/HTTP3, games, VoIP or
  WireGuard.
- Plain SOCKS5 with UDP ASSOCIATE works, but it is **unencrypted** between laptop and
  phone.
- **Shadowsocks AEAD encrypts and authenticates both TCP and UDP.** gost (phone) and
  tun2socks (laptop) both support it natively. TLS-wrapped SOCKS5 wouldn't cover UDP,
  and tun2socks can't speak it anyway.

---

## Security layers

| Layer | Protects against | Can it be spoofed? |
|---|---|---|
| SSID match | joining some other network by accident | yes, trivially; only a first filter |
| BSSID match | same SSID on a different access point | yes, MACs can be copied; still a filter |
| **NetworkManager profile UUID** | a fake access point with your SSID and BSSID | **no, with WPA3-SAE**: SAE authenticates both sides with the password, so only the real hotspot can complete the connection with your saved profile |
| **Pinned SSH host key** (`StrictHostKeyChecking=yes`, dedicated `known_hosts`, `HostKeyAlias`) | a fake "phone" (man-in-the-middle) | **no**: without the phone's private host key, the tunnel refuses to start |
| **Restricted SSH key** (`restrict,command="phone-tunnel-ctl"`) | a stolen laptop key being used to get a shell on the phone | the key can only start, stop or check gost. No shell, no port forwarding, no agent; all arguments are validated |
| **Shadowsocks AEAD** (per-session random key) | others on the hotspot reading or injecting tunnel traffic | encrypted and authenticated TCP + UDP |
| **Kill switch** (nftables) | leaks while the tunnel is starting, restarting or broken | only the phone's ssh + Shadowsocks ports (and DHCP) may leave the Wi-Fi interface |
| Unprivileged `tun2socks` (`phonetun` user) | a bug in the packet-processing code becoming root | it only gets the `tun0` it owns |

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
  by hand, since it's how the installer reaches the phone. The installer adds `gost` itself.
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
5. **Set up the phone over your normal SSH.** It installs gost and `phone-tunnel-ctl`,
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

Tested on **Ubuntu 24.04 LTS** + **Samsung Galaxy Z Fold 6** (Android 16, Termux, gost 2.12.0,
tun2socks 2.7.0). Medians, two alternating rounds:

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

## Troubleshooting / lessons learned

| Symptom | Cause | Fix (already in the scripts) |
|---|---|---|
| gost never starts | `pkill -f 'gost …'` inside `ssh "…"` matches the remote shell's **own** command line and kills it first | track gost with a pidfile |
| tun2socks prints its usage text and exits | it uses GNU-style flags: `-device` is parsed as `-d evice` | use a YAML `--config` file (also keeps the key out of `ps`) |
| Tunnel is up but "no internet" | `tun0` had no IP address, so systemd-resolved gave it no DNS scope and nothing resolved | give `tun0` an address (`198.18.0.1/15`, a range reserved for testing) |
| Re-running scripts while a tunnel is up picks `tun0` as "the phone" | `default dev tun0` has no gateway | only consider `default via …` routes |
| Kill switch fails to load | `fwd` is a reserved word in nftables | chains are called `egress` / `forwarding` |
| `sudo: a terminal is required` | the installer was started without a TTY | run it in a normal terminal |
| Slow, but the phone itself is fast | the Wi-Fi link between laptop and phone (signal, band, power saving) is the bottleneck, not the tunnel | check `iw dev <iface> link`, move closer, use 5 GHz |
| Some site fails over IPv6 | IPv6 is deliberately off during the session | expected; apps fall back to IPv4 |
| NetworkManager shows "limited connectivity" | its connectivity check is bound to Wi-Fi and the kill switch rejects it | cosmetic |

## License

MIT. See [LICENSE](LICENSE). Educational use only, as described above.
