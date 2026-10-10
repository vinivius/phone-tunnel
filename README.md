# phone-tunnel

Route all of a Linux laptop's internet traffic **through an Android phone** running
`sshd` in [Termux](https://termux.dev), while the laptop is connected to the phone's
Wi-Fi hotspot. The phone opens every connection itself, from inside Termux.
**No root on the phone is required.**

> ## ⚠️ For study purposes only
>
> This project is a learning exercise in Linux networking: SSH tunneling, SOCKS5,
> TUN devices, policy routing and DNS with systemd-resolved. It is provided as is,
> with no warranty.
>
> Many mobile carriers' terms of service restrict or charge separately for hotspot
> or tethering use. **You alone are responsible for making sure that using this on
> your network and plan is allowed.** Don't use it to break any contract, policy
> or law.

---

## Two variants

| Script | Carries | Mechanism | Laptop needs | Phone needs |
|---|---|---|---|---|
| `phone-tunnel-tcp.sh` | TCP + DNS | `sshuttle` over SSH | `sshuttle`, `sudo` | `openssh`, `python` |
| `phone-tunnel-udp.sh` | **TCP + UDP + DNS** | SOCKS5 (`gost`) + `tun2socks` | `tun2socks`, `sudo`, systemd-resolved | `openssh`, `gost` |

Use the **TCP** version if you only need web browsing, git, ssh and similar. It's simpler,
and everything is encrypted inside SSH.
Use the **UDP** version if you also need UDP: QUIC/HTTP3, games, VoIP, WireGuard, and so on.

---

## How it works

### TCP variant (sshuttle)

```
 laptop apps ──► nftables/iptables REDIRECT ──► sshuttle (local) ══SSH══► sshuttle server (python, in Termux) ──► internet
```

- `sshuttle` adds firewall rules that catch outgoing TCP connections and DNS queries.
  It sends them through one SSH connection to the phone.
- On the phone, a small Python helper (uploaded by sshuttle automatically) opens the
  real connections.
- **Why no UDP:** SSH can only forward TCP streams. OpenSSH's `ssh -D` SOCKS proxy
  doesn't support UDP either, so no SSH-based approach can carry it.

### UDP variant (gost + tun2socks)

```
 laptop apps ──► default route ──► tun0 ──► tun2socks ──SOCKS5 (TCP + UDP ASSOCIATE)──► gost (in Termux) ──► internet
```

1. **Phone:** the script connects over SSH and starts
   [`gost`](https://github.com/ginuerzh/gost), a SOCKS5 server that supports
   **UDP ASSOCIATE**. It's protected by a random password generated fresh each run.
2. **Laptop:** it creates a TUN interface `tun0` and runs
   [`tun2socks`](https://github.com/xjasonlyu/tun2socks) on it. tun2socks turns every
   TCP and UDP packet arriving on `tun0` into SOCKS5 requests to gost.
3. **Routing:** it adds a default route through `tun0` with a lower metric than the
   Wi-Fi route. The hotspot subnet's own link route is more specific, so traffic to
   the phone itself (including the SOCKS5 connection) still goes directly over Wi-Fi.
   tun2socks is also bound to the Wi-Fi interface (`--interface`) so its traffic can't
   loop back into the tunnel.
4. **DNS:** it sets systemd-resolved to use public resolvers on `tun0` with the
   catch-all domain `~.`, and removes the Wi-Fi link's DNS default route. That way
   every DNS lookup goes through the tunnel.

### Applies to both

- **IPv6 is disabled on the Wi-Fi interface** while the tunnel runs. Both variants
  only tunnel IPv4. Without this, IPv6 traffic would go around the tunnel, because
  many carriers hand out public IPv6 addresses on the hotspot.
- **`termux-wake-lock`** is run on the phone so Android doesn't suspend Termux.
- **Ctrl-C stops the tunnel cleanly:** the script removes routes, `tun0` and DNS
  overrides, turns IPv6 back on, stops gost and releases the wake lock.

---

## Setup

### 1. Phone (Termux)

Install Termux, preferably from F-Droid; the Play Store build is outdated. Then:

```sh
pkg update
pkg install openssh python gost      # python: TCP variant, gost: UDP variant
passwd                               # or add your laptop's public key to ~/.ssh/authorized_keys
sshd                                 # listens on port 8022
whoami                               # note this username, e.g. u0_a123
```

Recommended: Android settings → Apps → Termux → Battery → **Unrestricted**.
Otherwise Android may kill Termux in the background.

### 2. Laptop (Linux)

Connect to the phone's hotspot. Then check that SSH works:

```sh
ssh -p 8022 u0_a123@<phone-ip>        # phone-ip = your default gateway: ip route
```

**TCP variant:**
```sh
sudo apt install sshuttle             # the script installs it if missing
```

**UDP variant:** download `tun2socks` from its
[releases page](https://github.com/xjasonlyu/tun2socks/releases) into `./bin/`:
```sh
mkdir -p bin && cd bin
curl -LO https://github.com/xjasonlyu/tun2socks/releases/latest/download/tun2socks-linux-amd64.zip
unzip tun2socks-linux-amd64.zip && mv tun2socks-linux-amd64 tun2socks && chmod +x tun2socks
cd ..
```
(Use the `arm64` build on an ARM laptop. You can also just put `tun2socks` in your `$PATH`.)

---

## Usage

Run the scripts in a **real terminal**, because `sudo` will ask for your password.
They stay in the foreground; press **Ctrl-C** to stop and restore everything.

```sh
USER_=u0_a123 ./phone-tunnel-tcp.sh
# or
USER_=u0_a123 ./phone-tunnel-udp.sh
```

Settings (environment variables):

| Variable | Default | Meaning |
|---|---|---|
| `USER_` | *(required)* | Termux username (`whoami` in Termux) |
| `PHONE` | current default gateway | phone's IP on the hotspot |
| `PORT` | `8022` | Termux sshd port |
| `SOCKS_PORT` | `1080` | gost port on the phone (UDP variant) |

The TCP variant leaves common local ranges out of the tunnel: the hotspot LAN,
`172.16.0.0/12` (Docker), `192.168.122.0/24` (libvirt), `10.0.3.0/24` (LXC) and
`100.64.0.0/10` (Tailscale). Edit `EXCLUDES` in the script if you need others.

### Verify

```sh
ip route get 1.1.1.1                  # UDP variant: should say "dev tun0"
resolvectl status tun0                # UDP variant: DNS servers on tun0
dig @9.9.9.9 example.com              # UDP test: a direct UDP DNS query
curl https://cloudflare.com/cdn-cgi/trace
```

---

## Troubleshooting / lessons learned

| Symptom | Cause | Fix (already in the scripts) |
|---|---|---|
| gost never starts | `pkill -f 'gost …'` inside `ssh "…"` matches the remote shell's **own** command line, so it kills itself before starting gost | track gost with a pidfile (`$PREFIX/tmp/gost.pid`) |
| tun2socks prints its usage text and exits | it uses GNU-style flags: `-device` is parsed as `-d evice` | use `--device`, `--proxy`, `--interface`, `--loglevel warn` |
| Tunnel is up but "no internet" | `tun0` had no IP address, so systemd-resolved gave it no DNS scope. With Wi-Fi DNS turned off, nothing could resolve | give `tun0` an address (`198.18.0.1/15`, a range reserved for testing) |
| `sudo: a terminal is required` | the script was started without a TTY (for example from an IDE or agent shell) | run it in a normal terminal |
| Tunnel dies after a while | Android killed Termux | battery: Unrestricted; the scripts also take a wake lock |
| Some site fails over IPv6 | IPv6 is deliberately off during the session | expected; normal apps fall back to IPv4 |

## Security notes

- **TCP variant:** everything between laptop and phone is encrypted inside SSH.
- **UDP variant:** the SOCKS5 link between laptop and phone is **not encrypted**.
  It's protected only by your hotspot's Wi-Fi encryption and a random per-session
  password. gost listens on all of the phone's IPv4 addresses while it runs, so use
  it only on a hotspot you control.

## License

MIT. See [LICENSE](LICENSE). Educational use only, as described above.
