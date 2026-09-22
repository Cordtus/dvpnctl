# dvpnctl

A small controller for the [Sentinel](https://sentinel.co/) dVPN network. It
wraps the official `sentinel-dvpncli` to give you:

- **Full-tunnel WireGuard** — all traffic goes through the node (`0.0.0.0/0`).
- **Kill switch** — if the tunnel drops, host traffic is dropped, not leaked.
- **Stays up until you turn it off** — the tunnel is owned by a systemd unit
  with restart-on-failure.
- **One-command endpoint switching** — list cheapest/fastest nodes and jump
  between them.
- **Speed-probed selection** — `up best` measures real throughput through the
  top candidates before committing, and keeps the fastest.
- **Automatic session cleanup** — stale/duplicate on-chain sessions are
  cancelled and a healthy one reused on each connect.

No dependency on [MathNodes/meile](https://github.com/MathNodes/meile); the only
third-party component is the official Sentinel CLI.

## Requirements

- Linux with **systemd** and **WireGuard** (`wg`, `wg-quick`).
- **Python 3** with **PyYAML**.
- `iptables`/`ip6tables` (kill switch) and `openresolv` (`resolvconf`).
- **sentinel-dvpncli v5** — the installer obtains it (preinstalled → release →
  source build). Building from source needs **Go ≥ 1.25** and `git`.

## Install

```bash
sudo ./install.sh <your-username>
```

This obtains the engine, symlinks `/usr/local/bin/dvpnctl` into this repo,
installs a systemd unit that owns the tunnel as root, copies your wallet key into
a root-only keyring for the unit, points NetworkManager at `openresolv` (see
[DNS](#dns-and-wg-quick)), and adds a sudoers rule so `up|down|switch` need no
password.

## Usage

```bash
dvpnctl init          # create the wallet (once); saves a mnemonic backup
dvpnctl fund          # show the address to send DVPN to
dvpnctl nodes         # list usable WireGuard endpoints by price/speed
dvpnctl up best       # start a session + full tunnel + kill switch
dvpnctl switch kfmg   # jump to a better endpoint
dvpnctl status        # tunnel, session, balance
dvpnctl verify        # prove traffic is tunneled (routing, firewall, exit IP)
dvpnctl down          # deactivate (cancels the session, refunds unused deposit)
```

Node selectors accepted anywhere: a list index (`3`), a moniker substring
(`kfmg`), a full `sentnode1…` address, or `best`.

> ⚠️ `dvpnctl init` writes your mnemonic to
> `~/.config/dvpnctl/wallet-backup.json` (mode 600). Move it somewhere safe —
> it is the only way to recover funds. If you move it away, `dvpnctl init`
> prompts for the mnemonic and recreates it (verified against the wallet
> address); re-run `sudo ./install.sh <user>` afterwards so the root service
> keyring is seeded.

## Node selection

**Source.** Active nodes are pulled from the chain (`query nodes --status
active`), filtered to `service_type == wireguard` and to nodes that quote a
`udvpn` price. Self-reported fields read: advertised `downlink`, `uplink`,
`peers`, location, and gigabyte/hourly pricing.

**Shortlist.** Nodes are ranked cheapest-first, then by advertised downlink. A
node is eligible for auto-selection if it is at or below `max_price_per_gb`
(15 DVPN/GB), has at most `max_peers` (60) peers, and is not in the temporary
watchdog exclusion list.

**Advertised pick.** `best_node` takes the highest advertised downlink from the
eligible set, with fallbacks: if nothing meets price/peer limits, drop the
limits; if nothing has GB pricing, fall back to time-priced nodes; last resort,
ignore exclusions.

**Measured pick.** `up best` takes the top `speed_probe_count` (3) candidates
from the shortlist, connects to each for real, downloads a known-size payload
through the tunnel, and keeps the fastest measured. Losers are cancelled and
their deposits refunded. Measurements are cached for `speed_cache_ttl` (24h),
and a fresh cache entry is reused rather than re-probed.

**Persistent signals.** Measured throughput (`speeds.json`), watchdog exclusions
(`excluded.json`) for nodes that failed health probes, and a cached ranking
(`nodes.order`) backing numeric selectors.

- `--no-probe` takes the first advertised-best node without measuring.
- A node's advertised `downlink` is only a hint; the probe measures the actual
  end-to-end path. Each probe costs a session start + cancel (a couple of
  transactions), so keep `speed_probe_count` small.
- Tune `speed_probe_count`, `speed_test_url`, `speed_test_timeout`,
  `speed_cache_ttl`, `max_price_per_gb`, and `max_peers` in the config.

## Automatic failover

`dvpnctl watch` probes through the tunnel and, after `watch_fail_threshold`
consecutive failures, excludes the current node and reconnects to the best
remaining one. Enable it as a timer (opt-in):

```bash
sudo systemctl enable --now dvpnctl-watch.timer   # probes every 30s
```

It is a no-op when the tunnel is down. A failed node stays excluded for
`watch_exclude_ttl` seconds. Tune `watch_url`, `watch_timeout`,
`watch_fail_threshold`, and `watch_exclude_ttl` in the config.

## Kill switch

The Sentinel client writes a `wg-quick` config with `AllowedIPs = 0.0.0.0/0,
::/0`. Because that includes a default route, the SDK emits `PostUp`/`PreDown`
iptables rules that **DROP all output not leaving the WireGuard interface** (and
ACCEPT the excluded subnets); `wg-quick down` removes them. Nothing is
hand-rolled. With `exclude_lan: true` (default) loopback and RFC1918 stay
reachable; set it `false` for a strict full tunnel.

## DNS and wg-quick

`wg-quick` updates DNS via `resolvconf` (openresolv). If NetworkManager manages
`/etc/resolv.conf` itself, openresolv refuses to overwrite it and wg-quick aborts
with `signature mismatch`; the installer sets `rc-manager=resolvconf` in
`/etc/NetworkManager/conf.d/90-dvpnctl-resolvconf.conf` to prevent that. To
revert: delete that file and run `nmcli general reload dns-rc`.

## Configuration

Tunables live in `~/.config/dvpnctl/config.json` (created on first use; override
the directory with `DVPNCTL_CONFIG_DIR`). Defaults:

```json
{
  "rpc": "https://sentinel-rpc.polkachu.com:443",
  "chain_id": "sentinelhub-2",
  "keyring_backend": "os",
  "key_name": "main",
  "cli_home": "/home/<you>/.sentinel-dvpncli",
  "session_gigabytes": 5,
  "session_hours": 0,
  "max_price_per_gb": 15.0,
  "max_peers": 60,
  "unit_name": "dvpnctl.service",
  "root_home": "/var/lib/dvpnctl",
  "iface": "wg0",
  "exclude_lan": true,
  "watch_url": "https://api.ipify.org",
  "watch_timeout": 8,
  "watch_fail_threshold": 3,
  "watch_exclude_ttl": 3600,
  "speed_probe_count": 3,
  "speed_test_url": "https://speed.cloudflare.com/__down?bytes=25000000",
  "speed_test_timeout": 20,
  "speed_cache_ttl": 86400
}
```

- `session_gigabytes: 0` switches to time-based sessions via `session_hours`.
- `max_price_per_gb` / `max_peers` bound the nodes `nodes`/`best` consider.
- `iface` is the WireGuard interface name; if you change it after install,
  rerun `install.sh`.

## Costs and safety

- Starting a session **escrows** `price × gigabytes` DVPN on-chain (cheapest
  WireGuard nodes are currently ~12.5 DVPN/GB). The rest of the wallet is
  untouched — funds are never sent to the node up front.
- On `down` (or session timeout) the node is paid only for measured usage and
  **`deposit − usage` is refunded**. `dvpnctl down` prints a one-line report for
  the session it cancels: data used (down/up), cost, and the expected refund.
- The most a misbehaving node can take is one session's deposit. Keep
  `session_gigabytes` small to cap that, and cycle sessions rather than opening
  one huge one.

## Files

| Path | Purpose |
|---|---|
| `dvpnctl` | the controller (Python 3) |
| `install.sh` | one-time root install |
| `systemd/dvpnctl.service` | unit that owns the tunnel |
| `systemd/dvpnctl-watch.{service,timer}` | optional failover watchdog |
| `~/.config/dvpnctl/config.json` | tunables |
| `~/.config/dvpnctl/wallet-backup.json` | mnemonic — keep safe |

## License

MIT. See [LICENSE](LICENSE).
