# phone-tunnel

Route **all** of a Linux laptop's internet traffic (**TCP, UDP and DNS**) through an
Android phone running [Termux](https://termux.dev), while the laptop is connected to
the phone's Wi-Fi hotspot. The phone opens every connection itself, from inside
Termux. **No root on the phone is required.**

> ## ⚠️ For study purposes only
>
> This project is a learning exercise in Linux networking: SOCKS5 with UDP ASSOCIATE,
> TUN devices, routing metrics and DNS with systemd-resolved. It is provided as is,
> with no warranty.
>
> Many mobile carriers' terms of service restrict or charge separately for hotspot
> or tethering use. **You alone are responsible for making sure that using this on
> your network and plan is allowed.** Don't use it to break any contract, policy
> or law.

---

## How it works

```
 laptop apps ──► default route ──► tun0 ──► tun2socks ──SOCKS5 (TCP + UDP ASSOCIATE)──► gost (in Termux) ──► internet
```

1. **Phone:** the script connects to Termux's `sshd` and starts
   [`gost`](https://github.com/ginuerzh/gost), a SOCKS5 server that supports
   **UDP ASSOCIATE**. It's protected by a random password generated fresh each run.
   SSH is only used to start and stop gost; the traffic itself doesn't go through SSH.
2. **Laptop:** it creates a TUN interface `tun0` with the address `198.18.0.1/15`
   and runs [`tun2socks`](https://github.com/xjasonlyu/tun2socks) on it. tun2socks
   turns every TCP and UDP packet arriving on `tun0` into SOCKS5 requests to gost.
3. **Routing:** it adds a default route through `tun0` with a lower metric than the
   Wi-Fi route. The hotspot subnet's own link route is more specific, so traffic to
   the phone itself (including the SOCKS5 connection) still goes directly over Wi-Fi.
   tun2socks is also bound to the Wi-Fi interface (`--interface`) so its traffic can't
   loop back into the tunnel.
4. **DNS:** it sets systemd-resolved to use public resolvers (1.1.1.1 and 8.8.8.8) on
   `tun0` with the catch-all domain `~.`, and removes the Wi-Fi link's DNS default
   route. That way every DNS lookup goes through the tunnel.
5. **IPv6 is disabled on the Wi-Fi interface** while the tunnel runs. Only IPv4 is
   tunneled. Without this, IPv6 traffic would go around the tunnel, because many
   carriers hand out public IPv6 addresses on the hotspot.
6. **`termux-wake-lock`** is run on the phone so Android doesn't suspend Termux.
7. **Ctrl-C stops the tunnel cleanly:** the script removes the route, `tun0` and DNS
   overrides, turns IPv6 back on, stops gost and releases the wake lock.

### Why not just `ssh -D` or sshuttle?

SSH can only forward TCP streams. OpenSSH's built-in SOCKS proxy (`ssh -D`) doesn't
support UDP ASSOCIATE, and sshuttle only carries TCP and DNS. For QUIC/HTTP3, games,
VoIP, WireGuard and so on, you need a SOCKS5 server that relays UDP. That's why this
uses gost.

---

## Requirements

- **Laptop:** Linux with systemd-resolved, `iproute2`, `sudo`, and the `tun2socks` binary
- **Phone:** Termux with `openssh` and `gost`

## Setup

### 1. Phone (Termux)

Install Termux, preferably from F-Droid; the Play Store build is outdated. Then:

```sh
pkg update
pkg install openssh gost
passwd                               # or add your laptop's public key to ~/.ssh/authorized_keys
sshd                                 # listens on port 8022
whoami                               # note this username, e.g. u0_a123
```

Recommended: Android settings → Apps → Termux → Battery → **Unrestricted**.
Otherwise Android may kill Termux in the background.

### 2. Laptop (Linux)

Connect to the phone's hotspot. Then check that SSH works, ideally with key-based
login so the script doesn't ask for a password several times:

```sh
ssh -p 8022 u0_a123@<phone-ip>        # phone-ip = your default gateway: ip route
```

Download `tun2socks` from its [releases page](https://github.com/xjasonlyu/tun2socks/releases)
into `./bin/`:

```sh
mkdir -p bin && cd bin
curl -LO https://github.com/xjasonlyu/tun2socks/releases/latest/download/tun2socks-linux-amd64.zip
unzip tun2socks-linux-amd64.zip && mv tun2socks-linux-amd64 tun2socks && chmod +x tun2socks
cd ..
```

(Use the `arm64` build on an ARM laptop. You can also just put `tun2socks` in your `$PATH`.)

---

## Usage

Run it in a **real terminal**, because `sudo` will ask for your password. It stays in
the foreground; press **Ctrl-C** to stop and restore everything.

```sh
USER_=u0_a123 ./phone-tunnel.sh
```

Settings (environment variables):

| Variable | Default | Meaning |
|---|---|---|
| `USER_` | *(required)* | Termux username (`whoami` in Termux) |
| `PHONE` | current default gateway | phone's IP on the hotspot |
| `PORT` | `8022` | Termux sshd port |
| `SOCKS_PORT` | `1080` | gost port on the phone |

### Verify

```sh
ip route get 1.1.1.1                  # should say "dev tun0"
resolvectl status tun0                # DNS servers 1.1.1.1 / 8.8.8.8 on tun0
dig @9.9.9.9 example.com              # UDP test: a direct UDP DNS query
curl https://cloudflare.com/cdn-cgi/trace
```

On the phone, `$PREFIX/tmp/gost.log` shows the proxied connections. UDP sessions
appear as `[socks5-udp] … associated on …`.

---

## Troubleshooting / lessons learned

| Symptom | Cause | Fix (already in the script) |
|---|---|---|
| gost never starts | `pkill -f 'gost …'` inside `ssh "…"` matches the remote shell's **own** command line, so it kills itself before starting gost | track gost with a pidfile (`$PREFIX/tmp/gost.pid`) |
| tun2socks prints its usage text and exits | it uses GNU-style flags: `-device` is parsed as `-d evice` | use `--device`, `--proxy`, `--interface`, `--loglevel warn` |
| Tunnel is up but "no internet" | `tun0` had no IP address, so systemd-resolved gave it no DNS scope. With Wi-Fi DNS turned off, nothing could resolve | give `tun0` an address (`198.18.0.1/15`, a range reserved for testing) |
| `sudo: a terminal is required` | the script was started without a TTY (for example from an IDE or agent shell) | run it in a normal terminal |
| Tunnel dies after a while | Android killed Termux | battery: Unrestricted; the script also takes a wake lock |
| Some site fails over IPv6 | IPv6 is deliberately off during the session | expected; normal apps fall back to IPv4 |

## Security notes

- The SOCKS5 link between laptop and phone is **not encrypted**. It's protected only
  by your hotspot's Wi-Fi encryption and a random per-session password.
- gost listens on all of the phone's IPv4 addresses while the tunnel runs, so use it
  only on a hotspot you control.

## License

MIT. See [LICENSE](LICENSE). Educational use only, as described above.
