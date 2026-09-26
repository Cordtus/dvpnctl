# dvpnctl

A small controller for the [Sentinel](https://sentinel.co/) dVPN network. It
wraps the official `sentinel-dvpncli` to give you:

- **Full tunnel** — all traffic goes through the node (`0.0.0.0/0`).
- **Kill switch** — if the tunnel drops, host traffic is dropped, not leaked.
- **Stays up until you turn it off** — a systemd unit owns the tunnel and
  restarts it on failure.
- **Fastest-node selection** — `up best` measures real speed through the top
  candidates and keeps the quickest.
- **Easy switching and cleanup** — switch endpoints in one command; stale
  on-chain sessions are cancelled and recycled automatically.
- **Optional auto-failover** — a timer probes the tunnel and moves to a new node
  if it stops working.

## Requirements

- Linux with **systemd** and **WireGuard** (`wg`, `wg-quick`).
- **Python 3** with **PyYAML**.
- `iptables`/`ip6tables` (kill switch), `openresolv` (`resolvconf`), `curl`.

The installer obtains **sentinel-dvpncli v5** for you (a source build, if it has
to fall back to one, also needs `go` and `git`).

## Setup

Two commands, in this order:

```bash
git clone https://github.com/Cordtus/dvpnctl && cd dvpnctl
sudo ./install.sh "$USER"   # engine, unit, sudoers, DNS
dvpnctl init                # wallet + service keyring (one sudo prompt)
dvpnctl doctor              # check everything is ready
dvpnctl fund                # send DVPN to the printed address
dvpnctl up best             # connect
```

Keep the repo in place — `/usr/local/bin/dvpnctl` points into it.

`dvpnctl doctor` is safe to run any time; it reports each prerequisite as
`ok`, `warn`, or `FAIL` with the command to fix it.

> ⚠️ `init` writes your mnemonic to `~/.config/dvpnctl/wallet-backup.json`
> (mode 600). Keep it in place until `doctor` reports ready, then move it
> somewhere safe — it is the only way to recover funds.

## Commands

```bash
dvpnctl up best       # connect
dvpnctl switch kfmg   # move to a better endpoint
dvpnctl status        # connection, session, balance
dvpnctl down          # disconnect (cancels the session, refunds unused deposit)
```

| Command | What it does |
|---|---|
| `init` | Create the wallet and seed the service keyring. |
| `doctor` | Check setup readiness and print what is missing. |
| `address` / `balance` | Print the wallet address / DVPN balance. |
| `fund` | Show the address to fund and a suggested amount. |
| `nodes [-r] [-c CC] [-a]` | List WireGuard nodes by price. `-r` refresh, `-c` filter by country, `-a` ignore the price cap. |
| `best` | Print the auto-picked node. |
| `up [node] [--no-probe] [-g GB] [-H H]` | Connect. With no node it probes for the fastest; `--no-probe` takes the advertised best. `-g`/`-H` set the session size. |
| `down [--keep-session]` | Disconnect and cancel the session (refunding unused deposit); `--keep-session` keeps it. |
| `switch <node>` | Move to another endpoint. |
| `status` | Show connection, session, and balance. |
| `verify` | Prove traffic is actually tunneled. |
| `watch` | One failover health check (run by the timer). |

A node can be given as a list index (`3`), a moniker substring (`kfmg`), a full
`sentnode1…` address, or `best`.

## Node selection

Nodes are pulled from the chain, limited to WireGuard endpoints with a price,
ranked cheapest first. `up best` then connects to the top few (`speed_probe_count`,
default 3), measures real throughput through each, and keeps the fastest;
losers are cancelled and refunded. Measurements are cached for a day, so repeat
runs skip known nodes. `--no-probe` skips measuring and takes the advertised
best.

`best` picks the highest advertised downlink within `max_price_per_gb` and
`max_peers`; the speed probe applies the price cap only.

## Automatic failover

`dvpnctl watch` probes the tunnel and, after a few failures, excludes the
current node and reconnects to the best remaining one. It is a no-op when the
tunnel is down. Enable the timer (opt-in):

```bash
sudo systemctl enable --now dvpnctl-watch.timer   # probes every 30s
```

Tune it with `watch_url`, `watch_timeout`, `watch_fail_threshold`, and
`watch_exclude_ttl`.

## Kill switch

The Sentinel client writes the `wg-quick` config and its `iptables` rules:
everything not leaving the WireGuard interface is **dropped**, and
`wg-quick down` removes the rules. `exclude_lan: true` (default) keeps loopback
and your LAN reachable; set it `false` for a strict full tunnel.
`dvpnctl verify` checks these rules and the routing table.

## DNS

`wg-quick` updates DNS via `openresolv`. If NetworkManager owns
`/etc/resolv.conf`, wg-quick fails with `signature mismatch`; the installer
configures NetworkManager to avoid this. To revert, delete
`/etc/NetworkManager/conf.d/90-dvpnctl-resolvconf.conf` and run
`nmcli general reload dns-rc`.

## Configuration

Tunables live in `~/.config/dvpnctl/config.json` (override the directory with
`DVPNCTL_CONFIG_DIR`).

| Key | Default | Meaning |
|---|---|---|
| `rpc` | polkachu | Primary RPC endpoint; public fallbacks are tried automatically. |
| `keyring_backend` | `os` | User-side keyring backend. |
| `key_name` | `main` | Key name in the keyring. |
| `cli_home` | `~/.sentinel-dvpncli` | Engine data directory. |
| `session_gigabytes` | `5` | Session size. Set `0` to use `session_hours` instead. |
| `session_hours` | `0` | Time-based session length. |
| `max_price_per_gb` | `15.0` | DVPN/GB ceiling for node selection. |
| `max_peers` | `60` | Peer ceiling for node selection. |
| `unit_name` | `dvpnctl.service` | systemd unit that owns the tunnel. |
| `root_home` | `/var/lib/dvpnctl` | Root-side home for the unit keyring. |
| `iface` | `wg0` | WireGuard interface name. Change only with a reinstall. |
| `exclude_lan` | `true` | Keep loopback + LAN out of the tunnel. |
| `node` | — | Last selected node, reused when `up` is given no node. |
| `watch_url` | `https://api.ipify.org` | Fetched through the tunnel to test liveness. |
| `watch_timeout` | `8` | Seconds per health probe. |
| `watch_fail_threshold` | `3` | Consecutive failures before failing over. |
| `watch_exclude_ttl` | `3600` | Seconds a failed node stays excluded. |
| `speed_probe_count` | `3` | Candidates to speed-test before committing. |
| `speed_test_url` | cloudflare | Payload downloaded to measure throughput. |
| `speed_test_timeout` | `20` | Seconds allowed per download. |
| `speed_cache_ttl` | `86400` | Seconds a measured speed stays usable. |

## Files

| Path | Purpose |
|---|---|
| `dvpnctl` | the controller (Python 3) |
| `install.sh` | one-time root install |
| `systemd/dvpnctl.service` | unit that owns the tunnel |
| `systemd/dvpnctl-watch.{service,timer}` | optional failover timer |
| `~/.config/dvpnctl/config.json` | tunables |
| `~/.config/dvpnctl/wallet-backup.json` | mnemonic — keep safe |
| `~/.config/dvpnctl/` | session, node cache, measured speeds, watchdog state |
| `/var/lib/dvpnctl` | root-only keyring used by the tunnel unit |

## Costs and safety

- Connecting **escrows** `price × gigabytes` DVPN on-chain (currently ~12.5
  DVPN/GB). Funds are never sent to the node up front.
- On `down` the node is paid only for measured usage, and
  **`deposit − usage` is refunded**. `dvpnctl down` prints the usage, cost, and
  expected refund.
- The most a misbehaving node can take is one session's deposit. Keep
  `session_gigabytes` small to cap it.

## License

MIT. See [LICENSE](LICENSE).
