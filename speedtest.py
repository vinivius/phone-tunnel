#!/usr/bin/env python3
"""Measure latency, UDP DNS and throughput, through the tunnel or directly over Wi-Fi.

  ./speedtest.py                       # normal routing (through the tunnel when it's up)
  ./speedtest.py --direct wlan0        # bypass the tunnel: bind every socket to the Wi-Fi interface
                                       # (needs the kill switch off: sudo phone-tunnel off)

Uses Cloudflare's speed-test endpoints (speed.cloudflare.com). Needs curl.
Each throughput sample is time-boxed (--max-time, default 15 s), so slow links still give a number.
Worst case it transfers 3 x 25 MB down + 3 x 10 MB up.
"""
import argparse, json, os, random, socket, statistics, struct, subprocess, sys, time

HOST = "speed.cloudflare.com"


MAX_TIME = 15


def curl(args, direct):
    cmd = ["curl", "-sS", "-o", "/dev/null", "--max-time", str(MAX_TIME)]
    if direct:
        cmd += ["--interface", direct]
    p = subprocess.run(cmd + args, capture_output=True, text=True)
    if p.returncode not in (0, 28):   # 28 = hit --max-time: fine, we measure what got through
        raise RuntimeError(p.stderr.strip())
    return p.stdout


def mbps(out):  # "<bytes> <seconds>" -> Mbit/s
    nbytes, secs = out.split()
    return float(nbytes) * 8 / float(secs) / 1e6


def tls_rtt(direct, n):
    """Median TLS 1.3 handshake time (one full round trip to the server).
    Not the TCP connect time: tun2socks answers the TCP handshake locally, so through the
    tunnel that number would be ~0 ms and meaningless."""
    ts = []
    for _ in range(n):
        connect, app = map(float, curl(["--tlsv1.3", "-w", "%{time_connect} %{time_appconnect}",
                                        f"https://{HOST}/__down?bytes=0"], direct).split())
        ts.append((app - connect) * 1000)
    return statistics.median(ts)


def download(direct, nbytes, n):
    return [mbps(curl(["-w", "%{size_download} %{time_total}", f"https://{HOST}/__down?bytes={nbytes}"], direct))
            for _ in range(n)]


def upload(direct, nbytes, n):
    payload = "/tmp/phone-tunnel-speedtest.bin"
    with open(payload, "wb") as f:
        f.write(os.urandom(nbytes))
    try:
        return [mbps(curl(["-w", "%{size_upload} %{time_total}", "-X", "POST", "--data-binary", f"@{payload}",
                           f"https://{HOST}/__up"], direct)) for _ in range(n)]
    finally:
        os.unlink(payload)


def udp_dns(direct, n, server="1.1.1.1"):
    """n DNS queries over UDP; returns (median RTT ms, loss %)."""
    rtts, lost = [], 0
    for i in range(n):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        if direct:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, direct.encode())
        s.settimeout(2)
        qid = random.randrange(65536)
        name = f"t{random.randrange(10**9)}.example.com"   # unique name: no resolver cache hit
        q = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
        q += b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0" + struct.pack(">HH", 1, 1)
        t0 = time.perf_counter()
        try:
            s.sendto(q, (server, 53))
            while True:
                d, _ = s.recvfrom(2048)
                if d[:2] == struct.pack(">H", qid):
                    rtts.append((time.perf_counter() - t0) * 1000)
                    break
        except socket.timeout:
            lost += 1
        finally:
            s.close()
        time.sleep(0.05)
    return (statistics.median(rtts) if rtts else None), 100 * lost / n


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--direct", metavar="IFACE", help="bind to this interface (bypass the tunnel)")
    ap.add_argument("--label", default=None)
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--down-mb", type=int, default=25)
    ap.add_argument("--up-mb", type=int, default=10)
    ap.add_argument("--max-time", type=int, default=15, help="seconds per throughput sample")
    ap.add_argument("--latency-only", action="store_true", help="skip download/upload")
    ap.add_argument("--json", action="store_true", help="print one JSON line instead of a table")
    a = ap.parse_args()
    global MAX_TIME
    MAX_TIME = a.max_time

    label = a.label or ("direct" if a.direct else "tunnel")
    print(f"[{label}] measuring...", file=sys.stderr)
    r = {"label": label, "time": time.strftime("%Y-%m-%d %H:%M:%SZ", time.gmtime())}
    r["tls_rtt_ms"] = round(tls_rtt(a.direct, 10), 1)
    dns_ms, loss = udp_dns(a.direct, 30)
    r["udp_dns_ms"] = round(dns_ms, 1) if dns_ms else None
    r["udp_loss_pct"] = round(loss, 1)
    if a.latency_only:
        print(json.dumps(r) if a.json else "\n".join(f"{k:16} {v}" for k, v in r.items()))
        return
    d = download(a.direct, a.down_mb * 10**6, a.runs)
    u = upload(a.direct, a.up_mb * 10**6, a.runs)
    r["down_mbps"] = round(statistics.median(d), 2)
    r["up_mbps"] = round(statistics.median(u), 2)
    r["down_samples"] = [round(x, 2) for x in d]
    r["up_samples"] = [round(x, 2) for x in u]

    if a.json:
        print(json.dumps(r))
    else:
        for k, v in r.items():
            print(f"{k:16} {v}")


if __name__ == "__main__":
    main()
