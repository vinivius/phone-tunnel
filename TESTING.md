# Testing

> For study purposes only. See the disclaimer in [README.md](README.md).

## Test setup

| | |
|---|---|
| Laptop | **Ubuntu 24.04 LTS** (Linux 7.0, NetworkManager, systemd-resolved, nftables) |
| Phone | **Samsung Galaxy Z Fold 6** (Android 16), Termux, OpenSSH, gost 2.12.0. **Not rooted.** |
| Tunnel | tun2socks 2.7.0, Shadowsocks `chacha20-ietf-poly1305` (TCP + UDP) |
| Link | laptop on the phone's Wi-Fi hotspot (WPA3-SAE, 5 GHz); phone on 5G mobile data |
| Date | October 2026 |

---

## Speed: with vs without the tunnel

Measured with [`speedtest.py`](speedtest.py) against Cloudflare's speed-test endpoints.
The two modes were alternated (direct → tunnel → direct → tunnel) so changes in signal
wouldn't favor either one. Each throughput sample is time-boxed to 15 s, and the table
shows the **median of 3 samples**.

| Run | Path | Download | Upload |
|---|---|---:|---:|
| round 1 | **direct** (laptop → hotspot → internet) | 0.50 Mbit/s | 0.55 Mbit/s |
| round 1 | **tunnel** (laptop → phone-tunnel → internet) | **34.02 Mbit/s** | **8.25 Mbit/s** |
| round 2 | **direct** | 0.14 Mbit/s | 0.42 Mbit/s |
| round 2 | **tunnel** | **34.38 Mbit/s** | **10.54 Mbit/s** |
| reference | **on the phone itself** (`curl` in Termux) | 119.12 Mbit/s | — |

Raw samples (Mbit/s):
- direct: down `0.50 0.49 0.52` / `0.27 0.06 0.14`, up `0.57 0.55 0.54` / `0.49 0.31 0.42`
- tunnel: down `34.47 34.02 30.07` / `29.96 34.38 34.80`, up `18.22 8.25 5.33` / `10.54 11.31 7.90`
- on phone: down `113.40 120.72 119.12`

### Latency and UDP

| Run | Path | TLS handshake RTT | UDP DNS RTT | UDP loss |
|---|---|---:|---:|---:|
| round 1 | direct | 422.2 ms * | 70.9 ms | 0 % |
| round 1 | tunnel | 84.8 ms | 41.7 ms | 0 % |
| round 2 | direct | 45.1 ms | 45.1 ms | 0 % |
| round 2 | tunnel | 67.6 ms | 46.1 ms | 0 % |

\* An outlier on a congested link; round 2 is representative.

- **TLS handshake RTT** is the time for a TLS 1.3 handshake, which takes one full round
  trip to Cloudflare. The TCP connect time is *not* used: tun2socks completes the TCP
  handshake locally, so through the tunnel that number would be ~0.5 ms and meaningless.
- **UDP DNS** is 30 raw UDP DNS queries to 1.1.1.1, each for a unique name so no cache can
  answer it. 0 % loss through the tunnel confirms that **UDP really goes through it**.

### What the numbers say

- **On this phone and plan, direct hotspot traffic was very slow (≈0.1–0.5 Mbit/s), while
  the tunnel got ≈34 Mbit/s down and ≈8–10 Mbit/s up, about 70× faster.** Traffic the phone
  originates itself was not slowed down. That pattern is consistent with the network
  treating hotspot traffic differently from on-device traffic. Results depend entirely on
  your carrier and plan, and **using this may be against your plan's terms**
  (see the disclaimer).
- **The tunnel's cost** is the gap between ≈34 Mbit/s through the tunnel and ≈119 Mbit/s on
  the phone itself. It comes from the laptop-to-phone Wi-Fi link, Shadowsocks encryption on
  the phone's CPU, and the extra hop. It also adds about 20 ms of round-trip time.
- UDP DNS round-trip time and loss are the same with and without the tunnel.

### Caveats

- **Sample sizes:** direct samples used 1 MB transfers and tunnel samples 25 MB down /
  10 MB up. The direct link was so slow that 1 MB didn't finish within 15 s anyway, so
  both modes were really measured as "bytes moved in 15 s".
- **Where the tunnel ran:** the tunnel measurements ran the real laptop-side code
  (`phone-tunnel run` + tun2socks + kill switch) inside a Docker container on the same
  laptop, against the real phone, over the real hotspot. The installed version on the
  host takes the same network path.
- **Timing:** the on-phone reference was measured a few minutes after the other runs, and
  mobile speeds vary minute to minute.
- **Raw data:** in [`results/`](results/). `throughput.jsonl` still has an older
  `tcp_connect_ms` field, which included DNS lookup time and isn't meaningful through the
  tunnel. Its timestamps mix local time (direct runs) and UTC (container runs).
  `latency.jsonl` has the corrected metric.

---

## Functional and security tests

All run against the real phone over the real hotspot.

### Restricted tunnel key (phone side)

| Test | Expected | Result |
|---|---|---|
| `status` / `start PORT` / `stop` | work | ✅ |
| any other command (`id`) | `denied` | ✅ |
| a shell (`sh -c id`) | `denied` | ✅ |
| command injection (`start 8388; id`) | rejected (`bad port`) | ✅ |
| malformed key on stdin (`abc;rm -rf x`) | rejected (`bad key`) | ✅ |
| port forwarding (`-L`) | `administratively prohibited` | ✅ |
| **fake phone host key** (MITM) | connection refused | ✅ `REMOTE HOST IDENTIFICATION HAS CHANGED` |

### Tunnel + kill switch (laptop side)

| Test | Expected | Result |
|---|---|---|
| kill switch on, tunnel not up yet | direct traffic **refused** (fail-closed) | ✅ |
| tunnel up | default route via `tun0` | ✅ |
| tun2socks process user | unprivileged `phonetun` | ✅ |
| Shadowsocks key visible in any process command line | no | ✅ 0 matches |
| UDP (DNS to 9.9.9.9) through the tunnel | answers | ✅ |
| TCP (HTTPS) through the tunnel | works | ✅ |
| bypass: force traffic out the Wi-Fi interface | **blocked** | ✅ |
| bypass: DNS straight to the phone | **blocked** | ✅ |
| stop (SIGTERM, as `systemctl stop` does) | `tun0` removed, gost stopped on phone | ✅ |
| kill switch off | direct internet works again | ✅ |

### Trusted-hotspot detection (real Wi-Fi state)

| Test | Result |
|---|---|
| correct profile UUID + SSID + BSSID | ✅ trusted |
| wrong UUID | ✅ rejected |
| wrong SSID | ✅ rejected |
| SSID with regex characters (`.` matching any letter) | ✅ rejected |
| wrong BSSID | ✅ rejected |
| BSSID prefix (one character short) | ✅ rejected |
| BSSID in upper case | ✅ trusted (case-insensitive, as it should be) |
| empty `BSSID=` with a different BSSID (randomized hotspot MAC) | ✅ trusted; UUID and SSID still checked |

### Installer

| Test | Result |
|---|---|
| missing packages / tun2socks are listed and need confirmation; answering "no" changes nothing | ✅ |
| answering "yes" installs packages (apt stubbed) and fetches tun2socks | ✅ |
| genuine tun2socks v2.7.0 zip | ✅ sha256 ok |
| tun2socks zip with one byte changed | ✅ rejected: `checksum MISMATCH, aborting` |
| nothing missing | ✅ no prompt |
| phone setup (`setup-phone.sh`) against the real phone, run twice | ✅ idempotent: one key line, restricted |

### Real install on the host (Ubuntu 24.04)

`./install.sh` was run on the laptop itself, not in a container:

| Check | Result |
|---|---|
| installer lists missing tun2socks, asks, downloads, verifies the checksum | ✅ |
| service active, 0 restarts; files in `/etc` and `/usr/local` identical to the repo | ✅ |
| default route + DNS via `tun0`; IPv6 off on Wi-Fi | ✅ |
| HTTPS through the tunnel | ✅ |
| kill switch: forced direct connection over Wi-Fi | ✅ blocked |
| service not enabled at boot (`static`, started only by the NetworkManager hook) | ✅ |

### Portable client (`portable/phone-tunnel.sh`, sing-box 1.14.3)

Run against the real phone over home Wi-Fi (the phone side doesn't care which network it's on):

| Test | Result |
|---|---|
| generated `proxy` and `tun` configs pass `sing-box check` (real sing-box 1.14.3) | ✅ |
| `setup` against the real phone: host key cross-checked, key restricted, prompt honoured | ✅ |
| `setup` on a second computer keeps the first computer's key (one key line per computer) | ✅ |
| **proxy** (Docker, bridged like Docker Desktop on a Mac): SOCKS5 + HTTP through the phone | ✅ exit IP = phone's network |
| proxy published on `127.0.0.1` only, not reachable from the LAN | ✅ |
| proxy with `PT_DOCKER_NET=host`: **UDP through SOCKS5** (DNS to 9.9.9.9) | ✅ |
| stop: gost on the phone stopped, no container left behind | ✅ |
| **tun** (real sing-box TUN, isolated network namespace): HTTPS through the phone | ✅ |
| tun: system DNS intercepted and answered through the tunnel | ✅ |
| tun: UDP DNS straight to 9.9.9.9 goes through the tunnel | ✅ |
| tun: IPv6 destination captured by the tunnel, not sent direct | ✅ (the phone had no IPv6 on that network, so the connection was then refused) |

### Phone watchdog (real phone, 5 minutes)

| Instance | Result |
|---|---|
| watchdog on, **no heartbeat** | ✅ stopped itself at ~3 min, released its share of the wake lock |
| watchdog on, heartbeat every 60 s | ✅ still running at 5 min |
| started without watchdog (older clients) | ✅ still running at 5 min (backward compatible) |

Not tested on a real Mac: the macOS-only paths are default-gateway detection
(`route -n get default`), `shasum` and the darwin sing-box download. The script is written
for macOS's bash 3.2 (no associative arrays, no `mapfile`, empty-array-safe expansions).

### WireGuard VPN through the tunnel

A full-tunnel WireGuard VPN on the laptop, running over the phone tunnel. Same place, same
signal (-46 dBm, 867 Mbit/s link), measured a few minutes apart.

| | Default (MTU 1420, 208 KB buffers) | MTU 1360 + 4 MiB buffers |
|---|---|---|
| Download (5 MB) | 2.5–4.7 Mbit/s | **16.4 Mbit/s** |
| Upload (2 MB) | 1.8 Mbit/s | **8.9 Mbit/s** (same as the tunnel alone) |
| UDP receive-buffer drops during the test | 397 | **0** |
| IP fragments created / reassembled during the test | ~3,300 / ~8,300 | **4 / 8** |
| Ping loss through the VPN | 5–10% | 3% |

The drops were on tun2socks' UDP socket to the phone (`ss -uam` showed `rb212992` and a
growing `d` count). The remaining loss and jitter are on the cellular side.

## Resource cost

Measured on the installed version:

| | Not on the hotspot | On the trusted hotspot |
|---|---|---|
| processes | **none** (no daemon, no timer, no polling) | `tun2socks` + a small bash supervisor |
| memory | 0 | ~43 MB (tun2socks) + ~4 MB (bash) |
| CPU | 0. The NetworkManager hook runs for a few ms per network event and exits | ~0.7 % of one core with background traffic, ~1.2 % while downloading |
| health check | — | one TCP connection to the phone every 15 s |

On the phone, the main cost is battery: gost runs, and a wake lock keeps the CPU awake
while the tunnel is up.

## Bugs found during testing (all fixed)

1. `pkill -f` inside `ssh "…"` killed its own shell before gost started.
2. tun2socks takes GNU-style flags; `-device` was parsed as `-d evice`.
3. `tun0` without an IP address got no DNS scope from systemd-resolved, so nothing resolved.
4. With a tunnel already up, `default dev tun0` was mistaken for the phone's gateway.
5. `fwd` is a reserved word in nftables, so the kill switch failed to load.
6. The BSSID check was a prefix match.
7. TCP connect time is meaningless through tun2socks, so latency is now measured with the
   TLS handshake.
8. On the real install, `sudo` dropped `SSH_AUTH_SOCK`, so a phone key kept only in an ssh-agent
   (GNOME Keyring) wasn't available. `./install.sh` now re-runs itself with
   `sudo --preserve-env=SSH_AUTH_SOCK`, and if started with plain `sudo` it looks for the agent
   socket in the usual places.
9. A run that stopped early threw away the downloaded tun2socks, and a re-run after a
   successful install would have copied `/usr/local/bin/tun2socks` onto itself. The verified
   binary is now installed right away, and the copy is skipped.
10. Our TUN device was called `tun0`, the name OpenVPN-based VPNs use (Proton VPN was using
    it on the test laptop). Joining the hotspot would have deleted the other VPN's interface.
    Renamed to `phonetun0`.
11. `ssh` reads stdin unless given `-n`, so a one-shot `ssh … whoami` swallowed the answer
    meant for the next `[y/N]` prompt.
12. A second computer's setup replaced the first computer's key, and a single gost meant one
    computer's `start` killed the other's tunnel. Now there's one key line and one gost
    instance (port) per computer.
13. Leaving the hotspot (walking away, hotspot off) left gost running on the phone with the
    wake lock held, because the computer could no longer reach it to stop it. Now clients
    start gost with a watchdog and check in every 60 s; after 3 minutes of silence gost
    stops itself.
14. Samsung's hotspot uses a randomized MAC by default, and it changed between sessions. The
    BSSID check then rejected the real hotspot and the tunnel silently stopped auto-starting.
    An empty `BSSID=` now skips that check. The profile UUID (WPA3-SAE) and the pinned SSH
    host key still keep a fake hotspot out.
15. A WireGuard VPN through the tunnel ran at a few Mbit/s with 5–10% loss. tun2socks' UDP
    socket used the 208 KB default buffer and dropped packets, and full-size WireGuard packets
    plus the Shadowsocks wrapper exceeded 1500 bytes, so each was fragmented. `phone-tunnel`
    now raises the default socket buffers to 4 MiB for the session; the README explains the
    VPN MTU (1360).
