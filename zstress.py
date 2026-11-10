#!/usr/bin/env python3
"""
zstress.py - stress tests for the Zabbix + Grafana lab stack.

Run from the stack folder on the Docker machine (no installs needed):

  docker run --rm -it --network zabbix-grafana_default --env-file .env \
    -v "$PWD/zstress.py:/zstress.py:ro" python:3.12-alpine \
    python /zstress.py <command> [options]

Commands:
  setup    create test hosts with trapper items in Zabbix
             --hosts 50 --items 20                (1,000 items)
  zabbix   push values into Zabbix as fast as the target rate
             --rate 1000 --duration 600 --threads 4
  grafana  fire dashboard-style queries at Grafana
             --concurrency 10 --duration 300
  cleanup  delete all test hosts and the test group

Test data is kept for 1 day only and never creates trends, so the
database can't grow without limit. Run "cleanup" when you're done.
"""
import argparse, base64, json, os, random, socket, statistics, struct
import sys, threading, time, urllib.request, urllib.error

ZBX_API = "http://zabbix-web:8080/api_jsonrpc.php"
ZBX_TRAPPER = ("zabbix-server", 10051)
GRAFANA = "http://grafana:3000"
GROUP = "Stress test"
PREFIX = "stress-host-"


def env(name, default=None):
    v = os.environ.get(name, default)
    if v is None:
        sys.exit(f"Missing {name}. Did you pass --env-file .env ?")
    return v


# ------------------------------------------------------------------ Zabbix API
class Zabbix:
    def __init__(self):
        self.token = None
        self.token = self.call("user.login", {"username": env("ZBX_ADMIN_USER"),
                                              "password": env("ZBX_ADMIN_PASSWORD")})

    def call(self, method, params):
        body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode()
        req = urllib.request.Request(ZBX_API, body, {"Content-Type": "application/json-rpc"})
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        with urllib.request.urlopen(req, timeout=120) as r:
            out = json.load(r)
        if "error" in out:
            sys.exit(f"Zabbix API {method} failed: {out['error']}")
        return out["result"]

    def group_id(self, create=False):
        g = self.call("hostgroup.get", {"output": ["groupid"], "filter": {"name": [GROUP]}})
        if g:
            return g[0]["groupid"]
        if create:
            return self.call("hostgroup.create", {"name": GROUP})["groupids"][0]
        return None

    def test_hosts(self):
        gid = self.group_id()
        if not gid:
            return []
        return self.call("host.get", {"output": ["hostid", "host"], "groupids": [gid]})


def cmd_setup(a):
    z = Zabbix()
    gid = z.group_id(create=True)
    existing = {h["host"] for h in z.test_hosts()}
    made = 0
    for n in range(1, a.hosts + 1):
        name = f"{PREFIX}{n:03d}"
        if name in existing:
            continue
        hid = z.call("host.create", {"host": name, "groups": [{"groupid": gid}],
                                     "tags": [{"tag": "purpose", "value": "stress"}]})["hostids"][0]
        z.call("item.create", [{
            "hostid": hid, "name": f"Stress metric {i}", "key_": f"stress.metric[{i}]",
            "type": 2, "value_type": 0, "history": "1d", "trends": "0",
            "tags": [{"tag": "component", "value": "stress"}],
        } for i in range(1, a.items + 1)])
        made += 1
        print(f"\rcreated {made} hosts", end="", flush=True)
    print(f"\nDone: {a.hosts} hosts x {a.items} items = {a.hosts * a.items} trapper items "
          f"in group '{GROUP}'.")
    print("Wait about a minute for the Zabbix server to load them before running 'zabbix'.")


def cmd_cleanup(a):
    z = Zabbix()
    hosts = z.test_hosts()
    for i in range(0, len(hosts), 50):
        z.call("host.delete", [h["hostid"] for h in hosts[i:i + 50]])
    gid = z.group_id()
    if gid:
        z.call("hostgroup.delete", [gid])
    print(f"Deleted {len(hosts)} test hosts and the '{GROUP}' group.")


# ------------------------------------------------------------------ value flood
def send_batch(values):
    """Zabbix sender protocol: 'ZBXD\\x01' + 8-byte length + JSON."""
    payload = json.dumps({"request": "sender data", "data": values}).encode()
    packet = b"ZBXD\x01" + struct.pack("<Q", len(payload)) + payload
    with socket.create_connection(ZBX_TRAPPER, timeout=30) as s:
        s.sendall(packet)
        resp = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            resp += chunk
    body = json.loads(resp[13:].decode())
    info = body.get("info", "")
    # info looks like: "processed: 250; failed: 0; total: 250; seconds spent: 0.0012"
    parts = dict(p.split(": ") for p in info.split("; ") if ": " in p)
    return int(parts.get("processed", 0)), int(parts.get("failed", 0))


def cmd_zabbix(a):
    z = Zabbix()
    hosts = sorted(h["host"] for h in z.test_hosts())
    if not hosts:
        sys.exit("No test hosts found. Run 'setup' first.")
    items = z.call("item.get", {"output": ["key_"], "groupids": [z.group_id()],
                                "selectHosts": ["host"]})
    targets = [(i["hosts"][0]["host"], i["key_"]) for i in items]
    print(f"Sending to {len(targets)} items at a target of {a.rate} values/s "
          f"for {a.duration}s using {a.threads} threads.")

    stats = {"sent": 0, "ok": 0, "failed": 0, "errors": 0}
    lock = threading.Lock()
    stop = time.time() + a.duration
    batch = 250
    per_thread_rate = a.rate / a.threads

    def worker(tid):
        idx = tid
        next_t = time.time()
        while time.time() < stop:
            now = int(time.time())
            vals = []
            for _ in range(batch):
                h, k = targets[idx % len(targets)]
                idx += a.threads
                vals.append({"host": h, "key": k, "value": f"{random.uniform(0, 100):.3f}",
                             "clock": now})
            try:
                ok, failed = send_batch(vals)
                with lock:
                    stats["sent"] += len(vals); stats["ok"] += ok; stats["failed"] += failed
            except Exception as e:
                with lock:
                    stats["errors"] += 1
                if stats["errors"] < 5:
                    print(f"\n  send error: {e}")
            next_t += batch / per_thread_rate
            delay = next_t - time.time()
            if delay > 0:
                time.sleep(delay)

    threads = [threading.Thread(target=worker, args=(t,), daemon=True) for t in range(a.threads)]
    for t in threads:
        t.start()
    start, last_sent = time.time(), 0
    try:
        while any(t.is_alive() for t in threads):
            time.sleep(5)
            with lock:
                s = dict(stats)
            rate = (s["sent"] - last_sent) / 5
            last_sent = s["sent"]
            print(f"[{int(time.time() - start):4d}s] {rate:7.0f} values/s   "
                  f"accepted {s['ok']}  rejected {s['failed']}  connection errors {s['errors']}")
    except KeyboardInterrupt:
        print("\nStopping...")
    elapsed = time.time() - start
    print(f"\nTotal: {stats['sent']} values in {elapsed:.0f}s = {stats['sent'] / elapsed:.0f} values/s "
          f"(target {a.rate}). Accepted {stats['ok']}, rejected {stats['failed']}.")
    if stats["failed"]:
        print("Rejected values usually mean the server hasn't loaded the test items yet; "
              "wait a minute after 'setup'.")


# ------------------------------------------------------------------ Grafana queries
QUERIES = [  # (item tag, item pattern) - the same kinds of query the dashboard sends
    ("component: cpu", r"/^(VM|LXC) \[/"),
    ("component: memory", r"/^(VM|LXC) \[.*(used|usage)/i"),
    ("component: network", r"/^(VM|LXC) \[.*(incoming|outgoing)/i"),
    ("component: cpu", r"/^Node.*CPU, usage/i"),
    ("component: storage", r"/^Storage.*used/i"),
]
RANGES = ["now-1h", "now-6h", "now-24h", "now-7d"]


def grafana_query():
    tag, item = random.choice(QUERIES)
    body = {"from": random.choice(RANGES), "to": "now", "queries": [{
        "refId": "A", "datasource": {"type": "alexanderzobnin-zabbix-datasource", "uid": "zabbix"},
        "queryType": "0", "group": {"filter": "/.*/"}, "host": {"filter": "pve-cluster"},
        "application": {"filter": ""}, "itemTag": {"filter": tag}, "item": {"filter": item},
        "functions": [], "options": {"disableDataAlignment": True},
        "intervalMs": 60000, "maxDataPoints": 500}]}
    auth = base64.b64encode(f"{env('GRAFANA_ADMIN_USER')}:{env('GRAFANA_ADMIN_PASSWORD')}".encode()).decode()
    req = urllib.request.Request(f"{GRAFANA}/api/ds/query", json.dumps(body).encode(),
                                 {"Content-Type": "application/json", "Authorization": f"Basic {auth}"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=60) as r:
        out = json.load(r)
    err = out.get("results", {}).get("A", {}).get("error")
    if err:
        raise RuntimeError(err)
    return time.time() - t0


def pct(data, p):
    if not data:
        return 0.0
    data = sorted(data)
    return data[min(len(data) - 1, int(len(data) * p / 100))]


def cmd_grafana(a):
    try:
        grafana_query()
    except Exception as e:
        sys.exit(f"Test query failed before starting: {e}")
    print(f"Running {a.concurrency} simulated viewers for {a.duration}s against Grafana.")
    lat, errors, lock = [], [], threading.Lock()
    stop = time.time() + a.duration

    def viewer():
        while time.time() < stop:
            try:
                d = grafana_query()
                with lock:
                    lat.append(d)
            except Exception as e:
                with lock:
                    errors.append(str(e))
            time.sleep(random.uniform(0, a.think))

    threads = [threading.Thread(target=viewer, daemon=True) for _ in range(a.concurrency)]
    for t in threads:
        t.start()
    start, seen = time.time(), 0
    try:
        while any(t.is_alive() for t in threads):
            time.sleep(10)
            with lock:
                window, seen, errs = lat[seen:], len(lat), len(errors)
            print(f"[{int(time.time() - start):4d}s] {len(window) / 10:5.1f} queries/s   "
                  f"median {statistics.median(window) * 1000 if window else 0:6.0f} ms   "
                  f"p95 {pct(window, 95) * 1000:6.0f} ms   errors {errs}")
    except KeyboardInterrupt:
        print("\nStopping...")
    elapsed = time.time() - start
    print(f"\nTotal: {len(lat)} queries in {elapsed:.0f}s = {len(lat) / elapsed:.1f}/s, "
          f"{len(errors)} errors")
    if lat:
        print(f"Latency: median {statistics.median(lat) * 1000:.0f} ms, p95 {pct(lat, 95) * 1000:.0f} ms, "
              f"p99 {pct(lat, 99) * 1000:.0f} ms, max {max(lat) * 1000:.0f} ms")
    if errors:
        print(f"First error: {errors[0]}")


# ------------------------------------------------------------------ main
def main():
    p = argparse.ArgumentParser(description="Stress tests for the Zabbix + Grafana lab stack")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("setup");   s.add_argument("--hosts", type=int, default=50); s.add_argument("--items", type=int, default=20)
    z = sub.add_parser("zabbix");  z.add_argument("--rate", type=int, default=1000); z.add_argument("--duration", type=int, default=600); z.add_argument("--threads", type=int, default=4)
    g = sub.add_parser("grafana"); g.add_argument("--concurrency", type=int, default=10); g.add_argument("--duration", type=int, default=300); g.add_argument("--think", type=float, default=2.0, help="max pause between a viewer's queries (s)")
    sub.add_parser("cleanup")
    a = p.parse_args()
    {"setup": cmd_setup, "zabbix": cmd_zabbix, "grafana": cmd_grafana, "cleanup": cmd_cleanup}[a.cmd](a)


if __name__ == "__main__":
    main()
