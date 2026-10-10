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
